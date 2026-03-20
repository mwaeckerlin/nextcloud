#!/bin/bash

git checkout master
git pull
for i in {25..33}; do
    git checkout $i 2>/dev/null || git checkout -b $i
    git fetch origin $i 2>/dev/null || true
    git reset --hard origin/master
    sed -i 's/ARG SOURCE_FILE="latest\.tar\.bz2"/ARG SOURCE_FILE="latest-'$i'.tar.bz2"/g' \
        php-fpm/Dockerfile
    date > rebuilt
    git add .
    git commit -m "Update to latest-$i"
    git push -f origin $i
done
git checkout master
