# Docker Image for Nextcloud

## Configuration

- Port: `80`
- Volumes:
    - `/var/www/nextcloud/data`
    - `/var/www/nextcloud/config`
- Variables:
    - `HOST`: Host of the service. Should always be specified, at least if service is behind a proxy. E.g. `https://example.com/nextcloud` → `HOST="example.com"`
    - `WEBROOT`: Path in URL, must be set for proper forwarding if URL contains a path, e.g. `https://example.com/nextcloud` → `WEBROOT="/nextcloud"`
    - `PROTOCOL`: Protocol of your service, recommended and default is `https` → `PROTOCOL=https`
    - `ADMIN_USER`: Name of the administration user. Default: `admin`
    - `ADMIN_PWD`: Password of the administration user. Default: random (printed in the log)
    - `MEMORY_LIMIT`: PHP memory limit. Default: `1000M`
    - `UPLOAD_MAX_FILESIZE`: Maximum size of files to upload. Default: `8G`
    - `MAX_INPUT_TIME`: Timeout for apache in seconds, maximum response time. Default: `3600`
    - `DEBUG`: Set to `1` to enable debugging. Default: `0`
    - `MYSQL_USER`: name of the SQL user. Default: `nextcloud`
    - `MYSQL_PASSWORD`: password of the SQL user
    - `MYSQL_DATABASE`: name of the nextcloud database. Default: `nextcloud`
    - `MAX_REQUEST_WORKERS`: maximum number of requests Apache answers at the same time. Default: `100`

### Database connections

Every Apache worker holds one database connection while it answers a request and closes it when the request ends. `MAX_REQUEST_WORKERS` bounds the number of workers, so Nextcloud never opens more connections for requests, plus one for the cron job every 15 minutes and one for the daily `files:scan`. The database accepts `max_connections` connections, 151 by default in MySQL and MariaDB.

The two limits work together:

- Requests above `MAX_REQUEST_WORKERS` wait in the queue of Apache until a worker is free; Apache gives up after `Timeout`, 300 seconds.
- Connections above `max_connections` fail at once, and Nextcloud shows «Too many connections» (error 1040).

So `max_connections` must stay above `MAX_REQUEST_WORKERS` with room for the cron job, `files:scan`, backups and administration. The image gets no root password and never changes the limit of the database. To serve more requests at the same time, raise both, the limit of the database as an option of its own server:

```yaml
  mysql:
    image: mysql
    command: --max-connections=500
  nextcloud:
    image: mwaeckerlin/nextcloud
    environment:
      - MAX_REQUEST_WORKERS=400
```

Every open connection takes memory in the database server, so a higher limit needs the memory for it where the database runs with a memory limit.

## Examples

### Real Live Example Proxy

Example use with volumes and MySQL database behind a reverse proxy:

```sh
appname=nextcloud
host=cloud.example.com
docker pull mwaeckerlin/nextcloud
docker pull mysql
docker run -d --restart unless-stopped --name ${appname}-mysql-volume mysql sleep infinity
docker run -d --restart unless-stopped --name ${appname}-volume mwaeckerlin/nextcloud sleep infinity
docker run -d --restart unless-stopped --name ${appname}-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=$(pwgen 20 1) --volumes-from ${appname}-mysql-volume mysql
```

Behind a reverse proxy:

```sh
docker run -d --restart unless-stopped --name ${appname} -e HOST="${host}" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e ADMIN_PWD=$(pwgen 20 1) --volumes-from ${appname}-volume --link ${appname}-mysql:mysql mwaeckerlin/nextcloud
docker run -d -p 80:80 -p 443:443 [...] --link ${appname}:${host} mwaeckerlin/reverse-proxy
```

Or when exposing the port, e.g. to `http://localhost:8000`:

```sh
docker run -d --restart unless-stopped -p 8000:80 --name ${appname} -e HOST="${host}" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e ADMIN_PWD=$(pwgen 20 1) --volumes-from ${appname}-volume --link ${appname}-mysql:mysql mwaeckerlin/nextcloud
```

Check the logs:

```sh
docker logs -f ${appname}
```

It is initialized and ready, when you see in the logs:

```text
#### READY ####
```

### Simplest Call for Tests

```sh
docker rm -f test-nc-mysql
docker run -d --name test-nc-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=ert456 mysql
docker run --rm -it -p 9000:80 --name test-nc -e ADMIN_PWD=ert456 --link test-nc-mysql:mysql mwaeckerlin/nextcloud bash
/start.sh
```

## Admin Password

How to get the admin password depends on how you started. If you specified it with `ADMIN_PWD` on the command line, you have several options.

Simply get the environment variable:

```sh
docker exec -it ${appname} env | grep ADMIN_PWD
```

Get it from `docker inspect`:

```sh
docker inspect ${appname} | grep ADMIN_PWD
```

Or use [my backup toolset](https://github.com/mwaeckerlin/docker-backup) to get the full command line:

```sh
./docker-analysis.py ${appname}
```

But if the password was not set and is generated randomly, you only find it in the log of the first start, so do not forget it:

```sh
docker logs ${appname} | grep 'admin-password'
```

## Tags and Build

This is the legacy single image. The current images `mwaeckerlin/nextcloud:nginx` and `mwaeckerlin/nextcloud:php-fpm` are built from the branch `new`, whose README describes them.

Branch `master` publishes `latest`, branch `NN` the tag `NN` with Nextcloud major version `NN`, each also with the day of the build and the version from `package.json`, e.g. `33-20261002` and `33-1.0.0`. An installation upgrades one Nextcloud major version at a time, so it pins `NN` and steps through the versions; `npm test` checks that the image of branch `NN` carries exactly Nextcloud `NN`. The GitHub workflow `.github/workflows/docker.yml` builds, tests and publishes the images on every push and every Monday; `create-branches.sh` creates the branches `30` to `35` from `master`. The branches `13` to `29` are frozen.

The Ubuntu release is pinned in `ARG VERSION`: `jammy` for Nextcloud 30, `noble` from 31, because the `tar` of Ubuntu 26.04 fails on the old Docker Hub build servers. Both base tags exist for amd64 only, so the legacy image is built for amd64 only.
