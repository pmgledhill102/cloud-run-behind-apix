# Envoy ingress container for the sidecar variant (design doc §10 item 6):
# jwt_authn enforces the client JWT before the app container ever sees the
# request. gettext-base provides envsubst for the config template.
FROM envoyproxy/envoy:v1.31-latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY envoy.yaml.tmpl /etc/envoy/envoy.yaml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run as the image's own unprivileged user. The stock entrypoint does this too,
# after chown-ing stdout and stderr, which this config never opens by path;
# this image replaces that entrypoint, so without USER Envoy would run as root.
# Everything it needs is unprivileged: the listener and admin ports are above
# 1024 and the rendered config goes to /tmp.
USER envoy
ENTRYPOINT ["/entrypoint.sh"]
