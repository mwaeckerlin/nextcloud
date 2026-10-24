<?php
declare(strict_types=1);

// Started once per start by cron.php: the account Nextcloud logs in to MySQL
// with. MySQL 8.0 marks mysql_native_password as deprecated, 8.4 switches it
// off by default and 9.0 removes it, so an account that still uses it locks
// Nextcloud out after an upgrade of the database. The script reads the method
// of its own account, which needs no privilege, and warns with the statement
// an administrator of the database runs: switching the method needs the
// privilege CREATE USER, measured on MySQL 8.4 (error 1227), and Nextcloud has
// no such privilege. MariaDB keeps mysql_native_password as its default and is
// left as it is. PHP logs in with caching_sha2_password without TLS as well.
//
// Usage: php db-auth.php [<config.php>]   (default /app/config/config.php)

function logMessage(string $message): void
{
    fwrite(STDERR, "nextcloud-db-auth: {$message}\n");
}

$CONFIG = [];
include $argv[1] ?? '/app/config/config.php';
if (($CONFIG['dbtype'] ?? '') !== 'mysql') {
    exit(0);
}
[$host, $port] = array_pad(explode(':', (string) ($CONFIG['dbhost'] ?? 'localhost'), 2), 2, '3306');
$user = (string) $CONFIG['dbuser'];
try {
    $db = new PDO("mysql:host={$host};port={$port};dbname={$CONFIG['dbname']}", $user, (string) $CONFIG['dbpassword'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
} catch (PDOException $e) {
    logMessage('cannot log in to the database: ' . $e->getMessage());
    exit(1);
}
$version = (string) $db->query('SELECT VERSION()')->fetchColumn();
if (stripos($version, 'mariadb') !== false) {
    exit(0);
}
$definition = (string) $db->query('SHOW CREATE USER CURRENT_USER()')->fetchColumn();
if (!preg_match("/IDENTIFIED WITH '([a-z0-9_]+)'/", $definition, $match)) {
    logMessage("MySQL {$version}: cannot read the login method of the account {$user}");
    exit(1);
}
if ($match[1] === 'mysql_native_password') {
    [$account, $accountHost] = explode('@', (string) $db->query('SELECT CURRENT_USER()')->fetchColumn(), 2) + [1 => '%'];
    logMessage("warning: MySQL {$version}: the account {$user} logs in with mysql_native_password, which MySQL 9 removes; "
        . "an administrator of the database runs: ALTER USER '{$account}'@'{$accountHost}' IDENTIFIED WITH caching_sha2_password BY '<password of nextcloud_db_password>';"
        . " and removes --mysql-native-password from the command of the server before MySQL 9");
    exit(0);
}
logMessage("MySQL {$version}: the account {$user} logs in with {$match[1]}");
