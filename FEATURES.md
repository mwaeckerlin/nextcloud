# Features

Numbered register of every feature an operator of the legacy image sees; a number is never reused. Every feature is covered by tests listed in [TESTS.md](TESTS.md).

- **F1 — Nextcloud in one Apache image.** Apache with mod_php and the PHP modules Nextcloud needs serves Nextcloud from `/var/www/nextcloud`; `/start.sh` installs or upgrades it at every start.
- **F2 — One tag per Nextcloud major version.** Branch `NN` publishes the tag `NN`, and its image carries exactly Nextcloud `NN`, so an installation can step through the major versions one at a time.
- **F3 — Bounded database connections.** `MAX_REQUEST_WORKERS`, default 100, bounds the Apache workers and with them the database connections, and the image never changes the limit of the database and needs no root password.
- **F4 — Published with date and version tags.** Every push and every Monday builds the image for amd64 and publishes it under its tag, the day of the build and the version, with the reusable workflow of `mwaeckerlin/scratch`.
- **F5 — Session upload progress off.** PHP under Apache runs with `session.upload_progress.enabled` off, locked in the Apache configuration against `.htaccess`: the mitigation the advisory of CVE-2026-109619 names, until the PHP of Ubuntu carries the fix.
