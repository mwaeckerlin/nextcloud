#!/bin/bash

git checkout master
git pull
for i in {30..35}; do
    export VERSION=noble
    if [ $i -lt 31 ]; then
        export VERSION=jammy
    fi
    git checkout $i 2>/dev/null || git checkout -b $i
    git fetch origin $i
    git reset --hard origin/master
    sed -i 's/ARG VERSION=".*"/ARG VERSION="'$VERSION'"/g' Dockerfile
    sed -i 's/ENV SOURCE_FILE="latest.*"/ENV SOURCE_FILE="latest-'$i'.tar.bz2"/g' Dockerfile
    date > rebuilt
    git add .
    git commit -m "Update to latest-$i"
    git push -f origin $i
done
git checkout master