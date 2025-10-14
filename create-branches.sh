#!/bin/bash

git checkout master
git pull
for i in {13..32}; do
    git checkout $i 2>/dev/null || git checkout -b $i
    git pull
    git reset --hard origin/master
    sed -i 's/ENV SOURCE_FILE="latest.*"/ENV SOURCE_FILE="latest-'$i'.tar.bz2"/g' Dockerfile
    date > rebuilt
    git add .
    git commit -m "Update to latest-$i"
    git push -f origin $i
done
