Docker Image for Nextcloud
==========================

Example use with volumes and MySQL database behind a reverse proxy:

    docker run -d --name nextcloud-mysql-volume mysql sleep infinity
    docker run -d --name nextcloud-volume mwaeckerlin/nextcloud sleep infinity
    docker run -d --name nextcloud-mysql -e MYSQL_ROOT_PASSWORD=$(pwgen 20 1) -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD=$(pwgen 20 1) --volumes-from nextcloud-mysql-volume mysql
    docker run -d --name nextcloud -e URL="example.com" -e UPLOAD_MAX_FILESIZE=16G -e MAX_INPUT_TIME=7200 -e WEBROOT=/nextcloud --volumes-from nextcloud-volume --link nextcloud-mysql:mysql mwaeckerlin/nextcloud
    docker run -d -p 80:80 -p 443:443 [...] --link nextcloud:dev.marc.waeckerlin.org%2fnextcloud mwaeckerlin/reverse-proxy

Available Apps:
```
root@1fe4286762a5:/var/www/nextcloud# sudo -u www-data ./occ app:list        
  - activity: 2.2.1
  - announcementcenter: 1.1.1
  - calendar: 1.0
  - comments: 0.2
  - contacts: 1.0.0.0
  - dav: 0.1.5
  - documents: 0.12.0
  - encryption: 1.2.0
  - external: 1.2
  - federatedfilesharing: 0.1.0
  - federation: 0.0.4
  - files: 1.4.4
  - files_antivirus: 0.8.0.1
  - files_external: 0.5.2
  - files_pdfviewer: 0.8
  - files_sharing: 0.9.1
  - files_texteditor: 2.1
  - files_trashbin: 0.8.0
  - files_versions: 1.2.0
  - files_videoplayer: 0.9.8
  - files_w2g: 0.8.2.6
  - firstrunwizard: 1.1
  - gallery: 14.5.0
  - mail: 0.4.0
  - music: 0.3.10
  - news: 7.1.2
  - notes: 2.0.0
  - notifications: 0.2.3
  - ojsxc: 3.0.0
  - ownbackup: 0.3.8
  - ownnote: 1.07
  - provisioning_api: 0.4.1
  - shorten: 0.0.15
  - systemtags: 0.2
  - templateeditor: 0.1
  - updatenotification: 0.1.0
  - user_external: 0.4
  - pdflintview
  - user_ldap
root@1fe4286762a5:/var/www/nextcloud#
```