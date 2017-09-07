FROM mwaeckerlin/ubuntu-base
MAINTAINER mwaeckerlin

EXPOSE 80
ENV UPLOAD_MAX_FILESIZE "8G"
ENV MAX_INPUT_TIME "3600"
ENV WEBROOT ""
ENV ADMIN_USER ""
ENV ADMIN_PWD ""
ENV URL ""
ENV DEBUG "0"
ENV WAIT_SECONDS_FOR_MYSQL "20"

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
ENV SOURCE_FILE="latest.tar.bz2"
ENV SOURCE="https://download.nextcloud.com/server/releases/${SOURCE_FILE}"
WORKDIR /tmp

ADD nextcloud.asc /nextcloud.asc
ADD start.sh /start.sh
ADD nextcloud.conf /nextcloud.conf

RUN apt-get update && apt-get install -y gnupg bzip2 pwgen sudo apache2 libapache2-mod-php7.0 php7.0-gd php7.0-json php7.0-mysql php7.0-curl php7.0-mbstring php7.0-intl php7.0-mcrypt php-imagick php7.0-xml php7.0-zip php-apcu php-ldap mysql
RUN mkdir -p "${INSTDIR}"
RUN wget -qO${SOURCE_FILE} ${SOURCE}
RUN wget -qO${SOURCE_FILE}.asc ${SOURCE}.asc
RUN gpg --import /nextcloud.asc
RUN gpg --verify ${SOURCE_FILE}.asc ${SOURCE_FILE}

WORKDIR "${INSTBASE}"
RUN tar xf /tmp/${SOURCE_FILE}
RUN rm /tmp/${SOURCE_FILE} /tmp/${SOURCE_FILE}.asc /nextcloud.asc
WORKDIR "${INSTDIR}"
RUN chmod +x occ
RUN mkdir data
RUN chown -R www-data config apps data

VOLUME $DATADIR
VOLUME $CONFDIR
WORKDIR $INSTDIR
CMD /start.sh
