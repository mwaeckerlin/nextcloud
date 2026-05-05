# Minimalistic Secure Nextcloud Docker Images

Lean, hardened Nextcloud stack with two images:

- [mwaeckerlin/nextcloud:nginx]: NGINX Nextcloud frontend in only 608MB
- [mwaeckerlin/nextcloud:php-fpm]: PHP‑FPM Nextcloud backend in only 868MB

This splitting is in accordance to Docker philosophy of having only one server process per image and to NGINX which splits PHP processing into a separate service. It therefore also follows strong microservice architecture.

Both together are the most lean and secure images for Nextcloud:
 - extremely small size, minimalistic dependencies
 - no shell, only the server command
 - small attack surface
 - starts as non-root user
 - configuration and secrets hidden in the backend service only
 - all PHP files are empty stubs in the NGINX frontend
 - passwords never in environment variables, delivered as Docker secrets

Most of the combined 1476MB footprint is the Nextcloud distribution itself, stored in both images.

Compared to the official [nextcloud] image, this package has:
 - Less attack surface.
 - Better encapsulation.
 - Running as non-privileged user.
 - Much smaller: ~608MB (nginx) + ~868MB (php-fpm) vs. ~1.43GB for the official `nextcloud:latest` image.
 - Clear segmentation: only NGINX can reach PHP, only PHP can reach the DB; networks are isolated and marked `encrypted` (e.g. when run in Docker Swarm).
 - Headless: no shell, no package manager at runtime.
 - Configurable via environment (NGINX through envwrap templates, Nextcloud via `custom.config.php` reading `getenv()`).
 - No Nextcloud PHP file available in NGINX frontend, all PHP files emptied.
 - Passwords never exposed: delivered as Docker secrets, mounted as read-only tmpfs inside containers.


## Volumes / Persistence

All mutable Nextcloud data lives in three directories:

| Mount in container | Docker volume | Content                    |
|--------------------|---------------|----------------------------|
| `/app/data`        | `nc-data`     | User files and uploads     |
| `/app/config`      | `nc-config`   | `config.php` and fragments |
| `/app/apps`        | `nc-apps`     | User-installed apps        |

**Permissions** on the volumes: the runtime user comes from the base images and is not root. The helper service `access-fix` (based on `mwaeckerlin/allow-write-access`) runs once at startup to set the correct ownership; after that the volumes keep their owner.

**First-run initialization**: on first start, Docker initializes the `nc-config` volume from the image content of `/app/config`. This seeds two PHP config files:
- `autoconfig.php`: consumed by Nextcloud on the first web request to perform a fully headless installation (reads DB credentials from Docker secrets, admin credentials from the secret or auto-generates them).
- `custom.config.php`: a persistent config fragment always loaded alongside `config.php`; reads `HOST`, `PROTOCOL`, `WEBROOT`, `DEBUG` from environment variables at every request.


## Secrets

Passwords are delivered as Docker secrets — never as plain environment variables. They are mounted read-only as tmpfs files at `/run/secrets/` and never appear in `docker inspect` or process listings.

Two secrets are required:

| Secret name              | Used by                               | Purpose                        |
|--------------------------|---------------------------------------|--------------------------------|
| `nextcloud_db_password`  | `nextcloud-php-fpm`, `nextcloud-db`   | MariaDB password               |
| `nextcloud_admin_password` | `nextcloud-php-fpm`                 | Initial Nextcloud admin password |

### Creating secrets

In production on a docker swarm, use secrets. For `docker compose`, passwords are passed via environment variables, which Docker Compose reads from a `.env` file. For testing copy the sample: `cp .env.sample .env`, for more security, generate strong random passwords once:

```sh
printf "NEXTCLOUD_DB_PASSWORD=%s\nNEXTCLOUD_ADMIN_PASSWORD=%s\n" \
  "$(pwgen -sy 40 1)" "$(pwgen -sy 40 1)" > .env
```

Keep `.env` out of version control (added to `.gitignore`). Docker Compose picks it up automatically on `docker compose up`.

