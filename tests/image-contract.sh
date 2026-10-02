#!/usr/bin/env bash
# Image contract of the legacy single image: Apache, PHP and Nextcloud.
#
# A version branch NN sets `ENV SOURCE_FILE="latest-NN.tar.bz2"`; its image
# must then carry Nextcloud NN, because an installation upgrades one major
# version at a time and pulls the tag of exactly the version it steps to. The
# branch master downloads `latest.tar.bz2` and accepts any version.
#
# `--pull=never` keeps docker from silently pulling a stale image from the
# registry when the local build is missing; that would test the wrong artefact.
#
# Usage: tests/image-contract.sh IMAGE

set -uo pipefail

cd "$(dirname "$0")/.."

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_run() { docker run --rm --pull=never --entrypoint "$@" 2> /dev/null; }

image="$1"
expected=$(sed -nE 's/^ENV SOURCE_FILE="latest-([0-9]+)\.tar\.bz2"$/\1/p' Dockerfile)

echo "==> Image contract: legacy image ${image}"

if ! docker image inspect "${image}" > /dev/null 2>&1; then
    _fail "image_exists" "image not built — run 'npm run build' first"
else
    _pass "image_exists"

    major=$(_run /usr/bin/php "${image}" -r 'include "/var/www/nextcloud/version.php"; echo $OC_Version[0];')
    if [[ -z "${major}" ]]; then
        _fail "nextcloud_version" "no /var/www/nextcloud/version.php readable"
    elif [[ -n "${expected}" && "${major}" != "${expected}" ]]; then
        _fail "nextcloud_version" "Nextcloud ${major}, branch expects ${expected}"
    else
        _pass "nextcloud_version (${major})"
    fi

    # the PHP modules Nextcloud refuses to start without
    modules=$(_run /usr/bin/php "${image}" -m)
    for module in gd mysqli pdo_mysql curl mbstring intl xml zip; do
        if grep -qix "${module}" <<< "${modules}"; then
            _pass "php_module_${module}"
        else
            _fail "php_module_${module}" "PHP module missing"
        fi
    done

    if _run /usr/sbin/apache2 "${image}" -v > /dev/null; then
        _pass "apache2"
    else
        _fail "apache2" "/usr/sbin/apache2 does not run"
    fi

    if _run /usr/bin/test "${image}" -x /start.sh; then
        _pass "start_script"
    else
        _fail "start_script" "/start.sh missing or not executable"
    fi

    # Every Apache worker holds one database connection while it answers, so
    # the number of workers must stay below max_connections of the database
    # (151 by default). The image bounds it with MAX_REQUEST_WORKERS, default
    # 100, and never touches the database's own limit, which needs root.
    default=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" \
        | sed -n 's/^MAX_REQUEST_WORKERS=//p')
    if [[ "${default}" == "100" ]]; then
        _pass "max_request_workers_default (100)"
    else
        _fail "max_request_workers_default" "MAX_REQUEST_WORKERS is '${default}', expected 100"
    fi
    prefork=$(_run /bin/cat "${image}" /etc/apache2/mods-enabled/mpm_prefork.conf)
    if grep -q 'MaxRequestWorkers *${MAX_REQUEST_WORKERS}' <<< "${prefork}" \
        && grep -q 'ServerLimit *${MAX_REQUEST_WORKERS}' <<< "${prefork}"; then
        _pass "prefork_bounded_by_max_request_workers"
    else
        _fail "prefork_bounded_by_max_request_workers" "mpm_prefork.conf does not take MaxRequestWorkers and ServerLimit from MAX_REQUEST_WORKERS"
    fi
    if docker run --rm --pull=never -e MAX_REQUEST_WORKERS=37 --entrypoint /usr/sbin/apache2ctl "${image}" -t 2>&1 \
        | grep -q 'Syntax OK'; then
        _pass "apache_config_valid_with_override"
    else
        _fail "apache_config_valid_with_override" "apache2ctl -t fails with MAX_REQUEST_WORKERS=37"
    fi
    if _run /bin/grep "${image}" -q max_connections /start.sh; then
        _fail "no_database_limit_change" "/start.sh still changes max_connections of the database"
    else
        _pass "no_database_limit_change"
    fi
fi

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
