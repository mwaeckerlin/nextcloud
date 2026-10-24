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

// An empty variable takes the default, as in the legacy image.
function envOrDefault(string $envName, string $default): string
{
    $value = trim((string) getenv($envName));
    return $value !== '' ? $value : $default;
}

// Runs occ and returns [exit code, stdout, stderr]. With $live, every line
// occ prints goes to the container log the moment it arrives, so a long
// upgrade shows that it runs.
function runOcc(array $args, bool $live = false): array
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
    // fread takes what a pipe holds, also a line without its end, so neither
    // pipe fills up while the other one is read
    $output = [1 => '', 2 => ''];
    $partial = [1 => '', 2 => ''];
    $open = [1 => $pipes[1], 2 => $pipes[2]];
    while ($open !== []) {
        $read = array_values($open);
        $write = $except = null;
        if (stream_select($read, $write, $except, null) === false) {
            break;
        }
        foreach ($open as $channel => $pipe) {
            if (!in_array($pipe, $read, true)) {
                continue;
            }
            $chunk = fread($pipe, 65536);
            if ($chunk === false || ($chunk === '' && feof($pipe))) {
                fclose($pipe);
                unset($open[$channel]);
                $chunk = "\n";
            } else {
                $output[$channel] .= $chunk;
            }
            if ($live) {
                $lines = explode("\n", $partial[$channel] . $chunk);
                $partial[$channel] = array_pop($lines);
                foreach ($lines as $line) {
                    if (trim($line) !== '') {
                        logMessage('  ' . rtrim($line));
                    }
                }
            }
        }
    }
    $code = proc_close($proc);

    return [$code, $output[1], $output[2]];
}

function isInstalled(): bool
{
    [, $stdout,] = runOcc(['status', '--no-ansi']);
    return strpos($stdout, 'installed: true') !== false;
}

// Asks `occ status` until it answers, for at most WAIT_SECONDS_FOR_MYSQL: an
// installed Nextcloud cannot answer before its database does, and deciding
// between install and upgrade on that failure skipped the upgrade. Returns
// true or false once occ answers, null when the database never did.
function waitForStatus(): ?bool
{
    $waitSeconds = (int) envOrDefault('WAIT_SECONDS_FOR_MYSQL', '300');
    $started = time();
    while (true) {
        [, $stdout, $stderr] = runOcc(['status', '--no-ansi', '--no-warnings']);
        if (strpos($stdout, 'installed: true') !== false) {
            return true;
        }
        if (strpos($stdout, 'installed: false') !== false) {
            return false;
        }
        $waited = time() - $started;
        $reason = strtok(trim($stdout . "\n" . $stderr), "\n") ?: 'no answer';
        if ($waited + 5 > $waitSeconds) {
            logMessage("Nextcloud did not answer within {$waitSeconds}s: {$reason}");
            return null;
        }
        logMessage("Waiting for the database, {$waited}s of {$waitSeconds}s: {$reason}");
        sleep(5);
    }
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
    // MYSQL_ENV_MYSQL_* are the variables of a docker link to a container
    // named mysql, read by the legacy image before MYSQL_*
    $dbHost = getenv('MYSQL_HOST') ?: 'mysql';
    $dbName = getenv('MYSQL_ENV_MYSQL_DATABASE') ?: (getenv('MYSQL_DATABASE') ?: 'nextcloud');
    $dbUser = getenv('MYSQL_ENV_MYSQL_USER') ?: (getenv('MYSQL_USER') ?: 'nextcloud');
    $dbPass = getenv('MYSQL_ENV_MYSQL_PASSWORD') ?: getSecretOrEnv('MYSQL_PASSWORD', '/run/secrets/nextcloud_db_password');
    $dataDir = '/app/data';

    if ($adminPass === '' || $dbPass === '') {
        logMessage('Missing admin/db credentials, skipping unattended installation');
        return;
    }

    // the database may still be starting: retry for WAIT_SECONDS_FOR_MYSQL
    $waitSeconds = (int) envOrDefault('WAIT_SECONDS_FOR_MYSQL', '300');
    $deadline = time() + $waitSeconds;
    logMessage("Nextcloud not installed yet, starting unattended installation, waiting up to {$waitSeconds}s for the database");

    while (true) {
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

        // occ maintenance:install exits 0 also when the database refused the
        // connection, so only `occ status` tells whether it worked
        if (isInstalled()) {
            logMessage('Unattended installation completed');
            return;
        }

        $combined = trim($stdout . "\n" . $stderr);
        if ($combined !== '') {
            logMessage('Install retry: ' . preg_replace('/\s+/', ' ', $combined));
        }
        if (time() + 5 > $deadline) {
            break;
        }
        usleep(5_000_000);
    }

    logMessage('Installation did not complete within retry window');
}

