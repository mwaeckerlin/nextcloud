#!/bin/bash
set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-new}"
# Nextcloud 30 to 32 refuse the PHP 8.5 of mwaeckerlin/php-fpm, so their
# branches new-30 to new-32 stay frozen and are not rebuilt from here
START_VERSION="${START_VERSION:-33}"
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

    git checkout -B "$branch" "$BASE_COMMIT"

    sed -Ei "s|^ARG SOURCE_FILE=.*$|ARG SOURCE_FILE=\"${source_file}\"|" php-fpm/Dockerfile
    sed -Ei "s|^ARG SOURCE_FILE=.*$|ARG SOURCE_FILE=\"${source_file}\"|" nginx/Dockerfile

    date > rebuilt

    git add php-fpm/Dockerfile nginx/Dockerfile rebuilt
    if ! git diff --cached --quiet; then
        git commit -m "Build Nextcloud ${version} images"
    fi
    git push -f origin "$branch"
done

git checkout "$BASE_BRANCH"
