# Changelog

- 2026-10-24 **1.1.12**
    - The image test against MySQL 8.4 waits until the server answers over TCP; it went on while the temporary server of the MySQL start answered on its socket only, and failed on the arm64 runner.
    - The browser test of Collabora skips the onboarding tour that newer releases of Collabora show over the document.

- 2026-10-24 **1.1.11**
    - The images are rebuilt in an hourly check once a parent image or a download changed or the image is a week old, instead of once a week.
    - Tables still in `ROW_FORMAT=COMPACT` from an old installation are converted to `DYNAMIC` once per start, online, beside php-fpm; `occ db:add-missing-indices` runs there once more, because the run of the start left an index of an app missing.
    - Both images keep `apps/settings/js/map-test.js.map`: `nginx` serves it, and `php-fpm` needs it to build its address, so the source map check of the admin overview passes.
    - The start creates `appdata/theming/global` before the first background job: on a fresh installation the job `MigrateBackgroundImages` of Nextcloud failed on the missing folder, and the admin overview reported an error in the log.
    - The compose setup starts MariaDB with `--innodb-log-file-size=256M`, which the database checks of the admin overview ask for.
    - The image `php-fpm` builds on `mwaeckerlin/php-fpm` 1.2.11: OPcache keeps 32 MB for interned strings, `OPCACHE_INTERNED_STRINGS_BUFFER` and `OPCACHE_MEMORY_CONSUMPTION` set other sizes, and PHP loads the extension `redis`.
    - Every php-fpm container has a server ID; `SERVER_ID` now sets the key `serverid` Nextcloud reads, it set `server_id` before, which Nextcloud ignores.
    - The setup checks of the admin overview reach `nginx` from inside the container as `nextcloud-nginx:8080`.
    - The tests run every setup check of the admin overview and fail on its errors and warnings; the README lists what the administrator sets up outside the images.
    - On MySQL every start warns while the account of Nextcloud logs in with `mysql_native_password`, which MySQL 9 removes, and names the `ALTER USER` that switches it to `caching_sha2_password`.
    - Once per start the setup checks run beside php-fpm, repair what an `occ` command repairs and write what remains into the container log.
    - Nextcloud writes its log again to `/app/data/nextcloud.log`, readable under Administration settings › Logging; every line also reaches the container log, and the file is emptied at `LOG_MAX_SIZE` (default 100M) without leaving a rotated copy.
    - Nextcloud reads the client address from `X-Forwarded-For` of the proxies in `TRUSTED_PROXIES`, by default the private networks of Docker.
    - With `REDIS_HOST` Nextcloud locks files and shares its cache in Redis; the compose setup runs `mwaeckerlin/redis`.
    - New image `mwaeckerlin/nextcloud:notify-push`, the push server of Client Push; with `NOTIFY_PUSH_HOST` the start installs the app `notify_push`, and `nginx` forwards `/push/` to the push server.
    - `docker-compose.talk.yml` adds the Talk high-performance backend, a signaling server and NATS; with `TALK_SIGNALING_HOST` the start installs Talk and registers the server, and `nginx` forwards `/standalone-signaling/` to it.
    - `nginx` serves `.wasm`, `.tflite` and `.webp` files of apps directly.
    - PHP declares `exec`, `shell_exec`, `system` and `passthru` off, from `mwaeckerlin/php-fpm` 1.2.12, as fits an image without a shell; reported as available, they made Nextcloud log «exec(): Unable to fork» and Talk report an incompatible Apache configuration.
    - Collabora is the only office app: the start disables ONLYOFFICE where an earlier installation enabled it, because both claim the same file types.
    - Nextcloud Office allows WOPI requests only from the private networks of Docker, or from `OFFICE_WOPI_ALLOWLIST`; an empty variable removed the allowlist before, and Nextcloud Office warned that any host could fetch documents.
    - A browser test opens the administration pages Overview, Basic settings, Nextcloud Office, Talk and Logging and fails on every warning and error they show.

