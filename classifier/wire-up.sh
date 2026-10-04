#!/bin/sh
# Creates everything the classifier needs on the OpenZiti controller: an
# identity for the model, the service, and the bind and dial policies.
#
#   docker compose cp classifier/wire-up.sh quickstart:/tmp/wire-up.sh
#   docker compose exec quickstart sh /tmp/wire-up.sh
#
# Writes the enrolled identity to /ziti/classifier.json, which the classifier
# container reads through the shared ./.ziti mount.
#
# Idempotent - it deletes anything left from a previous run first.
set -e

CTRL="${ZITI_CTRL:-https://quickstart.127.0.0.1.nip.io:1280}"
CA="${ZITI_HOME:-/ziti}/pki/root-ca/certs/root-ca.cert"
OUT="${ZITI_HOME:-/ziti}/classifier.json"

# Unprefixed by default. The appetizer's Prepare() tags its server identity
# with a bare "classifier-clients" attribute, in a file where every other name
# is scoped by instance - so one classifier is intended to serve every
# instance. Set SVC_PREFIX=local_ for a per-instance classifier instead, and
# change the URL in overlay/reflectServer.go to match.
SVC_PREFIX="${SVC_PREFIX:-}"

SERVICE="${SVC_PREFIX}classifier-service"
SVC_ATTR="${SVC_PREFIX}classifier-services"
BIND_ATTR="${SVC_PREFIX}classifier-servers"
DIAL_ATTR="${SVC_PREFIX}classifier-clients"

ziti edge login "${CTRL}" -u "${ZITI_USER:-admin}" -p "${ZITI_PWD:-admin}" -y --ca "${CA}"

ziti edge delete service-policy "${SERVICE}-dial" 2>/dev/null || true
ziti edge delete service-policy "${SERVICE}-bind" 2>/dev/null || true
ziti edge delete service "${SERVICE}"             2>/dev/null || true
ziti edge delete identity "${SERVICE}-host"       2>/dev/null || true
rm -f "${OUT}"

echo "==> identity for the model"
ziti edge create identity "${SERVICE}-host" \
  -a "${BIND_ATTR}" -o "${ZITI_HOME:-/ziti}/classifier.jwt"
ziti edge enroll "${ZITI_HOME:-/ziti}/classifier.jwt" -o "${OUT}"
chmod a+r "${OUT}"

echo "==> the service"
ziti edge create service "${SERVICE}" -a "${SVC_ATTR}"

echo "==> bind policy: only the model may host it"
ziti edge create service-policy "${SERVICE}-bind" Bind \
  --identity-roles "#${BIND_ATTR}" --service-roles "#${SVC_ATTR}"

echo "==> dial policy: only classifier-clients may call it"
# The appetizer's server identity already carries this attribute, so no
# application code changes. Granting it is the whole fix.
ziti edge create service-policy "${SERVICE}-dial" Dial \
  --identity-roles "#${DIAL_ATTR}" --service-roles "#${SVC_ATTR}"

echo
echo "${SERVICE} created. Nothing binds it until the classifier starts:"
ziti edge list services "name=\"${SERVICE}\""
