<?php
declare(strict_types=1);

// Started by office-bootstrap.php beside php-fpm: passes every line Nextcloud
// writes to /app/data/nextcloud.log on to the container log, and empties the
// file once it reaches LOG_MAX_SIZE (default 100M). The file stays readable for
// the app logreader under Administration settings › Logging, it never grows
// beyond the limit, and no rotated copy is left behind. Nextcloud opens the file
// in append mode for every entry, so emptying it loses no entry of the file; at
// most the lines of the last second before it are missing in the container log.

const LOG_FILE = '/app/data/nextcloud.log';

function bytes(string $size): int
{
    if (!preg_match('/^\s*(\d+)\s*([kmg]?)b?\s*$/i', $size, $match)) {
        fwrite(STDERR, "nextcloud-log: LOG_MAX_SIZE '{$size}' is no size such as 100M, using 100M\n");
        return 100 * 1024 * 1024;
    }
    $factor = ['' => 1, 'k' => 1024, 'm' => 1024 ** 2, 'g' => 1024 ** 3][strtolower($match[2])];
    return (int) $match[1] * $factor;
}

$maxSize = bytes(getenv('LOG_MAX_SIZE') ?: '100M');
clearstatcache();
$offset = is_file(LOG_FILE) ? (int) filesize(LOG_FILE) : 0;
while (true) {
    clearstatcache();
    $size = is_file(LOG_FILE) ? (int) filesize(LOG_FILE) : 0;
    if ($size < $offset) {
        // emptied or replaced by somebody else: read it from the start
        $offset = 0;
    }
    if ($size > $offset && ($handle = fopen(LOG_FILE, 'r+')) !== false) {
        fseek($handle, $offset);
        while (($chunk = fread($handle, 65536)) !== false && $chunk !== '') {
            fwrite(STDERR, $chunk);
            $offset += strlen($chunk);
        }
        if ($offset >= $maxSize) {
            ftruncate($handle, 0);
            $offset = 0;
        }
        fclose($handle);
    }
    sleep(1);
}