Install `pwgen` if needed: `apt install pwgen` / `brew install pwgen`.

If `nextcloud_admin_password` is absent or empty, a random password is generated and written to the container log:

```sh
docker compose logs nextcloud-php-fpm | grep 'generated admin password'
```

#### Production: Docker Swarm secrets

For multi-node or high-security deployments, use Docker Swarm secrets instead. Change the `secrets:` block in `docker-compose.yml` to:

```yaml
secrets:
  nextcloud_db_password:
    external: true
  nextcloud_admin_password:
    external: true
```

Then initialize Swarm and create the secrets (once per swarm):

```sh
docker swarm init
docker secret create nextcloud_db_password    - <<<$(pwgen -sy 40 1)
docker secret create nextcloud_admin_password - <<<$(pwgen -sy 40 1)
```

The `<<<` herestring avoids a trailing newline. Swarm secrets are encrypted at rest and never exposed via `docker inspect`.


## Environment Variables

- **nextcloud-nginx**
  - `PHP_FPM_HOST` (default `php-fpm`): upstream FastCGI host; set to `nextcloud-php-fpm` in the compose setup.
  - `PHP_FPM_PORT` (default `9000`): upstream FastCGI port.
  - `ROOT` (default `/app`): document root served by NGINX.

- **nextcloud-php-fpm**
  - `ADMIN_USER`: Nextcloud admin login name; default `admin`.
  - `HOST`: public hostname (e.g. `cloud.example.com`); sets `overwritehost` and `trusted_domains`.
  - `PROTOCOL`: public protocol; default `https`.
  - `WEBROOT`: URL sub-path if Nextcloud is not at `/` (e.g. `/nextcloud`); sets `overwritewebroot`.
  - `DEBUG`: set to `1` to enable Nextcloud debug mode; default `0`.
  - `MYSQL_HOST`: database hostname; default `mysql`, set to `nextcloud-db` in the compose setup.
  - `MYSQL_USER`: database user; default `nextcloud`.
  - `MYSQL_DATABASE`: database name; default `nextcloud`.


## Docker Compose Setup

We will have the following network setup:

```mermaid
flowchart LR
    browser["Browser\nhttp://localhost:8080"]
    nginx["nextcloud-nginx"]
    php["nextcloud-php-fpm"]
    db["nextcloud-db"]
    data["nc-data"]
    config["nc-config"]
    apps["nc-apps"]
    sql["nc-dbdata"]
    sec1["nextcloud_db_password"]
    sec2["nextcloud_admin_password"]

    browser --> nginx
    nginx -->|FastCGI| php
    php -->|SQL| db

    data --- php
    config --- php
    apps --- php
    sql --- db

    data ---|update access rights at startup| access-fix
    config ---|update access rights at startup| access-fix
    apps ---|update access rights at startup| access-fix

    sec1 --- php
    sec1 --- db
    sec2 --- php

    subgraph php-net ["Encrypted Network\nphp-network"]
      nginx
      php
    end

    subgraph db-net ["Encrypted Network\ndb-network"]
      php
      db
    end

    subgraph volumes ["Persistent Storage Volumes"]
      data
      config
      apps
      sql
    end

    subgraph secrets ["Docker Secrets (encrypted)"]
      sec1
      sec2
    end
```

Generate passwords into `.env` (once) and start:

```sh
printf "NEXTCLOUD_DB_PASSWORD=%s\nNEXTCLOUD_ADMIN_PASSWORD=%s\n" \
  "$(pwgen -sy 40 1)" "$(pwgen -sy 40 1)" > .env
docker compose up
```

Complete and secure `docker-compose.yml`:

