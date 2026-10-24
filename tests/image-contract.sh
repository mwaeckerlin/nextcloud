#!/usr/bin/env bash
# Image contract: every shipped image must be headless.
#
# A production image must contain nothing that lets an attacker who reaches
# code execution pivot: no shell, no perl, no busybox. The image ships the
# service binary, its libraries and its configuration — nothing else.
#
# The check runs the interpreter as the container entrypoint instead of asking
# the image to look at its own filesystem: a headless image has no `ls` either,
# so a missing tool must be detected from outside. `--pull=never` keeps docker
# from silently pulling a stale image from the registry when the local build is
# missing; that would test the wrong artefact.
#
# Usage: tests/image-contract.sh IMAGE...

set -uo pipefail

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

# Absence of the interpreter is the pass condition, so the image itself must be
# present — otherwise every check would "pass" on a nonexistent image.
_image_exists() {
    local image="$1"
    if docker image inspect "${image}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "${image}_image_exists" "image not built — run 'npm run build' first"
    return 1
}

_no_interpreter() {
    local image="$1" path="$2" name="$3"
    shift 3
    if docker run --rm --pull=never --entrypoint "${path}" "${image}" "$@" > /dev/null 2>&1; then
        _fail "${image}_no_${name}" "${path} exists — image is not headless"
    else
        _pass "${image}_no_${name}"
    fi
}

# A version branch new-NN sets `ARG SOURCE_FILE="latest-NN.tar.bz2"`; its image
# must then carry Nextcloud NN, because an installation upgrades one major
# version at a time and pulls the tag of exactly the version it steps to. The
# branch new downloads `latest.tar.bz2` and accepts any version. Only the
# php-fpm image carries the real version.php; the nginx image has stubs.
_nextcloud_major() {
    local image="$1" expected
    expected=$(sed -nE 's/^ARG SOURCE_FILE="latest-([0-9]+)\.tar\.bz2"$/\1/p' php-fpm/Dockerfile)
    local major
    major=$(docker run --rm --pull=never --entrypoint /usr/bin/php "${image}" \
        -r 'include "/app/version.php"; echo $OC_Version[0];' 2> /dev/null)
    if [[ -z "${major}" ]]; then
        _fail "${image}_nextcloud_version" "no /app/version.php readable"
    elif [[ -n "${expected}" && "${major}" != "${expected}" ]]; then
        _fail "${image}_nextcloud_version" "Nextcloud ${major}, branch expects ${expected}"
    else
        _pass "${image}_nextcloud_version (${major})"
    fi
}

echo "==> Image contract: headless images"

