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
# the stack plus an SMTP server with login for the mail tests and a browser
# for the office test
export COMPOSE_FILE=docker-compose.yml:tests/e2e/docker-compose.mail.yml:tests/e2e/docker-compose.office.yml

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
  if grep -q 'installed: true' <<<"$(docker compose exec -T nextcloud-php-fpm php /app/occ status --no-ansi 2>/dev/null || true)"; then
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
grep -q 'fastcgi_read_timeout 7200s' <<<"$(docker compose exec -T nextcloud-nginx nginx -T 2>/dev/null)" \
  || fail "nginx does not wait 7200s for php-fpm (fastcgi_read_timeout)"

# --- URL is the older name of HOST and still sets the public host --------
echo "[E2E] Checking URL as replacement for HOST"
URL_HOST=$(docker compose exec -T -e HOST= -e URL=cloud.example.test nextcloud-php-fpm \
  php -r 'include "/app/config/custom.config.php"; echo $CONFIG["overwritehost"];')
[[ "$URL_HOST" == "cloud.example.test" ]] || fail "URL does not set the public host: '$URL_HOST'"
BOTH_HOST=$(docker compose exec -T -e HOST=host.example.test -e URL=cloud.example.test nextcloud-php-fpm \
  php -r 'include "/app/config/custom.config.php"; echo $CONFIG["overwritehost"];')
[[ "$BOTH_HOST" == "host.example.test" ]] || fail "HOST does not take precedence over URL: '$BOTH_HOST'"

# --- Mail server: smtp-relay by default, a value saved by an administrator
# (as Administration settings › Basic settings does) stays, NC_mail_smtphost
# takes precedence over both.
echo "[E2E] Checking the mail server settings"
smtphost() {
  docker compose exec -T "$@" nextcloud-php-fpm php /app/occ config:system:get mail_smtphost --no-warnings | tr -d '\r\n'
}
[[ "$(smtphost)" == "smtp-relay" ]] || fail "default mail server is not smtp-relay: '$(smtphost)'"
docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set mail_smtphost --value=mail.example.test --no-warnings >/dev/null
[[ "$(smtphost)" == "mail.example.test" ]] || fail "a saved mail server does not stay: '$(smtphost)'"
[[ "$(smtphost -e NC_mail_smtphost=env.example.test)" == "env.example.test" ]] \
  || fail "NC_mail_smtphost does not take precedence: '$(smtphost -e NC_mail_smtphost=env.example.test)'"
docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set mail_smtphost --value=smtp-relay --no-warnings >/dev/null

# --- External mail server through the variables: Nextcloud sends through
# mailpit with login when MAIL_SMTPHOST, MAIL_SMTPPORT, MAIL_SMTPNAME and
# MAIL_SMTPPASSWORD point there, and a wrong password delivers nothing.
mailpit_count() {
  docker compose exec -T nextcloud-php-fpm php -r \
    'echo json_decode(file_get_contents("http://mailpit:8025/api/v1/messages"), true)["messages_count"] ?? -1;'
}
send_mail() {
  docker compose exec -T -e MAIL_SMTPHOST=mailpit -e MAIL_SMTPPORT=1025 -e MAIL_SMTPNAME=nextcloud \
    -e MAIL_SMTPPASSWORD="$1" nextcloud-php-fpm php -r '
      require "/app/lib/base.php";
      $mailer = \OCP\Server::get(\OCP\Mail\IMailer::class);
      $message = $mailer->createMessage();
      $message->setTo(["e2e@example.test" => "E2E"]);
      $message->setSubject("e2e variables");
      $message->setPlainBody("sent through MAIL_SMTPHOST");
      exit(empty($mailer->send($message)) ? 0 : 1);' >/dev/null 2>&1
}
echo "[E2E] Sending mail through an external server set by variables"
BEFORE=$(mailpit_count)
send_mail e2e-mail-secret || fail "mail through MAIL_SMTPHOST with login failed"
[[ "$(mailpit_count)" == "$((BEFORE + 1))" ]] || fail "mailpit did not receive the mail sent through the variables"
send_mail wrong-password && fail "a wrong MAIL_SMTPPASSWORD still sent the mail"
[[ "$(mailpit_count)" == "$((BEFORE + 1))" ]] || fail "mailpit received a mail sent with a wrong password"

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
# without --no-warnings: occ must print the bare value, so the base image
# carries pcntl
MODE=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core backgroundjobs_mode --no-ansi | tr -d '\r\n')
[[ "$MODE" == "cron" ]] || fail "background jobs do not run by cron (mode: '$MODE')"
# cron.php records lastcron when its first run ends, at most one interval later
deadline=$(( $(date +%s) + 900 ))
while :; do
  LASTCRON=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core lastcron --no-ansi 2>/dev/null | tr -d '\r\n' || true)
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
# the whole log first: grep -q stops at the first hit, and the writer of a
# long log then ends with SIGPIPE, which pipefail reports as a failure
grep -q 'Upgrading and repairing the installation' <<<"$(docker compose logs nextcloud-php-fpm)" \
  || fail "the start did not upgrade and repair the installation"

