#!/bin/bash -e

! test -e /tmp/ready || rm /tmp/ready

cd $INSTDIR

# configure php and apache
CONF_FILE_CONTENT=$(eval "cat <<EOFXXXX
$(</nextcloud.conf)
EOFXXXX")
cat > /etc/apache2/conf-available/nextcloud.conf<<<"${CONF_FILE_CONTENT}"
a2enconf nextcloud

PHPCONFDIR=$(ls -d /etc/php/*/apache2/conf.d | head -1)
if test -d "${PHPCONFDIR}"; then
    PHPCONF="${PHPCONFDIR}"/99-nextcloud.ini
else
    echo "**** $(date +'%Y/%m/%d %H:%M:%S'): ERROR: PHP Configuration Path Not Found" 1>&2
    exit 1
fi
cat > ${PHPCONF} <<EOF
memory_limit = ${MEMORY_LIMIT:-${UPLOAD_MAX_FILESIZE}}
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

# configure or update nextcloud

if [ -e "${APPSDIR}.original" ]; then
    echo "**** $(date +'%Y/%m/%d %H:%M:%S'): restore apps"
    for dir in ${APPSDIR}.original/*; do
        target=${APPSDIR}/${dir#${APPSDIR}.original/}
        echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  install $dir to $target"
        rsync -qrlptD --delete "${dir}/" "${target}/" || true
    done
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  remove ${APPSDIR}.original"
    rm -rf ${APPSDIR}.original
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  apps updated"
fi

if ! test -s config/config.php || \
   ! (sudo -u www-data ./occ status | grep -q "installed: true") ; then # initial run
    echo "**** $(date +'%Y/%m/%d %H:%M:%S'): initial run, setup configuration"
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
        echo "#### $(date +'%Y/%m/%d %H:%M:%S'): ERROR in installation, please analyse" 1>&2
        exit 1
    fi
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  initial configuration done"
else
    echo "**** $(date +'%Y/%m/%d %H:%M:%S'): start maintenance"
    sudo -u www-data ./occ maintenance:mode --off
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  upgrade"
    sudo -u www-data ./occ upgrade -n -vvv
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  repair"
    sudo -u www-data ./occ maintenance:repair -n -vvv || sudo -u www-data ./occ maintenance:repair -n -vvv --include-expensive || sudo -u www-data ./occ upgrade -n -vvv
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  update database indices"
    sudo -u www-data ./occ db:add-missing-indices
    sudo -u www-data ./occ maintenance:mode --off
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  maintenance done"
fi

echo "**** $(date +'%Y/%m/%d %H:%M:%S'): repair broken apps"
for app in $(ls $APPSDIR); do
    if test -d ${APPSDIR}/${app}/${app}; then
        echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  broken app: ${app}"
        rm -rf ${APPSDIR}/${app}
        sudo -u www-data ./occ app:install ${app}
    fi
done
echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  broken apps repaired"
sudo -u www-data ./occ maintenance:mode --off

echo "**** $(date +'%Y/%m/%d %H:%M:%S'): reset configuration"
if test -n "${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"; then
    # allow more database connections
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  set maximal mysql connections"
    mysql -h mysql -u root -p${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD} <<<"set global max_connections = 2000;"
fi
# add debugging if required
if test "$DEBUG" -eq 1; then
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  enable debug"
    sudo -u www-data ./occ config:system:set --value true debug
else
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  disable debug"
    sudo -u www-data ./occ config:system:set --value false debug
fi
echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  setup log file"
sudo -u www-data ./occ log:file --enable --file=/var/log/nextcloud.log --rotate-size=0
#sudo -u www-data ./occ config:system:set memcache.local --value '\OC\Memcache\APCu'
if test -n "$WEBROOT"; then
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  set webroot to $WEBROOT"
    sudo -u www-data ./occ config:system:set overwritewebroot --value "${WEBROOT}"
fi
if test -n "${HOST:-${URL}}"; then
    echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  set host to ${HOST:-${URL}}"
    sudo -u www-data ./occ config:system:set overwriteprotocol --value "${PROTOCOL:-https}"
    sudo -u www-data ./occ config:system:set overwritehost --value "${HOST:-${URL}}"
    sudo -u www-data ./occ config:system:set trusted_domains 1 --value "${HOST:-${URL}}"
fi
echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  configuration reset done"

echo "**** $(date +'%Y/%m/%d %H:%M:%S'): start cron job"
cat > /etc/cron.d/nextcloud <<EOF
*/15  *  *  *  * www-data php -f $INSTDIR/cron.php
@daily www-data $INSTDIR/occ files:scan --all
EOF
chmod +x /etc/cron.d/nextcloud
(! service cron status || service cron stop ) && service cron start
echo "---- $(date +'%Y/%m/%d %H:%M:%S'):  cronjob started"

echo "**** $(date +'%Y/%m/%d %H:%M:%S'): run apache"
if test -f /run/apache2/apache2.pid; then
    rm /run/apache2/apache2.pid;
fi;

echo "#### $(date +'%Y/%m/%d %H:%M:%S'): READY ####"
if test -n "$PASS" -a "$PASS" != "$ADMIN_PWD"; then
    echo "************************************"
    echo "admin-user:     $USER"
    echo "admin-password: $PASS"
    echo "************************************"
fi
touch /tmp/ready
while : ; do apache2ctl -DFOREGROUND; done
rm /tmp/ready
