<?php
declare(strict_types=1);

// Started by office-bootstrap.php: registers the signaling server of the Talk
// high-performance backend, as `occ talk:signaling:add` does, but without the
// shared secret on a command line, where every process of the container sees
// it. The secret comes from the Docker secret nextcloud_signaling_secret; the
// address from TALK_SIGNALING_URL, or <public URL>/standalone-signaling.

require_once '/app/lib/base.php';

use OCP\IAppConfig;
use OCP\Server;

$secretFile = '/run/secrets/nextcloud_signaling_secret';
$secret = is_readable($secretFile) ? trim((string) file_get_contents($secretFile)) : '';
$url = (string) ($argv[1] ?? '');
if ($secret === '' || $url === '') {
    fwrite(STDERR, "nextcloud-talk: no secret nextcloud_signaling_secret or no address, the signaling server stays as it is\n");
    exit(1);
}

$appConfig = Server::get(IAppConfig::class);
$wanted = ['servers' => [['server' => $url, 'verify' => true]], 'secret' => $secret];
$saved = json_decode($appConfig->getValueString('spreed', 'signaling_servers', ''), true);
if ($saved === $wanted) {
    fwrite(STDERR, "nextcloud-talk: signaling server {$url} is registered\n");
    exit(0);
}
$appConfig->setValueString('spreed', 'signaling_servers', json_encode($wanted));
fwrite(STDERR, "nextcloud-talk: signaling server {$url} registered\n");
