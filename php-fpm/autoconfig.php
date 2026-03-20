<?php
// Nextcloud auto-installer: runs on first request if config/config.php is absent.
// Passwords are read from Docker secrets first, env vars as fallback.

function secret(string $secret, string $env = ''): string {
    $f = "/run/secrets/$secret";
    if (is_readable($f)) return trim(file_get_contents($f));
    return $env ? (getenv($env) ?: '') : '';
}

$dbpass = secret('nextcloud_db_password', 'MYSQL_PASSWORD');

if (!($pass = secret('nextcloud_admin_password', 'ADMIN_PWD'))) {
    $pass = bin2hex(random_bytes(16));
    error_log("nextcloud: generated admin password: $pass");
}

$AUTOCONFIG = [
    'adminlogin' => getenv('ADMIN_USER') ?: 'admin',
    'adminpass'  => $pass,
    'dbtype'     => $dbpass ? 'mysql' : 'sqlite3',
    'dbhost'     => getenv('MYSQL_HOST') ?: 'mysql',
    'dbname'     => getenv('MYSQL_DATABASE') ?: 'nextcloud',
    'dbuser'     => getenv('MYSQL_USER') ?: 'nextcloud',
    'dbpass'     => $dbpass,
    'directory'  => '/app/data',
];
