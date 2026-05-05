<?php
declare(strict_types=1);

function logMessage(string $message): void {
    fwrite(STDERR, "nextcloud-office-bootstrap: {$message}\n");
}

function getSecretOrEnv(string $envName, string $secretFile): string {
    $value = getenv($envName);
    if (is_string($value) && $value !== '') {
        return $value;
    }

    if (is_file($secretFile)) {
        $secret = trim((string) file_get_contents($secretFile));
        if ($secret !== '') {
            return $secret;
        }
    }

    return '';
}

function runOcc(array $args): array {
    $cmd = array_merge(['php', '/app/occ'], $args);
    $descriptorSpec = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $proc = proc_open($cmd, $descriptorSpec, $pipes);
    if (!is_resource($proc)) {
        return [1, '', 'failed to start process'];
    }

    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $code = proc_close($proc);

    return [$code, (string) $stdout, (string) $stderr];
}

function isInstalled(): bool {
    [, $stdout, ] = runOcc(['status', '--no-ansi']);
    return strpos($stdout, 'installed: true') !== false;
}

function ensureAutoconfig(): void {
    if (is_file('/app/config/config.php') || is_file('/app/config/autoconfig.php')) {
        return;
    }

    if (is_file('/usr/local/share/nextcloud/autoconfig.php')) {
        copy('/usr/local/share/nextcloud/autoconfig.php', '/app/config/autoconfig.php');
        logMessage('Installed autoconfig.php into mounted config volume');
    }
}

function installNextcloudIfNeeded(): void {
    if (isInstalled()) {
        return;
    }

    $adminUser = getenv('ADMIN_USER') ?: 'admin';
    $adminPass = getSecretOrEnv('ADMIN_PWD', '/run/secrets/nextcloud_admin_password');
    $dbHost = getenv('MYSQL_HOST') ?: 'mysql';
    $dbName = getenv('MYSQL_DATABASE') ?: 'nextcloud';
    $dbUser = getenv('MYSQL_USER') ?: 'nextcloud';
    $dbPass = getSecretOrEnv('MYSQL_PASSWORD', '/run/secrets/nextcloud_db_password');
    $dataDir = '/app/data';

    if ($adminPass === '' || $dbPass === '') {
        logMessage('Missing admin/db credentials, skipping unattended installation');
        return;
    }

    logMessage('Nextcloud not installed yet, starting unattended installation');

    for ($i = 0; $i < 60; $i++) {
        [$code, $stdout, $stderr] = runOcc([
            'maintenance:install',
            '--database=mysql',
            '--database-host=' . $dbHost,
            '--database-name=' . $dbName,
            '--database-user=' . $dbUser,
            '--database-pass=' . $dbPass,
            '--admin-user=' . $adminUser,
            '--admin-pass=' . $adminPass,
            '--data-dir=' . $dataDir,
            '--no-interaction',
            '--no-ansi',
        ]);

        if ($code === 0 || isInstalled()) {
            logMessage('Unattended installation completed');
            return;
        }

        $combined = trim($stdout . "\n" . $stderr);
        if ($combined !== '') {
            logMessage('Install retry: ' . preg_replace('/\s+/', ' ', $combined));
        }
        usleep(5_000_000);
    }

    logMessage('Installation did not complete within retry window');
}

function applyOfficeConfig(): void {
    $wopiUrl = getenv('OFFICE_WOPI_URL') ?: '';
    if ($wopiUrl === '') {
        logMessage('OFFICE_WOPI_URL is empty, skipping Office configuration');
        return;
    }

    if (!isInstalled()) {
        logMessage('Nextcloud still not installed, skipping Office configuration');
        return;
    }

    logMessage('Applying Office configuration from environment');

    runOcc(['app:install', 'richdocuments', '--no-ansi']);
    runOcc(['app:enable', 'richdocuments', '--no-ansi']);

    $callbackUrl = getenv('OFFICE_CALLBACK_URL') ?: '';
    if ($callbackUrl !== '') {
        runOcc(['richdocuments:activate-config', '--wopi-url=' . $wopiUrl, '--callback-url=' . $callbackUrl, '--no-ansi']);
    } else {
        runOcc(['richdocuments:activate-config', '--wopi-url=' . $wopiUrl, '--no-ansi']);
    }

    runOcc(['config:app:set', 'richdocuments', 'wopi_url', '--value=' . $wopiUrl, '--no-ansi']);

    if ($callbackUrl !== '') {
        runOcc(['config:app:set', 'richdocuments', 'wopi_callback_url', '--value=' . $callbackUrl, '--no-ansi']);
    }

    $publicWopiUrl = getenv('OFFICE_PUBLIC_WOPI_URL') ?: '';
    if ($publicWopiUrl !== '') {
        runOcc(['config:app:set', 'richdocuments', 'public_wopi_url', '--value=' . $publicWopiUrl, '--no-ansi']);
    }

    logMessage('Office configuration applied');
}

ensureAutoconfig();
installNextcloudIfNeeded();
applyOfficeConfig();

// No shell fallback: run php-fpm directly as a process.
$proc = proc_open([
    '/usr/sbin/php-fpm',
    '-F',
    '-R',
    '-O',
], [
    0 => STDIN,
    1 => STDOUT,
    2 => STDERR,
], $pipes);

if (!is_resource($proc)) {
    fwrite(STDERR, "nextcloud-office-bootstrap: failed to start php-fpm\n");
    exit(1);
}

$exitCode = proc_close($proc);
exit(is_int($exitCode) ? $exitCode : 1);
