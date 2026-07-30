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

ENTRYPOINT ["/entrypoint.sh"]
