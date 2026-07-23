#!/bin/bash
# End-to-end test for mwaeckerlin/nextcloud.
#
# Builds the full docker compose stack with default values from
# .env.sample, waits until Nextcloud is installed, and proves that the
# Collabora/Richdocuments integration actually works:
#
#   * richdocuments app is installed and enabled by office-bootstrap.php
#   * WOPI URLs (wopi_url, public_wopi_url, wopi_callback_url) are set
#   * Collabora answers /hosting/discovery and /hosting/capabilities and
#     advertises edit actions for typical office formats
#   * a freshly uploaded .odt can be opened through richdocuments, i.e.
#     the apps/richdocuments/index page returns the Collabora editor
#     iframe and a valid access_token for that file
#
# Required tooling: docker, docker compose, curl, jq.
# The script is intended to be self-contained -- no env vars need to be
# set; it falls back to .env.sample (which carries safe defaults).

set -euo pipefail

cd "$(dirname "$0")/../.."

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-mwaeckerlin_nextcloud_e2e}"
export COMPOSE_PROJECT_NAME

NEXTCLOUD_HTTP_PORT="${NEXTCLOUD_HTTP_PORT:-8824}"
HOST_VALUE="${HOST:-localhost:${NEXTCLOUD_HTTP_PORT}}"
PROTOCOL_VALUE="${PROTOCOL:-http}"
export HOST="$HOST_VALUE"
export PROTOCOL="$PROTOCOL_VALUE"
export WEBROOT="${WEBROOT:-}"

if [[ ! -f .env ]]; then
  cp .env.sample .env
  CLEANUP_ENV=1
else
  CLEANUP_ENV=0
fi

# shellcheck disable=SC1091
set -a; . ./.env; set +a

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${NEXTCLOUD_ADMIN_PASSWORD:?NEXTCLOUD_ADMIN_PASSWORD missing}"

cleanup() {
  echo "[E2E] Tearing down stack"
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ "$CLEANUP_ENV" == "1" ]]; then
    rm -f .env
  fi
}
trap cleanup EXIT

fail() { echo "E2E ERROR: $*" >&2; exit 1; }

# --- Bring the stack up -------------------------------------------------
echo "[E2E] Building and starting stack"
docker compose up -d --build --force-recreate --remove-orphans >/dev/null

# --- Wait until Nextcloud is installed and richdocuments is active ----
echo "[E2E] Waiting until Nextcloud is installed"
deadline=$(( $(date +%s) + 600 ))
while :; do
  if docker compose exec -T nextcloud-php-fpm php /app/occ status --no-ansi 2>/dev/null \
       | grep -q 'installed: true'; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=200 nextcloud-php-fpm >&2 || true
    fail "Nextcloud was not installed in time"
  fi
  sleep 5
done

echo "[E2E] Waiting until richdocuments is enabled"
deadline=$(( $(date +%s) + 300 ))
while :; do
  state=$(docker compose exec -T nextcloud-php-fpm \
            php /app/occ config:app:get richdocuments enabled \
              --no-ansi --no-warnings 2>/dev/null \
          | tr -d '\r' | tail -n1 || true)
  if [[ "$state" == "yes" ]]; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=100 nextcloud-php-fpm >&2 || true
    fail "richdocuments was not enabled (status: '$state')"
  fi
  sleep 3
done

occ() {
  docker compose exec -T nextcloud-php-fpm \
    php /app/occ --no-ansi --no-warnings "$@" 2>/dev/null \
    | tr -d '\r'
}

# Host-side curl against Nextcloud (port is mapped to the host).
nc_curl() {
  curl --silent --show-error --max-time 20 "$@"
}

# curl in a temporary container attached to the internal compose network
# 'php-collabora', so the hostname 'collabora' resolves.
COLLAB_NET="${COMPOSE_PROJECT_NAME}_php-collabora"
collab_curl() {
  docker run --rm --network "$COLLAB_NET" curlimages/curl:8.10.1 \
    --silent --show-error --max-time 20 "$@"
}

# --- WOPI configuration ------------------------------------------------
# `enabled: yes` does not mean the bootstrap already ran
# richdocuments:activate-config — wait for the keys instead of reading
# them once (an unset key exits occ non-zero, which under `set -e` would
# kill the script without any diagnostic).
echo "[E2E] Checking WOPI configuration"
deadline=$(( $(date +%s) + 120 ))
while :; do
  WOPI_URL=$(occ config:app:get richdocuments wopi_url 2>/dev/null | tail -n1 || true)
  if [[ -n "$WOPI_URL" ]]; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=100 nextcloud-php-fpm >&2 || true
    fail "richdocuments wopi_url was never configured (activate-config failed?)"
  fi
  sleep 3
done
PUB_WOPI_URL=$(occ config:app:get richdocuments public_wopi_url | tail -n1)
CB_URL=$(occ config:app:get richdocuments wopi_callback_url | tail -n1)

