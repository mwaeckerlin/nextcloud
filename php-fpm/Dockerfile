# syntax=docker/dockerfile:1.4
FROM mwaeckerlin/build AS build
ARG SOURCE_FILE="latest-32.tar.bz2"
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE} /tmp/${SOURCE_FILE}
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}.asc
ADD --chmod=644 nextcloud.asc /tmp/nextcloud.asc
RUN gpg --dearmor < /tmp/nextcloud.asc > /tmp/nextcloud.gpg
RUN gpgv --keyring /tmp/nextcloud.gpg /tmp/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}
RUN tar xf /tmp/${SOURCE_FILE} --strip-components=1
RUN mkdir -p data
USER root
RUN ${ALLOW_USER} data
RUN ${PKG_INSTALL} php

FROM mwaeckerlin/php-fpm AS production
ENV ADMIN_USER "admin"
ENV ADMIN_PWD ""
ENV HOST "localhost:8824"
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
COPY --from=build /app /app
COPY --from=build /usr/bin/php /usr/bin/php
COPY autoconfig.php /app/config/autoconfig.php
COPY autoconfig.php /usr/local/share/nextcloud/autoconfig.php
COPY custom.config.php /app/config/custom.config.php
COPY custom.config.php /usr/local/share/nextcloud/custom.config.php
COPY --chmod=755 office-bootstrap.php /usr/local/bin/office-bootstrap.php
ENTRYPOINT ["/usr/bin/php", "/usr/local/bin/office-bootstrap.php"]

FROM production
