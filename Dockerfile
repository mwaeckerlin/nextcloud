# Example use with volumes and MySQL database behind a reverse proxy:
# docker run -d --name nextcloud-mysql-volume mysql sleep infinity
# docker run -d --name nextcloud-volume mwaeckerlin/nextcloud sleep infinity
# docker run -d --name nextcloud-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=$(pwgen 20 1) --volumes-from nextcloud-mysql-volume mysql
# docker run -d --name nextcloud -e URL="example.com" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e BASEPATH=/nextcloud --volumes-from nextcloud-volume --link nextcloud-mysql:mysql mwaeckerlin/nextcloud
# docker run -d -p 80:80 -p 443:443 [...] --link nextcloud:dev.marc.waeckerlin.org%2fnextcloud mwaeckerlin/reverse-proxy
FROM mwaeckerlin/ubuntu-base
MAINTAINER mwaeckerlin

EXPOSE 80
ENV UPLOAD_MAX_FILESIZE "8G"
ENV MAX_INPUT_TIME "3600"
ENV BASEPATH ""
ENV WEBROOT ""
ENV ADMIN_USER ""
ENV ADMIN_PWD ""
ENV URL ""

# default: your choice
ENV APPS ""

# recommended apps: disable activity and gallery (replace with galleryplus)
#ENV APPS "-activity -gallery calendar contacts galleryplus:@interfasys notes user_ldap"

# more examples for APPS
#ENV APPS "calendar contacts documents music news notes ownnote"
#ENV APPS "announcementcenter calendar contacts documents encryption external files_antivirus files_external files_w2g mail music news notes ojsxc ownbackup ownnote shorten user_external"
#ENV APPS "announcementcenter calendar contacts documents files_w2g music news notes ojsxc ownbackup ownnote"

# compile time variables
ENV INSTBASE "/var/www"
ENV INSTDIR "${INSTBASE}/nextcloud"
ENV DATADIR "${INSTDIR}/data"
ENV CONFDIR "${INSTDIR}/config"
ENV APPSDIR "${INSTDIR}/apps"
ENV SOURCE "https://download.nextcloud.com/server/releases/latest.zip"
WORKDIR /tmp
RUN apt-get update && apt-get install -y apache2 libapache2-mod-php7.0 php7.0-gd php7.0-json php7.0-mysql php7.0-curl php7.0-mbstring php7.0-intl php7.0-mcrypt php-imagick php7.0-xml php7.0-zip
RUN mkdir -p "${INSTDIR}"
RUN wget -qOnextcloud.tar.bz2 "${SOURCE}"
WORKDIR "${INSTBASE}"
RUN tar xf /tmp/nextcloud.tar.bz2
RUN rm /tmp/nextcloud.tar.bz2
WORKDIR "${INSTDIR}"
RUN cat > /etc/apache2/conf-available/nextcloud.conf <<EOF
Alias /nextcloud "${INSTDIR}/"

<Directory ${INSTDIR}/>
  Options +FollowSymlinks
  AllowOverride All

 <IfModule mod_dav.c>
  Dav off
 </IfModule>

 SetEnv HOME ${INSTDIR}
 SetEnv HTTP_HOME ${INSTDIR}

</Directory>
EOF

VOLUME $DATADIR
VOLUME $CONFDIR
VOLUME $APPSDIR
WORKDIR $INSTDIR
ADD start.sh /start.sh
CMD /start.sh
