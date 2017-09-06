#!/bin/bash -e

cd $INSTDIR

# configure php and apache
CONF_FILE_CONTENT=$(eval "cat <<EOFXXXX
$(</nextcloud.conf)
EOFXXXX")
cat > /etc/apache2/conf-available/nextcloud.conf<<<"${CONF_FILE_CONTENT}"
a2enconf nextcloud

if test -d /etc/php/7.0/apache2/conf.d; then
    PHPCONF=/etc/php/7.0/apache2/conf.d/99-nextcloud.ini
elif test -d /etc/php5/apache2/conf.d; then
    PHPCONF=/etc/php5/apache2/conf.d/99-nextcloud.ini
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
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
EOF

if test -n "$MYSQL_ENV_MYSQL_PASSWORD"; then
    echo "wait for mysql to become ready"
    for ((i=0; i<20; ++i)); do
        if nmap -p ${MYSQL_PORT_3306_TCP_PORT:-3306} ${MYSQL_PORT_3306_TCP_ADDR:-mysql} \
            | grep -q ${MYSQL_PORT_3306_TCP_PORT:-3306}'/tcp open'; then
            echo "mysql is ready"
            break;
        fi
        sleep 1
    done
fi

# configure or update nextcloud
sudo chown -R www-data.www-data "${CONFDIR}" "${DATADIR}" "${APPSDIR}"
if ! test -s config/config.php; then # initial run
    # install nextcloud
    USER=${ADMIN_USER:-admin}
    PASS=${ADMIN_PWD:-$(pwgen 20 1)}
    for ((i=10; i>0; --i)); do # database connection sometimes fails retry 10 times
        if sudo -u www-data ./occ maintenance:install \
            --database $(test -n "$MYSQL_ENV_MYSQL_PASSWORD" && echo mysql || echo sqlite) \
            --database-name "${MYSQL_ENV_MYSQL_DATABASE:-nextcloud}" \
            --database-host "mysql" \
            --database-user "$MYSQL_ENV_MYSQL_USER:-nextcloud" \
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
    # add debugging if required
    if test "$DEBUG" -eq 1; then
        sudo -u www-data ./occ config:system:set --value true debug
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
                            account=nextcloud
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
else # upgrade nextcloud
    if ! (sudo -u www-data ./occ upgrade --no-interaction || test $? -eq 3); then
        if ! sudo -u www-data ./occ maintenance:repair --no-interaction; then
            if ! (sudo -u www-data ./occ upgrade --no-interaction || test $? -eq 3); then
                echo "#### ERROR in upgrade, please analyse" 1>&2
                sleep infinity
            fi
        fi
    fi
fi

sudo -u www-data ./occ log:file --file=/proc/$$/fd/1 --enable
sudo -u www-data ./occ config:system:set memcache.local --value '\OC\Memcache\APCu'
if test -n "$WEBROOT"; then
    sudo -u www-data ./occ config:system:set overwritewebroot --value "${WEBROOT}"
fi
if test -n "$URL"; then
    sudo -u www-data ./occ config:system:set overwritehost --value "${URL}"
    sudo -u www-data ./occ config:system:set trusted_domains 1 --value "${URL}"
fi

cat > /etc/cron.d/nextcloud <<EOF
*/15  *  *  *  * www-data php -f $INSTDIR/cron.php
@daily www-data $INSTDIR/occ files:scan --all
EOF
chmod +x /etc/cron.d/nextcloud
(! service cron status || service cron stop ) && service cron start

if test -f /run/apache2/apache2.pid; then
    rm /run/apache2/apache2.pid;
fi;

echo "#### READY ####"
if test -n "$PASS" -a "$PASS" != "$ADMIN_PWD"; then
    echo "************************************"
    echo "admin-user:     $USER"
    echo "admin-password: $PASS"
    echo "************************************"
fi
apache2ctl -DFOREGROUND
