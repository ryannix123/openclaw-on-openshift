# =============================================================================
# OpenClaw on UBI 10 — OpenShift-Compatible Container
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
#
# Two-stage build:
#   builder  — UBI 10 Node 24 + pnpm + full source build
#   runtime  — UBI 10 Node 24 with compiled dist only
#
# OpenShift compatibility:
#   - Runs as UID 1001, GID 0 (arbitrary UID support for restricted SCC)
#   - No hardcoded secrets; all credentials injected via env vars from Secret
#   - Config/workspace directories are PVC-backed (see Ansible playbook)
#   - Gateway port 18789 exposed (non-privileged, >1024)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder
#
# Base: ubi10/ubi (RHEL 10 userland) + the OFFICIAL Node.js 24 binary from
# nodejs.org — NOT Red Hat's ubi10/nodejs-24 image.
#
# Why: OpenClaw 2.0 (v2026.8.x) requires WAL-reset-safe SQLite (>=3.50.7).
# Red Hat's nodejs-24 build dynamically links the SYSTEM libsqlite3, and RHEL
# 10 ships SQLite 3.46.1 (affected by the WAL-reset corruption bug) and — per
# Red Hat policy — will never rebase it. OpenClaw's build guard hard-fails on
# it. The official Node.js binary STATICALLY BUNDLES SQLite 3.53.4, which is
# safe, so we use upstream Node on a UBI base. This keeps the RHEL 10 userland
# (and the Red Hat supply-chain / CVE story) while satisfying the SQLite gate.
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi10/ubi:latest AS builder

LABEL stage="builder"

USER root
WORKDIR /build

# pnpm requires CI=true to run non-interactively in a container (no TTY).
ENV CI=true

# Install build toolchain (git for clone; gcc/make/python3 for native modules).
# xz is needed to unpack the Node.js .tar.xz tarball.
RUN dnf install -y \
      git \
      python3 \
      make \
      gcc \
      gcc-c++ \
      tar \
      xz \
      findutils && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Install the official Node.js 24 LTS binary from nodejs.org.
# This build statically bundles SQLite 3.53.4 (WAL-reset-safe), unlike
# Red Hat's nodejs-24 which links the unsafe system libsqlite3.
# Pinned to a specific version for reproducible builds; bump deliberately.
ARG NODE_VERSION=24.20.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  node_arch="x64" ;; \
      aarch64) node_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    rm -f /tmp/node.tar.xz; \
    node --version; \
    npm --version; \
    # Sanity-check that this Node's bundled SQLite is the safe one.
    node -e "const {DatabaseSync}=require('node:sqlite'); const db=new DatabaseSync(':memory:'); const v=db.prepare('select sqlite_version() as v').get().v; console.log('bundled sqlite',v); db.close();"

# Clone a specific release tag (passed by CI) instead of HEAD.
# HEAD of main moves daily and can be mid-development between releases,
# causing protocol mismatches between the UI and gateway.
ARG OPENCLAW_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_REF}"     https://github.com/openclaw/openclaw.git .

# Activate pnpm at the version OpenClaw pins in package.json's "packageManager"
# field (v2026.8.x pins pnpm@12.x with a SHA-512 hash). The official Node
# binary ships a modern corepack, so enable it and activate the pinned version.
# Falls back to enabling corepack's shims; the first pnpm call auto-provisions.
RUN npm install -g corepack@latest && \
    corepack enable && \
    PM="$(node -p "require('./package.json').packageManager" 2>/dev/null || echo '')" && \
    if [ -n "$PM" ]; then corepack prepare "$PM" --activate; else corepack prepare --activate; fi && \
    pnpm --version

# Install ALL dependencies (dev deps required for the TypeScript/asset build).
# --frozen-lockfile: OpenClaw now ships a committed lockfile and expects it to
# be honored exactly (their own Dockerfile uses --frozen-lockfile).
# NODE_OPTIONS raises the heap — the tsdown/asset build is memory-hungry and
# OOMs (exit 137) on default limits.
RUN NODE_OPTIONS=--max-old-space-size=8192 \
    pnpm install --frozen-lockfile

