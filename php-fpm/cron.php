<?php
declare(strict_types=1);

// Background jobs of Nextcloud, started by office-bootstrap.php beside php-fpm:
// /app/cron.php every 15 minutes and `occ files:scan --all` once a day, the
// schedule of the legacy image. The first cron.php run switches Nextcloud from
// AJAX to cron mode. The image has no cron daemon, so this loop is the cron.

const CRON_INTERVAL = 15 * 60;
const SCAN_INTERVAL = 24 * 60 * 60;

function run(array $command): void
{
    $proc = proc_open($command, [0 => ['pipe', 'r'], 1 => STDOUT, 2 => STDERR], $pipes);
    if (!is_resource($proc)) {
        fwrite(STDERR, 'nextcloud-cron: failed to start ' . implode(' ', $command) . "\n");
        return;
    }
    fclose($pipes[0]);
    $code = proc_close($proc);
    if ($code !== 0) {
        fwrite(STDERR, 'nextcloud-cron: ' . implode(' ', $command) . " returned {$code}\n");
    }
}

// The first cron.php run comes first: it switches Nextcloud to cron mode.
run(['/usr/bin/php', '-f', '/app/cron.php']);

// Once per start, beside php-fpm, so the start does not wait for it: the login
// method of the database account, which MySQL 9 changes (db-auth.php); the
// optional indices again, because the run of the start printed nothing while
// an index of an app (tr_room_object of spreed) was still missing; the tables
// still in an old row format, rebuilt online by row-format.php; then the setup
// checks of the admin overview, with the repairs occ offers.
run(['/usr/bin/php', '/usr/local/bin/db-auth.php']);
run(['/usr/bin/php', '/app/occ', 'db:add-missing-indices', '--no-interaction', '--no-ansi']);
run(['/usr/bin/php', '/usr/local/bin/row-format.php']);
run(['/usr/bin/php', '/usr/local/bin/setup-checks.php']);

$nextScan = time() + SCAN_INTERVAL;
while (true) {
    sleep(CRON_INTERVAL);
    run(['/usr/bin/php', '-f', '/app/cron.php']);
    if (time() >= $nextScan) {
        run(['/usr/bin/php', '/app/occ', 'files:scan', '--all', '--no-interaction', '--no-ansi']);
        $nextScan = time() + SCAN_INTERVAL;
    }
}