- 2026-10-23 **1.1.10**
    - The image `nginx` starts without `php-fpm` and Collabora and answers 502 until they are there; in a Docker Swarm it died at the start while their names were not yet in the DNS.
    - The image `php-fpm` waits for the database before it decides between installation and upgrade, so a database that starts together with it no longer skips the upgrade.
    - The start no longer hangs when an `occ` command writes much to stderr, and it shows every step with the output of `occ` as it comes and the time the step took.
    - The health check of the image `php-fpm` gives a start of up to 60 minutes, enough for a long upgrade, checks every 5 seconds during it, so a quick start is healthy within seconds, and marks the container unhealthy after six failed checks, one every 10 seconds with a timeout of 5 seconds, instead of the two hours and five minutes of the legacy image.
    - Nextcloud logs to the container log only, also where a `logfile` of the legacy image stands in `config.php`, and the image no longer carries the empty `data/nextcloud.log` its build left behind, which every new data volume took over; `LOGLEVEL` overrides a saved debug level.
    - The image `php-fpm` is tested for `session.upload_progress.enabled` and `fatal_error_backtraces` locked off (CVE-2026-109619).

- 2026-10-22 **1.1.9**
    - The image `php-fpm` builds on `mwaeckerlin/php-fpm` 1.2.10, which takes its PHP limits from variables; in this image `UPLOAD_MAX_FILESIZE`, `MAX_INPUT_TIME` and `MAX_REQUEST_WORKERS` keep setting `post_max_size`, `max_execution_time` and `pm.max_children`, as in the legacy image.

- 2026-10-22 **1.1.8**
    - The image `php-fpm` builds on `mwaeckerlin/php-fpm` 1.2.9: its health check uses the FastCGI client of the base image, and `occ` runs without the warning about the missing `pcntl`.

- 2026-10-22 **1.1.7**
    - The image `nginx` leaves out the source maps of the JavaScript bundles and the sample files of new users, which no browser requests: about 300M less.
    - The image `php-fpm` leaves out the source maps and keeps JavaScript and CSS as empty files. The build signs the release again with a CA of its own beside the Nextcloud CA, so the integrity check stays active and passes.
    - The mail server, the phone region, the maintenance window and the log level saved under Administration settings, or by the legacy image, take effect again; the image sets `smtp-relay:25` and its other defaults only where nothing is saved. An external mail server with login is also set by `MAIL_SMTPHOST`, `MAIL_SMTPPORT`, `MAIL_SMTPSECURE`, `MAIL_SMTPNAME` and the secret `nextcloud_smtp_password`, which take precedence.
    - The tests open a document in Collabora in a real browser, edit and save it.
    - The development `docker-compose.yml` takes its host port from `NEXTCLOUD_HTTP_PORT` (default `8824`), for nginx and Collabora alike.
    - The unused files `php-fpm/99-nextcloud.ini` and `php-fpm/fpm.conf` are gone; the variables set the PHP limits, and further PHP settings go into a mounted `.ini` file.

- 2026-10-21 **1.1.6**
    - The images `nginx` and `php-fpm` take the variables of the legacy image again, with the same names and defaults: `UPLOAD_MAX_FILESIZE` (8G), `MEMORY_LIMIT` (1000M), `MAX_INPUT_TIME` (3600, also the timeout of `nginx`), `MAX_REQUEST_WORKERS` (100), `WAIT_SECONDS_FOR_MYSQL` (300), `URL` beside `HOST`, and `MYSQL_ENV_MYSQL_*`. `HOST` is empty by default, so `URL` takes effect.
    - The image `php-fpm` reports its health to Docker without any configuration, as the legacy image does: healthy once it answers requests, Nextcloud is installed, not in maintenance mode and needs no database upgrade. `nginx` starts only once `php-fpm` is healthy.
    - At most 100 PHP processes run at the same time by default, up from 50.
    - Every start of the image `php-fpm` upgrades and repairs an installed Nextcloud, as the legacy image does, and background jobs run by cron every 15 minutes with a daily file scan.
    - `/var/www/nextcloud`, the directory of the legacy image, leads to `/app`, so a `config.php` and the `data` and `config` volumes of the legacy image keep their paths.
    - The unattended installation waits for the database: a refused connection no longer counts as a completed installation.

- 2026-10-21 **1.1.5**
    - The WebSocket example of the documentation names a neutral app `myapp`

- 2026-10-21 **1.1.4**
    - The PHP CLI that installs and upgrades Nextcloud comes from `mwaeckerlin/php-fpm` 1.2.6, which builds on the official PHP image; the image no longer copies the CLI of the Alpine PHP packages, which found no modules on the new base

- 2026-10-03 **1.1.3**
    - The images `nginx-30` to `nginx-32` and `php-fpm-30` to `php-fpm-32` are no longer rebuilt: Nextcloud 30 to 32 refuse PHP 8.5, the only PHP of the base image, so these tags never installed. Their published tags stay; the legacy tags `30` to `35` remain the upgrade path for Nextcloud 30 to 32.

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
