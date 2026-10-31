<?php
declare(strict_types=1);

// Started once by cron.php: converts every Nextcloud table whose row format is
// not DYNAMIC, which the admin overview reports as «MySQL row format». Tables
// created before MariaDB 10.2.2 and MySQL 5.7.9 kept COMPACT; the migrations of
// Nextcloud never change the format of an existing table, and its collation
// repair touches only tables with a wrong collation. The table is rebuilt
// online (ALGORITHM=INPLACE, LOCK=NONE), so Nextcloud keeps reading and writing
// it meanwhile; a table the server cannot rebuild online is left as it is and
// logged with the error of the server.

require_once '/app/lib/base.php';

use OCP\IConfig;
use OCP\IDBConnection;
use OCP\Server;

function logMessage(string $message): void
{
    fwrite(STDERR, "nextcloud-row-format: {$message}\n");
}

$connection = Server::get(IDBConnection::class);
// the values of PLATFORM_MYSQL and PLATFORM_MARIADB; Nextcloud 30 and 31 have no PLATFORM_MARIADB
if (!in_array($connection->getDatabaseProvider(), ['mysql', 'mariadb'], true)) {
    exit(0);
}

// the query of the setup check MysqlRowFormat, so both see the same tables
$result = $connection->executeQuery(
    "SELECT table_name FROM information_schema.tables
        WHERE table_schema = ? AND table_name LIKE '*PREFIX*%' AND row_format != 'Dynamic'",
    [Server::get(IConfig::class)->getSystemValueString('dbname')],
);
// fetchOne() row by row: the result of Nextcloud 30 to 32 has no fetchFirstColumn()
$tables = [];
while (($table = $result->fetchOne()) !== false) {
    $tables[] = (string) $table;
}
$result->closeCursor();
if ($tables === []) {
    exit(0);
}

logMessage(count($tables) . ' tables are not ROW_FORMAT=DYNAMIC, converting them online');
$failed = 0;
foreach ($tables as $table) {
    $started = time();
    try {
        $connection->executeStatement("ALTER TABLE `{$table}` ROW_FORMAT=DYNAMIC, ALGORITHM=INPLACE, LOCK=NONE");
        logMessage("{$table} converted after " . (time() - $started) . 's');
    } catch (\Throwable $e) {
        $failed++;
        logMessage("{$table} left as it is: " . $e->getMessage());
    }
}
logMessage(($failed === 0 ? 'all tables' : (count($tables) - $failed) . ' of ' . count($tables) . ' tables') . ' are ROW_FORMAT=DYNAMIC now');
exit($failed === 0 ? 0 : 1);