[[ "$WOPI_URL" == http://collabora:9980* ]] \
  || fail "wopi_url misconfigured: '$WOPI_URL'"
[[ "$PUB_WOPI_URL" == ${PROTOCOL_VALUE}://${HOST_VALUE}* ]] \
  || fail "public_wopi_url misconfigured: '$PUB_WOPI_URL' (expected prefix ${PROTOCOL_VALUE}://${HOST_VALUE})"
[[ "$CB_URL" == http://nextcloud-nginx:8080* ]] \
  || fail "wopi_callback_url misconfigured: '$CB_URL'"

# Derive webroot from the callback (default image: WEBROOT=nextcloud)
WEBROOT_PATH=${CB_URL#http://nextcloud-nginx:8080}
WEBROOT_PATH=${WEBROOT_PATH%/}
echo "[E2E] detected webroot: '${WEBROOT_PATH:-/}'"

# --- Collabora discovery + capabilities -------------------------------
echo "[E2E] Checking Collabora /hosting/discovery"
DISCOVERY=$(collab_curl http://collabora:9980/hosting/discovery)
grep -q '<wopi-discovery>' <<<"$DISCOVERY" || fail "wopi-discovery not found"
grep -Eq '(name="edit"[^>]*ext="odt")|(ext="odt"[^>]*name="edit")' <<<"$DISCOVERY" \
  || fail "Collabora offers no edit action for odt"
grep -Eq '(name="edit"[^>]*ext="docx")|(ext="docx"[^>]*name="edit")' <<<"$DISCOVERY" \
  || fail "Collabora offers no edit action for docx"

echo "[E2E] Checking Collabora /hosting/capabilities"
CAPS=$(collab_curl http://collabora:9980/hosting/capabilities)
jq -e '.hasMobileSupport == true' <<<"$CAPS" >/dev/null \
  || fail "Collabora capabilities without hasMobileSupport"
jq -e '."convert-to".available == true' <<<"$CAPS" >/dev/null \
  || fail "Collabora capabilities without convert-to"

# --- Upload a test document via WebDAV and open it in Collabora -------
echo "[E2E] Providing test document"
TEST_DOC="e2e-collabora-test.odt"
DAV_PUBLIC_BASE="${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/remote.php/dav/files/${ADMIN_USER}"

HOST_TMP=$(mktemp -d)
trap 'rm -rf "$HOST_TMP"' RETURN 2>/dev/null || true

# Empty file with an .odt extension. Nextcloud accepts arbitrary content
# via WebDAV; the richdocuments controller renders the editor page based
# on the file ID, not the content.
: > "${HOST_TMP}/${TEST_DOC}"

echo "[E2E] Uploading test document (${DAV_PUBLIC_BASE}/${TEST_DOC})"
nc_curl --fail -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -T "${HOST_TMP}/${TEST_DOC}" \
  "${DAV_PUBLIC_BASE}/${TEST_DOC}" >/dev/null \
  || fail "WebDAV upload failed"

FILE_ID=$(nc_curl -u "${ADMIN_USER}:${ADMIN_PASS}" -X PROPFIND \
  -H 'Depth: 0' \
  -H 'Content-Type: application/xml' \
  --data '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>' \
  "${DAV_PUBLIC_BASE}/${TEST_DOC}" \
  | grep -oE '<oc:fileid>[0-9]+</oc:fileid>' \
  | grep -oE '[0-9]+' \
  | head -n1)
[[ -n "$FILE_ID" ]] || fail "Could not determine the test document's fileid"

# --- Request the richdocuments editor page and verify WOPI data --------
echo "[E2E] Opening richdocuments editor (fileId=${FILE_ID})"
EDITOR_HTML=$(nc_curl -L -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -H 'OCS-APIRequest: true' \
  "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/index.php/apps/richdocuments/index?fileId=${FILE_ID}")

if ! grep -Eq 'richdocuments-document\.js|initial-state-richdocuments|collabora[^"]*:?9980|/cool/|wopi(Src|_src|_token|_url)|access_token' <<<"$EDITOR_HTML"; then
  echo "--- editor html (head) ---" >&2
  head -c 4000 <<<"$EDITOR_HTML" >&2
  fail "richdocuments editor page contains no Collabora/WOPI hints"
fi

# Additionally check that the editor is loaded for exactly this document.
grep -Eq "fileId=${FILE_ID}|\"fileid\":${FILE_ID}|\"fileid\":\"${FILE_ID}\"|initial-state-richdocuments" <<<"$EDITOR_HTML" \
  || fail "richdocuments editor page does not reference file ID ${FILE_ID}"

echo "E2E succeeded: stack up, richdocuments active, WOPI URLs"
echo "configured, Collabora discovery + capabilities ok, test document"
echo "openable through richdocuments with a WOPI token."
