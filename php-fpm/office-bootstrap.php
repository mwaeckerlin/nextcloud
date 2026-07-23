<?php
declare(strict_types=1);

function logMessage(string $message): void
{
    fwrite(STDERR, "nextcloud-office-bootstrap: {$message}\n");
}

function getSecretOrEnv(string $envName, string $secretFile): string
{
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

function runOcc(array $args): array
{
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

function isInstalled(): bool
{
    [, $stdout,] = runOcc(['status', '--no-ansi']);
    return strpos($stdout, 'installed: true') !== false;
}

function ensureAutoconfig(): void
{
    if (is_file('/app/config/config.php') || is_file('/app/config/autoconfig.php')) {
        return;
    }

    if (is_file('/usr/local/share/nextcloud/autoconfig.php')) {
        copy('/usr/local/share/nextcloud/autoconfig.php', '/app/config/autoconfig.php');
        logMessage('Installed autoconfig.php into mounted config volume');
    }
}

function ensureRuntimeConfig(): void
{
    $source = '/usr/local/share/nextcloud/custom.config.php';
    $target = '/app/config/custom.config.php';

    if (!is_file($source)) {
        return;
    }

    if (!is_dir('/app/config')) {
        mkdir('/app/config', 0770, true);
    }

    $sourceHash = @hash_file('sha256', $source);
    $targetHash = is_file($target) ? @hash_file('sha256', $target) : false;

    if ($sourceHash !== false && $sourceHash === $targetHash) {
        return;
    }

    if (!copy($source, $target)) {
        logMessage('Failed to sync custom.config.php into mounted config volume');
        return;
    }

    logMessage(is_string($targetHash) ? 'Updated custom.config.php in mounted config volume' : 'Installed custom.config.php into mounted config volume');
}

function listVisibleEntries(string $path): array
{
    $entries = @scandir($path);
    if ($entries === false) {
        return [];
    }

    return array_values(array_filter(
        $entries,
        static fn(string $entry): bool => $entry !== '.' && $entry !== '..'
    ));
}

function copyTree(string $source, string $target): void
{
    if (is_file($source)) {
        $parent = dirname($target);
        if (!is_dir($parent)) {
            mkdir($parent, 0775, true);
        }
        copy($source, $target);
        return;
    }

    if (!is_dir($target)) {
        mkdir($target, 0775, true);
    }

    foreach (listVisibleEntries($source) as $entry) {
        copyTree($source . '/' . $entry, $target . '/' . $entry);
    }
}

function seedCustomAppsIfEmpty(): void
{
    $seedDir = '/usr/local/share/nextcloud/seed/custom_apps';
    $targetDir = '/app/custom_apps';

    if (!is_dir($seedDir)) {
        return;
    }

    $seedEntries = listVisibleEntries($seedDir);
    if ($seedEntries === []) {
        return;
    }

    if (!is_dir($targetDir)) {
        mkdir($targetDir, 0775, true);
    }

    if (listVisibleEntries($targetDir) !== []) {
        return;
    }

    foreach ($seedEntries as $entry) {
        copyTree($seedDir . '/' . $entry, $targetDir . '/' . $entry);
    }

    logMessage('Seeded custom_apps into mounted apps volume (first run)');
}

function installNextcloudIfNeeded(): void
{
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

function appendWebroot(string $url, string $webroot): string
{
    if ($webroot === '' || $url === '') {
        return $url;
    }
    $webroot = '/' . trim($webroot, '/');
    // Don't double-add the webroot if it's already present
    $path = parse_url($url, PHP_URL_PATH) ?? '';
    if ($path === $webroot || str_starts_with($path, $webroot . '/')) {
        return $url;
    }
    return rtrim($url, '/') . $webroot;
}

function resolveWopiUrl(string $configuredWopiUrl): string
{
    // Use the configured URL as-is for discovery (internal container networking)
    // Don't validate at bootstrap time - Collabora may not be ready yet
    // Richdocuments app will validate when actually needed at token generation
    return $configuredWopiUrl;
}

function resolvePublicHost(): string
{
    $host = trim((string) (getenv('HOST') ?: ''));
    if ($host !== '') {
        return $host;
    }

    // Backward-compatible alias for older compose setups.
    $domain = trim((string) (getenv('DOMAIN') ?: ''));
    if ($domain !== '') {
        return $domain;
    }

    $selfCheckUrl = trim((string) (getenv('SELF_CHECK_URL') ?: ''));
    if ($selfCheckUrl !== '') {
        $selfCheckHost = (string) (parse_url($selfCheckUrl, PHP_URL_HOST) ?: '');
        if ($selfCheckHost !== '') {
            $selfCheckPort = parse_url($selfCheckUrl, PHP_URL_PORT);
            return $selfCheckPort ? $selfCheckHost . ':' . $selfCheckPort : $selfCheckHost;
        }
    }

    return 'localhost:8824';
}

function getPublicBaseUrl(string $webroot): string
{
    $protocol = getenv('PROTOCOL') ?: 'https';
    $host = resolvePublicHost();

    return appendWebroot($protocol . '://' . $host, $webroot);
}

function getInternalBaseUrl(string $webroot): string
{
    return appendWebroot('http://nextcloud-nginx:8080', $webroot);
}

function isValidUrl(string $url): bool
{
    // Check if URL has a hostname/host component (not just protocol)
    // Reject incomplete URLs like 'https://' or 'http://'
    $parsed = parse_url($url);
    if ($parsed === false || !isset($parsed['host']) || $parsed['host'] === '') {
        return false;
    }
    return true;
}

function applyOfficeConfig(): void
{
    // All Collabora URLs are auto-derived from HOST and PROTOCOL only
    // No external env vars for OFFICE_PUBLIC_WOPI_URL or OFFICE_CALLBACK_URL

    $webroot = trim(getenv('WEBROOT') ?: '', '/');
    $protocol = getenv('PROTOCOL') ?: 'https';
    $publicHost = resolvePublicHost();

    // OFFICE_WOPI_URL: can be overridden, defaults to local Collabora service
    $wopiUrl = getenv('OFFICE_WOPI_URL') ?: 'http://collabora:9980';

    // Public and callback URLs: always auto-derived from HOST/PROTOCOL
    $publicWopiUrl = appendWebroot($protocol . '://' . $publicHost, $webroot);
    $callbackUrl = appendWebroot('http://nextcloud-nginx:8080', $webroot);

    logMessage("Collabora config auto-derived: WOPI={$wopiUrl}, PUBLIC={$publicWopiUrl}, CALLBACK={$callbackUrl}");

    if (!isInstalled()) {
        logMessage('Nextcloud still not installed, skipping Office configuration');
        return;
    }

    logMessage('Applying Office configuration from environment');

    $wopiDiscoveryUrl = resolveWopiUrl($wopiUrl);
    $wopiUrlForAppConfig = $wopiDiscoveryUrl;

    if ($publicWopiUrl !== '' && $publicWopiUrl !== $wopiDiscoveryUrl) {
        logMessage("Using '{$wopiDiscoveryUrl}' for discovery and '{$publicWopiUrl}' as public WOPI URL");
    }

    // The app store index (apps.json) is ~12 MB; on slow connections the
    // default fetcher timeout of 120 s aborts mid-download and app:install
    // fails with "not found on the appstore". Raise it before installing.
    $appstoreTimeout = getenv('APPSTORE_TIMEOUT') ?: '600';
    [$code, , $stderr] = runOcc(['config:app:set', 'settings', 'appstore-timeout', '--value=' . $appstoreTimeout, '--no-interaction', '--no-ansi']);
    logMessage("appstore-timeout set to {$appstoreTimeout} returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    // A previously failed fetch blocks all app store requests for 300 s
    // (appstore-fetcher-lastFailure); clear it so the install can retry now.
    runOcc(['config:app:delete', 'settings', 'appstore-fetcher-lastFailure', '--no-ansi']);

    [$code, $stdout, $stderr] = runOcc(['app:install', 'richdocuments', '--no-ansi']);
    logMessage("app:install returned {$code}" . ($code !== 0 ? ' output: ' . preg_replace('/\s+/', ' ', trim($stdout . ' ' . $stderr)) : ''));

    [$code, $stdout, $stderr] = runOcc(['app:enable', 'richdocuments', '--no-ansi']);
    logMessage("app:enable returned {$code}" . ($code !== 0 ? ' output: ' . preg_replace('/\s+/', ' ', trim($stdout . ' ' . $stderr)) : ''));

    [$code, , $stderr] = runOcc(['richdocuments:activate-config', '--wopi-url=' . $wopiUrlForAppConfig, '--callback-url=' . $callbackUrl, '--no-ansi']);
    logMessage("richdocuments:activate-config returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_url', '--value=' . $wopiDiscoveryUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("wopi_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_callback_url', '--value=' . $callbackUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("wopi_callback_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'public_wopi_url', '--value=' . $publicWopiUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("public_wopi_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    $wopiAllowlist = getenv('OFFICE_WOPI_ALLOWLIST') ?: '';
    if ($wopiAllowlist !== '') {
        [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_allowlist', '--value=' . $wopiAllowlist, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
        logMessage("wopi_allowlist set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));
    } else {
        [$code, , $stderr] = runOcc(['config:app:delete', 'richdocuments', 'wopi_allowlist', '--error-if-not-exists', '--no-ansi']);
        logMessage("wopi_allowlist delete returned {$code}" . ($stderr ? " error: {$stderr}" : ''));
    }

    logMessage('Office configuration applied');
}

ensureAutoconfig();
seedCustomAppsIfEmpty();
ensureRuntimeConfig();
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
