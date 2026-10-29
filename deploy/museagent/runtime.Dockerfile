FROM ghcr.io/nuphos/runtime:0.1.40-opencode
USER root
COPY apps/runtime/image/pi-acp/package.json apps/runtime/image/pi-acp/package-lock.json /opt/nuphos-pi-acp/
RUN cd /opt/nuphos-pi-acp \
 && npm ci --omit=dev --ignore-scripts --cache /opt/npm-cache \
 && rm -rf /opt/npm-cache
COPY apps/runtime/image/acp-shim.mjs apps/runtime/image/pi-session.mjs /opt/
COPY apps/runtime/image/openab-config.pi.toml /etc/openab/config.toml
ENV PATH="/opt/nuphos-pi-acp/node_modules/.bin:${PATH}" \
    OPENAB_AGENT_COMMAND="node /opt/acp-shim.mjs pi" \
    OPENAB_AGENT_AUTH_COMMAND="" \
    OPENAB_RUNTIME_LOGIN_COMMAND="" \
    OPENAB_RUNTIME_AUTH_FILE="" \
    OPENAB_ADAPTER_VERSION="pi-acp@0.0.34" \
    OPENAB_RUNTIME_LABEL="MuseAgent Pi" \
    NUPHOS_RUNTIME_PREINSTALL=""
USER node
