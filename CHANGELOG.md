# Changelog

- 2026-10-31 **1.0.6**
    - The workflow and the branch contract name `new-30` to `new-35` as built, as on `new`, where Nextcloud 30 to 32 run on PHP 8.3 and 8.4 again; the legacy image is unchanged.

- 2026-10-31 **1.0.5**
    - The tags `13` to `23` are built again, on Ubuntu jammy, and deliver its patched PHP 8.1, the fix of CVE-2026-109618 and CVE-2026-109619 included. Nextcloud 13 to 23 refuse every PHP above 8.0 and do not start in them, as before, when they carried the PHP 8.3 of noble.

- 2026-10-31 **1.0.4**
    - The tags `24` to `29` are built again, on Ubuntu jammy, and get every PHP fix of Ubuntu like `30` to `35`, among them the fix of CVE-2026-109618 and CVE-2026-109619. Until now `25` to `29` carried PHP 8.1.2-1ubuntu2.23, and `24` carried the PHP 8.3 of noble, on which Nextcloud 24 does not start.
    - The tags `13` to `23` stay as published: Nextcloud 13 to 23 refuse every PHP above 8.0, which no Ubuntu release with security updates carries.

- 2026-10-26 **1.0.3**
    - Every published version carries a leading `v`: `master` publishes `latest`, `v1.0.3` and both with the date, the branches `30` to `35` `35`, `35-v1.0.3` and both with the date. The tags `1.0.2`, `35-1.0.2` and their like stay published.
    - A push to `master` rebuilds `30` to `35` from the pushed commit, so every Nextcloud major version of the legacy image publishes the version just pushed.

- 2026-10-21 **1.0.2**
    - PHP runs with session upload progress off, locked against `.htaccess`: the mitigation the advisory of CVE-2026-109619 names for Apache `mod_php`, where both PHP vulnerabilities of 21 October allow remote code execution; the complete fix is the PHP update of Ubuntu

- 2026-10-03 **1.0.1**
    - The weekly rebuild no longer starts the branches of the images `nginx-30` to `nginx-32` and `php-fpm-30` to `php-fpm-32`, which cannot install Nextcloud 30 to 32 on PHP 8.5; the legacy tags `30` to `35` stay the upgrade path for these versions.

- 2026-10-02 **1.0.0**
    - The image no longer needs the root password of the database: it stops raising `max_connections` itself, and `MAX_REQUEST_WORKERS`, default 100, keeps Apache below the default connection limit of the database, so a burst of requests waits instead of failing with «Too many connections».
    - Every image is also published with the day of its build and its version, and every Nextcloud major version from 30 to 35 under its own tag; the test of a version branch checks that the image carries exactly that major version.
    - Images are built and published on every change and every Monday for the security fixes of the base image.
