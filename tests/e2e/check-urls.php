<?php
// Diagnostic of the e2e, copied into nextcloud-php-fpm when the setup checks
// report something: the URLs the setup checks try for map-test.js.map, each
// with the answer to HEAD, the error entries of nextcloud.log, and the
// findings of the database checks of serverinfo.

require_once '/app/lib/base.php';

use OCP\Http\Client\IClientService;
use OCP\IConfig;
use OCP\IURLGenerator;
use OCP\Server;

$config = Server::get(IConfig::class);
$urls = Server::get(IURLGenerator::class);
$webroot = rtrim($urls->getWebroot(), '/');
$path = '/apps/settings/js/map-test.js.map';
$bases = [rtrim($config->getSystemValueString('overwrite.cli.url', ''), '/'), rtrim($urls->getBaseUrl(), '/')];
foreach ($config->getSystemValue('trusted_domains', []) as $host) {
    $bases[] = "https://{$host}{$webroot}";
    $bases[] = "http://{$host}{$webroot}";
}
$client = Server::get(IClientService::class)->newClient();
foreach (array_unique(array_filter($bases)) as $base) {
    try {
        $answer = $client->head($base . $path, ['connect_timeout' => 10, 'verify' => false, 'http_errors' => true, 'nextcloud' => ['allow_local_address' => true]]);
        echo "{$base}{$path}: {$answer->getStatusCode()}\n";
    } catch (\Throwable $e) {
        echo "{$base}{$path}: " . substr($e->getMessage(), 0, 160) . "\n";
    }
}

foreach (file('/app/data/nextcloud.log') ?: [] as $line) {
    $entry = json_decode($line, true);
    if (is_array($entry) && ($entry['level'] ?? 0) >= 3) {
        echo "log: {$entry['app']}: " . substr((string) $entry['message'], 0, 300) . "\n";
        $exception = $entry['exception'] ?? null;
        while (is_array($exception)) {
            echo '  ' . ($exception['Exception'] ?? '') . ': ' . substr((string) ($exception['Message'] ?? ''), 0, 400)
                . ' at ' . ($exception['File'] ?? '') . ':' . ($exception['Line'] ?? '') . "\n";
            $exception = $exception['Previous'] ?? null;
        }
    }
}

// the rules of the database checks that do not pass, as the page of serverinfo
// lists them
try {
    $snapshot = Server::get(\OCA\ServerInfo\Database\DatabaseProbe::class)->snapshot();
    $results = Server::get(\OCA\ServerInfo\Database\Advisor::class)
        ->run(Server::get(\OCA\ServerInfo\Database\RuleSet\Mysql::class), $snapshot);
    foreach ($results as $result) {
        $row = $result->jsonSerialize();
        if (($row['status'] ?? $row['state'] ?? '') !== 'pass') {
            echo 'database check: ' . json_encode($row) . "\n";
        }
    }
} catch (\Throwable $e) {
    echo 'database checks: ' . $e->getMessage() . "\n";
}