```yaml
services:
  nextcloud-nginx:
    image: mwaeckerlin/nextcloud:nginx
    environment:
      PHP_FPM_HOST: nextcloud-php-fpm
    ports:
      - "8080:8080"
    networks:
      - php-network

  nextcloud-php-fpm:
    image: mwaeckerlin/nextcloud:php-fpm
    environment:
      HOST: cloud.example.com
      PROTOCOL: https
      ADMIN_USER: admin
      MYSQL_HOST: nextcloud-db
      MYSQL_USER: nextcloud
      MYSQL_DATABASE: nextcloud
    secrets:
      - nextcloud_db_password
      - nextcloud_admin_password
    volumes:
      - nc-data:/app/data
      - nc-config:/app/config
      - nc-apps:/app/apps
    networks:
      - php-network
      - db-network
    depends_on:
      - access-fix

  nextcloud-db:
    image: mariadb
    environment:
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD_FILE: /run/secrets/nextcloud_db_password
      MYSQL_RANDOM_ROOT_PASSWORD: "yes"
    secrets:
      - nextcloud_db_password
    volumes:
      - nc-dbdata:/var/lib/mysql
    networks:
      - db-network

  access-fix:
    image: mwaeckerlin/allow-write-access
    volumes:
      - nc-data:/app/data
      - nc-config:/app/config
      - nc-apps:/app/apps

secrets:
  nextcloud_db_password:
    environment: NEXTCLOUD_DB_PASSWORD
  nextcloud_admin_password:
    environment: NEXTCLOUD_ADMIN_PASSWORD

volumes:
  nc-data:
  nc-config:
  nc-apps:
  nc-dbdata:

networks:
  php-network:
    driver_opts:
      encrypted: "1"
  db-network:
    driver_opts:
      encrypted: "1"
```

Service roles:
- [mwaeckerlin/nextcloud:nginx]: HTTP endpoint; forwards PHP requests to [mwaeckerlin/nextcloud:php-fpm] via `PHP_FPM_HOST`/`PHP_FPM_PORT`; serves Nextcloud static assets directly; all `.php` files are empty stubs.
- [mwaeckerlin/nextcloud:php-fpm]: runs Nextcloud/PHP-FPM; performs headless installation on the first request via `autoconfig.php`; reads runtime config from `custom.config.php` at every request.
- `nextcloud-db`: MariaDB database; reachable only from `nextcloud-php-fpm`.
- `access-fix`: one-time chown on the shared volumes. FYI: `${ALLOW_USER}` is provided by `mwaeckerlin/allow-write-access` and resolves to the proper chown command for the runtime user.


## Network Topology

In the best setup, two completely separated distinct networks, encrypted and locked from outside access:

- `php-network`: only [mwaeckerlin/nextcloud:nginx] ↔ [mwaeckerlin/nextcloud:php-fpm].
- `db-network`: only [mwaeckerlin/nextcloud:php-fpm] ↔ `nextcloud-db`.
- No direct DB access from NGINX nor from outside; no direct PHP access from outside.


## Build and Development

The images are available directly from Docker Hub, there is no need to build. But if you want to build them:

1. Clone: `git clone <url> && cd nextcloud`
2. Build the images: `docker compose build`
3. Initialize Swarm if not already done: `docker swarm init`
4. Create secrets: `docker secret create nextcloud_db_password - <<<$(pwgen -sy 40 1)` and `docker secret create nextcloud_admin_password - <<<$(pwgen -sy 40 1)`
5. Deploy: `docker stack deploy -c docker-compose.yml nextcloud`
6. Stop and tear down: `docker stack rm nextcloud`

After deployment you may connect to Nextcloud at: http://localhost:8080

For local development without Swarm, replace the `external: true` secrets with `file:` pointing to local plaintext files (keep those outside version control):

```yaml
secrets:
  nextcloud_db_password:
    file: ./dev-secrets/nextcloud_db_password
  nextcloud_admin_password:
    file: ./dev-secrets/nextcloud_admin_password
```

Or (since Docker Compose 2.24) read directly from environment variables — no file, no Swarm needed:

```yaml
secrets:
  nextcloud_db_password:
    environment: NEXTCLOUD_DB_PASSWORD
  nextcloud_admin_password:
    environment: NEXTCLOUD_ADMIN_PASSWORD
```

Then start with:

