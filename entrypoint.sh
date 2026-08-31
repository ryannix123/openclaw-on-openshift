#!/bin/bash
# =============================================================================
# OpenClaw entrypoint — OpenShift-compatible startup script
#
# Responsibilities:
#   1. Bootstrap OPENCLAW_CONFIG_DIR if this is a first run
#   2. Write a minimal .env from injected environment variables
#      (API key + gateway token come from an OpenShift Secret)
#   3. Apply any additional config via the OpenClaw CLI config set command
#   4. exec the gateway process (PID 1)
#
# Environment variables expected (injected by OpenShift Secret):
#   OPENCLAW_GATEWAY_TOKEN  — shared secret for the Control UI
#   OPENCLAW_AI_ENV_VAR     — name of the provider env var (e.g. ANTHROPIC_API_KEY)
#   <PROVIDER>_API_KEY      — the actual API key value
#
# Optional:
#   OPENCLAW_DISABLE_BONJOUR — set to 1 to disable mDNS (default: 1 in containers)
#   OPENCLAW_LOG_LEVEL       — debug | info | warn | error (default: info)
# =============================================================================

set -euo pipefail

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/opt/openclaw/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/opt/openclaw/workspace}"
ENV_FILE="${CONFIG_DIR}/.env"
INITIALIZED_FLAG="${CONFIG_DIR}/.initialized"

echo "[entrypoint] Starting OpenClaw gateway..."
echo "[entrypoint] Config dir:    ${CONFIG_DIR}  (HOME=${HOME})"
echo "[entrypoint] Workspace dir: ${WORKSPACE_DIR}"

# ---------------------------------------------------------------------------
# Ensure directories exist and are writable
# The PVC may have been freshly provisioned; subdirs may not exist yet
# ---------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}" "${WORKSPACE_DIR}"

# ---------------------------------------------------------------------------
# First-run bootstrap
# Write .env only if it doesn't already exist (idempotent across restarts)
# ---------------------------------------------------------------------------
if [[ ! -f "${INITIALIZED_FLAG}" ]]; then
    echo "[entrypoint] First run detected — bootstrapping config..."

    # Require gateway token
    if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
        echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
        echo "[entrypoint]        Generate one and store it in your OpenShift Secret." >&2
        exit 1
    fi

    # Write the .env file that OpenClaw reads at startup
    # Do NOT clobber if already present (e.g. manual edits persisted on PVC)
    if [[ ! -f "${ENV_FILE}" ]]; then
        cat > "${ENV_FILE}" <<EOF
# OpenClaw runtime environment — written by entrypoint.sh on first run
# This file is persisted on the config PVC. Edit carefully.

OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_DISABLE_BONJOUR=1
NODE_ENV=production
EOF
        echo "[entrypoint] Wrote ${ENV_FILE}"
    fi

    # Run the non-interactive onboard (skips interactive API key prompts;
    # keys are picked up from env vars injected by the OpenShift Secret)
    echo "[entrypoint] Running onboard (non-interactive, local mode)..."
    node /app/dist/index.js onboard \
        --mode local \
        --no-install-daemon \
        --yes 2>&1 || true
    # Note: --yes may not suppress all prompts on every OpenClaw version.
    # If the container hangs on onboard, set OPENCLAW_SKIP_ONBOARD=1 and
    # the block below will skip straight to the gateway start.

    echo "[entrypoint] First-run complete — core config applied after this block."

    touch "${INITIALIZED_FLAG}"
    echo "[entrypoint] Bootstrap complete."
else
    echo "[entrypoint] Config already initialized — skipping bootstrap."
fi

# ---------------------------------------------------------------------------
# Apply core gateway config on EVERY startup — not gated by the initialized
# flag. These calls are idempotent; running them again is safe.
#
# Why not inside the first-run block? If the config set failed silently on
# the first run (swallowed by || true), gateway.mode=local is never written
# and the gateway refuses to start with "Missing config" on every subsequent
# restart. Always applying it here ensures the mode is always set regardless
# of what happened on first boot.
# ---------------------------------------------------------------------------
# Write gateway config directly into openclaw.json via Node.js.
# openclaw config set requires the gateway to already be running,
# so we merge settings into the JSON file directly instead.
# OpenClaw reads this file at startup before accepting connections.
echo "[entrypoint] Writing gateway config to openclaw.json..."

ALLOWED_ORIGINS="[\"http://localhost:18789\",\"http://127.0.0.1:18789\""
if [[ -n "${OPENCLAW_PUBLIC_URL:-}" ]]; then
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS},\"${OPENCLAW_PUBLIC_URL}\""
    echo "[entrypoint] Including ${OPENCLAW_PUBLIC_URL} in controlUi.allowedOrigins"
fi
ALLOWED_ORIGINS="${ALLOWED_ORIGINS}]"
export ALLOWED_ORIGINS

node << JSEOF
const fs = require("fs");
// OpenClaw reads config from $HOME/.openclaw/openclaw.json by default.
// OPENCLAW_CONFIG_DIR is our env var for the PVC mount point — same location.
const cfgPath = (process.env.OPENCLAW_CONFIG_DIR || (process.env.HOME + "/.openclaw")) + "/openclaw.json";
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch(e) {}
cfg.gateway            = cfg.gateway            || {};
cfg.gateway.mode       = "local";
cfg.gateway.bind       = "lan";
cfg.gateway.auth       = cfg.gateway.auth       || {};
cfg.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN || cfg.gateway.auth.token;
cfg.gateway.controlUi  = cfg.gateway.controlUi  || {};
cfg.gateway.controlUi.allowedOrigins = JSON.parse(process.env.ALLOWED_ORIGINS);

