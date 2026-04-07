FROM mwaeckerlin/build AS build
ARG SOURCE_FILE="latest.tar.bz2"
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE} /tmp/${SOURCE_FILE}
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}.asc
ADD --chmod=644 nextcloud.asc /tmp/nextcloud.asc
RUN gpg --dearmor < /tmp/nextcloud.asc > /tmp/nextcloud.gpg
RUN gpgv --keyring /tmp/nextcloud.gpg /tmp/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}
RUN tar xf /tmp/${SOURCE_FILE} --strip-components=1
RUN mkdir -p data
USER root
RUN ${ALLOW_USER} data

FROM mwaeckerlin/php-fpm
ENV ADMIN_USER "admin"
ENV ADMIN_PWD ""
ENV HOST ""
ENV PROTOCOL "https"
ENV WEBROOT ""
ENV DEBUG "0"
ENV MYSQL_HOST "mysql"
ENV MYSQL_USER "nextcloud"
ENV MYSQL_DATABASE "nextcloud"
ENV MYSQL_PASSWORD ""
COPY --from=build /app /app
COPY autoconfig.php /app/config/autoconfig.php
COPY custom.config.php /app/config/custom.config.php
