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
export COMPOSE_FILE=docker-compose.yml:docker-compose.talk.yml:tests/e2e/docker-compose.mail.yml:tests/e2e/docker-compose.office.yml

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
# small, so the test sees nextcloud.log emptied
export LOG_MAX_SIZE=256K
# the self-test of Client Push runs inside the containers, where localhost is
# not the host; a browser uses <public URL>/push
export NOTIFY_PUSH_ENDPOINT=http://nextcloud-nginx:8080/push

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

# the Talk high-performance backend of docker-compose.talk.yml, with the
# configuration of the signaling server the README shows; the address is the
# internal one for the same reason as above
export TALK_SIGNALING_URL=http://nextcloud-nginx:8080/standalone-signaling
NEXTCLOUD_SIGNALING_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
export NEXTCLOUD_SIGNALING_SECRET
TALK_SIGNALING_CONFIG="[http]
listen = 0.0.0.0:8080

[sessions]
hashkey = $(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
blockkey = $(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')

[clients]
internalsecret = $(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')

[backend]
backends = nextcloud
timeout = 10
connectionsperhost = 8

[nextcloud]
urls = ${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT:+/${WEBROOT#/}}, http://nextcloud-nginx:8080${WEBROOT:+/${WEBROOT#/}}
secret = ${NEXTCLOUD_SIGNALING_SECRET}

[nats]
url = nats://nats:4222

[mcu]
type =
"
export TALK_SIGNALING_CONFIG

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
MODE=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core backgroundjobs_mode --no-ansi | tr -d '\r\n') \
  || fail "occ config:app:get core backgroundjobs_mode fails, background jobs are not switched to cron (got '$MODE')"
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

# --- The log: /app/data/nextcloud.log for the app logreader, every entry also
# in the container log, the file emptied at LOG_MAX_SIZE (256K in this test)
# and no other log file in the data or config volume.
logfiles() {
  docker compose exec -T nextcloud-php-fpm php -r \
    'echo implode(" ", array_merge(glob("/app/data/*.log*") ?: [], glob("/app/config/*.log*") ?: []));'
}
logsize() {
  docker compose exec -T nextcloud-php-fpm php -r 'clearstatcache(); echo is_file("/app/data/nextcloud.log") ? filesize("/app/data/nextcloud.log") : -1;'
}
echo "[E2E] Checking the log file and the container log"
[[ "$(logfiles)" == "/app/data/nextcloud.log" ]] \
  || fail "the volumes hold the log files '$(logfiles)', expected /app/data/nextcloud.log alone"
grep -q '"reqId"' <<<"$(docker compose logs nextcloud-php-fpm)" \
  || fail "the container log carries no log entry of Nextcloud"
grep -q '"reqId"' <<<"$(docker compose exec -T nextcloud-php-fpm php -r 'echo file_get_contents("/app/data/nextcloud.log");')" \
  || fail "nextcloud.log carries no log entry of Nextcloud"

# The settings a legacy installation leaves in config.php: a log file of its
# own path, no rotation, debug level. The log still goes to nextcloud.log and
# the container log, and the file stays below LOG_MAX_SIZE while far more than
# that passes through it.
echo "[E2E] Checking the log with the saved settings of a legacy installation"
for setting in "log_type syslog" "logfile /app/data/legacy.log" "log_rotate_size 0 --type=integer" "loglevel 0 --type=integer"; do
  set -- $setting
  docker compose exec -T nextcloud-php-fpm php /app/occ config:system:set "$1" --value="$2" ${3:-} --no-warnings --no-ansi >/dev/null
done
LOG_BYTES_BEFORE=$(docker compose logs nextcloud-php-fpm | wc -c)
for round in $(seq 1 200); do
  for request in status.php index.php/login remote.php/dav/files/admin/; do
    curl --silent --max-time 20 -o /dev/null -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT:+/${WEBROOT#/}}/${request}" \
      || fail "request ${request} through nginx failed"
  done
  (( round % 20 == 0 )) || continue
  sleep 2
  (( $(docker compose logs nextcloud-php-fpm | wc -c) - LOG_BYTES_BEFORE > 4 * 262144 )) && break
done
docker compose exec -T nextcloud-php-fpm php /app/occ status --no-warnings --no-ansi >/dev/null
docker compose exec -T nextcloud-php-fpm php -f /app/cron.php >/dev/null 2>&1 || true
sleep 3
LOG_BYTES_PASSED=$(( $(docker compose logs nextcloud-php-fpm | wc -c) - LOG_BYTES_BEFORE ))
(( LOG_BYTES_PASSED > 4 * 262144 )) \
  || fail "with debug level only ${LOG_BYTES_PASSED} bytes reached the container log, expected more than 1M"
LOG_SIZE=$(logsize)
(( LOG_SIZE >= 0 && LOG_SIZE < 2 * 262144 )) \
  || fail "nextcloud.log holds ${LOG_SIZE} bytes after ${LOG_BYTES_PASSED} bytes of log, LOG_MAX_SIZE is 256K"
[[ "$(logfiles)" == "/app/data/nextcloud.log" ]] \
  || fail "the saved log settings of a legacy installation leave the log files '$(logfiles)'"

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
# The stopped database left errors in nextcloud.log («Connection refused»,
# «MySQL server has gone away»), which «Errors in the log» of the admin
# overview counts. The test empties the file, as LOG_MAX_SIZE does, so that
# check below sees the errors of normal operation alone.
docker compose exec -T nextcloud-php-fpm php -r 'file_put_contents("/app/data/nextcloud.log", "");'

# --- An installation from the time of COMPACT tables, with an optional index
# missing: the next start adds the index and converts the table to DYNAMIC,
# the conversion in the background while Nextcloud already answers. The
# password stays inside the database container.
echo "[E2E] Converting an old row format and adding a missing index"
db() {
  docker compose exec -T nextcloud-db sh -c \
    'MYSQL_PWD=$(cat /run/secrets/nextcloud_db_password) mariadb -unextcloud nextcloud -N -e "$1"' sh "$1"
}
db "ALTER TABLE oc_appconfig ROW_FORMAT=COMPACT; DROP INDEX share_with_index ON oc_share"
[[ "$(db "SELECT row_format FROM information_schema.tables WHERE table_schema='nextcloud' AND table_name='oc_appconfig'")" == "Compact" ]] \
  || fail "oc_appconfig could not be set to COMPACT for the test"
docker compose restart nextcloud-php-fpm >/dev/null
deadline=$(( $(date +%s) + 600 ))
while :; do
  ROW_FORMAT=$(db "SELECT row_format FROM information_schema.tables WHERE table_schema='nextcloud' AND table_name='oc_appconfig'")
  INDEX=$(db "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='nextcloud' AND table_name='oc_share' AND index_name='share_with_index'")
  [[ "$ROW_FORMAT" == "Dynamic" && "$INDEX" != "0" ]] && break
  if (( $(date +%s) > deadline )); then
    docker compose logs --tail=30 nextcloud-php-fpm >&2 || true
    fail "after the start oc_appconfig is '$ROW_FORMAT' and share_with_index has $INDEX columns"
  fi
  sleep 5
done
grep -q 'oc_appconfig converted after' <<<"$(docker compose logs nextcloud-php-fpm)" \
  || fail "the conversion of oc_appconfig is not in the container log"
# the setup checks run after the repairs and say what remains
deadline=$(( $(date +%s) + 300 ))
until grep -qE 'nextcloud-setup-check: (no errors and no warnings|[0-9]+ errors and warnings remain)' <<<"$(docker compose logs nextcloud-php-fpm)"; do
  (( $(date +%s) > deadline )) && fail "the start wrote no result of the setup checks into the container log"
  sleep 5
done

# --- The server ID: every php-fpm gets one in 0..511, SERVER_ID sets it.
echo "[E2E] Checking the server ID"
SERVER_ID_DEFAULT=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get serverid --no-warnings --no-ansi | tr -d '\r\n')
[[ "$SERVER_ID_DEFAULT" =~ ^[0-9]+$ ]] && (( SERVER_ID_DEFAULT <= 511 )) \
  || fail "the server ID '$SERVER_ID_DEFAULT' is not a number from 0 to 511"
SERVER_ID_SET=$(docker compose exec -T -e SERVER_ID=7 nextcloud-php-fpm php /app/occ config:system:get serverid --no-warnings --no-ansi | tr -d '\r\n')
[[ "$SERVER_ID_SET" == "7" ]] || fail "SERVER_ID=7 does not set the server ID: '$SERVER_ID_SET'"

# --- Trusted proxies and Redis: the private networks by default,
# TRUSTED_PROXIES replaces them; REDIS_HOST of the compose setup locks files.
echo "[E2E] Checking the trusted proxies and Redis"
PROXIES=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get trusted_proxies --no-warnings --no-ansi 2>&1 | tr '\r\n' '  ') \
  || fail "occ config:system:get trusted_proxies fails: $PROXIES"
[[ "$PROXIES" == *"10.0.0.0/8"*"172.16.0.0/12"*"192.168.0.0/16"* ]] || fail "trusted_proxies are '$PROXIES', not the private networks"
PROXIES=$(docker compose exec -T -e TRUSTED_PROXIES="198.51.100.7, 203.0.113.0/24" nextcloud-php-fpm php /app/occ config:system:get trusted_proxies --no-warnings --no-ansi 2>&1 | tr '\r\n' '  ') \
  || fail "occ config:system:get trusted_proxies with TRUSTED_PROXIES fails: $PROXIES"
[[ "$PROXIES" == *"198.51.100.7"*"203.0.113.0/24"* && "$PROXIES" != *"10.0.0.0/8"* ]] || fail "TRUSTED_PROXIES does not replace the list: '$PROXIES'"
LOCKING=$(docker compose exec -T nextcloud-php-fpm php /app/occ config:system:get memcache.locking --no-warnings --no-ansi 2>&1 | tr -d '\r\n') \
  || fail "files are not locked in Redis: occ config:system:get memcache.locking fails: '$LOCKING' (PHP extension redis: $(docker compose exec -T nextcloud-php-fpm php -r 'echo extension_loaded("redis") ? "loaded" : "missing";'))"
[[ "$LOCKING" == '\OC\Memcache\Redis' ]] || fail "files are not locked in Redis: memcache.locking is '$LOCKING'"

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
# Nextcloud stores that result for the app files and shows it under Overview;
# the check of the real app replaces it, as «Rescan» does for an administrator
docker compose exec -T nextcloud-php-fpm php /app/occ integrity:check-app files --no-warnings --output=json >/dev/null 2>&1 \
  || fail "the app files does not pass the integrity check after the test of a changed copy"

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

# --- The administration pages in a real browser: every warning and error they
# show fails the test, except the AppAPI deploy daemon the README leaves to
# the administrator, and two texts Nextcloud shows as a warning card whatever
# the configuration: the risk of PDF scripting under Basic settings, and that
# mobile clients make no end-to-end encrypted calls under Talk.
echo "[E2E] Checking the administration pages in a browser"
docker rm -f e2e-admin-browser >/dev/null 2>&1 || true
ADMIN_EXIT=0
docker compose run --name e2e-admin-browser --entrypoint python3 \
  -e NC_URL="${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}" \
  -e NC_USER="${ADMIN_USER}" -e NC_PASSWORD="${ADMIN_PASS}" \
  -e ALLOWED="AppAPI|Enabling PDF scripting|do not support end-to-end encrypted calls" \
  office-browser /work/admin_pages_test.py || ADMIN_EXIT=$?
if [[ "$ADMIN_EXIT" != 0 ]]; then
  docker cp e2e-admin-browser:/tmp/admin-pages-failure.png "${HOST_TMP}/admin-pages-failure.png" >/dev/null 2>&1 \
    && echo "[E2E] screenshot of the failure: ${HOST_TMP}/admin-pages-failure.png" >&2
  docker rm -f e2e-admin-browser >/dev/null 2>&1 || true
  fail "the administration pages show warnings or errors"
fi
docker rm -f e2e-admin-browser >/dev/null 2>&1 || true

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

# --- Client Push: nginx forwards /push/ to the push server, and the self-test
# of the app notify_push passes: Nextcloud reaches the push server, the push
# server reaches Nextcloud and Redis, and Nextcloud trusts it as a proxy.
echo "[E2E] Checking Client Push"
deadline=$(( $(date +%s) + 300 ))
until [[ "$(docker compose exec -T nextcloud-php-fpm php /app/occ app:list --output=json --no-warnings 2>/dev/null | tr -d '\r')" == *'"notify_push"'* ]]; do
  (( $(date +%s) > deadline )) && fail "the start did not install the app notify_push"
  sleep 5
done
# the self-test goes through nginx (NOTIFY_PUSH_ENDPOINT), so it covers /push/
SELF_TEST=$(docker compose exec -T nextcloud-php-fpm php /app/occ notify_push:self-test --no-ansi 2>&1) \
  || fail "the self-test of Client Push fails:"$'\n'"$SELF_TEST"

# --- Talk high-performance backend: the start installs Talk and registers the
# signaling server, nginx forwards /standalone-signaling/ to it; the setup
# check of Talk below then reaches it.
echo "[E2E] Checking the Talk high-performance backend"
deadline=$(( $(date +%s) + 300 ))
until [[ "$(docker compose exec -T nextcloud-php-fpm php /app/occ app:list --output=json --no-warnings 2>/dev/null | tr -d '\r')" == *'"spreed"'* ]]; do
  (( $(date +%s) > deadline )) && fail "the start did not install Talk (spreed)"
  sleep 5
done
WELCOME=$(nc_curl "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/standalone-signaling/api/v1/welcome" 2>/dev/null || true)
[[ "$WELCOME" == *'"nextcloud-spreed-signaling"'* ]] \
  || fail "/standalone-signaling/api/v1/welcome does not reach the signaling server (got '$WELCOME')"

# --- Collabora is the office of the image: an installation that also has
# ONLYOFFICE enabled gets it disabled on the next start, richdocuments stays.
echo "[E2E] Checking that the start leaves Collabora as the only office app"
docker compose exec -T nextcloud-php-fpm php /app/occ app:install onlyoffice --no-ansi >/dev/null 2>&1 \
  || docker compose exec -T nextcloud-php-fpm php /app/occ app:enable onlyoffice --no-ansi >/dev/null 2>&1 \
  || fail "ONLYOFFICE cannot be installed for the test"
docker compose restart nextcloud-php-fpm >/dev/null
deadline=$(( $(date +%s) + 600 ))
until [[ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q nextcloud-php-fpm)")" == healthy ]]; do
  (( $(date +%s) > deadline )) && fail "nextcloud-php-fpm not healthy after the restart with ONLYOFFICE"
  sleep 5
done
ENABLED_APPS=$(docker compose exec -T nextcloud-php-fpm php /app/occ app:list --enabled --output=json --no-warnings 2>/dev/null | tr -d '\r')
[[ "$ENABLED_APPS" != *'"onlyoffice"'* ]] || fail "ONLYOFFICE is still enabled after the start"
[[ "$ENABLED_APPS" == *'"richdocuments"'* ]] || fail "richdocuments is not enabled after the start"

# --- Administration settings › Overview: every setup check, through the route
# the page itself calls, with the X-Forwarded-For of a reverse proxy. An error
# or a warning fails the test, except the checks the README lists as work of
# the administrator, because they need a service outside these images.
echo "[E2E] Checking the setup checks of the admin overview"
# Allowed, as «class» or «class|text the description contains»:
#   the AppAPI deploy daemon, which the README leaves to the administrator;
#   HTTPS and HSTS, because this test reaches Nextcloud over plain http
#   without the reverse proxy that serves both in production;
#   the signaling server lacking «changed-users»: 2.1.1 of struktur AG is
#   its latest release and does not have it yet.
ADMIN_TASKS='OCA\AppAPI\SetupChecks\DaemonCheck
OCA\Settings\SetupChecks\HttpsUrlGeneration
OCA\Settings\SetupChecks\SecurityHeaders|Strict-Transport-Security
OCA\Talk\SetupCheck\HighPerformanceBackend|missing features: changed-users'
SETUP=$(nc_curl -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'OCS-APIRequest: true' -H 'X-Forwarded-For: 203.0.113.9' \
  "${PROTOCOL_VALUE}://${HOST_VALUE}${WEBROOT_PATH}/index.php/settings/setupcheck") \
  || fail "the setup checks of the admin overview do not answer"
FINDINGS=$(docker compose exec -T nextcloud-php-fpm php -r '
  $allowed = array_map(fn ($line) => explode("|", $line, 2) + [1 => ""], explode("\n", $argv[1]));
  $all = json_decode(stream_get_contents(STDIN), true);
  if (!is_array($all)) { echo "no JSON answer\n"; exit; }
  foreach ($all as $checks) {
    foreach ($checks as $class => $result) {
      if (!in_array($result["severity"], ["error", "warning"], true)) {
        continue;
      }
      foreach ($allowed as [$allowedClass, $text]) {
        if ($class === $allowedClass && str_contains($result["description"], $text)) {
          continue 2;
        }
      }
      echo "{$result["severity"]} {$class} ({$result["name"]}): {$result["description"]}\n";
    }
  }' "$ADMIN_TASKS" <<<"$SETUP")
if [[ -n "$FINDINGS" ]]; then
  # the details the overview only links to
  docker compose exec -T nextcloud-php-fpm php /app/occ config:app:get core oc.integritycheck.checker --no-warnings 2>&1 | cut -c1-2000 || true
  docker compose cp tests/e2e/check-urls.php nextcloud-php-fpm:/tmp/check-urls.php >/dev/null 2>&1 \
    && docker compose exec -T nextcloud-php-fpm php /tmp/check-urls.php 2>&1 || true
  fail "the admin overview reports:"$'\n'"$FINDINGS"
fi

echo "E2E succeeded: stack up, richdocuments active, WOPI URLs"
echo "configured, Collabora discovery + capabilities ok, test document"
echo "openable through richdocuments with a WOPI token, WebSocket app"
echo "proxy /ws/<appid>/ reaches <appid>-ws:3001."
