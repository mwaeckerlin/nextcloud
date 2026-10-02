# Changelog

- 2026-10-02 **1.1.2**
    - Every image is also published with the day of its build and with the version, so a rebuild stays addressable, e.g. `nginx-33-1.1.2-20261002`.
    - Images are built and published for amd64 and arm64, on every change and every Monday for the security fixes of the base images.
    - The test of a version branch checks that its image carries exactly that Nextcloud major version.
    - The documentation explains how the number of PHP processes and the connection limit of the database work together, and how to raise the limit without giving Nextcloud the root password of the database.

- 2026-09-23 **1.1.1**
    - Version branches are created up to Nextcloud 35.

- 2026-07-23 **1.1.0**
    - Office (Collabora) app installation is reliable on slow connections: the app-store fetch timeout is configurable (`APPSTORE_TIMEOUT`, default 600 s — the ~12 MB store index used to abort at the 120 s default), a previously failed fetch no longer blocks the retry, and install/enable failures now log their real error output.
    - The shipped images are pinned headless by a new image-contract test (`npm test` runs it before the end-to-end suite).
    - The end-to-end suite no longer dies silently on a start-up race: it waits for the office WOPI configuration to appear (app enabled does not yet mean configured) and dumps the bootstrap log when it never does.
