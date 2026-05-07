#!/bin/bash
set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-new}"
START_VERSION="${START_VERSION:-30"
END_VERSION="${END_VERSION:-33}"

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

    git checkout -B "$branch" "origin/$BASE_BRANCH"

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