```sh
NEXTCLOUD_DB_PASSWORD=$(pwgen -sy 40 1) \
NEXTCLOUD_ADMIN_PASSWORD=$(pwgen -sy 40 1) \
docker compose up
```

## Issues with Collabora Office Integration

### Target state

A stable Nextcloud + Collabora integration requires two clearly separated URL perspectives:

- Browser perspective: users access Nextcloud through the public host (for example `localhost:8824`).
- Service perspective: containers talk to each other via Docker DNS (for example `nextcloud-nginx:8080`).

If these two perspectives are mixed, typical symptoms are endless editor reloads, repeated WebSocket reconnects, or seemingly "green" 200/101 responses without a usable editor.

### Proven configuration

For this Compose topology, the following mapping has proven reliable:

- `richdocuments.wopi_url`: `http://collabora:9980`
- `richdocuments.public_wopi_url`: `http://nextcloud-nginx:8080`
- `richdocuments.wopi_callback_url`: `http://nextcloud-nginx:8080`
- Collabora `aliasgroup1`: includes internal `http://nextcloud-nginx:8080` and optionally the local browser host.

Important: from inside the Collabora container, `localhost` means the container itself, not the Docker host and not the Nextcloud NGINX service.

### Why loops can still happen

Even with correct WOPI URLs, some absolute links in Richdocuments (for example preset/template settings) can still depend on the incoming request host.
If `localhost:8824` appears in server-side responses, Collabora will try to fetch those URLs internally and produce errors such as:

- `Failed to fetch preset uri[http://localhost:8824/... ]`
- `ECONNREFUSED`
- `Failed to load all settings ...`

Result: kit processes are discarded and the editor stays in a Ready/Init cycle.

### Host resolution fix

A request-specific switch in `custom.config.php` is effective:

- for normal browser requests, keep normal public-host behavior,
- for `COOLWSD HTTP Agent` requests, switch internally to `nextcloud-nginx:8080` (http).

This keeps browser links correct while letting Collabora reliably reach internal settings/template URLs.

### Persistence and re-initialization (new volumes)

The integration remains reproducible with fresh volumes if the following points are in place:

1. The Dockerfile includes office defaults (`OFFICE_WOPI_URL`, `OFFICE_PUBLIC_WOPI_URL`, `OFFICE_CALLBACK_URL`) and the bootstrap entrypoint.
2. `office-bootstrap.php` installs/enables `richdocuments` and sets required app values via `occ`.
3. `custom.config.php` is always loaded (either from the image or as a bind mount, as in this Compose file).
4. With an empty `config` volume, `autoconfig.php` is provided automatically and first-time setup runs headless.

This ensures behavior is not dependent on old volume state.

### Common pitfalls

- Using `localhost` as internal callback/settings base.
- Setting only `wopi_url` without keeping `public_wopi_url` and `wopi_callback_url` consistent.
- Treating 502 errors during container restarts as permanent issues (short upstream outages are normal during restart).
- Looking only at browser console output; decisive evidence comes from time-correlated logs in NGINX, Collabora, and PHP-FPM.

### Minimal verification test

After start or recreate:

1. Open a document in the editor.
2. Check Collabora logs for absence of `localhost:...` preset-fetch failures and `ECONNREFUSED`.
3. Check NGINX logs to confirm `/cool/.../ws` upgrades run without repeated errors.

If these three points are stable, the integration is usually correct.


[mwaeckerlin/nextcloud:nginx]: https://github.com/mwaeckerlin/nextcloud-nginx "NGINX Service for Nextcloud"
[mwaeckerlin/nextcloud:php-fpm]: https://github.com/mwaeckerlin/nextcloud "PHP-FPM Service for Nextcloud"
[mwaeckerlin/nginx]: https://github.com/mwaeckerlin/nginx "NGINX Service Base Image"
[mwaeckerlin/php-fpm]: https://github.com/mwaeckerlin/php-fpm "PHP-FPM Service Base Image"
[nextcloud]: https://hub.docker.com/_/nextcloud "the official Nextcloud Docker image"
