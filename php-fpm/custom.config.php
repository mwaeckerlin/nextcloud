<?php
// Runtime configuration fragment: always loaded by Nextcloud alongside config.php.
// Values are read from environment variables at request time (clear_env = no in fpm).

$CONFIG = [
    'memcache.local' => '\OC\Memcache\APCu',
    'log_type' => 'errorlog',
    'logdateformat' => 'c',
    'debug' => getenv('DEBUG') === '1',
    'overwriteprotocol' => getenv('PROTOCOL') ?: 'https',
];

if ($host = getenv('HOST')) {
    $CONFIG['overwritehost'] = $host;
    $CONFIG['trusted_domains'] = [$host];
}

if ($webroot = getenv('WEBROOT')) {
    $CONFIG['overwritewebroot'] = $webroot;
}
