# Changelog

- 2026-10-03 **1.0.1**
    - The weekly rebuild no longer starts the branches of the images `nginx-30` to `nginx-32` and `php-fpm-30` to `php-fpm-32`, which cannot install Nextcloud 30 to 32 on PHP 8.5; the legacy tags `30` to `35` stay the upgrade path for these versions.

- 2026-10-02 **1.0.0**
    - The image no longer needs the root password of the database: it stops raising `max_connections` itself, and `MAX_REQUEST_WORKERS`, default 100, keeps Apache below the default connection limit of the database, so a burst of requests waits instead of failing with «Too many connections».
    - Every image is also published with the day of its build and its version, and every Nextcloud major version from 30 to 35 under its own tag; the test of a version branch checks that the image carries exactly that major version.
    - Images are built and published on every change and every Monday for the security fixes of the base image.