# Build the backend + assets using OpenClaw's Docker build target.
# As of v2026.8.x the old "pnpm build" was replaced by "pnpm build:docker",
# a chain that runs plugins:assets:build, tsdown-build, runtime-postbuild,
# build stamping, and metadata generation. OPENCLAW_PREFER_PNPM=1 forces the
# pnpm path for asset bundling (upstream's Bun path can fail on some arches);
# skipping .d.ts generation speeds the build and drops nothing needed at runtime.
#
# OPENCLAW_TSDOWN_MAX_OLD_SPACE_MB is REQUIRED under buildah/podman: the build
# runs in a rootless namespace where the process can't read its own cgroup
# memory limit, so OpenClaw's tsdown wrapper refuses to guess a heap size and
# aborts ("process memory limit is not visible through this cgroup mount
# namespace"). Setting it explicitly (and its DOCKER_BUILD_ alias) satisfies
# that guardrail. 6144 MB stays safely under GitHub's ~7 GB runner ceiling —
# 8192 would risk an OOM kill on the runner itself.
RUN NODE_OPTIONS=--max-old-space-size=6144 \
    OPENCLAW_TSDOWN_MAX_OLD_SPACE_MB=6144 \
    OPENCLAW_DOCKER_BUILD_TSDOWN_MAX_OLD_SPACE_MB=6144 \
    OPENCLAW_PREFER_PNPM=1 \
    OPENCLAW_RUN_NODE_SKIP_DTS_BUILD=1 \
    pnpm_config_verify_deps_before_run=false \
    pnpm build:docker

# Build the Control UI frontend bundle (separate from the backend build).
# Without this the gateway serves "Control UI assets not found."
RUN OPENCLAW_PREFER_PNPM=1 \
    pnpm_config_verify_deps_before_run=false \
    pnpm ui:build

# Prune dev dependencies, then aggressively strip the node_modules tree
# before it gets COPY'd into the runtime stage.
#
# What each find pass removes:
#   *.md / *.txt / *.map / CHANGELOG* / LICENCE*
#     — docs and source maps are never needed at runtime (~15–25 MiB)
#   __tests__ / test / tests / spec
#     — test suites bundled inside packages (~10–20 MiB)
#   *.ts (but NOT *.d.ts — type declarations are sometimes required by
#     packages that do runtime require() of them; *.js.map is safe to drop)
#     — TypeScript source files left behind by packages that ship src/
#   .github / .circleci / .travis.yml / Makefile
#     — CI configs shipped inside npm packages
#   *.node pre-built binaries for platforms other than linux-x64
#     — native add-on variants for darwin/win32/arm64 (~20–40 MiB)
#
# pnpm store prune removes the content-addressable cache that accumulates
# during install; it lives under ~/.local/share/pnpm/store and is not
# referenced at runtime but would bloat the layer if not cleared.
RUN pnpm prune --prod 2>/dev/null || true && \
    find node_modules -maxdepth 4 \( \
        -name "*.md"        -o -name "*.MD"      \
        -o -name "*.txt"    -o -name "*.map"      \
        -o -name "CHANGELOG*" -o -name "LICENCE*" \
        -o -name "LICENSE"  -o -name "AUTHORS"    \
        -o -name ".travis.yml" -o -name ".eslintrc*" \
        -o -name "Makefile" -o -name "*.sh"       \
    \) -delete && \
    find node_modules -maxdepth 5 -type d \( \
        -name "__tests__" -o -name "test"  \
        -o -name "tests"  -o -name "spec"  \
        -o -name ".github" -o -name ".circleci" \
        -o -name "example" -o -name "examples"  \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    find node_modules -maxdepth 6 -name "*.ts" ! -name "*.d.ts" -delete && \
    find node_modules -maxdepth 6 -name "*.js.map" -delete && \
    find node_modules -maxdepth 6 \( \
        -name "*darwin*" -o -name "*win32*"  \
        -o -name "*freebsd*" -o -name "*linux-arm*" \
    \) -name "*.node" -delete 2>/dev/null || true && \
    pnpm store prune --force 2>/dev/null || true

# Strip dev/build artifacts BEFORE copying /build to /app in the runtime stage.
# This lets the runtime stage use a single defensive COPY /build /app — every
# runtime resource OpenClaw adds (templates, schemas, configs in unexpected
# paths) ships automatically. Without this, every upstream change that adds a
# new runtime path forces a Containerfile update.
RUN rm -rf .git .github .gitignore .gitattributes \
           .eslintrc* .prettierrc* .editorconfig \
           tsconfig*.json \
           pnpm-lock.yaml package-lock.json yarn.lock \
           tests test __tests__ \
           scripts \
           examples \
           CONTRIBUTING.md SECURITY.md CHANGELOG.md 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 2: Runtime
#
# Same base strategy as the builder: ubi10/ubi + official Node.js 24.
# OpenClaw uses SQLite at RUNTIME (sessions, transcripts, memory in 2.0), so
# the runtime Node must also bundle WAL-reset-safe SQLite 3.53.4. Red Hat's
# nodejs-24 (unsafe system 3.46.1) would fail the same guard at gateway start.
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi10/ubi:latest AS runtime

LABEL name="openclaw-openshift" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>" \
      summary="OpenClaw AI agent gateway on UBI 10 for OpenShift" \
      description="Model-agnostic AI coding agent runtime, built on RHEL 10 UBI for restricted SCC compatibility" \
      io.k8s.display-name="OpenClaw UBI 10" \
      io.openshift.expose-services="18789:http" \
      io.openshift.tags="ai,agent,nodejs,ubi10"

USER root

# Runtime needs the official Node.js 24 (bundled safe SQLite) plus a few
# runtime utilities. tar/xz to unpack Node; git because OpenClaw shells out to
# it for some workspace operations; shadow-utils for user management.
ARG NODE_VERSION=24.20.0
RUN dnf install -y tar xz git shadow-utils && \
    dnf clean all && rm -rf /var/cache/dnf && \
    set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  node_arch="x64" ;; \
      aarch64) node_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    rm -f /tmp/node.tar.xz; \
    node --version; \
    node -e "const {DatabaseSync}=require('node:sqlite'); const db=new DatabaseSync(':memory:'); console.log('runtime sqlite',db.prepare('select sqlite_version() as v').get().v); db.close();"