// One step of the start: announced, its occ output shown as it comes, and
// its result with the time it took.
function logOcc(string $step, array $args): int
{
    logMessage("{$step} …");
    $started = time();
    [$code] = runOcc(array_merge($args, ['--no-interaction', '--no-ansi', '--no-warnings']), true);
    logMessage("{$step} returned {$code} after " . (time() - $started) . 's');
    return $code;
}

function removeTree(string $path): void
{
    if (is_dir($path) && !is_link($path)) {
        foreach (listVisibleEntries($path) as $entry) {
            removeTree($path . '/' . $entry);
        }
        rmdir($path);
        return;
    }
    unlink($path);
}

// On every start of an installed Nextcloud, as the legacy image does: leave
// maintenance mode, upgrade, repair, complete the database, reinstall apps
// that an update left nested in themselves.
function upgradeNextcloud(): void
{
    logMessage('Upgrading and repairing the installation');
    logOcc('maintenance:mode --off', ['maintenance:mode', '--off']);
    logOcc('upgrade', ['upgrade']);
    if (logOcc('maintenance:repair', ['maintenance:repair']) !== 0
        && logOcc('maintenance:repair --include-expensive', ['maintenance:repair', '--include-expensive']) !== 0) {
        logOcc('upgrade', ['upgrade']);
    }
    logOcc('db:add-missing-indices', ['db:add-missing-indices']);
    logOcc('db:add-missing-columns', ['db:add-missing-columns']);
    logOcc('db:convert-filecache-bigint', ['db:convert-filecache-bigint']);
    logOcc('db:convert-mysql-charset', ['db:convert-mysql-charset']);
    logOcc('db:add-missing-primary-keys', ['db:add-missing-primary-keys']);
    foreach (listVisibleEntries('/app/custom_apps') as $app) {
        if (is_dir("/app/custom_apps/{$app}/{$app}")) {
            logMessage("Reinstalling broken app {$app}");
            removeTree("/app/custom_apps/{$app}");
            logOcc("app:install {$app}", ['app:install', $app]);
        }
    }
    logOcc('maintenance:mode --off', ['maintenance:mode', '--off']);
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

    // URL is the same setting as HOST, as in the legacy image
    $url = trim((string) (getenv('URL') ?: ''));
    if ($url !== '') {
        return $url;
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

    // Collabora is the office of the image: a second office app (ONLYOFFICE)
    // claims the same file types, so a document opens in whichever app wins
    if (str_contains(runOcc(['app:list', '--enabled', '--output=json', '--no-warnings'])[1], '"onlyoffice"')) {
        logOcc('app:disable onlyoffice', ['app:disable', 'onlyoffice']);
    }

    [$code, , $stderr] = runOcc(['richdocuments:activate-config', '--wopi-url=' . $wopiUrlForAppConfig, '--callback-url=' . $callbackUrl, '--no-ansi']);
    logMessage("richdocuments:activate-config returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_url', '--value=' . $wopiDiscoveryUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("wopi_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_callback_url', '--value=' . $callbackUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("wopi_callback_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'public_wopi_url', '--value=' . $publicWopiUrl, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("public_wopi_url set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    // Only Collabora may fetch documents over WOPI. Without an allowlist any
    // host may, and Nextcloud Office warns; Collabora runs in a network of the
    // stack, so the private networks of Docker are the default.
    $wopiAllowlist = getenv('OFFICE_WOPI_ALLOWLIST') ?: '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16';
    [$code, , $stderr] = runOcc(['config:app:set', 'richdocuments', 'wopi_allowlist', '--value=' . $wopiAllowlist, '--type=string', '--internal', '--no-interaction', '--no-warnings', '--no-ansi']);
    logMessage("wopi_allowlist {$wopiAllowlist} set returned {$code}" . ($stderr ? " error: {$stderr}" : ''));

    logMessage('Office configuration applied');
}

// Client Push: where NOTIFY_PUSH_HOST names the push server of the stack
// (image mwaeckerlin/nextcloud:notify-push), the app notify_push is installed
// and sends the clients to <public URL>/push, which nginx forwards to that
// server. NOTIFY_PUSH_ENDPOINT sets another address.
function applyNotifyPushConfig(): void
{
    if (trim((string) getenv('NOTIFY_PUSH_HOST')) === '' || !isInstalled()) {
        return;
    }
    $endpoint = getenv('NOTIFY_PUSH_ENDPOINT') ?: getPublicBaseUrl(trim(getenv('WEBROOT') ?: '', '/')) . '/push';
    if (!is_dir('/app/custom_apps/notify_push')) {
        logOcc('app:install notify_push', ['app:install', 'notify_push']);
    }
    logOcc('app:enable notify_push', ['app:enable', 'notify_push']);
    logOcc("notify_push base_endpoint {$endpoint}", ['config:app:set', 'notify_push', 'base_endpoint', '--value=' . $endpoint]);
}

// Talk high-performance backend: where TALK_SIGNALING_HOST names the signaling
// server of docker-compose.talk.yml, Talk is installed and the server is
// registered at <public URL>/standalone-signaling, which nginx forwards to it.
// TALK_SIGNALING_URL sets another address.
function applyTalkConfig(): void
{
    if (trim((string) getenv('TALK_SIGNALING_HOST')) === '' || !isInstalled()) {
        return;
    }
    $url = getenv('TALK_SIGNALING_URL') ?: getPublicBaseUrl(trim(getenv('WEBROOT') ?: '', '/')) . '/standalone-signaling';
    if (!is_dir('/app/custom_apps/spreed')) {
        logOcc('app:install spreed', ['app:install', 'spreed']);
    }
    logOcc('app:enable spreed', ['app:enable', 'spreed']);
    $proc = proc_open(['/usr/bin/php', '/usr/local/bin/talk-signaling.php', $url], [0 => STDIN, 1 => STDOUT, 2 => STDERR], $pipes);
    if (is_resource($proc)) {
        proc_close($proc);
    }
}

// Nextcloud's log file on to the container log, kept below LOG_MAX_SIZE; it
// starts first, so the log of the installation and the upgrade arrives too.
$logFollow = proc_open(['/usr/bin/php', '/usr/local/bin/log-follow.php'], [0 => STDIN, 1 => STDOUT, 2 => STDERR], $logFollowPipes);
if (!is_resource($logFollow)) {
    logMessage('Failed to pass nextcloud.log on to the container log');
}

ensureAutoconfig();
seedCustomAppsIfEmpty();
ensureRuntimeConfig();
// The decision waits for the database; after an install the upgrade path
// runs as well and has nothing to do on a fresh installation.
if (waitForStatus() !== true) {
    installNextcloudIfNeeded();
}
if (isInstalled()) {
    upgradeNextcloud();
} else {
    logMessage('Nextcloud is not installed, nothing to upgrade');
}
applyOfficeConfig();
applyNotifyPushConfig();
applyTalkConfig();
if (isInstalled()) {
    // before the first background job, see theming-appdata.php
    $theming = proc_open(['/usr/bin/php', '/usr/local/bin/theming-appdata.php'], [0 => STDIN, 1 => STDOUT, 2 => STDERR], $themingPipes);
    if (is_resource($theming)) {
        proc_close($theming);
    }
}

// The background jobs of the legacy image: cron.php every 15 minutes and a
// daily file scan, in a process of its own beside php-fpm.
$cron = proc_open(['/usr/bin/php', '/usr/local/bin/cron.php'], [0 => STDIN, 1 => STDOUT, 2 => STDERR], $cronPipes);
if (!is_resource($cron)) {
    logMessage('Failed to start the background jobs');
}

// The PHP limits of the legacy image: UPLOAD_MAX_FILESIZE bounds uploads and
// POST bodies, MAX_INPUT_TIME the time to read and run a request, and
// MEMORY_LIMIT falls back to UPLOAD_MAX_FILESIZE when empty.
$uploadMaxFilesize = envOrDefault('UPLOAD_MAX_FILESIZE', '8G');
$maxInputTime = envOrDefault('MAX_INPUT_TIME', '3600');
$memoryLimit = envOrDefault('MEMORY_LIMIT', $uploadMaxFilesize);
// zz-nextcloud.conf reads it; php-fpm refuses to start on an empty value
putenv('MAX_REQUEST_WORKERS=' . envOrDefault('MAX_REQUEST_WORKERS', '100'));

// No shell fallback: run php-fpm directly as a process.
$proc = proc_open([
    '/usr/sbin/php-fpm',
    '-F',
    '-R',
    '-O',
    '-d', 'upload_max_filesize=' . $uploadMaxFilesize,
    '-d', 'post_max_size=' . $uploadMaxFilesize,
    '-d', 'memory_limit=' . $memoryLimit,
    '-d', 'max_input_time=' . $maxInputTime,
    '-d', 'max_execution_time=' . $maxInputTime,
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
