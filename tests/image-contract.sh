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
    if [[ "${image}" == *:php-fpm* ]]; then
        _nextcloud_major "${image}"
        # Every PHP process holds one database connection while it answers,
        # so the pool must stay below max_connections of the database (151
        # by default); the bound comes from the base image mwaeckerlin/php-fpm.
        local_pool=$(docker run --rm --pull=never --entrypoint /usr/bin/php "${image}" \
            -r 'foreach (glob("/etc/php*/php-fpm.d/www.conf") as $f) echo file_get_contents($f);' 2> /dev/null)
        if grep -qE '^pm\.max_children *= *50$' <<< "${local_pool}"; then
            _pass "${image}_php_fpm_max_children (50)"
        else
            _fail "${image}_php_fpm_max_children" "pm.max_children is not 50 in /etc/php*/php-fpm.d/www.conf: '$(grep -E '^pm\.max_children' <<< "${local_pool}")'"
        fi
    fi
done

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
