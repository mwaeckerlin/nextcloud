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
#sed -i '
#  s/\(php_value *\(memory_limit\|upload_max_filesize\|post_max_size\) *\).*/\1'"${UPLOAD_MAX_FILESIZE}"'/g;
#  s/\(php_value *\(max_input_time\|max_execution_time\) *\).*/\1'"${MAX_INPUT_TIME}"'/g;
#' .htaccess
chown www-data.www-data .htaccess

# configure or update nextcloud
if [ -e "${APPSDIR}.original" ]; then
    echo "**** restore apps"
    for dir in ${APPSDIR}.original/*; do
        target=${APPSDIR}/${dir#${APPSDIR}.original/}
        if ! [ -e "${target}" ]; then
            echo "----  install $target"
            mv "$dir" "$target"
        fi
    done
    rm -rf ${APPSDIR}.original
    echo "**** reset apps access rights"
    chown -R www-data.www-data "${APPSDIR}"
fi

if ! test -s config/config.php || \
   ! (sudo -u www-data ./occ status | grep -q "installed: true") ; then # initial run
    echo "**** reset access rights"
    chown -R www-data.www-data "${CONFDIR}" "${DATADIR}" "${APPSDIR}"
    echo "**** initial run, setup configuration"
    # install nextcloud
    USER=${ADMIN_USER:-admin}
    PASS=${ADMIN_PWD:-$(pwgen 20 1)}
    sudo -u www-data ./occ maintenance:install \
         --database $(test -n "${MYSQL_ENV_MYSQL_PASSWORD:-$MYSQL_PASSWORD}" && echo mysql || echo sqlite) \
         --database-name "${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_DATABASE:-nextcloud}}" \
         --database-host "mysql" \
         --database-user "${MYSQL_ENV_MYSQL_USER:-${MYSQL_USER:-nextcloud}}" \
         --database-pass "${MYSQL_ENV_MYSQL_PASSWORD:-$MYSQL_PASSWORD}" \
         --admin-user "${USER}" \
         --admin-pass "${PASS}" \
         --data-dir "${DATADIR}" \
         --no-interaction
    # check if installation was successful
    if ! test -s config/config.php; then
        echo "#### ERROR in installation, please analyse" 1>&2
        exit 1
    fi
else
    sudo -u www-data ./occ maintenance:mode --off
    echo "**** upgrade"
    sudo -u www-data ./occ upgrade -n -vvv
    echo "**** repair"
    sudo -u www-data ./occ maintenance:repair -n -vvv || sudo -u www-data ./occ maintenance:repair -n -vvv --include-expensive || sudo -u www-data ./occ upgrade -n -vvv
    sudo -u www-data ./occ maintenance:mode --off
fi

echo "**** reset configuration"
if test -n "${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"; then
    # allow more database connections
    mysql -h mysql -u root -p${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD} <<<"set global max_connections = 2000;"
fi
# add debugging if required
if test "$DEBUG" -eq 1; then
    sudo -u www-data ./occ config:system:set --value true debug
else
    sudo -u www-data ./occ config:system:set --value false debug
fi
sudo -u www-data ./occ log:file --enable --file=/var/log/nextcloud.log --rotate-size=0
sudo -u www-data ./occ config:system:set memcache.local --value '\OC\Memcache\APCu'
if test -n "$WEBROOT"; then
    sudo -u www-data ./occ config:system:set overwritewebroot --value "${WEBROOT}"
fi
if test -n "$URL"; then
    sudo -u www-data ./occ config:system:set overwritehost --value "${URL}"
    sudo -u www-data ./occ config:system:set trusted_domains 1 --value "${URL}"
fi

echo "**** start cron job"
cat > /etc/cron.d/nextcloud <<EOF
*/15  *  *  *  * www-data php -f $INSTDIR/cron.php
@daily www-data $INSTDIR/occ files:scan --all
EOF
chmod +x /etc/cron.d/nextcloud
(! service cron status || service cron stop ) && service cron start

echo "**** run apache"
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
