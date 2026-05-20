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
  echo "[E2E] Stack abreissen"
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ "$CLEANUP_ENV" == "1" ]]; then
    rm -f .env
  fi
}
trap cleanup EXIT

fail() { echo "E2E FEHLER: $*" >&2; exit 1; }

# --- Stack hochfahren --------------------------------------------------
echo "[E2E] Stack bauen und starten"
docker compose up -d --build --force-recreate --remove-orphans >/dev/null

# --- Warten bis Nextcloud installiert ist und richdocuments aktiv ist
echo "[E2E] Warte bis Nextcloud installiert ist"
deadline=$(( $(date +%s) + 600 ))
while :; do
  if docker compose exec -T nextcloud-php-fpm php /app/occ status --no-ansi 2>/dev/null \
       | grep -q 'installed: true'; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=200 nextcloud-php-fpm >&2 || true
    fail "Nextcloud wurde nicht rechtzeitig installiert"
  fi
  sleep 5
done

echo "[E2E] Warte bis richdocuments aktiviert ist"
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
    fail "richdocuments wurde nicht aktiviert (Status: '$state')"
  fi
  sleep 3
done

occ() {
  docker compose exec -T nextcloud-php-fpm \
    php /app/occ --no-ansi --no-warnings "$@" 2>/dev/null \
    | tr -d '\r'
}

# Host-seitiger curl gegen Nextcloud (Port ist auf den Host gemappt).
nc_curl() {
  curl --silent --show-error --max-time 20 "$@"
}

# curl in einem temporären Container, das im internen Compose-Netz
# 'php-collabora' hängt, damit der Hostname 'collabora' aufgelöst wird.
COLLAB_NET="${COMPOSE_PROJECT_NAME}_php-collabora"
collab_curl() {
  docker run --rm --network "$COLLAB_NET" curlimages/curl:8.10.1 \
    --silent --show-error --max-time 20 "$@"
}

# --- WOPI-Konfiguration -----------------------------------------------
echo "[E2E] WOPI-Konfiguration prüfen"
WOPI_URL=$(occ config:app:get richdocuments wopi_url | tail -n1)
PUB_WOPI_URL=$(occ config:app:get richdocuments public_wopi_url | tail -n1)
CB_URL=$(occ config:app:get richdocuments wopi_callback_url | tail -n1)

[[ "$WOPI_URL" == http://collabora:9980* ]] \
  || fail "wopi_url falsch konfiguriert: '$WOPI_URL'"
[[ "$PUB_WOPI_URL" == ${PROTOCOL_VALUE}://${HOST_VALUE}* ]] \
  || fail "public_wopi_url falsch konfiguriert: '$PUB_WOPI_URL' (erwartet Prefix ${PROTOCOL_VALUE}://${HOST_VALUE})"
[[ "$CB_URL" == http://nextcloud-nginx:8080* ]] \
  || fail "wopi_callback_url falsch konfiguriert: '$CB_URL'"

# Webroot vom Callback ableiten (Default-Bild: WEBROOT=nextcloud)
WEBROOT_PATH=${CB_URL#http://nextcloud-nginx:8080}
WEBROOT_PATH=${WEBROOT_PATH%/}
echo "[E2E] erkannter Webroot: '${WEBROOT_PATH:-/}'"

# --- Collabora-Discovery + Capabilities -------------------------------
echo "[E2E] Collabora /hosting/discovery prüfen"
DISCOVERY=$(collab_curl http://collabora:9980/hosting/discovery)
grep -q '<wopi-discovery>' <<<"$DISCOVERY" || fail "wopi-discovery nicht gefunden"
grep -Eq '(name="edit"[^>]*ext="odt")|(ext="odt"[^>]*name="edit")' <<<"$DISCOVERY" \
  || fail "Collabora bietet keine edit-Action für odt an"
grep -Eq '(name="edit"[^>]*ext="docx")|(ext="docx"[^>]*name="edit")' <<<"$DISCOVERY" \
  || fail "Collabora bietet keine edit-Action für docx an"

echo "[E2E] Collabora /hosting/capabilities prüfen"
CAPS=$(collab_curl http://collabora:9980/hosting/capabilities)
jq -e '.hasMobileSupport == true' <<<"$CAPS" >/dev/null \
  || fail "Collabora capabilities ohne hasMobileSupport"
jq -e '."convert-to".available == true' <<<"$CAPS" >/dev/null \
  || fail "Collabora capabilities ohne convert-to"

# --- Testdokument via WebDAV hochladen und in Collabora oeffnen -------
echo "[E2E] Testdokument bereitstellen"
TEST_DOC="e2e-collabora-test.odt"
DAV_PUBLIC_BASE="${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/remote.php/dav/files/${ADMIN_USER}"

HOST_TMP=$(mktemp -d)
trap 'rm -rf "$HOST_TMP"' RETURN 2>/dev/null || true

# Leere Datei mit .odt-Endung. Nextcloud akzeptiert beliebige Inhalte
# via WebDAV; der richdocuments-Controller rendert die Editor-Seite
# anhand der File-ID, nicht des Inhalts.
: > "${HOST_TMP}/${TEST_DOC}"

echo "[E2E] Testdokument hochladen (${DAV_PUBLIC_BASE}/${TEST_DOC})"
nc_curl --fail -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -T "${HOST_TMP}/${TEST_DOC}" \
  "${DAV_PUBLIC_BASE}/${TEST_DOC}" >/dev/null \
  || fail "WebDAV-Upload fehlgeschlagen"

FILE_ID=$(nc_curl -u "${ADMIN_USER}:${ADMIN_PASS}" -X PROPFIND \
  -H 'Depth: 0' \
  -H 'Content-Type: application/xml' \
  --data '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>' \
  "${DAV_PUBLIC_BASE}/${TEST_DOC}" \
  | grep -oE '<oc:fileid>[0-9]+</oc:fileid>' \
  | grep -oE '[0-9]+' \
  | head -n1)
[[ -n "$FILE_ID" ]] || fail "Konnte fileid des Testdokuments nicht ermitteln"

# --- richdocuments-Editor-Seite anfordern und WOPI-Daten verifizieren -
echo "[E2E] richdocuments-Editor öffnen (fileId=${FILE_ID})"
EDITOR_HTML=$(nc_curl -L -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -H 'OCS-APIRequest: true' \
  "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/index.php/apps/richdocuments/index?fileId=${FILE_ID}")

if ! grep -Eq 'richdocuments-document\.js|initial-state-richdocuments|collabora[^"]*:?9980|/cool/|wopi(Src|_src|_token|_url)|access_token' <<<"$EDITOR_HTML"; then
  echo "--- editor html (head) ---" >&2
  head -c 4000 <<<"$EDITOR_HTML" >&2
  fail "richdocuments-Editor-Seite enthält keine Collabora-/WOPI-Hinweise"
fi

# Prüfe zusätzlich, dass der Editor für genau dieses Dokument geladen wird.
grep -Eq "fileId=${FILE_ID}|\"fileid\":${FILE_ID}|\"fileid\":\"${FILE_ID}\"|initial-state-richdocuments" <<<"$EDITOR_HTML" \
  || fail "richdocuments-Editor-Seite referenziert FileID ${FILE_ID} nicht"

echo "E2E erfolgreich: Stack hochgefahren, richdocuments aktiv, WOPI-URLs"
echo "konfiguriert, Collabora-Discovery + Capabilities ok, Testdokument"
echo "über richdocuments mit WOPI-Token öffnenbar."