for image in "$@"; do
    _image_exists "${image}" || continue
    _no_interpreter "${image}" /bin/sh      sh      -c :
    _no_interpreter "${image}" /bin/bash    bash    -c :
    _no_interpreter "${image}" /bin/busybox busybox ls /
    _no_interpreter "${image}" /usr/bin/perl perl   -e 1
    if [[ "${image}" == *:nginx* ]]; then
        # nginx starts without php-fpm and collabora: in a swarm their names
        # reach the DNS only once their tasks run, so nginx resolves them per
        # request and answers 502 until they are there.
        alone_net="nc-contract-alone-$$"
        docker network create "${alone_net}" > /dev/null
        docker run -d --pull=never --name nc-contract-nginx-alone --network "${alone_net}" "${image}" > /dev/null
        sleep 5
        running=$(docker inspect --format '{{.State.Running}}' nc-contract-nginx-alone 2> /dev/null)
        codes=""
        for path in /index.php /browser/dist/cool.html /hosting/discovery /push/test/version /standalone-signaling/api/v1/welcome; do
            codes+="$(docker run --rm --network "${alone_net}" curlimages/curl:8.10.1 --silent --max-time 10 \
                --output /dev/null --write-out '%{http_code}' "http://nc-contract-nginx-alone:8080${path}") "
        done
        startlog=$(grep -m1 'emerg' <<< "$(docker logs nc-contract-nginx-alone 2>&1)" || true)
        docker rm -f nc-contract-nginx-alone > /dev/null
        docker network rm "${alone_net}" > /dev/null
        if [[ "${running}" == "true" && "${codes}" == "502 502 502 502 502 " ]]; then
            _pass "${image}_starts_without_upstreams"
        else
            _fail "${image}_starts_without_upstreams" "running=${running}, answers ${codes}${startlog}"
        fi
        # The nginx image leaves out what no browser requests: source maps and
        # the sample files of new users. The browser still loads the bundles
        # and both forms of the translations (l10n/<lang>.js, and
        # l10n/<lang>.json through loadTranslations of @nextcloud/l10n). The
        # one source map the setup check of the admin overview requests stays.
        lister=$(docker create --pull=never "${image}")
        files=$(docker export "${lister}" | tar -t)
        docker rm "${lister}" > /dev/null
        maps=$(grep '\.map$' <<< "${files}" | grep -vx 'app/apps/settings/js/map-test.js.map' || true)
        if [[ -n "${maps}" ]]; then
            _fail "${image}_no_source_maps" "$(grep -c . <<< "${maps}") .map files in the image"
        else
            _pass "${image}_no_source_maps"
        fi
        if grep -q '^app/core/skeleton/' <<< "${files}"; then
            _fail "${image}_no_skeleton" "app/core/skeleton is in the image"
        else
            _pass "${image}_no_skeleton"
        fi
        for kept in app/dist/core-common.js app/core/l10n/de.js app/core/l10n/de.json app/apps/settings/js/map-test.js.map; do
            if grep -qx "${kept}" <<< "${files}"; then
                _pass "${image}_keeps_${kept}"
            else
                _fail "${image}_keeps_${kept}" "${kept} is missing"
            fi
        done
    fi
    if [[ "${image}" == *:php-fpm* ]]; then
        _nextcloud_major "${image}"
        # php-fpm only checks that the browser files exist: no source maps but
        # the one the setup check links to with linkTo(), which needs the file
        # in php-fpm to build its address; JavaScript and CSS are empty, and
        # the release is signed again by a CA of the build that root.crt
        # lists after the Nextcloud CA.
        lister=$(docker create --pull=never "${image}")
        listing=$(docker export "${lister}" | tar -tv)
        root_crt=$(docker export "${lister}" | tar -xO app/resources/codesigning/root.crt)
        docker rm "${lister}" > /dev/null
        maps=$(grep '\.map$' <<< "${listing}" | grep -v ' app/apps/settings/js/map-test\.js\.map$' || true)
        if [[ -n "${maps}" ]]; then
            _fail "${image}_no_source_maps" "$(grep -c . <<< "${maps}") .map files in the image"
        else
            _pass "${image}_no_source_maps"
        fi
        if grep -q ' app/apps/settings/js/map-test\.js\.map$' <<< "${listing}"; then
            _pass "${image}_keeps_map_test"
        else
            _fail "${image}_keeps_map_test" "app/apps/settings/js/map-test.js.map is missing"
        fi
        # a new data or config volume takes over what the image holds there,
        # so a log file of the build would be the start of a growing file
        if grep -qE ' app/(data|config)/[^/]*\.log$' <<< "${listing}"; then
            _fail "${image}_no_log_file" "log files in the image: $(grep -oE 'app/(data|config)/[^/]*\.log$' <<< "${listing}" | tr '\n' ' ')"
        else
            _pass "${image}_no_log_file"
        fi
        core_common=$(grep -E ' app/dist/core-common\.js$' <<< "${listing}" | awk '{print $3}')
        if [[ "${core_common}" == "0" ]]; then
            _pass "${image}_empty_browser_files"
        else
            _fail "${image}_empty_browser_files" "app/dist/core-common.js has '${core_common}' bytes"
        fi
        nginx_image="${image/:php-fpm/:nginx}"
        lister=$(docker create --pull=never "${nginx_image}")
        nextcloud_ca=$(docker export "${lister}" | tar -xO app/resources/codesigning/root.crt)
        docker rm "${lister}" > /dev/null
        # the release ships one or more CAs of Nextcloud; the build adds one
        expected_cas=$(( $(grep -c 'BEGIN CERTIFICATE' <<< "${nextcloud_ca}") + 1 ))
        if [[ $(grep -c 'BEGIN CERTIFICATE' <<< "${root_crt}") == "${expected_cas}" && "${root_crt}" == "${nextcloud_ca}"* ]]; then
            _pass "${image}_root_crt_keeps_nextcloud_ca"
        else
            _fail "${image}_root_crt_keeps_nextcloud_ca" "root.crt holds $(grep -c 'BEGIN CERTIFICATE' <<< "${root_crt}") certificates, expected ${expected_cas}, Nextcloud CAs first: $([[ "${root_crt}" == "${nextcloud_ca}"* ]] && echo yes || echo no)"
        fi
        # Every PHP process holds one database connection while it answers,
        # so the pool must stay below max_connections of the database (151
        # by default): MAX_REQUEST_WORKERS of the legacy image, default 100,
        # read from the configuration php-fpm really loads (-tt prints it).
        for workers in default 7; do
            expected=$([[ ${workers} == default ]] && echo 100 || echo "${workers}")
            env_args=()
            [[ ${workers} == default ]] || env_args=(-e "MAX_REQUEST_WORKERS=${workers}")
            pool=$(docker run --rm --pull=never "${env_args[@]}" --entrypoint /usr/sbin/php-fpm "${image}" -tt 2>&1)
            if grep -qE "pm\.max_children = ${expected}$" <<< "${pool}"; then
                _pass "${image}_max_request_workers_${workers} (${expected})"
            else
                _fail "${image}_max_request_workers_${workers}" "pm.max_children is not ${expected}: '$(grep -E 'pm\.max_children|ERROR' <<< "${pool}")'"
            fi
        done
        # CVE-2026-109619: the pool of the base image locks the session
        # upload progress and the fatal error backtraces off, and nothing of
        # nextcloud turns them back on
        pool=$(docker run --rm --pull=never --entrypoint /usr/sbin/php-fpm "${image}" -tt 2>&1)
        for flag in session.upload_progress.enabled fatal_error_backtraces; do
            if grep -Eq "${flag//./\\.}\] = (off|no|0)" <<< "${pool}"; then
                _pass "${image}_${flag}_locked"
            else
                _fail "${image}_${flag}_locked" "the pool does not lock ${flag} off"
            fi
        done
        info=$(docker run --rm --pull=never --entrypoint /usr/sbin/php-fpm "${image}" -i 2>&1)
        if grep -Eiq 'session\.upload_progress\.enabled( => |</td><td class="v">)(Off|0)' <<< "${info}"; then
            _pass "${image}_session_upload_progress_off"
        else
            _fail "${image}_session_upload_progress_off" "$(grep -i 'session.upload_progress.enabled' <<< "${info}" || echo 'setting not reported')"
        fi
        # Without a shell exec() can only fail, and Talk and Nextcloud report
        # that as errors; with exec off they skip it.
        if grep -Eq '^disable_functions => exec,shell_exec,system,passthru => ' <<< "${info}"; then
            _pass "${image}_shell_functions_disabled"
        else
            _fail "${image}_shell_functions_disabled" "$(grep '^disable_functions' <<< "${info}" || echo 'disable_functions not reported')"
        fi
        # The admin overview warns while OPcache keeps the PHP default of 8 MB
        # for interned strings; the image sets 32, OPCACHE_INTERNED_STRINGS_BUFFER
        # another value.
        for buffer in default 64; do
            option=()
            expected=32
            if [[ "${buffer}" != default ]]; then
                option=(-e "OPCACHE_INTERNED_STRINGS_BUFFER=${buffer}")
                expected=${buffer}
            fi
            info=$(docker run --rm --pull=never "${option[@]}" --entrypoint /usr/sbin/php-fpm "${image}" -i 2>&1)
            if grep -Eq "^opcache\.interned_strings_buffer => ${expected} => ${expected}$" <<< "${info}"; then
                _pass "${image}_opcache_interned_strings_buffer_${buffer}"
            else
                _fail "${image}_opcache_interned_strings_buffer_${buffer}" "$(grep 'opcache.interned_strings_buffer' <<< "${info}" || echo 'OPcache not reported')"
            fi
        done
        # MAX_CHILDREN of the base image does not override MAX_REQUEST_WORKERS:
        # zz-nextcloud.conf is read after www.conf of the base image.
        pool=$(docker run --rm --pull=never -e MAX_CHILDREN=7 --entrypoint /usr/sbin/php-fpm "${image}" -tt 2>&1)
        if grep -qE "pm\.max_children = 100$" <<< "${pool}"; then
            _pass "${image}_max_request_workers_over_max_children"
        else
            _fail "${image}_max_request_workers_over_max_children" "MAX_CHILDREN=7 changed the pool: '$(grep -E 'pm\.max_children|ERROR' <<< "${pool}")'"
        fi
        # The paths of the legacy image lead to the volumes of this one.
        legacy_paths=$(docker run --rm --pull=never --entrypoint /usr/bin/php "${image}" \
            -r 'foreach (["data", "config"] as $d) echo realpath("/var/www/nextcloud/$d"), " ";' 2> /dev/null)
        if [[ "${legacy_paths}" == "/app/data /app/config " ]]; then
            _pass "${image}_legacy_paths"
        else
            _fail "${image}_legacy_paths" "/var/www/nextcloud does not lead to /app: '${legacy_paths}'"
        fi
        # The variables of the legacy image keep its names and defaults.
        env_list=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2> /dev/null)
        for pair in MEMORY_LIMIT=1000M UPLOAD_MAX_FILESIZE=8G MAX_INPUT_TIME=3600 MAX_REQUEST_WORKERS=100 \
                    WAIT_SECONDS_FOR_MYSQL=300 HOST= URL= PROTOCOL=https WEBROOT= DEBUG=0 ADMIN_PWD=; do
            if grep -qxF "${pair}" <<< "${env_list}"; then
                _pass "${image}_env_${pair}"
            else
                _fail "${image}_env_${pair}" "image sets $(grep "^${pair%%=*}=" <<< "${env_list}" || echo nothing)"
            fi
        done
        # WAIT_SECONDS_FOR_MYSQL bounds how long the installation waits for an
        # unreachable database before php-fpm starts anyway; nothing listens
        # on 127.0.0.1:3306, so every attempt is refused at once.
        waiter=$(docker run -d --pull=never -e MYSQL_HOST=127.0.0.1 -e MYSQL_PASSWORD=x \
            -e ADMIN_PWD=x -e WAIT_SECONDS_FOR_MYSQL=5 "${image}")
        waited=""
        for second in $(seq 1 90); do
            if grep -q 'Installation did not complete within retry window' <<< "$(docker logs "${waiter}" 2>&1)"; then
                waited=${second}
                break
            fi
            sleep 1
        done
        waiter_log=$(docker logs "${waiter}" 2>&1)
        docker rm -f "${waiter}" > /dev/null
        if [[ -n "${waited}" ]] && grep -q 'waiting up to 5s for the database' <<< "${waiter_log}"; then
            _pass "${image}_wait_seconds_for_mysql (gave up after ${waited}s)"
        else
            _fail "${image}_wait_seconds_for_mysql" "no end of the retry window within 90s, log: $(grep 'nextcloud-office-bootstrap' <<< "${waiter_log}" | cut -c1-300)"
        fi
        # MySQL 9 removes mysql_native_password: db-auth.php warns about the
        # account Nextcloud logs in with and names the ALTER USER; after an
        # administrator ran it, PHP logs in with caching_sha2_password. Against
        # a real MySQL 8.4 without TLS, as in the stack.
        mysql_net="nc-contract-mysql-$$"
        docker network create "${mysql_net}" > /dev/null
        docker run -d --name nc-contract-mysql --network "${mysql_net}" \
            -e MYSQL_ROOT_PASSWORD=contract-root -e MYSQL_DATABASE=nextcloud \
            mysql:8.4 --mysql-native-password=ON > /dev/null
        for second in $(seq 1 180); do
            docker exec nc-contract-mysql mysql -uroot -pcontract-root -e 'SELECT 1' > /dev/null 2>&1 && break
            sleep 1
        done
        docker exec nc-contract-mysql mysql -uroot -pcontract-root -e \
            "CREATE USER 'nextcloud'@'%' IDENTIFIED WITH mysql_native_password BY 'contract-pw'; GRANT ALL ON nextcloud.* TO 'nextcloud'@'%';" > /dev/null 2>&1
        auth_config=$(mktemp)
        printf '<?php\n$CONFIG = ["dbtype" => "mysql", "dbhost" => "nc-contract-mysql", "dbname" => "nextcloud", "dbuser" => "nextcloud", "dbpassword" => "contract-pw"];\n' > "${auth_config}"
        # mktemp creates it for its owner alone; the user of the image reads it
        chmod 644 "${auth_config}"
        auth_run() {
            local runner
            runner=$(docker create --pull=never --network "${mysql_net}" --entrypoint /usr/bin/php "${image}" /usr/local/bin/db-auth.php /tmp/config.php)
            docker cp "${auth_config}" "${runner}:/tmp/config.php" > /dev/null
            docker start -a "${runner}" 2>&1 || true
            docker rm "${runner}" > /dev/null
        }
        auth_first=$(auth_run)
        docker exec nc-contract-mysql mysql -uroot -pcontract-root -e \
            "ALTER USER 'nextcloud'@'%' IDENTIFIED WITH caching_sha2_password BY 'contract-pw'; FLUSH PRIVILEGES;" > /dev/null 2>&1
        auth_plugin=$(docker exec nc-contract-mysql mysql -uroot -pcontract-root -N -e "SELECT plugin FROM mysql.user WHERE user='nextcloud'" 2> /dev/null)
        auth_second=$(auth_run)
        docker rm -f nc-contract-mysql > /dev/null
        docker network rm "${mysql_net}" > /dev/null
        rm -f "${auth_config}"
        if [[ "${auth_first}" == *"warning: MySQL 8.4"*"mysql_native_password"*"ALTER USER 'nextcloud'@'%' IDENTIFIED WITH caching_sha2_password"* \
            && "${auth_plugin}" == caching_sha2_password && "${auth_second}" == *"the account nextcloud logs in with caching_sha2_password"* ]]; then
            _pass "${image}_mysql_account_on_mysql_native_password_is_reported"
            _pass "${image}_mysql_login_with_caching_sha2_password_without_tls"
        else
            _fail "${image}_mysql_account_on_mysql_native_password" "plugin '${auth_plugin}' after ALTER USER, first run: ${auth_first}, second run: ${auth_second}"
        fi
        # The image carries its health check as default, so a stack without a
        # healthcheck block in its compose file gets it too; it runs php
        # directly, the image has no shell. A start period of 60 minutes covers
        # a long upgrade, then six failed checks mark the container unhealthy.
        health=$(docker image inspect --format '{{json .Config.Healthcheck}}' "${image}" 2> /dev/null)
        if grep -q '"Test":\["CMD","/usr/bin/php","/usr/local/bin/health.php"\]' <<< "${health}" \
            && grep -q '"StartPeriod":3600000000000' <<< "${health}" \
            && grep -q '"StartInterval":5000000000' <<< "${health}" \
            && grep -q '"Interval":10000000000' <<< "${health}" \
            && grep -q '"Timeout":5000000000' <<< "${health}" \
            && grep -q '"Retries":6' <<< "${health}"; then
            _pass "${image}_healthcheck_default"
        else
            _fail "${image}_healthcheck_default" "no HEALTHCHECK running /usr/local/bin/health.php with interval 10s, timeout 5s, start period 60m, start interval 5s and 6 retries: ${health}"
        fi
        # Without a running php-fpm the check must report unhealthy.
        if docker run --rm --pull=never --entrypoint /usr/bin/php "${image}" /usr/local/bin/health.php > /dev/null 2>&1; then
            _fail "${image}_healthcheck_unhealthy_without_fpm" "health.php reports healthy while php-fpm does not run"
        else
            _pass "${image}_healthcheck_unhealthy_without_fpm"
        fi
    fi
    if [[ "${image}" == *:notify-push* ]]; then
        # The push server of Client Push is the release binary of notify_push
        # for the architecture of the image, and it runs without a shell.
        if grep -q 'notify_push' <<< "$(docker run --rm --pull=never "${image}" --help 2>&1)"; then
            _pass "${image}_runs"
        else
            _fail "${image}_runs" "$(docker run --rm --pull=never "${image}" --help 2>&1 | head -3)"
        fi
    fi
done

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
