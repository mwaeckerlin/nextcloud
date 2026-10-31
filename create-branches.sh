#!/bin/bash
set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-new}"
START_VERSION="${START_VERSION:-30}"
END_VERSION="${END_VERSION:-35}"
# the workflow passes the commit of the push, so the branches carry exactly
# that commit and not what origin points at when the script runs
BASE_COMMIT="${BASE_COMMIT:-origin/$BASE_BRANCH}"

if [[ "$#" -gt 0 ]]; then
    VERSIONS=("$@")
else
    VERSIONS=()
    for ((v=START_VERSION; v<=END_VERSION; v++)); do
        VERSIONS+=("$v")
    done
fi

git fetch origin
git checkout "$BASE_BRANCH"
git pull --ff-only origin "$BASE_BRANCH"

for version in "${VERSIONS[@]}"; do
    branch="new-$version"
    source_file="latest-${version}.tar.bz2"
    # Nextcloud 30 refuses PHP 8.4 and newer, 31 and 32 refuse PHP 8.5; Nextcloud
    # 30 and 31 warn about a MariaDB newer than 11.4 in the admin overview
    php_fpm_image=""
    mariadb=""
    case "$version" in
        30) php_fpm_image="mwaeckerlin/php-fpm:8.3"; mariadb="mariadb:11.4" ;;
        31) php_fpm_image="mwaeckerlin/php-fpm:8.4"; mariadb="mariadb:11.4" ;;
        32) php_fpm_image="mwaeckerlin/php-fpm:8.4" ;;
    esac

    git checkout -B "$branch" "$BASE_COMMIT"

    sed -Ei "s|^ARG SOURCE_FILE=.*$|ARG SOURCE_FILE=\"${source_file}\"|" php-fpm/Dockerfile
    sed -Ei "s|^ARG SOURCE_FILE=.*$|ARG SOURCE_FILE=\"${source_file}\"|" nginx/Dockerfile
    if [[ -n "$php_fpm_image" ]]; then
        sed -Ei "s|^ARG PHP_FPM_IMAGE=.*$|ARG PHP_FPM_IMAGE=\"${php_fpm_image}\"|" php-fpm/Dockerfile
    fi
    if [[ -n "$mariadb" ]]; then
        sed -Ei "s|^(    image: )mariadb:.*$|\1${mariadb}|" docker-compose.yml example/docker-compose.yml
    fi

    date > rebuilt

    git add php-fpm/Dockerfile nginx/Dockerfile docker-compose.yml example/docker-compose.yml rebuilt
    if ! git diff --cached --quiet; then
        git commit -m "Build Nextcloud ${version} images"
    fi
    git push -f origin "$branch"
done

git checkout "$BASE_BRANCH"