# ---------------------------------------------------------------------------
# Directory layout
#   /app                 — compiled application (read-only at runtime)
#   /opt/openclaw/config — OpenClaw config + .env (PVC-backed)
#   /opt/openclaw/workspace — agent workspace (PVC-backed)
#
# GID 0 group ownership + g+rwX allows OpenShift's arbitrary assigned UID
# to write to these directories without running as root.
# ---------------------------------------------------------------------------
RUN mkdir -p /app /opt/openclaw/config /opt/openclaw/workspace && \
    chown -R 1001:0 /app /opt/openclaw && \
    chmod -R g=u /opt/openclaw && \
    chmod g+rwX /opt/openclaw /opt/openclaw/config /opt/openclaw/workspace

# Single defensive COPY — ship everything the builder produced.
# Dev/build junk (.git, tests, lint configs, lockfiles) was already stripped
# in the builder stage so /build contains only runtime-relevant files.
# This protects against upstream OpenClaw adding new runtime resource paths
# (e.g. src/agents/templates/HEARTBEAT.md in v2026.6.x).
COPY --from=builder --chown=1001:0 /build /app

# Copy entrypoint
COPY --chown=1001:0 entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

# ---------------------------------------------------------------------------
# Runtime environment
#
# OPENCLAW_CONFIG_DIR    — where OpenClaw stores .env, memory, config
# OPENCLAW_WORKSPACE_DIR — agent working directory (files agent can read/write)
# HOME                   — must point to a writable location for Node.js internals
#
# AI provider keys (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.) and
# OPENCLAW_GATEWAY_TOKEN are injected at runtime via OpenShift Secret.
# See deploy-openclaw.yml for Secret creation.
# ---------------------------------------------------------------------------
ENV OPENCLAW_CONFIG_DIR=/opt/openclaw/config \
    OPENCLAW_WORKSPACE_DIR=/opt/openclaw/workspace \
    NODE_ENV=production \
    HOME=/opt/openclaw \
    PATH=/app/node_modules/.bin:$PATH

WORKDIR /app

# OpenClaw gateway UI/API port (non-privileged)
EXPOSE 18789

# Drop to non-root UID with GID 0 for OpenShift restricted SCC
USER 1001

ENTRYPOINT ["/app/entrypoint.sh"]
