#!/bin/sh
#
# Render the Envoy config from env and exec Envoy.
# Explicit variable list so any Envoy-native $ syntax added to the template
# later survives envsubst untouched.
#
set -eu
envsubst '$PORT $APP_PORT $JWT_ISSUER $JWT_AUDIENCE $JWKS_JSON' \
  < /etc/envoy/envoy.yaml.tmpl > /tmp/envoy.yaml
exec envoy -c /tmp/envoy.yaml --log-level info
