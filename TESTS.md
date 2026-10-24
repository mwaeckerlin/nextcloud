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
- **F10** checks that background jobs run in cron mode and `lastcron` is set; switches on maintenance mode, restarts `nextcloud-php-fpm`, waits until it is healthy again and checks that the start logged the upgrade and repair. Finds `/app/data/nextcloud.log` as the only log file in `/app/data` and `/app/config`, and Nextcloud's entries in it and in the container log; with `LOG_MAX_SIZE=256K` saves the log settings of a legacy installation (`log_type` `syslog`, `logfile` `/app/data/legacy.log`, `log_rotate_size` `0`, `loglevel` `0`), sends requests through nginx until more than 1M of log reached the container log, runs `occ` and `cron.php`, and finds `nextcloud.log` below 512K and still the only log file; checks that the saved `loglevel` `0` applies, that `LOGLEVEL=3` overrides it, and that the default without a saved level is `2`. Enables an app `noisy` that writes 88KB to stderr on every `occ` call and restarts `nextcloud-php-fpm`, which must become healthy. Sets the `version` in `config.php` one step back, stops the database, restarts `nextcloud-php-fpm`, starts the database 60 seconds later, and checks that `nextcloud-php-fpm` becomes healthy, logged an upgrade and carries the version of the image.
- **F13** sets `oc_appconfig` to `ROW_FORMAT=COMPACT` and drops `share_with_index` of `oc_share`, restarts `nextcloud-php-fpm`, and waits until the table is `Dynamic`, the index is back and the container log names the conversion and the result of the setup checks; reads `serverid` (0 to 511, and `7` with `SERVER_ID=7`); fetches `/index.php/settings/setupcheck`, the route of Administration settings › Overview, as admin with an `X-Forwarded-For` header and fails on every error and warning except `OCA\AppAPI\SetupChecks\DaemonCheck`, which needs a deploy daemon outside the images; HTTPS and `Strict-Transport-Security`, which the reverse proxy serves in production while the test runs over plain http; and the missing feature `changed-users` of the signaling server, whose latest release 2.1.1 lacks it. On a finding it prints the stored results of `serverinfo` and of the integrity check and the answer of nginx for `map-test.js.map`.
- **F13** a Chromium of the Playwright image logs in as admin and opens Administration settings › Overview, Basic settings, Nextcloud Office, Talk and Logging; every visible note card of the kind warning or error and every error toast fails the test, except one that names AppAPI and the two fixed texts about PDF scripting and end-to-end encrypted calls on mobile clients. This covers the allowlist for WOPI requests of Nextcloud Office.
- **F3** installs and enables ONLYOFFICE, restarts `nextcloud-php-fpm`, and finds ONLYOFFICE disabled and `richdocuments` enabled after the start.
- **F14** waits until the start installed `notify_push` and runs `occ notify_push:self-test` against `http://nextcloud-nginx:8080/push`, which must pass: Redis, the push server through nginx, its way back to Nextcloud, Nextcloud trusting it as a proxy, and the same version as the app.
- **F15** runs with `docker-compose.talk.yml` and a generated configuration of the signaling server, waits until the start installed Talk, fetches `/standalone-signaling/api/v1/welcome` through nginx; the setup checks above then cover the check of the high-performance backend.

## Image contract

`tests/image-contract.sh`, run by `npm run test:contract` against the built images.

- **F1** no sh, no bash, no busybox, no perl in either image; the `nginx` image holds no `*.map` file and no `app/core/skeleton`, and keeps `app/dist/core-common.js`, `app/core/l10n/de.js` and `app/core/l10n/de.json`; the `php-fpm` image holds no `*.map` file, no `*.log` file in `app/data` and `app/config`, and an empty `app/dist/core-common.js`.
- **F11** `resources/codesigning/root.crt` of the `php-fpm` image holds one certificate more than the release and starts with the unchanged certificates of the release, as the `nginx` image carries them.
- **F13** against a MySQL 8.4 with an account `nextcloud` on `mysql_native_password`, `db-auth.php` of the `php-fpm` image warns and names the `ALTER USER`; after root ran it, `db-auth.php` logs in without TLS and reports `caching_sha2_password`.
- **F14** the `notify-push` image runs its push server without a shell (`--help`); the `nginx` image, alone, answers 502 for `/push/test/version` and `/standalone-signaling/api/v1/welcome` (F15).
- **F13** `php-fpm -i` reports `disable_functions` `exec,shell_exec,system,passthru`.
- **F13** the `nginx` image keeps `app/apps/settings/js/map-test.js.map` as its only source map; `php-fpm -i` reports `opcache.interned_strings_buffer` `32`, and `64` with `OPCACHE_INTERNED_STRINGS_BUFFER=64`.
- **F5** the `php-fpm` image carries the Nextcloud major version the branch names in `ARG SOURCE_FILE`.
- **F7** `php-fpm -tt` in the `php-fpm` image loads `pm.max_children = 100` by default, `7` with `MAX_REQUEST_WORKERS=7`, and still `100` with `MAX_CHILDREN=7` of the base image.
- **F8** the `php-fpm` image carries a `HEALTHCHECK` that runs `/usr/bin/php /usr/local/bin/health.php` every 10 seconds with a timeout of 5 seconds, a start period of 60 minutes with a check every 5 seconds during it, and 6 retries, and the check reports unhealthy in a container where php-fpm does not run. The `nginx` image, started alone in an empty network, keeps running and answers 502 for `/index.php`, `/browser/…` and `/hosting/discovery`. The pool of the `php-fpm` image locks `session.upload_progress.enabled` and `fatal_error_backtraces` off, and `php-fpm -i` reports the first as `Off`.
- **F9** `/var/www/nextcloud/data` and `/var/www/nextcloud/config`, the paths of the legacy image, resolve to `/app/data` and `/app/config`; the `php-fpm` image sets the variables of the legacy image with its defaults; with an unreachable database and `WAIT_SECONDS_FOR_MYSQL=5` the installation gives up within 90 seconds and logs the window of 5 seconds.

## Branch contract

`tests/branch-rules.py`, run by `npm run test:branches`, applies the `branch-tags` rules of `.github/workflows/docker.yml` the way the shared workflow does.

- **F5** `new`, `new-33` to `new-35` and `30` to `35` are built with their suffix; `new-30` to `new-32` and `13` to `29` match no rule and stay frozen.

## Workflow contract

- **F6** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the images a repository publishes and the tags of its branch; this repository calls it from `.github/workflows/docker.yml`.
