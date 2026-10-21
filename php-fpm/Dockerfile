# syntax=docker/dockerfile:1.4
FROM mwaeckerlin/build AS build
ARG SOURCE_FILE="latest.tar.bz2"
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE} /tmp/${SOURCE_FILE}
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}.asc
ADD --chmod=644 nextcloud.asc /tmp/nextcloud.asc
RUN gpg --dearmor < /tmp/nextcloud.asc > /tmp/nextcloud.gpg
RUN gpgv --keyring /tmp/nextcloud.gpg /tmp/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}
RUN tar xf /tmp/${SOURCE_FILE} --strip-components=1
# browser files: nginx delivers its own copy, php-fpm only checks that they
# exist; sign-release.php signs the release again afterwards
RUN find . -name '*.map' -delete
RUN find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.css' \) -exec sh -c ': > "$1"' _ {} \;
RUN mkdir -p data
USER root
RUN ${ALLOW_USER} data
# the paths of the legacy image: its config.php names /var/www/nextcloud/data,
# and its compose files mount the volumes below /var/www/nextcloud
RUN mkdir -p /legacy/var/www && ln -s /app /legacy/var/www/nextcloud

# signs core and the shipped apps with a CA of the build beside the Nextcloud
# CA; the image has no shell, so the steps run in exec form, as root of this
# stage only, which writes the release that the build stage owns
FROM mwaeckerlin/php-fpm AS sign
USER 0
COPY --from=build /app /app
COPY sign-release.php /usr/local/bin/sign-release.php
RUN ["/usr/bin/php", "/usr/local/bin/sign-release.php", "/app"]

FROM mwaeckerlin/php-fpm AS production
# the variables of the legacy image, with its names and defaults
ENV MEMORY_LIMIT "1000M"
ENV UPLOAD_MAX_FILESIZE "8G"
ENV MAX_INPUT_TIME "3600"
ENV MAX_REQUEST_WORKERS "100"
ENV WAIT_SECONDS_FOR_MYSQL "300"
ENV ADMIN_USER "admin"
ENV ADMIN_PWD ""
# HOST and URL are the same setting, HOST wins; empty both means localhost:8824
ENV HOST ""
ENV URL ""
ENV PROTOCOL "https"
ENV WEBROOT ""
ENV DEBUG "0"
ENV MYSQL_HOST "mysql"
ENV MYSQL_USER "nextcloud"
ENV MYSQL_DATABASE "nextcloud"
ENV MYSQL_PASSWORD ""
ENV OFFICE_WOPI_URL "http://collabora:9980"
ENV OFFICE_PUBLIC_WOPI_URL ""
ENV OFFICE_CALLBACK_URL ""
ENV OFFICE_WOPI_ALLOWLIST ""
COPY --from=sign /app /app
COPY --from=build /legacy/var/www /var/www
COPY autoconfig.php /app/config/autoconfig.php
COPY autoconfig.php /usr/local/share/nextcloud/autoconfig.php
COPY custom.config.php /app/config/custom.config.php
COPY custom.config.php /usr/local/share/nextcloud/custom.config.php
COPY --chmod=755 office-bootstrap.php /usr/local/bin/office-bootstrap.php
COPY --chmod=644 cron.php /usr/local/bin/cron.php
# replaces the ping check of mwaeckerlin/php-fpm and uses its FastCGI client
# /usr/local/bin/fastcgi.php
COPY --chmod=644 health.php /usr/local/bin/health.php
COPY --chmod=644 zz-nextcloud.conf /usr/local/etc/php-fpm.d/zz-nextcloud.conf
ENTRYPOINT ["/usr/bin/php", "/usr/local/bin/office-bootstrap.php"]
# Healthy once php-fpm answers status.php, Nextcloud is installed, not in
# maintenance mode and needs no database upgrade; the timing of the legacy
# image. A compose healthcheck block overrides any of these values.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=240 \
    CMD ["/usr/bin/php", "/usr/local/bin/health.php"]

FROM production
