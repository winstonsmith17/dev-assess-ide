# ---------- Stage 1: BUILD FROM SOURCE ----------
# Use a full Node image for the build (tools, compilers, etc.)
FROM node:22-bookworm AS builder

# Optional: speed up installs
ENV CI=1
WORKDIR /src

# Copy your forked source
# (Building from parent directory, so copy dev-assess-ide contents into /src)
COPY dev-assess-ide/ .

# ▶ tools needed to fetch VS Code + ensure yarn classic is available
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates \
      build-essential pkg-config \
      libxkbfile-dev libx11-dev \
  && rm -rf /var/lib/apt/lists/*
# ▶ enable corepack and pin Yarn v1 (VS Code uses yarn classic)
RUN corepack enable && corepack prepare yarn@1.22.22 --activate

# ▶ fetch the VS Code sources your fork expects (adjust tag if needed)
ARG VSCODE_REF=1.103.2
RUN git clone --depth=1 --branch ${VSCODE_REF} https://github.com/microsoft/vscode.git lib/vscode

# --- Choose your package manager (uncomment ONE block) ---

# PNPM
# RUN corepack enable && corepack prepare pnpm@latest --activate
# RUN pnpm install --frozen-lockfile
# RUN pnpm build

# YARN
# RUN corepack enable && corepack prepare yarn@stable --activate
# RUN yarn install --frozen-lockfile
# RUN yarn build

# NPM
RUN npm ci
RUN npm run build

# If your build produces a tarball (recommended), create one:
# (Adjust paths to your fork’s output – common pattern shown)
RUN npm pack --silent
# This will create something like: code-server-<version>.tgz in /src

# Alternatively, if the build outputs a folder with the runtime app,
# archive it to a predictable path we can COPY in the next stage:
# RUN tar -C . -czf /tmp/code-server.tgz dist


# =======================================================================
# Stage 1b: Build your custom extension (dev-assess-extension)
# =======================================================================
FROM node:22-bookworm AS extbuilder
WORKDIR /ext

# Copy extension and schemagen directories
COPY dev-assess-extension/ ./dev-assess-extension/
COPY schemagen/ ./schemagen/

# Install monorepo dependencies first
WORKDIR /ext/dev-assess-extension
RUN npm ci

# Build packages sequentially (no npm workspaces configured)
RUN cd packages/config-types && npm ci && npm run build && cd ../..
RUN cd packages/fetch && npm ci && npm run build && cd ../..
RUN cd packages/config-yaml && npm ci && npm run build && cd ../..
RUN cd packages/llm-info && npm ci && npm run build && cd ../..
RUN cd packages/openai-adapters && npm ci && npm run build && cd ../..
RUN cd packages/hub && npm ci && npm run build && cd ../..

# Build core package 
RUN cd core && npm ci && npm run build && cd ..

# Build GUI (required by VS Code extension)
RUN cd gui && npm ci && npm run build && cd ..

# Finally build and package the VS Code extension
WORKDIR /ext/dev-assess-extension/extensions/vscode
RUN npm ci
RUN npm run prepackage
RUN mkdir -p build
RUN npm run esbuild
RUN mkdir -p /artifacts \
 && npx --yes @vscode/vsce@latest package --allow-star-activation --no-dependencies -o /artifacts/dev-assess-extension.vsix


# ---------- Stage 2: CODER RUNTIME (SAFEST) ----------
FROM codercom/code-server:4.103.2

USER root

# If you produced an npm pack tarball in Stage 1:
# bring the built package over
RUN rm -rf /usr/local/lib/node_modules/code-server
COPY --from=builder /src/code-server-*.tgz /tmp/code-server.tgz

# install it without npm: extract to node_modules path & link the CLI
RUN mkdir -p /usr/local/lib/node_modules/code-server \
 && tar -xzf /tmp/code-server.tgz -C /usr/local/lib/node_modules/code-server --strip-components=1 \
 && ln -sf /usr/local/lib/node_modules/code-server/bin/code-server /usr/local/bin/code-server \
 && rm -f /tmp/code-server.tgz

# If you produced a generic tarball of the app:
# COPY --from=builder /tmp/code-server.tgz /tmp/code-server.tgz
# RUN mkdir -p ~/.local/lib && tar -xzf /tmp/code-server.tgz -C ~/.local/lib \
#  && echo 'export PATH="$HOME/.local/lib/code-server/bin:$PATH"' >> ~/.profile

# If your build outputs directly to a folder (e.g., /src/dist),
# copy and link a binary/entrypoint as needed:
# COPY --from=builder /src/dist /home/coder/code-server
# ENV PATH="/home/coder/code-server/bin:${PATH}"


# =======================================================================
# Install custom extension (dev-assess-extension)
# =======================================================================
COPY --from=extbuilder /artifacts/dev-assess-extension.vsix /tmp/dev-assess-extension.vsix

# Create startup script that installs extension after volume mount
RUN printf '#!/bin/bash\n\
set -e\n\
\n\
# Ensure extensions directory exists (as coder user)\n\
mkdir -p /home/coder/.local/share/code-server/extensions\n\
\n\
# Check if our extension is already installed\n\
if [ ! -f /home/coder/.local/share/code-server/extensions/extensions.json ] || ! grep -q "continue" /home/coder/.local/share/code-server/extensions/extensions.json 2>/dev/null; then\n\
    echo "Installing DevAssess extension..."\n\
    code-server --install-extension /tmp/dev-assess-extension.vsix --force\n\
    echo "DevAssess extension installed successfully!"\n\
else\n\
    echo "DevAssess extension already installed."\n\
fi\n\
\n\
# Start code-server with passed arguments\n\
exec code-server "$@"\n' > /usr/local/bin/startup.sh

RUN chmod +x /usr/local/bin/startup.sh

USER 1000

# code-server listens on 0.0.0.0:8080 inside the container
EXPOSE 8080

# Use startup script as entrypoint
ENTRYPOINT ["/usr/local/bin/startup.sh"]
CMD ["--bind-addr","0.0.0.0:8080"]


# ---------- Stage 2: SLIM RUNTIME (INDEPENDENT) ----------
# Uncomment this block if you do NOT want to depend on codercom/code-server
# FROM node:22-bookworm-slim AS runtime
#
# RUN apt-get update && apt-get install -y --no-install-recommends \
#       ca-certificates tini git curl unzip \
#       libnss3 libxkbfile1 libsecret-1-0 fonts-dejavu \
#   && rm -rf /var/lib/apt/lists/*
#
# RUN useradd -m -u 1000 coder
# USER 1000
# WORKDIR /home/coder
#
# # If you produced an npm pack tarball in Stage 1:
# COPY --from=builder /src/code-server-*.tgz /tmp/code-server.tgz
# RUN npm install -g /tmp/code-server.tgz
#
# # If you produced a generic tarball of the app:
# # COPY --from=builder /tmp/code-server.tgz /tmp/code-server.tgz
# # RUN mkdir -p ~/.local/lib && tar -xzf /tmp/code-server.tgz -C ~/.local/lib \
# #  && echo 'export PATH="$HOME/.local/lib/code-server/bin:$PATH"' >> ~/.profile
#
# # If your build outputs directly to a folder (e.g., /src/dist):
# # COPY --from=builder /src/dist /home/coder/code-server
# # ENV PATH="/home/coder/code-server/bin:${PATH}"
#
# EXPOSE 8080
# ENTRYPOINT ["tini","-g","--"]
# CMD ["code-server","--bind-addr","0.0.0.0:8080"]