# --- The log goes to the container log only: after installation, requests,
# occ and cron, no nextcloud.log exists in the data or config volume.
echo "[E2E] Checking that Nextcloud writes no log file"
LOGFILES=$(docker compose exec -T nextcloud-php-fpm php -r \
  'echo implode(" ", array_merge(glob("/app/data/*.log") ?: [], glob("/app/config/*.log") ?: []));')
if [[ -n "$LOGFILES" ]]; then
  docker compose exec -T nextcloud-php-fpm php -r \
    'foreach (explode(" ", $argv[1]) as $f) { echo "--- $f ", filesize($f), " bytes, ", date("c", filemtime($f)), "\n", substr(file_get_contents($f), 0, 4000), "\n"; }' "$LOGFILES" || true
  docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get log_type || true
  fail "Nextcloud writes log files into its volumes: $LOGFILES"
fi
grep -q '"reqId"' <<<"$(docker compose logs nextcloud-php-fpm)" \
  || fail "the container log carries no log entry of Nextcloud"

# The settings a legacy installation leaves in config.php: a log file in the
# data volume, no rotation, debug level. Requests, occ and cron.php still log
# to the container log and write no file.
echo "[E2E] Checking the log with the saved settings of a legacy installation"
for setting in "log_type file" "logfile /app/data/nextcloud.log" "log_rotate_size 0 --type=integer" "loglevel 0 --type=integer"; do
  set -- $setting
  docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set "$1" --value="$2" ${3:-} --no-warnings --no-ansi >/dev/null
done
LOG_LINES_BEFORE=$(docker compose logs nextcloud-php-fpm | grep -c '"reqId"')
for request in status.php index.php/login remote.php/dav/files/admin/; do
  curl --silent --max-time 20 -o /dev/null -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT:+/${WEBROOT#/}}/${request}" \
    || fail "request ${request} through nginx failed"
done
docker compose exec -T nextcloud-php-fpm php /app/occ status --no-warnings --no-ansi >/dev/null
docker compose exec -T nextcloud-php-fpm php -f /app/cron.php >/dev/null 2>&1 || true
LOGFILES=$(docker compose exec -T nextcloud-php-fpm php -r \
  'echo implode(" ", array_merge(glob("/app/data/*.log") ?: [], glob("/app/config/*.log") ?: []));')
[[ -z "$LOGFILES" ]] || fail "the saved log settings of a legacy installation create log files: $LOGFILES"
LOG_LINES_AFTER=$(docker compose logs nextcloud-php-fpm | grep -c '"reqId"')
(( LOG_LINES_AFTER > LOG_LINES_BEFORE )) || fail "with debug level, nothing reached the container log"

# LOGLEVEL overrides a saved level; unset, the saved level applies; with
# nothing saved, the image default 2 applies.
echo "[E2E] Checking LOGLEVEL against a saved level"
loglevel() {
  docker compose exec -T "$@" nextcloud-php-fpm php /app/occ config:system:get loglevel --no-warnings --no-ansi | tr -d '\r\n'
}
[[ "$(loglevel)" == "0" ]] || fail "the saved loglevel 0 does not apply: '$(loglevel)'"
[[ "$(loglevel -e LOGLEVEL=3)" == "3" ]] || fail "LOGLEVEL=3 does not override the saved level: '$(loglevel -e LOGLEVEL=3)'"
for key in loglevel log_type logfile log_rotate_size; do
  docker compose exec -T nextcloud-php-fpm php /app/occ config:system:delete "$key" --no-warnings --no-ansi >/dev/null
done
[[ "$(loglevel)" == "2" ]] || fail "without a saved level the default is not 2: '$(loglevel)'"

# --- A noisy occ: an app that writes 88 KB to stderr on every occ call, as a
# broken app does, must not stop the start; php-fpm comes back healthy.
echo "[E2E] Restarting php-fpm with an app that floods the stderr of occ"
docker compose exec -T nextcloud-php-fpm php -r '
  $dir = "/app/custom_apps/noisy";
  @mkdir("$dir/appinfo", 0775, true);
  @mkdir("$dir/lib/AppInfo", 0775, true);
  file_put_contents("$dir/appinfo/info.xml", "<?xml version=\"1.0\"?><info><id>noisy</id><name>Noisy</name><summary>e2e</summary><description>e2e</description><version>1.0.0</version><licence>agpl</licence><author>e2e</author><namespace>Noisy</namespace><category>tools</category><dependencies><nextcloud min-version=\"30\" max-version=\"99\"/></dependencies></info>");
  file_put_contents("$dir/lib/AppInfo/Application.php", "<?php\nnamespace OCA\\Noisy\\AppInfo;\nclass Application extends \\OCP\\AppFramework\\App implements \\OCP\\AppFramework\\Bootstrap\\IBootstrap {\n  public function __construct() { parent::__construct(\"noisy\"); }\n  public function register(\\OCP\\AppFramework\\Bootstrap\\IRegistrationContext \$context): void { if (PHP_SAPI === \"cli\") { fwrite(STDERR, str_repeat(\"noisy e2e stderr line\\n\", 4000)); } }\n  public function boot(\\OCP\\AppFramework\\Bootstrap\\IBootContext \$context): void {}\n}\n");'
docker compose exec -T nextcloud-php-fpm php /app/occ app:enable noisy --no-ansi >/dev/null 2>&1 \
  || fail "the noisy test app does not enable"
docker compose restart nextcloud-php-fpm >/dev/null
deadline=$(( $(date +%s) + 600 ))
while :; do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q nextcloud-php-fpm)")
  [[ "$HEALTH" == "healthy" ]] && break
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=20 nextcloud-php-fpm >&2 || true
    fail "nextcloud-php-fpm hangs at the start when occ writes 88 KB to stderr (status: '$HEALTH')"
  fi
  sleep 5
