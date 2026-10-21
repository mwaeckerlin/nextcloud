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
# limits above the image defaults, so the test proves they reach php-fpm and nginx
export UPLOAD_MAX_FILESIZE=20G
export MAX_INPUT_TIME=7200
export MEMORY_LIMIT=1500M

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

# --- Health check: php-fpm serves status.php and Nextcloud is installed ---
echo "[E2E] Waiting until nextcloud-php-fpm reports healthy"
PHP_CONTAINER=$(docker compose ps -q nextcloud-php-fpm)
deadline=$(( $(date +%s) + 600 ))
while :; do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$PHP_CONTAINER" 2>/dev/null || true)
  [[ "$HEALTH" == "healthy" ]] && break
  if (( $(date +%s) > deadline )); then
    docker inspect --format '{{json .State.Health}}' "$PHP_CONTAINER" >&2 || true
    fail "nextcloud-php-fpm did not become healthy (status: '$HEALTH')"
  fi
  sleep 5
done

# --- Limits from the environment: UPLOAD_MAX_FILESIZE, MEMORY_LIMIT,
# MAX_INPUT_TIME reach the php-fpm workers, MAX_INPUT_TIME the FastCGI
# timeout of nginx; measured in a worker, requested over FastCGI.
echo "[E2E] Checking the limits of the php-fpm workers"
docker compose cp tests/e2e/ini-probe.php nextcloud-php-fpm:/tmp/ini-probe.php >/dev/null
LIMITS=$(docker compose exec -T nextcloud-php-fpm php -r \
  'require "/usr/local/bin/fastcgi.php"; echo fastcgiGet("/tmp/ini-probe.php", "/ini-probe.php");')
for expected in '"upload_max_filesize":"20G"' '"post_max_size":"20G"' '"memory_limit":"1500M"' \
                '"max_input_time":"7200"' '"max_execution_time":"7200"'; do
  grep -qF "$expected" <<<"$LIMITS" || fail "php-fpm worker lacks $expected: $LIMITS"
done
docker compose exec -T nextcloud-nginx nginx -T 2>/dev/null | grep -q 'fastcgi_read_timeout 7200s' \
  || fail "nginx does not wait 7200s for php-fpm (fastcgi_read_timeout)"

# --- URL is the older name of HOST and still sets the public host --------
echo "[E2E] Checking URL as replacement for HOST"
URL_HOST=$(docker compose exec -T -e HOST= -e URL=cloud.example.test nextcloud-php-fpm \
  php -r 'include "/app/config/custom.config.php"; echo $CONFIG["overwritehost"];')
[[ "$URL_HOST" == "cloud.example.test" ]] || fail "URL does not set the public host: '$URL_HOST'"
BOTH_HOST=$(docker compose exec -T -e HOST=host.example.test -e URL=cloud.example.test nextcloud-php-fpm \
  php -r 'include "/app/config/custom.config.php"; echo $CONFIG["overwritehost"];')
[[ "$BOTH_HOST" == "host.example.test" ]] || fail "HOST does not take precedence over URL: '$BOTH_HOST'"

# As in the legacy image, maintenance mode counts as unhealthy, and the
# check is healthy again once it ends.
echo "[E2E] Checking the health check in maintenance mode"
docker compose exec -T nextcloud-php-fpm php /app/occ maintenance:mode --on --no-ansi >/dev/null
HEALTH_OUT=$(docker compose exec -T nextcloud-php-fpm php /usr/local/bin/health.php 2>&1) \
  && fail "health check is healthy in maintenance mode: $HEALTH_OUT"
grep -q 'maintenance' <<<"$HEALTH_OUT" \
  || fail "health check does not name maintenance mode: $HEALTH_OUT"
docker compose exec -T nextcloud-php-fpm php /app/occ maintenance:mode --off --no-ansi >/dev/null
docker compose exec -T nextcloud-php-fpm php /usr/local/bin/health.php >/dev/null \
  || fail "health check stays unhealthy after maintenance mode ended"

# --- Background jobs: the cron loop ran cron.php, which switched Nextcloud
# from AJAX to cron mode and recorded its run.
echo "[E2E] Checking the background jobs"
# occ prints a warning about the missing pcntl extension of the base image
# in front of the value, on the same line
MODE=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core backgroundjobs_mode --no-ansi | tr -d '\r\n')
MODE=${MODE##*php.ini.}
[[ "$MODE" == "cron" ]] || fail "background jobs do not run by cron (mode: '$MODE')"
# cron.php records lastcron when its first run ends, at most one interval later
deadline=$(( $(date +%s) + 900 ))
while :; do
  LASTCRON=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core lastcron --no-ansi 2>/dev/null | tr -d '\r\n' || true)
  LASTCRON=${LASTCRON##*php.ini.}
  [[ "$LASTCRON" =~ ^[0-9]+$ && "$LASTCRON" -gt 0 ]] && break
  (( $(date +%s) > deadline )) && fail "cron.php never completed a run (lastcron: '$LASTCRON')"
  sleep 10
done

# --- Every start upgrades and repairs, as the legacy image does: a container
# stopped in maintenance mode comes back healthy.
echo "[E2E] Restarting php-fpm in maintenance mode"
docker compose exec -T nextcloud-php-fpm php /app/occ maintenance:mode --on --no-ansi >/dev/null
docker compose restart nextcloud-php-fpm >/dev/null
deadline=$(( $(date +%s) + 600 ))
while :; do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q nextcloud-php-fpm)")
  [[ "$HEALTH" == "healthy" ]] && break
  (( $(date +%s) > deadline )) && fail "nextcloud-php-fpm not healthy after restart in maintenance mode (status: '$HEALTH')"
  sleep 5
done
docker compose logs nextcloud-php-fpm | grep -q 'Upgrading and repairing the installation' \
  || fail "the start did not upgrade and repair the installation"

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

# --- WebSocket app convention: /ws/<appid>/<path> -> <appid>-ws:3001/<path>
# A stand-in backend named e2e-ws answers plain HTTP on port 3001 in the
# network nginx shares with Collabora; nginx must strip /ws/e2e and pass the
# rest of the path and the query string through.
echo "[E2E] Checking the WebSocket app proxy /ws/<appid>/"
WS_NET="${COMPOSE_PROJECT_NAME}_nginx-collabora"
docker rm -f e2e-ws >/dev/null 2>&1 || true
trap 'docker rm -f e2e-ws >/dev/null 2>&1 || true; cleanup' EXIT
docker run -d --rm --name e2e-ws --network "$WS_NET" --network-alias e2e-ws \
  python:3-alpine sh -c 'mkdir -p /srv/probe && echo ws-proxy-ok > /srv/probe/answer.txt && cd /srv && python -m http.server 3001' >/dev/null
deadline=$(( $(date +%s) + 60 ))
while :; do
  WS_ANSWER=$(nc_curl "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/ws/e2e/probe/answer.txt?x=1" 2>/dev/null || true)
  [[ "$WS_ANSWER" == "ws-proxy-ok" ]] && break
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=50 nextcloud-nginx >&2 || true
    fail "/ws/e2e/probe/answer.txt did not reach e2e-ws:3001/probe/answer.txt (got '$WS_ANSWER')"
  fi
  sleep 2
done
docker rm -f e2e-ws >/dev/null 2>&1 || true

echo "E2E succeeded: stack up, richdocuments active, WOPI URLs"
echo "configured, Collabora discovery + capabilities ok, test document"
echo "openable through richdocuments with a WOPI token, WebSocket app"
echo "proxy /ws/<appid>/ reaches <appid>-ws:3001."
