# Features

Numbered register of every feature an operator or user of the images sees; a number is never reused. Every feature is covered by tests listed in [TESTS.md](TESTS.md).

- **F1 — Two headless images.** `mwaeckerlin/nextcloud:nginx` serves the web frontend, `mwaeckerlin/nextcloud:php-fpm` runs Nextcloud; neither image carries a shell, bash, busybox or perl.
- **F2 — Unattended installation.** On the first start Nextcloud installs itself against MariaDB, with the database and admin passwords read from Docker secrets, and needs no browser step.
- **F3 — Office works out of the box.** The office app `richdocuments` is installed and configured against Collabora, and a document uploaded over WebDAV opens in the office editor.
- **F4 — WebSocket apps without nginx changes.** A request to `/ws/<appid>/<path>` reaches the service `<appid>-ws` on port 3001 with the path and query string after `/ws/<appid>`.
- **F5 — One tag per Nextcloud major version.** Branch `new-NN` publishes `nginx-NN` and `php-fpm-NN`, and its `php-fpm` image carries exactly Nextcloud `NN`, so an installation can step through the major versions one at a time.
- **F6 — Published for amd64 and arm64 with date and version tags.** Every push and every Monday builds the images natively for both architectures and publishes them under their tag, the day of the build and the version, with the reusable workflow of `mwaeckerlin/scratch`.
- **F7 — Bounded database connections.** At most 50 PHP processes answer at the same time, a limit of the base image `mwaeckerlin/php-fpm`, so Nextcloud stays below the default connection limit of the database and needs no root password for it.