done
docker compose exec -T nextcloud-php-fpm php /app/occ app:disable noisy --no-ansi >/dev/null 2>&1 || true

# --- A database that comes up only after php-fpm, and holds an older version
# than the image: the start waits for it, then upgrades, and php-fpm becomes
# healthy. In a swarm the database and php-fpm start together.
echo "[E2E] Restarting php-fpm before its database, with an older database version"
CODE_VERSION=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get version --no-ansi | tr -d '\r\n')
IFS=. read -r v1 v2 v3 v4 <<<"$CODE_VERSION"
if (( ${v4:-0} > 0 )); then v4=$((v4 - 1)); else v3=$((v3 - 1)); fi
OLD_VERSION="$v1.$v2.$v3.${v4:-0}"
docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set version --value="$OLD_VERSION" --no-ansi >/dev/null
UPGRADES_BEFORE=$(docker compose logs nextcloud-php-fpm | grep -c 'Upgrading and repairing the installation')
docker compose stop nextcloud-db >/dev/null
docker compose restart nextcloud-php-fpm >/dev/null
sleep 60
docker compose start nextcloud-db >/dev/null
deadline=$(( $(date +%s) + 900 ))
while :; do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q nextcloud-php-fpm)")
  [[ "$HEALTH" == "healthy" ]] && break
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=30 nextcloud-php-fpm >&2 || true
    fail "nextcloud-php-fpm not healthy after a late database with version $OLD_VERSION (status: '$HEALTH')"
  fi
  sleep 5
done
UPGRADES_AFTER=$(docker compose logs nextcloud-php-fpm | grep -c 'Upgrading and repairing the installation')
(( UPGRADES_AFTER > UPGRADES_BEFORE )) || fail "the start after the late database did not upgrade"
NOW_VERSION=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get version --no-ansi | tr -d '\r\n')
[[ "$NOW_VERSION" == "$CODE_VERSION" ]] || fail "database stays at version $NOW_VERSION, the image carries $CODE_VERSION"

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

# --- Integrity: the build signed core and the shipped apps again with its
# own CA; the check stays active, passes, accepts richdocuments from the App
# Store with the Nextcloud CA, and still finds a changed file.
echo "[E2E] Checking the integrity of the release"
CORE_CHECK=$(docker compose exec -T nextcloud-php-fpm php /app/occ integrity:check-core --no-warnings --output=json 2>&1) \
  || fail "integrity check of core fails: $CORE_CHECK"
APP_CHECK=$(docker compose exec -T nextcloud-php-fpm php /app/occ integrity:check-app --all --no-warnings --output=json 2>&1) \
  || fail "integrity check of the apps fails: $APP_CHECK"
