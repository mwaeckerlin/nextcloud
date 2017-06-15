#!/bin/bash -e

cd $INSTDIR

# configure php and apache
if test -z "$BASEPATH" -o "$BASEPATH" = "/"; then
    sed -i '/Alias \/owncloud /d' /etc/apache2/conf-available/owncloud.conf
    sed -i 's,DocumentRoot.*,DocumentRoot '$INSTDIR',' /etc/apache2/sites-available/000-default.conf
else
    grep -q Alias /etc/apache2/conf-available/owncloud.conf && \
        sed -i 's,Alias *[^ ]* ,Alias '"$BASEPATH"' ,' /etc/apache2/conf-available/owncloud.conf || \
        sed -i '0aAlias '"$BASEPATH" /etc/apache2/conf-available/owncloud.conf
fi
if test -d /etc/php/7.0/apache2/conf.d; then
    PHPCONF=/etc/php/7.0/apache2/conf.d/99-owncloud.ini
elif test -d /etc/php5/apache2/conf.d; then
    PHPCONF=/etc/php5/apache2/conf.d/99-owncloud.ini
else
    echo "**** ERROR: PHP Configuration Path Not Found" 1>&2
    exit 1
fi
cat > ${PHPCONF} <<EOF
max_input_time = ${MAX_INPUT_TIME}
max_execution_time = ${MAX_INPUT_TIME}
upload_max_filesize = ${UPLOAD_MAX_FILESIZE}
post_max_size = ${UPLOAD_MAX_FILESIZE}
max_input_time = ${MAX_INPUT_TIME}
max_execution_time = ${MAX_INPUT_TIME}
EOF

# configure or update owncloud
if ! test -s config/config.php; then # initial run
    # install owncloud
    USER=${ADMIN_USER:-admin}
    PASS=${ADMIN_PWD:-$(pwgen 20 1)}
    for ((i=10; i>0; --i)); do # database connection sometimes fails retry 10 times
        if sudo -u www-data ./occ maintenance:install \
            --database $(test -n "$MYSQL_ENV_MYSQL_PASSWORD" && echo mysql || echo sqlite) \
            --database-name "${MYSQL_ENV_MYSQL_DATABASE}" \
            --database-host "mysql" \
            --database-user "$MYSQL_ENV_MYSQL_USER" \
            --database-pass "$MYSQL_ENV_MYSQL_PASSWORD" \
            --admin-user "${USER}" \
            --admin-pass "${PASS}" \
            --data-dir "${DATADIR}" \
            --no-interaction; then
            break
        fi
        echo "#### ERROR in installation; retry: $i" 1>&2
        if test -f config/config.php; then
            rm config/config.php
        fi
        sleep 5
    done
    # check if installation was successful
    if ! test -s config/config.php; then
        echo "#### ERROR in installation, please analyse" 1>&2
        sleep infinity
    fi
    # download and enable missing apps
    ocver=$(sudo -u www-data ./occ -V | sed -n 's,^.*version \([.0-9]\+\).*$,\1,p')
    if test -n "$APPS"; then
        for a in $APPS; do
            if  [[ $a =~ ^- ]]; then
                sudo -u www-data ./occ app:disable "${a#-}"
            else
                if ! test -d "apps/${a%%:*}"; then
                    a="${a#+}"
                    if test "${a}" != "${a#*:http}"; then
                        src=${a#*:}
                    else
                        if test "${a}" != "${a#*:@}"; then
                            account=${a#*:@}
                        else
                            account=owncloud
                        fi
                        src=https://github.com/${account}/${a%%:*}/releases
                    fi
                    cd apps
                    base=$(sed 's,^\(http.*//[^/]*\)/.*,\1,' <<< $src)
                    while test -z "$link"; do
                        link=$(wget -O- -q ${src} \
                            | sed -n 's,.*href="\(/'"${src#http*://*/}"'/[^"]*stable'"${ocver//./\\.}"'[^"]*\.tar\.gz\)".*,\1,p' \
                            | sort -h | tail -1)
                        if test "${ocver}" = "${ocver%.*}"; then
                            break;
                    fi
                        ocver="${ocver%.*}"
                    done
                    if test -z "$link"; then
                        link=$(wget -O- -q ${src} \
                            | sed -n 's,.*href="\(/'"${src#http*://*/}"'/[^"]*\.tar\.gz\)".*,\1,p' \
                            | sort -h | egrep -v 'beta|alpha|RC' | tail -1)
                    fi
                    if test -z "$link"; then
                        echo "**** ERROR: app ${a%%:*} not found on $src" 1>&2
                        exit 1
                    fi
                    echo "download: ${a%%:*} from ${base}${link}"
                    sudo -u www-data mkdir "${a%%:*}"
                    wget -O- -q ${base}${link} \
                        | sudo -u www-data tar xz -C "${a%%:*}" --strip-components 1
                    cd ..
                fi
                sudo -u www-data ./occ app:enable "${a%%:*}"
            fi
        done
    fi
else # upgrade owncloud
    if ! (sudo -u www-data ./occ upgrade --no-interaction || test $? -eq 3); then
        if ! sudo -u www-data ./occ maintenance:repair --no-interaction; then
            if ! (sudo -u www-data ./occ upgrade --no-interaction || test $? -eq 3); then
                echo "#### ERROR in upgrade, please analyse" 1>&2
                sleep infinity
            fi
        fi
    fi
fi

sudo -u www-data ./occ log:owncloud --file=/proc/$$/fd/1 --enable
if test -n "$WEBROOT"; then
    sudo -u www-data ./occ config:system:set overwritewebroot --value "${WEBROOT}"
fi
if test -n "$URL"; then
    sudo -u www-data ./occ config:system:set overwritehost --value "${URL}"
    sudo -u www-data ./occ config:system:set trusted_domains 1 --value "${URL}"
fi

cat > /etc/cron.d/owncloud <<EOF
*/15  *  *  *  * www-data php -f $INSTDIR/cron.php
@daily www-data $INSTDIR/occ files:scan --all
EOF
chmod +x /etc/cron.d/owncloud
cron

if test -f /run/apache2/apache2.pid; then
    rm /run/apache2/apache2.pid;
fi;

if test -n "$PASS" -a "$PASS" != "$ADMIN_PWD"; then
    echo "************************************"
    echo "admin-user:     $USER"
    echo "admin-password: $PASS"
    echo "************************************"
fi
apache2ctl -DFOREGROUND
