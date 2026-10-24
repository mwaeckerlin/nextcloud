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

$protocol = getenv('PROTOCOL') ?: 'https';
$host = resolvePublicHost();
$defaultSelfCheckUrl = $protocol . '://' . $host;
$selfCheckUrl = getenv('SELF_CHECK_URL') ?: $defaultSelfCheckUrl;

// What config.php holds: what an administrator saved under Administration
// settings, or what the legacy image left there. Nextcloud reads this file
// after config.php, so a value set here would hide it.
$saved = (static function (): array {
    $CONFIG = [];
    if (is_file(__DIR__ . '/config.php')) {
        include __DIR__ . '/config.php';
    }
    return $CONFIG;
})();

$CONFIG = [
    // under the legacy image the log file in the data volume grew without
    // limit, with a debug level saved in config.php: the file stays for the
    // app logreader, log-follow.php passes it on to the container log and
    // empties it at LOG_MAX_SIZE, so Nextcloud's own rotation is off
    'log_type' => 'file',
    'logfile' => '/app/data/nextcloud.log',
    'log_rotate_size' => 0,
    'logdateformat' => 'c',
    'debug' => getenv('DEBUG') === '1',
    'overwriteprotocol' => $protocol,
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

// Defaults an administrator may change: the mail server is the smtp-relay of
// the compose stack. A saved value stays; the variables below and the NC_<key>
// variables, which Nextcloud reads itself, take precedence over both.
$defaults = [
    'maintenance_window_start' => 1,
    'default_phone_region' => 'CH',
    'mail_smtpmode' => 'smtp',
    'mail_sendmailmode' => 'smtp',
    'mail_smtphost' => 'smtp-relay',
    'mail_smtpport' => '25',
    'loglevel' => 2,
];
foreach ($defaults as $key => $default) {
    if (!array_key_exists($key, $saved)) {
        $CONFIG[$key] = $default;
    }
}
if (getenv('LOGLEVEL') !== false && getenv('LOGLEVEL') !== '') {
    $CONFIG['loglevel'] = (int) getenv('LOGLEVEL');
}

// Mail server of a provider or an own MTA: a variable that is set takes
// precedence over the saved value and the default smtp-relay:25. A user name
// switches authentication on; the password comes from a Docker secret.
$mailVariables = [
    'MAIL_SMTPHOST' => 'mail_smtphost',
    'MAIL_SMTPPORT' => 'mail_smtpport',
    'MAIL_SMTPSECURE' => 'mail_smtpsecure',
    'MAIL_SMTPNAME' => 'mail_smtpname',
];
foreach ($mailVariables as $variable => $key) {
    $value = getenv($variable);
    if (is_string($value) && $value !== '') {
        $CONFIG[$key] = $value;
    }
}
if (isset($CONFIG['mail_smtpname'])) {
    $CONFIG['mail_smtpauth'] = true;
}
$smtpPassword = is_readable('/run/secrets/nextcloud_smtp_password')
    ? trim((string) file_get_contents('/run/secrets/nextcloud_smtp_password'))
    : (string) getenv('MAIL_SMTPPASSWORD');
if ($smtpPassword !== '') {
    $CONFIG['mail_smtppassword'] = $smtpPassword;
}

// Behind a reverse proxy Nextcloud reads the client address from
// X-Forwarded-For only when the request comes from a trusted proxy. Docker
// creates its networks in the private ranges, so these are the default; a
// container in them could claim another client address, and so could a client
// that reaches nginx directly through the routing mesh of a swarm or
// docker-proxy, which hand it a private address (README, TRUSTED_PROXIES).
// TRUSTED_PROXIES takes precedence over a saved list, the default fills in
// where nothing is saved.
$trustedProxies = getenv('TRUSTED_PROXIES');
if (is_string($trustedProxies) && trim($trustedProxies) !== '') {
    $CONFIG['trusted_proxies'] = preg_split('/[\s,]+/', trim($trustedProxies));
} elseif (!array_key_exists('trusted_proxies', $saved)) {
    $CONFIG['trusted_proxies'] = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];
}
if (!array_key_exists('forwarded_for_headers', $saved)) {
    $CONFIG['forwarded_for_headers'] = ['HTTP_X_FORWARDED_FOR'];
}

// Nextcloud names the server in the IDs it generates, 0 to 511, so every
// php-fpm that serves the same database needs its own; without SERVER_ID each
// container derives one from its host name, which differs per swarm replica.
$serverId = getenv('SERVER_ID');
$CONFIG['serverid'] = is_string($serverId) && $serverId !== ''
    ? (int) $serverId
    : crc32((string) gethostname()) % 512;

// Redis locks files and holds the cache all php-fpm containers share, where
// REDIS_HOST names a server; without it Nextcloud locks files in the database,
// which the admin overview reports. The password comes from a Docker secret.
$redisHost = (string) getenv('REDIS_HOST');
if ($redisHost !== '' && class_exists('Redis')) {
    $CONFIG['memcache.distributed'] = '\\OC\\Memcache\\Redis';
    $CONFIG['memcache.locking'] = '\\OC\\Memcache\\Redis';
    $CONFIG['redis'] = ['host' => $redisHost, 'port' => (int) (getenv('REDIS_PORT') ?: 6379)];
    $redisPassword = is_readable('/run/secrets/nextcloud_redis_password')
        ? trim((string) file_get_contents('/run/secrets/nextcloud_redis_password'))
        : (string) getenv('REDIS_PASSWORD');
    if ($redisPassword !== '') {
        $CONFIG['redis']['password'] = $redisPassword;
    }
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
        // the setup checks of the admin overview reach nginx under this name
        // where the public URL is not reachable from inside the container
        'nextcloud-nginx:8080',
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
