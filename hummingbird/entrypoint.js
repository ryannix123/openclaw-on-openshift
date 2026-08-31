// =============================================================================
// OpenClaw on OpenShift — Node.js Entrypoint
// File: hummingbird/entrypoint.js
//
// Distroless runtime has no shell, so the entrypoint must be a Node.js script.
// Mirrors the logic in ../entrypoint.sh for the UBI 10 variant.
//
// Responsibilities:
//   1. Ensure config and workspace directories exist
//   2. Bootstrap config on first run (write .env, run onboard)
//   3. Write openclaw.json on every start with gateway mode, bind, auth,
//      allowedOrigins, default model, and optional internal-LLM override
//   4. Apply channel configuration from ConfigMap if present
//   5. Spawn the gateway process and forward signals (SIGTERM/SIGINT)
//
// Environment variables (injected by OpenShift Secret + Deployment):
//   OPENCLAW_GATEWAY_TOKEN    — shared secret for the Control UI
//   OPENCLAW_CONFIG_DIR       — config PVC mount (/opt/openclaw/.openclaw)
//   OPENCLAW_WORKSPACE_DIR    — workspace PVC mount (/opt/openclaw/workspace)
//   OPENCLAW_PUBLIC_URL       — Route HTTPS URL added to allowedOrigins
//   OPENCLAW_DEFAULT_MODEL    — e.g. "anthropic/claude-sonnet-4-6"
//   OPENCLAW_OPENAI_BASE_URL  — optional: OpenAI-compatible endpoint URL
//   OPENCLAW_OPENAI_MODEL     — optional: model ID for the custom endpoint
//   OPENCLAW_OPENAI_API_KEY   — optional: API key (defaults to "ignored")
//   OPENCLAW_CHANNEL_CONFIG_PATH — path to channels-config.json ConfigMap
// =============================================================================

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";

const APP            = "/app/dist/index.js";
const CONFIG_DIR     = process.env.OPENCLAW_CONFIG_DIR    || "/opt/openclaw/.openclaw";
const WORKSPACE_DIR  = process.env.OPENCLAW_WORKSPACE_DIR || "/opt/openclaw/workspace";
const CONFIG_FILE    = join(CONFIG_DIR, "openclaw.json");
const ENV_FILE       = join(CONFIG_DIR, ".env");
const INIT_FLAG      = join(CONFIG_DIR, ".initialized");

const log  = (msg) => process.stdout.write(`[entrypoint] ${msg}\n`);
const warn = (msg) => process.stderr.write(`[entrypoint] WARNING: ${msg}\n`);
const die  = (msg) => { process.stderr.write(`[entrypoint] ERROR: ${msg}\n`); process.exit(1); };

// ---------------------------------------------------------------------------
// 1. Ensure directories exist
// ---------------------------------------------------------------------------
log("Starting OpenClaw gateway...");
log(`Config dir    : ${CONFIG_DIR}  (HOME=${process.env.HOME})`);
log(`Workspace dir : ${WORKSPACE_DIR}`);

mkdirSync(CONFIG_DIR,    { recursive: true });
mkdirSync(WORKSPACE_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// 2. First-run bootstrap
// ---------------------------------------------------------------------------
if (!existsSync(INIT_FLAG)) {
  log("First run detected — bootstrapping config...");

  const token = process.env.OPENCLAW_GATEWAY_TOKEN;
  if (!token) {
    die("OPENCLAW_GATEWAY_TOKEN is not set. Generate one and store it in your OpenShift Secret.");
  }

  if (!existsSync(ENV_FILE)) {
    writeFileSync(ENV_FILE, [
      "# OpenClaw runtime environment — written by entrypoint.js on first run",
      `OPENCLAW_GATEWAY_TOKEN=${token}`,
      "OPENCLAW_DISABLE_BONJOUR=1",
      "NODE_ENV=production",
      "",
    ].join("\n"));
    log(`Wrote ${ENV_FILE}`);
  }

  log("Running onboard (non-interactive, local mode)...");
  spawnSync("node", [APP, "onboard", "--mode", "local", "--no-install-daemon", "--yes"], {
    stdio: "inherit",
  });

  writeFileSync(INIT_FLAG, "");
  log("First-run bootstrap complete.");
} else {
  log("Config already initialized — skipping bootstrap.");
}

// ---------------------------------------------------------------------------
// 3. Write gateway config on every startup (idempotent)
// ---------------------------------------------------------------------------
log("Writing gateway config to openclaw.json...");

const allowedOrigins = [
  "http://localhost:18789",
  "http://127.0.0.1:18789",
];
const publicUrl = process.env.OPENCLAW_PUBLIC_URL || "";
if (publicUrl) {
  allowedOrigins.push(publicUrl);
  log(`Including ${publicUrl} in controlUi.allowedOrigins`);
}

let cfg = {};
try {
  cfg = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
} catch {
  // First run or missing file — start fresh
}

// Gateway settings
cfg.gateway                          = cfg.gateway                          || {};
cfg.gateway.mode                     = "local";
cfg.gateway.bind                     = "lan";
cfg.gateway.auth                     = cfg.gateway.auth                     || {};
cfg.gateway.auth.token               = process.env.OPENCLAW_GATEWAY_TOKEN || cfg.gateway.auth.token;
cfg.gateway.controlUi                = cfg.gateway.controlUi                || {};
cfg.gateway.controlUi.allowedOrigins = allowedOrigins;

// OpenClaw 2.0 requires trustedProxies when running behind a reverse proxy.
// On OpenShift the HAProxy router terminates TLS and forwards to the pod, so
// the gateway sees a cluster-internal source IP rather than the real client.
// Without this, OpenClaw 2.0 fails closed with "proxy_attribution_required".
// Auth stays token-based; this only enables safe X-Forwarded-* handling.
// Override with OPENCLAW_TRUSTED_PROXIES (JSON array) for non-default CIDRs.
cfg.gateway.trustedProxies = JSON.parse(
  process.env.OPENCLAW_TRUSTED_PROXIES ||
  '["10.0.0.0/8","172.16.0.0/12","100.64.0.0/10"]'
);

// Default model from ai_provider mapping
const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  cfg.agents                              = cfg.agents                              || {};
  cfg.agents.defaults                     = cfg.agents.defaults                     || {};
  cfg.agents.defaults.model               = cfg.agents.defaults.model               || {};
  cfg.agents.defaults.model.primary       = defaultModel;
  cfg.agents.defaults.models              = cfg.agents.defaults.models              || {};
  cfg.agents.defaults.models[defaultModel] = cfg.agents.defaults.models[defaultModel] || {};
  log(`Default model set to: ${defaultModel}`);
}

