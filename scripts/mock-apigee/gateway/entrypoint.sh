#!/bin/sh
#
# Generate a self-signed cert (the real Apigee runtime also presents a cert
# the PoC clients don't verify — tests use curl -k against 10.2.0.2), render
# the Envoy config from env, and exec Envoy.
# Explicit variable list so any Envoy-native $ syntax added to the template
# later survives envsubst untouched.
#
set -eu

openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout /tmp/gw-key.pem -out /tmp/gw-cert.pem \
  -subj "/CN=mock-apigee-gw" 2>/dev/null

envsubst '$GW_PORT $JWT_ISSUER $JWT_AUDIENCE $JWKS_JSON $HELLO_HOST $AUTH_ECHO_HOST $HELLO_AUDIENCE $AUTH_ECHO_AUDIENCE' \
  < /etc/envoy/envoy.yaml.tmpl > /tmp/envoy.yaml
exec envoy -c /tmp/envoy.yaml --log-level info
