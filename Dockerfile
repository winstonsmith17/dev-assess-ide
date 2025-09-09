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

# NPM
RUN npm ci
RUN npm run build

# If your build produces a tarball (recommended), create one:
# (Adjust paths to your fork’s output – common pattern shown)
RUN npm pack --silent
# This will create something like: code-server-<version>.tgz in /src


# =======================================================================
# Stage 1b: Build your custom extension (dev-assess-extension)
# =======================================================================
FROM node:22-bookworm AS extbuilder
WORKDIR /ext

# Copy extension and schemagen directories
COPY dev-assess-extension/ ./dev-assess-extension/
COPY schemagen/ ./schemagen/

WORKDIR /ext/dev-assess-extension

# Use CI installs and skip large, optional downloads (e.g. puppeteer)
ENV CI=true \
    PUPPETEER_SKIP_DOWNLOAD=true

# Install root deps and build all local packages via the project script
RUN npm ci \
 && node ./scripts/build-packages.js

# Build Core and GUI (GUI build ensures gui/dist exists for packaging)
RUN cd core && npm ci && npm run build && cd .. \
 && cd gui && npm ci && npm run build && cd ..

# Create VSIX using the extension's packaging script
WORKDIR /ext/dev-assess-extension/extensions/vscode
RUN npm ci \
 && npm run package \
 && mkdir -p /artifacts \
 && cp build/*.vsix /artifacts/dev-assess-extension.vsix


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


# =======================================================================
# Install custom extension (dev-assess-extension)
# =======================================================================
COPY --from=extbuilder /artifacts/dev-assess-extension.vsix /tmp/dev-assess-extension.vsix

# Pre-create a global extensions directory outside /home/coder so PV doesn't mask it
RUN mkdir -p /opt/code-server/extensions /opt/code-server/data \
 && chown -R 1000:1000 /opt/code-server

# Install the extension at build-time into the global extensions dir, then clean up the VSIX
RUN su -s /bin/sh -c "code-server --user-data-dir /opt/code-server/data --extensions-dir /opt/code-server/extensions --install-extension /tmp/dev-assess-extension.vsix --force" coder \
 && rm -f /tmp/dev-assess-extension.vsix

USER 1000

# code-server listens on 0.0.0.0:8080 inside the container
EXPOSE 8080

# Use code-server directly; args provided by chart
ENTRYPOINT ["code-server"]
CMD ["--bind-addr","0.0.0.0:8080",
     "--user-data-dir","/opt/code-server/data",
     "--extensions-dir","/opt/code-server/extensions"]
