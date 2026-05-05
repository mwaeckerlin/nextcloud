<?php
// Runtime configuration fragment: always loaded by Nextcloud alongside config.php.
// Values are read from environment variables at request time (clear_env = no in fpm).

$CONFIG = [
    'log_type' => 'errorlog',
    'loglevel' => (int) (getenv('LOGLEVEL') !== false ? getenv('LOGLEVEL') : 2),
    'logdateformat' => 'c',
    'debug' => getenv('DEBUG') === '1',
    'overwriteprotocol' => getenv('PROTOCOL') ?: 'https',
    'maintenance_window_start' => 1,
    'default_phone_region' => 'CH',
    'mail_smtpmode' => 'smtp',
    'mail_sendmailmode' => 'smtp',
    'mail_smtphost' => 'smtp-relay',
    'mail_smtpport' => '25',
    'apps_paths' => [
        [
            'path' => '/app/apps',
            'url' => '/apps',
            'writable' => false,
        ],
        [
            'path' => '/app/custom_apps',
            'url' => '/custom_apps',
            'writable' => true,
        ],
    ],
];

if ($serverId = getenv('SERVER_ID')) {
    $CONFIG['server_id'] = $serverId;
}

if (function_exists('apcu_enabled') && apcu_enabled()) {
    $CONFIG['memcache.local'] = '\\OC\\Memcache\\APCu';
} else {
    $CONFIG['memcache.local'] = '\\OC\\Memcache\\ArrayCache';
}

$hostNoPort = null;
if ($host = getenv('HOST')) {
    $hostNoPort = preg_replace('/:\\d+$/', '', $host);
    $CONFIG['overwritehost'] = $host;
    $CONFIG['trusted_domains'] = array_values(array_unique([
        $host,
        $hostNoPort,
        'localhost',
        'nextcloud-nginx',
        'nextcloud-nextcloud-nginx-1',
    ]));
    $CONFIG['overwrite.cli.url'] = getenv('SELF_CHECK_URL') ?: ((getenv('PROTOCOL') ?: 'https') . '://' . $host);
}

if ($selfCheckUrl = getenv('SELF_CHECK_URL')) {
    $selfCheckHost = parse_url($selfCheckUrl, PHP_URL_HOST);
    $selfCheckPort = parse_url($selfCheckUrl, PHP_URL_PORT);
    if ($selfCheckHost) {
        $selfCheckDomain = $selfCheckPort ? $selfCheckHost . ':' . $selfCheckPort : $selfCheckHost;
        $CONFIG['trusted_domains'] = array_values(array_unique(array_merge($CONFIG['trusted_domains'] ?? [], [
            $selfCheckHost,
            $selfCheckDomain,
        ])));
    }
    $CONFIG['overwrite.cli.url'] = $selfCheckUrl;
}

$CONFIG['mail_from_address'] = getenv('MAIL_FROM_ADDRESS') ?: 'nextcloud';
$CONFIG['mail_domain'] = getenv('MAIL_DOMAIN') ?: ($hostNoPort ?: 'localhost');

if ($webroot = getenv('WEBROOT')) {
    $CONFIG['overwritewebroot'] = $webroot;
}
