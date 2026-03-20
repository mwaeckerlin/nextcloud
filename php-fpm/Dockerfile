FROM mwaeckerlin/very-base AS build
ARG SOURCE_FILE="latest.tar.bz2"
ARG EXTRA_MODULES="php-bcmath php-gmp php-pdo_mysql php-apcu php-opcache"

# Install extra PHP modules not included in mwaeckerlin/php-fpm,
# plus wget/gnupg for Nextcloud download and verification.
RUN ${PKG_INSTALL} ${EXTRA_MODULES} gnupg wget

# mwaeckerlin/php-fpm renames /etc/phpX → /etc/php; do the same so
# the extra module configs overlay the base image's conf.d correctly.
RUN V=$(ls -d /var/log/php* | sed 's,/var/log/php,,') && \
    mv /etc/php${V} /etc/php

# Bundle the extra module .so files, their conf.d enablement files,
# and all shared library dependencies into /root/ for COPY into final stage.
RUN tar cph \
    /usr/lib/php*/modules/*.so /etc/php/conf.d \
    $(for f in /usr/lib/php*/modules/*.so; do \
      ldd $f 2>/dev/null | sed -n 's,.* => \([^ ]*\) .*,\1,p'; \
    done | sort -u) 2>/dev/null \
    | tar xpC /root/

# Download and GPG-verify Nextcloud.
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
RUN ${ALLOW_USER} config data apps

FROM mwaeckerlin/php-fpm
ENV CONTAINERNAME "nextcloud"
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

# Overlay extra PHP modules and their library deps from build stage.
COPY --from=build /root /
# Bake Nextcloud app files into the image (static assets; mutable dirs are volumes).
COPY --from=build /app /app
# Override fpm pool settings (tuned for Nextcloud).
COPY fpm.conf /etc/php/php-fpm.d/www.conf
# Static PHP ini (memory, upload limits, opcache).
COPY 99-nextcloud.ini /etc/php/conf.d/99-nextcloud.ini
# Auto-installer: consumed by Nextcloud on first request when config.php is absent.
COPY autoconfig.php /app/config/autoconfig.php
# Runtime config fragment: always loaded, reads env vars via getenv().
COPY custom.config.php /app/config/custom.config.php
