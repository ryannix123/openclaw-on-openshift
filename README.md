<div align="center">
  <img src=".github/logo.svg" width="640" alt="OpenClaw on OpenShift"/>

  <br/><br/>

  [![Build & Push](https://github.com/ryannix123/openclaw-on-openshift/actions/workflows/build.yml/badge.svg)](https://github.com/ryannix123/openclaw-on-openshift/actions/workflows/build.yml)
  [![UBI 10](https://img.shields.io/badge/base-UBI%2010-EE0000?logo=redhat&logoColor=white)](https://catalog.redhat.com/software/containers/ubi10/ubi)
  [![Hummingbird](https://img.shields.io/badge/base-Hummingbird%20%28distroless%29-EE0000?logo=redhat&logoColor=white)](https://hummingbird-project.io)
  [![Platform](https://img.shields.io/badge/platform-OpenShift-EE0000?logo=redhatopenshift&logoColor=white)](https://developers.redhat.com/developer-sandbox)
  [![Deploy](https://img.shields.io/badge/deploy-Ansible-EE0000?logo=ansible&logoColor=white)](https://docs.ansible.com/)
  [![Runtime](https://img.shields.io/badge/runtime-Node.js%2024-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
  [![Registry](https://img.shields.io/badge/registry-Quay.io-40B4E5?logo=quay&logoColor=white)](https://quay.io/repository/ryan_nix/openclaw-openshift)
  [![SCC](https://img.shields.io/badge/SCC-restricted-success)](https://docs.openshift.com/container-platform/4.17/authentication/managing-security-context-constraints.html)

  <br/>

  *[OpenClaw](https://github.com/openclaw/openclaw) on **Red Hat UBI 10** or **Project Hummingbird** — deployed to OpenShift with a single Ansible command.*

</div>

---

## Why this exists

[OpenClaw](https://github.com/openclaw/openclaw) is the fastest-growing software project in GitHub history — 366,000 stars in under five months. It connects AI models to the tools, files, and platforms you already use. It's powerful, it's fast-moving, and 93% of publicly exposed instances have authentication bypass vulnerabilities.

Running OpenClaw on your laptop is easy. Running it **safely, in production** is a different problem entirely.

This project solves that. OpenClaw packaged as a Red Hat container, deployed to OpenShift via Ansible — with enterprise-grade security baked in from the first command:

- **Your choice of base image.** Red Hat UBI 10 (familiar, full toolchain) or Project Hummingbird (distroless, near-zero CVEs, signed SBOM) — switch with one variable
- **Secrets stay secret.** API keys and tokens live in OpenShift Secrets, injected as env vars at runtime — never in the image or ConfigMaps
- **Zero data loss on upgrade.** PVC-backed config and workspace survive pod restarts, image rebuilds, and redeployments
- **One command to deploy, one to delete.** Ansible handles everything — Secrets, PVCs, Route, device pairing, model config — start to finish
- **Always current.** Nightly CI/CD builds both variants, tracks upstream OpenClaw releases, and rebuilds only when something changes

If you run OpenShift and you want OpenClaw, this is how you do it right.

---

## 🆓 Red Hat Developer Sandbox

The [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) is a **free** OpenShift environment — no credit card required.

- **Free tier** — Instant access, no cost
- **Generous resources** — 14 GB RAM, 40 GB storage, 3 CPU cores
- **Latest OpenShift** — Always running a recent version
- **Pre-configured** — Routes, TLS, and image registry included out of the box

### Waking Up After Hibernation

The Sandbox scales pods to zero after 12 hours of inactivity. Your PVC data is safe — just bring the pod back up:

```bash
oc scale deployment openclaw --replicas=1
```

### See it in action

<div align="center">
  <img src=".github/openshift-console.png" width="49%" alt="OpenClaw running in the OpenShift Developer Console"/>
  &nbsp;
  <img src=".github/openclaw-console.png" width="49%" alt="OpenClaw Control UI running on OpenShift"/>

  <br/><br/>

  <a href="https://youtu.be/IDiXK8MYUBo">
    <img src="https://img.youtube.com/vi/IDiXK8MYUBo/maxresdefault.jpg" width="75%" alt="Watch the full walkthrough on YouTube"/>
  </a>

  *▶️ Watch the full walkthrough on YouTube*
</div>

---

## Prerequisites

### OpenShift CLI

```bash
# macOS
brew install openshift-cli

# Linux (download directly)
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xf openshift-client-linux.tar.gz && sudo mv oc /usr/local/bin/

# Verify
oc version
```

Log in via the Sandbox console: **your username → Copy login command → paste it in your terminal.**

### Ansible + Kubernetes

```bash
pip install ansible kubernetes
ansible-galaxy collection install kubernetes.core
```

You'll also need a [Quay.io](https://quay.io) account and an API key from your AI provider of choice.

---

## Container Images

Two variants are available on [Quay.io](https://quay.io/repository/ryan_nix/openclaw-openshift) — choose based on your security requirements:

| Variant | Base | Node.js | Tag | Entrypoint | Best for |
|---|---|---|---|---|---|
| **UBI 10** *(default)* | `ubi10/ubi` (RHEL 10) | Official 24 LTS | `:latest` | `entrypoint.sh` | Familiar tooling, full Red Hat ecosystem, shell access for debugging |
| **Hummingbird** | `hi/nodejs` (distroless) | 24 | `:hummingbird-latest` | `entrypoint.js` | Near-zero CVEs, smallest attack surface, regulated industries |

Both run Node.js 24 at runtime, are built nightly by GitHub Actions, and support all AI providers, channels, and custom skills. Switch between them with a single variable — no rebuild needed:

```bash
# Switch an existing deployment from UBI to Hummingbird
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e openclaw_variant=hummingbird

# Switch back to UBI
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-...
```

Your PVC data (agent memory, config, workspace) is preserved across variant switches — only the container image changes.

### Why the official Node.js binary?

Both variants build on a Red Hat base (`ubi10/ubi`) but install the **official Node.js 24 LTS binary** from nodejs.org rather than Red Hat's `nodejs-24` image. This is deliberate: OpenClaw 2.0 requires WAL-reset-safe SQLite (≥ 3.50.7) for database integrity, and refuses to run against older versions. Red Hat's Node build dynamically links the *system* SQLite, which on RHEL 10 is 3.46.1 (affected by the WAL-reset bug and, per Red Hat's backport-only policy, never rebased). The official Node.js binary statically bundles SQLite 3.53.4, which is safe. Building on the UBI base keeps the RHEL 10 userland, Red Hat supply chain, and CVE story intact while satisfying OpenClaw's SQLite requirement.

### Hummingbird caveats

The Hummingbird variant trades some operational convenience for a dramatically smaller attack surface. Know these before choosing it:

- **No shell for debugging.** Distroless images have no `/bin/sh`, so `oc rsh` and `oc exec ... -- bash` won't work. Use `oc logs` and `oc exec deploy/openclaw -- node -e "..."` for inspection. This is the point of distroless — but it changes your troubleshooting workflow.
- **Manual device pairing.** OpenClaw's `devices list` command segfaults (exit 139) on the distroless runtime, so the playbook's automated pairing can't read the request ID. The playbook detects this and prints manual approval instructions: copy the `requestId` from the browser's pairing error and run `oc exec deploy/openclaw -- node dist/index.js devices approve <requestId>`. This is a one-time step per browser.
- **Cosmetic EPERM toast.** OpenClaw's gateway calls `fs.chmod()` on its config directory at runtime. Under OpenShift's restricted SCC the pod runs as an arbitrary UID that doesn't own the files, so the call fails with `EPERM: operation not permitted, chmod '/opt/openclaw/.openclaw'`. This surfaces as a toast in the Control UI but is **non-fatal** — the agent works, config persists, and channels function normally.
- **Both issues are upstream OpenClaw limitations**, not OpenShift or packaging defects. They stem from OpenClaw assuming a full OS with a shell and file ownership it controls. Track them at [openclaw/openclaw](https://github.com/openclaw/openclaw/issues).

If you need interactive shell debugging or fully automated pairing, use the UBI 10 variant. If you need the smallest possible CVE footprint for a regulated environment and can accept a one-time manual pairing step, Hummingbird is the better choice. Both are fully functional for running OpenClaw.

---

## Quick Start

```bash
# Deploy with UBI 10 (default)
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-...

# Deploy with Project Hummingbird (near-zero CVE, distroless)
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e openclaw_variant=hummingbird

# Delete (preserves PVC data)
ansible-playbook openclaw-on-ocp.yml -e state=absent

# Delete everything including data
ansible-playbook openclaw-on-ocp.yml -e state=absent -e delete_pvcs=true
```

The playbook auto-detects your active `oc` project — no namespace config needed.

---

## AI Providers

Set `ai_provider` to any of the following. The matching API key env var is injected automatically. Leave `ai_model` empty to use the provider default.

| Provider | Default model |
|---|---|
| `anthropic` | `anthropic/claude-sonnet-4-6` |
| `openai` | `openai/gpt-5.5` |
| `google` | `google/gemini-2.5-pro` |
| `xai` | `xai/grok-3` |
| `mistral` | `mistral/mistral-large-latest` |
| `cohere` | `cohere/command-r-plus` |

Switch provider without rebuilding the image:

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=openai \
  -e ai_api_key=sk-proj-...
```

Switch model live from the Control UI chat: `/model anthropic/claude-opus-4-6`

---

## Internal LLM (OpenAI-compatible endpoint)

Point OpenClaw at any OpenAI-compatible endpoint — vLLM, Ollama, RHOAI KServe, llama.cpp's server, or anything else that speaks the OpenAI Completions API. This is the right path for fully on-cluster, air-gapped deployments where your model runs alongside OpenClaw and no traffic leaves the cluster.

Set three variables in `vars/openclaw.yml` (or pass with `-e`):

| Variable | Purpose | Required |
|---|---|---|
| `openai_base_url` | Endpoint URL ending in `/v1` | Yes |
| `openai_model` | Model ID the endpoint serves | Yes |
| `openai_api_key` | Auth token if required (defaults to `ignored`) | No |

### Example — vLLM serving Granite on RHOAI

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e openai_base_url=http://granite-predictor.rhoai-models.svc.cluster.local:8080/v1 \
  -e openai_model=ibm-granite/granite-4.1-3b-instruct
```

OpenClaw will use the Granite endpoint as the primary model. The Anthropic credentials are still loaded as a fallback — switch live in the Control UI with `/model anthropic/claude-sonnet-4-6` if the local model trips on a request.

### How it works

When both `openai_base_url` and `openai_model` are set, the entrypoint writes a custom provider block into `openclaw.json` at every pod start:

```json
{
  "models": {
    "providers": {
      "internal-llm": {
        "baseUrl": "<openai_base_url>",
        "api": "openai-completions",
        "apiKey": "<openai_api_key or 'ignored'>",
        "models": [{ "id": "<openai_model>" }]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "internal-llm/<openai_model>" }
    }
  }
}
```

This config persists on the PVC — pod restarts and image updates preserve your custom endpoint.

### Caveats

- **Tool calling varies by model.** Smaller models (3B–8B parameters) can be unreliable at producing valid JSON tool calls under load. Test against your actual workflows before relying on it for skills.
- **NetworkPolicy.** If you have an egress NetworkPolicy on the OpenClaw namespace, ensure traffic to your model-serving namespace is allowed.
- **Keep a cloud fallback configured.** A misbehaving local model is one chat command away from a working Claude or GPT response: `/model anthropic/claude-sonnet-4-6`.

---

## Accessing the Control UI

The playbook prints your URL and token at the end of every run. Retrieve them anytime:

```bash
# Route URL
oc get route openclaw -o jsonpath='https://{.spec.host}{"\n"}'

# Gateway token
oc get secret openclaw-credentials \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo
```

Open the URL, paste the token, and click **Connect**.

> **OpenClaw 2.0 note:** The gateway runs behind OpenShift's HAProxy router, which OpenClaw 2.0 treats as a reverse proxy. The entrypoint sets `gateway.trustedProxies` to the standard OpenShift SDN ranges (`10.0.0.0/8`, `172.16.0.0/12`, `100.64.0.0/10`) so forwarded client headers are trusted — without this, OpenClaw 2.0 rejects every request with `proxy_attribution_required`. If your cluster uses non-default pod-network CIDRs, override with `-e openclaw_trusted_proxies='["<your-cidr>"]'`.

On first connect from a new browser, OpenClaw requires device pairing approval. The playbook handles this automatically:

1. Waits for the pod to be fully Ready
2. Prints the direct URL and pauses — you'll see something like:

```
TASK [Prompt user to open browser and connect] *******
OpenClaw is ready. Open the Control UI and click Connect:
https://<route>/?token=<token>

Just press ENTER after clicking Connect — do not type anything.
```

3. Open the URL, click **Connect**, then press **Enter** in the terminal
4. The playbook detects and approves the pending pairing request automatically
5. Click **Connect** once more in the browser — you're in

> **Note:** When Ansible's `pause:` prompt is waiting, just press Enter — don't type the requestId shown in the browser. The playbook retrieves and approves it automatically.

**Already paired?** Skip the pairing step on subsequent deploys:

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e skip_pairing=true
```

**Manual approval** (if the playbook's pairing request expires):

```bash
# Trigger a fresh request by clicking Connect in the browser, then:
oc exec deploy/openclaw -- node dist/index.js devices approve <requestId>

# List pending requests
oc exec deploy/openclaw -- node dist/index.js devices list
```

Pairing is stored on the config PVC — one-time per browser, survives pod restarts.

---

## Messaging Channels

Configure headless-compatible channels in `vars/openclaw.yml` with `enabled: true`. Tokens are stored in an OpenShift Secret — never in ConfigMaps or the image.

| Channel | Notes |
|---|---|
| Telegram ✅ | Bot token from @BotFather |
| Discord ✅ | Bot token from developer portal |
| Slack ✅ | Three tokens (bot, app, signing secret) |
| WhatsApp Business ✅ | Meta developer account + public webhook |
| Matrix ✅ | Access token from any homeserver |
| Teams ✅ | Azure bot registration |
| WhatsApp (Baileys) ❌ | Requires phone QR scan — not headless |
| iMessage / Signal ❌ | Require companion app or interactive setup |

---

## Custom Skills

Skills are `SKILL.md` files with YAML frontmatter that teach the agent new capabilities. Add them to `vars/openclaw.yml`:

```yaml
openclaw_custom_skills:
  - name: my-skill
    skill_md: "{{ lookup('file', 'skills/my-skill/SKILL.md') }}"
```

See `skills/satellite-cv-promote/SKILL.md` for a working example.

---

## CI/CD

GitHub Actions builds and pushes both variants to [Quay.io](https://quay.io/repository/ryan_nix/openclaw-openshift) nightly via a matrix strategy. A version check against the upstream OpenClaw release skips the build if nothing changed.

**Required secrets:** `QUAY_USERNAME` (`ryan_nix+github_actions_openclaw`) and `QUAY_PASSWORD` (robot account token).

### Tags

| Purpose | UBI 10 tag | Hummingbird tag |
|---|---|---|
| Latest stable | `:latest` | `:hummingbird-latest` |
| Dated build | `:YYYY.MM.DD` | `:hummingbird-YYYY.MM.DD` |
| Immutable git SHA | `:git-<sha>` | `:hummingbird-git-<sha>` |
| Tracks upstream | `:openclaw-<version>` | `:hummingbird-openclaw-<version>` |

### Software Bill of Materials (SBOM)

Every pushed image gets an SBOM generated by [syft](https://github.com/anchore/syft) in both industry-standard formats, attached to the workflow run as a downloadable artifact (`sbom-ubi10` / `sbom-hummingbird`, retained 90 days):

| Format | Standard | Use |
|---|---|---|
| SPDX JSON | ISO/IEC 5962 | Procurement, license compliance, broad tooling |
| CycloneDX JSON | OWASP | Security and vulnerability tooling |
| Table (`.txt`) | — | Quick human-readable package list |

**SBOM vs. vulnerability scan — they answer different questions.** Quay's built-in Clair scanner *analyzes* each image against CVE databases and tells you what's exploitable right now (the "High / fixable" counts on the tags page). The SBOM *inventories* the image — a durable, attestable manifest of every package present, tied to the exact image digest. A CVE scan is a point-in-time report that changes as new vulnerabilities are disclosed; the SBOM is a permanent record of composition. Regulated environments (financial services, healthcare) typically require both: the scan for current risk, the SBOM for supply-chain provenance and audit.

### Release-tag pinning

The build clones OpenClaw's latest stable release tag, not `HEAD` of `main`. The upstream project releases daily and `main` can be mid-development between releases — pinning to a tagged release prevents protocol-mismatch errors between the gateway and Control UI that would otherwise occur when building against an unstable commit.

The pin is automatic: the workflow detects the latest stable release tag and passes it as the `OPENCLAW_REF` build argument. You can override it for testing:

```bash
gh workflow run build.yml -f openclaw_ref=v2026.6.5
```

---

## Route Security

The Control UI is gated by the gateway token. For public deployments, restrict access further:

```bash
# IP allowlist via HAProxy annotation
oc annotate route openclaw \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.10/32" \
  --overwrite

# Rotate the gateway token
NEW_TOKEN=$(openssl rand -hex 32)
oc patch secret openclaw-credentials --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/OPENCLAW_GATEWAY_TOKEN\",\"value\":\"$(echo -n $NEW_TOKEN | base64)\"}]"
oc rollout restart deployment/openclaw
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for full security details and NetworkPolicy examples.

---

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — storage layout, SCC design, security hardening
- [OpenClaw docs](https://docs.openclaw.ai)
- [OpenClaw releases](https://github.com/openclaw/openclaw/releases)

---

<div align="center">
  <sub>Built on Red Hat UBI 10 + Project Hummingbird · Deployed with Ansible · Running on OpenShift 🦞</sub>
</div>
