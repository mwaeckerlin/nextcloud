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
        # The nginx image leaves out what no browser requests: source maps and
        # the sample files of new users. The browser still loads the bundles
        # and both forms of the translations (l10n/<lang>.js, and
        # l10n/<lang>.json through loadTranslations of @nextcloud/l10n).
        lister=$(docker create --pull=never "${image}")
        files=$(docker export "${lister}" | tar -t)
        docker rm "${lister}" > /dev/null
        if grep -q '\.map$' <<< "${files}"; then
            _fail "${image}_no_source_maps" "$(grep -c '\.map$' <<< "${files}") .map files in the image"
        else
            _pass "${image}_no_source_maps"
        fi
        if grep -q '^app/core/skeleton/' <<< "${files}"; then
            _fail "${image}_no_skeleton" "app/core/skeleton is in the image"
        else
            _pass "${image}_no_skeleton"
        fi
        for kept in app/dist/core-common.js app/core/l10n/de.js app/core/l10n/de.json; do
            if grep -qx "${kept}" <<< "${files}"; then
                _pass "${image}_keeps_${kept}"
            else
                _fail "${image}_keeps_${kept}" "${kept} is missing"
            fi
        done
    fi
    if [[ "${image}" == *:php-fpm* ]]; then
        _nextcloud_major "${image}"
        # php-fpm only checks that the browser files exist: no source maps,
        # JavaScript and CSS are empty, and the release is signed again by a
        # CA of the build that root.crt lists after the Nextcloud CA.
        lister=$(docker create --pull=never "${image}")
        listing=$(docker export "${lister}" | tar -tv)
        root_crt=$(docker export "${lister}" | tar -xO app/resources/codesigning/root.crt)
        docker rm "${lister}" > /dev/null
        if grep -q '\.map$' <<< "${listing}"; then
            _fail "${image}_no_source_maps" "$(grep -c '\.map$' <<< "${listing}") .map files in the image"
        else
            _pass "${image}_no_source_maps"
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
            if docker logs "${waiter}" 2>&1 | grep -q 'Installation did not complete within retry window'; then
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
        # The image carries its health check as default, so a stack without a
        # healthcheck block in its compose file gets it too; it runs php
        # directly, the image has no shell. Timing as in the legacy image.
        health=$(docker image inspect --format '{{json .Config.Healthcheck}}' "${image}" 2> /dev/null)
        if grep -q '"Test":\["CMD","/usr/bin/php","/usr/local/bin/health.php"\]' <<< "${health}" \
            && grep -q '"StartPeriod":300000000000' <<< "${health}" \
            && grep -q '"Retries":240' <<< "${health}"; then
            _pass "${image}_healthcheck_default"
        else
            _fail "${image}_healthcheck_default" "no HEALTHCHECK running /usr/local/bin/health.php with start period 300s and 240 retries: ${health}"
        fi
        # Without a running php-fpm the check must report unhealthy.
        if docker run --rm --pull=never --entrypoint /usr/bin/php "${image}" /usr/local/bin/health.php > /dev/null 2>&1; then
            _fail "${image}_healthcheck_unhealthy_without_fpm" "health.php reports healthy while php-fpm does not run"
        else
            _pass "${image}_healthcheck_unhealthy_without_fpm"
        fi
    fi
done

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