// ---------------------------------------------------------------------------
// Internal LLM (OpenAI-compatible) override
// When OPENCLAW_OPENAI_BASE_URL and OPENCLAW_OPENAI_MODEL are both set,
// register a custom "internal-llm" provider and make it the primary model.
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
    models:  [{ id: internalModel }],
  };
  cfg.agents                              = cfg.agents                              || {};
  cfg.agents.defaults                     = cfg.agents.defaults                     || {};
  cfg.agents.defaults.model               = cfg.agents.defaults.model               || {};
  cfg.agents.defaults.model.primary       = `internal-llm/${internalModel}`;
  cfg.agents.defaults.models              = cfg.agents.defaults.models              || {};
  cfg.agents.defaults.models[`internal-llm/${internalModel}`] =
    cfg.agents.defaults.models[`internal-llm/${internalModel}`] || {};
  log(`Internal LLM configured: ${internalUrl}`);
  log(`Primary model overridden to: internal-llm/${internalModel}`);
}

writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
log("openclaw.json written OK.");

// ---------------------------------------------------------------------------
// 4. Apply channel configuration (idempotent on every start)
// ---------------------------------------------------------------------------
const channelConfigPath = process.env.OPENCLAW_CHANNEL_CONFIG_PATH || "";
if (channelConfigPath && existsSync(channelConfigPath)) {
  log(`Applying channel configuration from ${channelConfigPath}...`);
  try {
    const channelCfg = JSON.parse(readFileSync(channelConfigPath, "utf8"));
    const batchJson  = Object.entries(channelCfg.channels || {}).map(([id, val]) => ({
      path:  `channels.${id}`,
      value: val,
    }));

    if (batchJson.length > 0) {
      const result = spawnSync(
        "node",
        [APP, "config", "set", "--batch-json", JSON.stringify(batchJson)],
        { stdio: "inherit" }
      );
      if (result.status === 0) {
        log("Channel config applied.");
      } else {
        warn("channel config set returned non-zero — check config syntax.");
      }
    } else {
      log("No channel entries found in config file — skipping.");
    }
  } catch (err) {
    warn(`Could not apply channel config: ${err.message}`);
  }
} else {
  log("No channel config path set — running gateway-only (no messaging channels).");
}

// ---------------------------------------------------------------------------
// 5. Launch the gateway with signal forwarding for clean K8s shutdown
// ---------------------------------------------------------------------------
log("Launching OpenClaw gateway on port 18789...");

const gateway = spawn("node", [APP, "gateway", "--allow-unconfigured"], {
  stdio: "inherit",
});

process.on("SIGTERM", () => {
  log("Received SIGTERM — forwarding to gateway...");
  gateway.kill("SIGTERM");
});

process.on("SIGINT", () => {
  log("Received SIGINT — forwarding to gateway...");
  gateway.kill("SIGINT");
});

gateway.on("error", (err) => {
  warn(`Failed to start gateway: ${err.message}`);
  process.exit(1);
});

gateway.on("exit", (code, signal) => {
  log(`Gateway exited — code=${code ?? "null"} signal=${signal ?? "null"}`);
  process.exit(code ?? 0);
});
