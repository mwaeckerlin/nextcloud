# syntax=docker/dockerfile:1.4
FROM mwaeckerlin/build AS build
ARG SOURCE_FILE="latest-34.tar.bz2"
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE} /tmp/${SOURCE_FILE}
ADD --chmod=644 https://download.nextcloud.com/server/releases/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}.asc
ADD --chmod=644 nextcloud.asc /tmp/nextcloud.asc
RUN gpg --dearmor < /tmp/nextcloud.asc > /tmp/nextcloud.gpg
RUN gpgv --keyring /tmp/nextcloud.gpg /tmp/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}
RUN tar xf /tmp/${SOURCE_FILE} --strip-components=1
RUN find . -name '*.php' -exec sh -c 'rm "{}" && touch "{}"' \;

FROM mwaeckerlin/nginx AS production
ENV CONTAINERNAME "nextcloud-nginx"
ENV PHP_FPM_HOST "nextcloud-php-fpm"
ENV WEBROOT ""
COPY conf/conf.d/websocket.conf    /etc/nginx.template/conf.d/websocket.conf
COPY conf/server.d/default.conf    /etc/nginx.template/server.d/default.conf
COPY --from=build /app /app

FROM production