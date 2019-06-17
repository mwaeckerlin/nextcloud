Docker Image for Nextcloud
==========================

Configuration
-------------

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
    - `UPLOAD_MAX_FILESIZE`: Maximum size of files to upload. Default: `8G`
    - `MAX_INPUT_TIME`: Timeout for apache in seconds , maximum response time. Dafault: `3600`
    - `DEBUG`: Set to `1` to enable debugging. Default: `0`
    - `MYSQL_USER`: name of the SQL user. Default: `nextcloud`
    - `MYSQL_PASSWORD`: password of the SQL user
    - `MYSQL_DATABASE`: name of the nextcloud database. Default: `nextcloud`

Examples
--------

### Real Live Example Proxy ###

Example use with volumes and MySQL database behind a reverse proxy:

    appname=nextcloud
    host=cloud.example.com
    docker pull mwaeckerlin/nextcloud
    docker pull mysql
    docker run -d --restart unless-stopped --name ${appname}-mysql-volume mysql sleep infinity
    docker run -d --restart unless-stopped --name ${appname}-volume mwaeckerlin/nextcloud sleep infinity
    docker run -d --restart unless-stopped --name ${appname}-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=$(pwgen 20 1) --volumes-from ${appname}-mysql-volume mysql

Behind a reverse proxy:

    docker run -d --restart unless-stopped --name ${appname} -e HOST="${host}" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e ADMIN_PWD=$(pwgen 20 1) --volumes-from ${appname}-volume --link ${appname}-mysql:mysql mwaeckerlin/nextcloud
    docker run -d -p 80:80 -p 443:443 [...] --link ${appname}:${host} mwaeckerlin/reverse-proxy

Or when exposing the port, e.g. to `http://localhost:8000`:

    docker run -d --restart unless-stopped -p 8000:80 --name ${appname} -e HOST="${host}" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e ADMIN_PWD=$(pwgen 20 1) --volumes-from ${appname}-volume --link ${appname}-mysql:mysql mwaeckerlin/nextcloud

Check the logs:

    docker logs -f ${appname}

It is initialied and ready, when you see in the logs:

```
#### READY ####
```

### Simplest Call for Tests ###

    docker rm -f test-nc-mysql
    docker run -d --name test-nc-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=ert456 mysql
    docker run --rm -it -p 9000:80 --name test-nc -e ADMIN_PWD=ert456 --link test-nc-mysql:mysql mwaeckerlin/nextcloud bash
    /start.sh

Admin Password
--------------

How to get the admin password depends, how you started. If you specified it with `ADMIN_PWD` on command line, you have several options:

Simply get the environment variable:

    docker exec -it ${appname} env | grep ADMIN_PWD

Get it from `docker inspect`:

    docker inspect ${appname} | grep ADMIN_PWD


Or use [my backup toolset](https://github.com/mwaeckerlin/docker-backup) to get the full command line:

    ./docker-analysis.py ${appname}

But if the password was not set and is generated randomly, you only find it in the log of the first start, so do not forget it:

    docker logs ${appname} | grep 'admin-password'
