# Mock-Apigee gateway (issue #51): Envoy standing in for the Apigee runtime.
#   jwt_authn  = the VerifyJWT env flow hook (client JWT at the edge)
#   gcp_authn  = the GoogleIDToken target auth (mints a Google ID token from
#                the VM metadata server into X-Serverless-Authorization,
#                leaving the client JWT untouched in Authorization)
#   routes     = the API proxies (/hello, /auth-echo)
#
# Same base/version as the proven sidecar variant (scripts/auth/envoy/).
# gettext-base provides envsubst; openssl generates the self-signed cert at
# startup. USER root so Envoy can bind :443 on the host network (COS VM).
FROM envoyproxy/envoy:v1.31-latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base openssl \
    && rm -rf /var/lib/apt/lists/*

COPY envoy.yaml.tmpl /etc/envoy/envoy.yaml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENTRYPOINT ["/entrypoint.sh"]
