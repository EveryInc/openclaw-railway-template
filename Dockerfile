# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.2.15
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile

# ── Patch: Node.js 22 + undici TLS session crash ──────────────────────
#
# Node.js 22's _tls_wrap.js calls socket._handle.setSession(session) in
# tls.connect(), but _handle can be null when the underlying TCP socket
# closes before the TLS handshake begins. undici@7.x caches TLS sessions
# and passes them to tls.connect() on reconnect, triggering:
#
#   TypeError: Cannot read properties of null (reading 'setSession')
#       at TLSSocket.setSession (node:_tls_wrap)
#       at Object.connect (node:_tls_wrap)
#       at Client.connect (undici/lib/core/connect.js)
#
# This is a Node.js bug (no null guard in setSession), surfaced by
# undici's session reuse. As of 2026-02:
#   - undici@7.x is the latest — no upstream fix available
#   - No Node.js 22.x patch has landed
#   - Related: https://github.com/nodejs/undici/issues/3813
#
# Fix: disable TLS session reuse by forcing `session: null` in undici's
# tls.connect() call. Cost: full TLS handshake each time instead of
# abbreviated (~1 extra RTT per new connection). Negligible for a chat
# gateway that makes infrequent outbound HTTPS calls.
#
# Remove this patch when Node.js fixes the null guard in setSession().
# ───────────────────────────────────────────────────────────────────────
# The target line inside tls.connect() is indented with 8 spaces: "        session,"
# We match that specific pattern to avoid breaking other "session," occurrences.
RUN find /openclaw/node_modules -path '*/undici/lib/core/connect.js' -exec \
      sed -i 's/^        session,$/        session: null, \/\/ patched: disable TLS session reuse (Node 22 crash)/' {} +

RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Persist user-installed tools by default by targeting the Railway volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Railway injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "--"]
CMD ["node", "src/server.js"]