// OpenClaw 2.0 requires trustedProxies when running behind a reverse proxy.
// On OpenShift the HAProxy router terminates TLS and forwards traffic to the
// pod, so the gateway sees the request's source IP as a cluster-internal
// address, not the real client. Without trustedProxies, OpenClaw 2.0 fails
// closed with "proxy_attribution_required" (anti-spoofing for X-Forwarded-*).
// We trust the pod/service network CIDRs the router forwards from. Auth stays
// token-based (not trusted-proxy mode); this only enables safe forwarded-header
// handling. Override with OPENCLAW_TRUSTED_PROXIES (JSON array) if your cluster
// uses non-default network ranges.
cfg.gateway.trustedProxies = JSON.parse(
  process.env.OPENCLAW_TRUSTED_PROXIES ||
  '["10.0.0.0/8","172.16.0.0/12","100.64.0.0/10"]'
);

// Set the default model from the OPENCLAW_DEFAULT_MODEL env var.
// This ensures the agent uses the provider configured via Ansible
// (e.g. anthropic/claude-sonnet-4-6) rather than whatever onboard picked.
const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  cfg.agents         = cfg.agents         || {};
  cfg.agents.defaults = cfg.agents.defaults || {};
  cfg.agents.defaults.model = cfg.agents.defaults.model || {};
  cfg.agents.defaults.model.primary = defaultModel;
  // Seed the allowlist so the model picker shows it immediately
  cfg.agents.defaults.models = cfg.agents.defaults.models || {};
  cfg.agents.defaults.models[defaultModel] = cfg.agents.defaults.models[defaultModel] || {};
  console.log("[entrypoint] Default model set to: " + defaultModel);
}

// ---------------------------------------------------------------------------
// Internal LLM (OpenAI-compatible) override
// When OPENCLAW_OPENAI_BASE_URL and OPENCLAW_OPENAI_MODEL are both set,
// register a custom "internal-llm" provider and make it the primary model.
// This lets users point at vLLM, Ollama, RHOAI KServe, or any other
// OpenAI-compatible endpoint without rebuilding the image.
// ---------------------------------------------------------------------------
const internalUrl   = process.env.OPENCLAW_OPENAI_BASE_URL || "";
const internalModel = process.env.OPENCLAW_OPENAI_MODEL    || "";
const internalKey   = process.env.OPENCLAW_OPENAI_API_KEY  || "ignored";

if (internalUrl && internalModel) {
  cfg.models                   = cfg.models                   || {};
  cfg.models.providers         = cfg.models.providers         || {};
  cfg.models.providers["internal-llm"] = {
    baseUrl: internalUrl,
    api:     "openai-completions",
    apiKey:  internalKey,
    models:  [{ id: internalModel }]
  };
  cfg.agents                              = cfg.agents                              || {};
  cfg.agents.defaults                     = cfg.agents.defaults                     || {};
  cfg.agents.defaults.model               = cfg.agents.defaults.model               || {};
  cfg.agents.defaults.model.primary       = "internal-llm/" + internalModel;
  cfg.agents.defaults.models              = cfg.agents.defaults.models              || {};
  cfg.agents.defaults.models["internal-llm/" + internalModel] =
    cfg.agents.defaults.models["internal-llm/" + internalModel] || {};
  console.log("[entrypoint] Internal LLM configured: " + internalUrl);
  console.log("[entrypoint] Primary model overridden to: internal-llm/" + internalModel);
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
console.log("[entrypoint] openclaw.json written.");
console.log(JSON.stringify({gateway: cfg.gateway, agents: cfg.agents}, null, 2));
JSEOF

# ---------------------------------------------------------------------------
# Apply channel configuration (idempotent on every start)
#
# The channel ConfigMap is mounted at $OPENCLAW_CHANNEL_CONFIG_PATH.
# It contains the channels.* config structure with ${ENV_VAR} placeholders
# that OpenClaw resolves at startup from the injected Secret env vars.
# We apply it every time (not just on first run) so that playbook changes
# take effect on pod restart without needing to delete the .initialized flag.
# ---------------------------------------------------------------------------
CHANNEL_CONFIG_PATH="${OPENCLAW_CHANNEL_CONFIG_PATH:-}"

if [[ -n "${CHANNEL_CONFIG_PATH}" && -f "${CHANNEL_CONFIG_PATH}" ]]; then
    echo "[entrypoint] Applying channel configuration from ${CHANNEL_CONFIG_PATH}..."

    # Read the JSON and pass it to config set as a single-path merge
    # openclaw config set --path channels --value '<json>' merges the
    # channels block into the live config without clobbering other keys.
    CHANNELS_JSON=$(node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('${CHANNEL_CONFIG_PATH}', 'utf8'));
        // Flatten to batch-json array: [{path, value}, ...]
        const items = Object.entries(cfg.channels || {}).map(([id, val]) => ({
            path: 'channels.' + id,
            value: val
        }));
        process.stdout.write(JSON.stringify(items));
    " 2>/dev/null) || true

    if [[ -n "${CHANNELS_JSON}" && "${CHANNELS_JSON}" != "[]" ]]; then
        node /app/dist/index.js config set --batch-json "${CHANNELS_JSON}" 2>&1 \
            && echo "[entrypoint] Channel config applied." \
            || echo "[entrypoint] WARNING: channel config set returned non-zero — check config syntax."
    else
        echo "[entrypoint] No channel entries found in config file — skipping."
    fi
else
    echo "[entrypoint] No channel config path set — running gateway-only (no messaging channels)."
fi

# ---------------------------------------------------------------------------
# Start the gateway (replaces this shell process as PID 1)
# ---------------------------------------------------------------------------
echo "[entrypoint] Launching OpenClaw gateway on port 18789..."
exec node /app/dist/index.js gateway --allow-unconfigured
