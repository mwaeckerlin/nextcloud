FROM mwaeckerlin/very-base AS build
ARG SOURCE_FILE="latest.tar.bz2"
RUN ${PKG_INSTALL} gnupg wget
RUN wget -qO /tmp/${SOURCE_FILE} \
      https://download.nextcloud.com/server/releases/${SOURCE_FILE} \
    && wget -qO /tmp/${SOURCE_FILE}.asc \
      https://download.nextcloud.com/server/releases/${SOURCE_FILE}.asc \
    && wget -qO /tmp/nextcloud.asc \
      https://nextcloud.com/nextcloud.asc \
    && gpg --import /tmp/nextcloud.asc \
    && gpg --verify /tmp/${SOURCE_FILE}.asc /tmp/${SOURCE_FILE}
WORKDIR /app
RUN tar xf /tmp/${SOURCE_FILE} --strip-components=1
RUN find . -name '*.php' -exec sh -c 'rm "{}" && touch "{}"' \;
RUN ${ALLOW_USER} /app

FROM mwaeckerlin/nginx
ENV CONTAINERNAME "nextcloud-nginx"
COPY conf/locations.d/default.conf /etc/nginx.template/locations.d/default.conf
COPY conf/server.d/default.conf    /etc/nginx.template/server.d/default.conf
COPY --from=build /app /app
