<?php
declare(strict_types=1);

// Health check of the php-fpm image, run by the HEALTHCHECK of the Dockerfile.
//
// Asks the local php-fpm for status.php over FastCGI, the same way nginx does.
// Healthy means, as in the legacy image: php-fpm accepts the request, runs PHP
// and answers, and Nextcloud reports `installed: true`, `maintenance: false`
// and `needsDbUpgrade: false`.

require __DIR__ . '/fastcgi.php';

function unhealthy(string $reason): never
{
    fwrite(STDOUT, "unhealthy: {$reason}\n");
    exit(1);
}

try {
    $body = fastcgiGet('/app/status.php', '/status.php');
} catch (RuntimeException $e) {
    unhealthy($e->getMessage());
}

$status = json_decode($body, true);
if (!is_array($status)) {
    unhealthy('status.php answered no JSON: ' . substr(trim($body), 0, 200));
}
if (($status['installed'] ?? false) !== true) {
    unhealthy('Nextcloud is not installed');
}

if (($status['maintenance'] ?? true) !== false) {
    unhealthy('Nextcloud is in maintenance mode');
}
if (($status['needsDbUpgrade'] ?? true) !== false) {
    unhealthy('Nextcloud needs a database upgrade');
}
fwrite(STDOUT, 'healthy: Nextcloud ' . ($status['versionstring'] ?? '?') . "\n");
exit(0);
