<?php
// Runtime configuration fragment: always loaded by Nextcloud alongside config.php.
// Values are read from environment variables at request time (clear_env = no in fpm).

function addWebrootToUrl(string $url, string $webroot): string
{
    if ($webroot === '') {
        return $url;
    }

    $parts = parse_url($url);
    if ($parts === false) {
        return $url;
    }

    $path = $parts['path'] ?? '';
    if ($path !== '' && $path !== '/') {
        return $url;
    }

    $scheme = isset($parts['scheme']) ? $parts['scheme'] . '://' : '';
    $user = $parts['user'] ?? '';
    $pass = $parts['pass'] ?? '';
    $auth = $user === '' ? '' : $user . ($pass === '' ? '' : ':' . $pass) . '@';
    $host = $parts['host'] ?? '';
    $port = isset($parts['port']) ? ':' . $parts['port'] : '';
    $query = isset($parts['query']) ? '?' . $parts['query'] : '';
    $fragment = isset($parts['fragment']) ? '#' . $parts['fragment'] : '';

    return $scheme . $auth . $host . $port . $webroot . $query . $fragment;
}

$webroot = getenv('WEBROOT');
$webroot = is_string($webroot) && trim($webroot, '/') !== '' ? '/' . trim($webroot, '/') : '';

$protocol = getenv('PROTOCOL') ?: 'https';
$host = getenv('HOST') ?: 'localhost:8824';
$defaultSelfCheckUrl = $protocol . '://' . $host;
$selfCheckUrl = getenv('SELF_CHECK_URL') ?: $defaultSelfCheckUrl;

$CONFIG = [
    'log_type' => 'errorlog',
    'loglevel' => (int) (getenv('LOGLEVEL') !== false ? getenv('LOGLEVEL') : 2),
    'logdateformat' => 'c',
    'debug' => getenv('DEBUG') === '1',
    'overwriteprotocol' => $protocol,
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
if ($host !== '') {
    $hostNoPort = preg_replace('/:\\d+$/', '', $host);
    $CONFIG['trusted_domains'] = array_values(array_unique([
        $host,
        $hostNoPort,
        'localhost',
        'nextcloud-nginx',
        'nextcloud-nextcloud-nginx-1',
    ]));

    $CONFIG['overwritehost'] = $host;
    $CONFIG['overwrite.cli.url'] = addWebrootToUrl($selfCheckUrl, $webroot);
}

if ($selfCheckUrl !== '') {
    $selfCheckHost = parse_url($selfCheckUrl, PHP_URL_HOST);
    $selfCheckPort = parse_url($selfCheckUrl, PHP_URL_PORT);
    if ($selfCheckHost) {
        $selfCheckDomain = $selfCheckPort ? $selfCheckHost . ':' . $selfCheckPort : $selfCheckHost;
        $CONFIG['trusted_domains'] = array_values(array_unique(array_merge($CONFIG['trusted_domains'] ?? [], [
            $selfCheckHost,
            $selfCheckDomain,
        ])));
    }
    $CONFIG['overwrite.cli.url'] = addWebrootToUrl($selfCheckUrl, $webroot);
}

$CONFIG['mail_from_address'] = getenv('MAIL_FROM_ADDRESS') ?: 'nextcloud';
$CONFIG['mail_domain'] = getenv('MAIL_DOMAIN') ?: ($hostNoPort ?: 'localhost');

if ($webroot !== '') {
    $CONFIG['overwritewebroot'] = $webroot;
}

// Collabora fetches richdocuments settings/assets server-to-server.
// When users access Nextcloud via localhost, absolute URLs in this response
// must switch to the internal nginx service that Collabora can actually reach.
$userAgent = $_SERVER['HTTP_USER_AGENT'] ?? '';
if (strpos($userAgent, 'COOLWSD HTTP Agent') !== false) {
    $CONFIG['overwritehost'] = 'nextcloud-nginx:8080';
    $CONFIG['overwriteprotocol'] = 'http';
}