grep -q '"richdocuments"' <<<"$(docker compose exec -T nextcloud-php-fpm php /app/occ app:list --no-warnings --output=json)" \
  || fail "richdocuments is not installed, the check of an App Store app proves nothing"
docker compose exec -T nextcloud-php-fpm php -r '
  $src = "/app/apps/files"; $dst = "/tmp/files-check";
  mkdir($dst);
  $items = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($src, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
  foreach ($items as $item) {
    $target = $dst . substr($item->getPathname(), strlen($src));
    $item->isDir() ? mkdir($target) : copy($item->getPathname(), $target);
  }
  file_put_contents("$dst/appinfo/info.xml", "<!-- changed -->", FILE_APPEND);'
CHANGED_CHECK=$(docker compose exec -T nextcloud-php-fpm php /app/occ integrity:check-app files --path=/tmp/files-check --no-warnings --output=json 2>&1) \
  && fail "integrity check does not notice a changed file: $CHANGED_CHECK"
grep -q 'INVALID_HASH' <<<"$CHANGED_CHECK" || fail "integrity check names no INVALID_HASH: $CHANGED_CHECK"

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

# --- External mail server through the frontend: the three endpoints the form
# under Administration settings › Basic settings calls save mailpit with
# login, and «Send email» delivers the test mail there.
echo "[E2E] Saving an external mail server through the administration settings"
NC_BASE="${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/index.php"
admin_post() {
  nc_curl -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'OCS-APIRequest: true' \
    -X POST "${NC_BASE}$1" "${@:2}"
}
docker compose exec -T nextcloud-php-fpm php /app/occ user:setting "${ADMIN_USER}" settings email admin@example.test --no-warnings >/dev/null
CODE=$(admin_post /settings/admin/mailsettings -d mail_domain=example.test -d mail_from_address=nextcloud \
  -d mail_smtpmode=smtp -d mail_smtpsecure= -d mail_smtphost=mailpit -d mail_smtpauth=1 -d mail_smtpport=1025 \
  -d mail_sendmailmode=smtp)
[[ "$CODE" == "200" ]] || fail "saving the mail server answered $CODE"
CODE=$(admin_post /settings/admin/mailsettings/credentials -d mail_smtpname=nextcloud -d mail_smtppassword=e2e-mail-secret)
[[ "$CODE" == "200" ]] || fail "saving the mail credentials answered $CODE"
BEFORE=$(mailpit_count)
CODE=$(admin_post /settings/admin/mailtest)
[[ "$CODE" == "200" ]] || fail "sending the test mail answered $CODE"
[[ "$(mailpit_count)" == "$((BEFORE + 1))" ]] || fail "mailpit did not receive the test mail of the administration settings"
for key in mail_smtpauth mail_smtpname mail_smtppassword; do
  docker compose exec -T nextcloud-php-fpm php /app/occ config:system:delete "$key" --no-warnings >/dev/null
done
docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set mail_smtphost --value=smtp-relay --no-warnings >/dev/null
docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set mail_smtpport --value=25 --no-warnings >/dev/null

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

# --- Office in a real browser: Collabora opens the document through nginx
# under the address of the host, the text typed in it is saved, and WebDAV
# delivers the saved document with that text.
echo "[E2E] Editing the test document in Collabora in a browser"
docker rm -f e2e-office-browser >/dev/null 2>&1 || true
docker compose build office-browser >/dev/null
OFFICE_EXIT=0
docker compose run --name e2e-office-browser \
  -e NC_URL="${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}" \
  -e NC_USER="${ADMIN_USER}" -e NC_PASSWORD="${ADMIN_PASS}" \
  -e FILE_ID="${FILE_ID}" -e DAV_URL="${DAV_PUBLIC_BASE}/${TEST_DOC}" \
  office-browser || OFFICE_EXIT=$?
if [[ "$OFFICE_EXIT" != 0 ]]; then
  docker cp e2e-office-browser:/tmp/office-failure.png "${HOST_TMP}/office-failure.png" >/dev/null 2>&1 \
    && echo "[E2E] screenshot of the failure: ${HOST_TMP}/office-failure.png" >&2
  docker compose logs --tail=40 nextcloud-nginx nextcloud-php-fpm >&2 || true
  docker rm -f e2e-office-browser >/dev/null 2>&1 || true
  fail "office in the browser failed"
fi
docker rm -f e2e-office-browser >/dev/null 2>&1 || true

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
