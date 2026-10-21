<?php
declare(strict_types=1);

// Minimal FastCGI client: sends one GET request for a PHP file to the local
// php-fpm, the way nginx does, and returns the response body. The image has no
// shell and no HTTP client, so the health check (health.php) speaks FastCGI
// through this function.

// php-fpm listens on port 9000 of the container (www.conf of mwaeckerlin/php-fpm)
const FASTCGI_ADDRESS = '127.0.0.1:9000';

function fastcgiGet(string $scriptFilename, string $scriptName): string
{
    $record = static fn(int $type, string $content): string =>
        pack('CCnnCC', 1, $type, 1, strlen($content), 0, 0) . $content;
    $length = static fn(string $s): string => strlen($s) < 128
        ? chr(strlen($s))
        : pack('N', strlen($s) | 0x80000000);

    $socket = @stream_socket_client('tcp://' . FASTCGI_ADDRESS, $errno, $error, 5);
    if ($socket === false) {
        throw new RuntimeException('php-fpm does not accept connections on ' . FASTCGI_ADDRESS . ": {$error}");
    }
    stream_set_timeout($socket, 8);

    $params = [
        'GATEWAY_INTERFACE' => 'FastCGI/1.0',
        'REQUEST_METHOD' => 'GET',
        'SCRIPT_FILENAME' => $scriptFilename,
        'SCRIPT_NAME' => $scriptName,
        'REQUEST_URI' => $scriptName,
        'DOCUMENT_ROOT' => dirname($scriptFilename),
        'QUERY_STRING' => '',
        'SERVER_PROTOCOL' => 'HTTP/1.1',
        'SERVER_NAME' => 'localhost',
        'SERVER_PORT' => '80',
        'REMOTE_ADDR' => '127.0.0.1',
        'HTTP_HOST' => 'localhost',
        'CONTENT_LENGTH' => '0',
    ];
    $encoded = '';
    foreach ($params as $name => $value) {
        $encoded .= $length($name) . $length($value) . $name . $value;
    }

    // BEGIN_REQUEST (role responder), PARAMS, empty PARAMS, empty STDIN
    fwrite($socket, $record(1, pack('nCxxxxx', 1, 0)) . $record(4, $encoded) . $record(4, '') . $record(5, ''));

    $read = static function (int $bytes) use ($socket): string {
        $data = '';
        while (strlen($data) < $bytes) {
            $chunk = fread($socket, $bytes - strlen($data));
            if ($chunk === false || $chunk === '') {
                throw new RuntimeException('php-fpm closed the connection before the answer was complete');
            }
            $data .= $chunk;
        }
        return $data;
    };

    $output = '';
    while (true) {
        $header = unpack('Cversion/Ctype/nid/nlength/Cpadding/Creserved', $read(8));
        $content = $header['length'] > 0 ? $read($header['length']) : '';
        if ($header['padding'] > 0) {
            $read($header['padding']);
        }
        if ($header['type'] === 6) {
            $output .= $content;
        } elseif ($header['type'] === 3) {
            break;
        }
    }
    fclose($socket);

    $parts = preg_split("/\r?\n\r?\n/", $output, 2);
    return $parts[1] ?? '';
}
