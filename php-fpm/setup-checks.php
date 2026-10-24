<?php
declare(strict_types=1);

// Started once per start by cron.php, beside php-fpm: runs the setup checks of
// Administration settings › Overview, repairs what an occ command repairs, runs
// the checks again and writes every error and warning that stays into the
// container log, with what the check says. What needs the administrator
// stands in the README under «Admin overview».

// check class => the command that settles it
const REPAIRS = [
    'OCA\Settings\SetupChecks\DatabaseHasMissingIndices' => ['/usr/bin/php', '/app/occ', 'db:add-missing-indices'],
    'OCA\Settings\SetupChecks\DatabaseHasMissingColumns' => ['/usr/bin/php', '/app/occ', 'db:add-missing-columns'],
    'OCA\Settings\SetupChecks\DatabaseHasMissingPrimaryKeys' => ['/usr/bin/php', '/app/occ', 'db:add-missing-primary-keys'],
    'OCA\Settings\SetupChecks\DatabasePendingBigIntConversions' => ['/usr/bin/php', '/app/occ', 'db:convert-filecache-bigint'],
    'OCA\Settings\SetupChecks\MysqlRowFormat' => ['/usr/bin/php', '/usr/local/bin/row-format.php'],
    'OCA\Settings\SetupChecks\MimeTypeMigrationAvailable' => ['/usr/bin/php', '/app/occ', 'maintenance:repair', '--include-expensive'],
    'OCA\DAV\SetupChecks\NeedsSystemAddressBookSync' => ['/usr/bin/php', '/app/occ', 'dav:sync-system-addressbook'],
];

function logMessage(string $message): void
{
    fwrite(STDERR, "nextcloud-setup-check: {$message}\n");
}

// check class => [severity, name, description] of every error and warning
function findings(): array
{
    $proc = proc_open(['/usr/bin/php', '/app/occ', 'setupchecks', '--output=json', '--no-warnings'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => STDERR], $pipes);
    if (!is_resource($proc)) {
        logMessage('cannot run occ setupchecks');
        return [];
    }
    fclose($pipes[0]);
    $json = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    proc_close($proc);
    $all = json_decode((string) $json, true);
    if (!is_array($all)) {
        logMessage('occ setupchecks gave no JSON: ' . substr(trim((string) $json), 0, 200));
        return [];
    }
    $found = [];
    foreach ($all as $checks) {
        foreach ($checks as $class => $result) {
            if (in_array($result['severity'] ?? '', ['error', 'warning'], true)) {
                $found[$class] = [$result['severity'], $result['name'] ?? $class, trim((string) ($result['description'] ?? ''))];
            }
        }
    }
    return $found;
}

function run(array $command): int
{
    $proc = proc_open(array_merge($command, str_ends_with($command[1], 'occ') ? ['--no-interaction', '--no-ansi'] : []), [0 => ['pipe', 'r'], 1 => STDOUT, 2 => STDERR], $pipes);
    if (!is_resource($proc)) {
        return 1;
    }
    fclose($pipes[0]);
    return proc_close($proc);
}

foreach (findings() as $class => [$severity, $name]) {
    if (isset(REPAIRS[$class])) {
        $started = time();
        logMessage("{$name} reports a {$severity}, running " . implode(' ', array_slice(REPAIRS[$class], 1)));
        $code = run(REPAIRS[$class]);
        logMessage("{$name}: repair returned {$code} after " . (time() - $started) . 's');
    }
}
$remaining = findings();
foreach ($remaining as $class => [$severity, $name, $description]) {
    logMessage("{$severity} {$name} ({$class}): " . preg_replace('/\s+/', ' ', $description));
}
logMessage($remaining === [] ? 'no errors and no warnings' : count($remaining) . ' errors and warnings remain, see the README section «Admin overview»');
