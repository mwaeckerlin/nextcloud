# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs the branch contract, the image contract and then the end-to-end suite; no test is skipped.

## End-to-end

`tests/e2e/run-compose-e2e.sh` builds and starts the whole compose stack, with Collabora and MariaDB, and tears it down afterwards.

- **F2** waits until `occ status` reports `installed: true`.
- **F3** waits until `richdocuments` is enabled and its WOPI URLs are set, checks `/hosting/discovery` and `/hosting/capabilities` of Collabora, uploads a document over WebDAV and opens it in the office editor. A Chromium of the Playwright image (`tests/e2e/office/`), in the network of the host, logs in under the address a user types, opens the document with `/f/<id>`, waits until Collabora shows it, types a text, saves with Ctrl+S, and finds that text in `content.xml` of the document WebDAV delivers.
- **F4** starts a stand-in backend `e2e-ws` on port 3001 and fetches `/ws/e2e/probe/answer.txt` through nginx.
- **F8** waits until Docker reports `nextcloud-php-fpm` as `healthy`, which the stack itself needs, since `nextcloud-nginx` starts only then; switches on maintenance mode, checks that `health.php` reports unhealthy and names the mode, and healthy again once the mode ends.
- **F9** starts the stack with `UPLOAD_MAX_FILESIZE=20G`, `MAX_INPUT_TIME=7200` and `MEMORY_LIMIT=1500M`, requests `tests/e2e/ini-probe.php` over FastCGI from a php-fpm worker and checks `upload_max_filesize`, `post_max_size`, `memory_limit`, `max_input_time` and `max_execution_time`; checks `fastcgi_read_timeout 7200s` in `nginx -T`; checks that `URL` alone sets `overwritehost` and that `HOST` takes precedence over `URL`.
- **F11** `occ integrity:check-core` and `occ integrity:check-app --all` pass with `richdocuments` from the App Store installed; a copy of the app `files` with a changed `appinfo/info.xml` fails `occ integrity:check-app` with `INVALID_HASH`.
- **F12** reads `mail_smtphost` with `occ config:system:get`: `smtp-relay` after the installation, `mail.example.test` after `occ config:system:set`, and `env.example.test` with `NC_mail_smtphost=env.example.test`. Against `mailpit` of `tests/e2e/docker-compose.mail.yml`, which accepts only one login: a mail sent through Nextcloud with `MAIL_SMTPHOST`, `MAIL_SMTPPORT`, `MAIL_SMTPNAME` and `MAIL_SMTPPASSWORD` arrives, one with a wrong password does not; the endpoints of the form under Administration settings save mailpit with login, and «Send email» delivers the test mail there.
- **F10** checks that background jobs run in cron mode and `lastcron` is set; switches on maintenance mode, restarts `nextcloud-php-fpm`, waits until it is healthy again and checks that the start logged the upgrade and repair. Finds no `*.log` in `/app/data` and `/app/config` and Nextcloud's entries in the container log; saves the log settings of a legacy installation (`log_type` `file`, `logfile` in the data volume, `log_rotate_size` `0`, `loglevel` `0`), sends requests through nginx, runs `occ` and `cron.php`, and still finds no log file and new entries in the container log; checks that the saved `loglevel` `0` applies, that `LOGLEVEL=3` overrides it, and that the default without a saved level is `2`. Enables an app `noisy` that writes 88KB to stderr on every `occ` call and restarts `nextcloud-php-fpm`, which must become healthy. Sets the `version` in `config.php` one step back, stops the database, restarts `nextcloud-php-fpm`, starts the database 60 seconds later, and checks that `nextcloud-php-fpm` becomes healthy, logged an upgrade and carries the version of the image.

## Image contract

`tests/image-contract.sh`, run by `npm run test:contract` against the built images.

- **F1** no sh, no bash, no busybox, no perl in either image; the `nginx` image holds no `*.map` file and no `app/core/skeleton`, and keeps `app/dist/core-common.js`, `app/core/l10n/de.js` and `app/core/l10n/de.json`; the `php-fpm` image holds no `*.map` file, no `*.log` file in `app/data` and `app/config`, and an empty `app/dist/core-common.js`.
- **F11** `resources/codesigning/root.crt` of the `php-fpm` image holds one certificate more than the release and starts with the unchanged certificates of the release, as the `nginx` image carries them.
- **F5** the `php-fpm` image carries the Nextcloud major version the branch names in `ARG SOURCE_FILE`.
- **F7** `php-fpm -tt` in the `php-fpm` image loads `pm.max_children = 100` by default, `7` with `MAX_REQUEST_WORKERS=7`, and still `100` with `MAX_CHILDREN=7` of the base image.
- **F8** the `php-fpm` image carries a `HEALTHCHECK` that runs `/usr/bin/php /usr/local/bin/health.php` every 10 seconds with a timeout of 5 seconds, a start period of 60 minutes with a check every 5 seconds during it, and 6 retries, and the check reports unhealthy in a container where php-fpm does not run. The `nginx` image, started alone in an empty network, keeps running and answers 502 for `/index.php`, `/browser/…` and `/hosting/discovery`. The pool of the `php-fpm` image locks `session.upload_progress.enabled` and `fatal_error_backtraces` off, and `php-fpm -i` reports the first as `Off`.
- **F9** `/var/www/nextcloud/data` and `/var/www/nextcloud/config`, the paths of the legacy image, resolve to `/app/data` and `/app/config`; the `php-fpm` image sets the variables of the legacy image with its defaults; with an unreachable database and `WAIT_SECONDS_FOR_MYSQL=5` the installation gives up within 90 seconds and logs the window of 5 seconds.

## Branch contract

`tests/branch-rules.py`, run by `npm run test:branches`, applies the `branch-tags` rules of `.github/workflows/docker.yml` the way the shared workflow does.

- **F5** `new`, `new-33` to `new-35` and `30` to `35` are built with their suffix; `new-30` to `new-32` and `13` to `29` match no rule and stay frozen.

## Workflow contract

- **F6** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the images a repository publishes and the tags of its branch; this repository calls it from `.github/workflows/docker.yml`.
