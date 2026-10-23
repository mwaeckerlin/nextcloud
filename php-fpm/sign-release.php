<?php
declare(strict_types=1);

// Build step of the php-fpm image: signs the Nextcloud release again after the
// build removed the source maps and emptied the browser files, so the
// integrity check of Nextcloud stays active and passes.
//
// Nextcloud trusts every certificate in resources/codesigning/root.crt
// (Checker.php and Installer.php load each one as a CA), and a certificate
// named "core" may sign core and every app. The step creates a CA of its own,
// appends it to root.crt beside the Nextcloud CA, issues a "core" certificate
// and signs core and every shipped app with occ. The private keys exist only
// in this build stage; nobody can sign with them afterwards.
//
// Usage: php sign-release.php <nextcloud root>

function fail(string $reason): never
{
    fwrite(STDERR, "sign-release: {$reason}\n");
    exit(1);
}

function occ(string $root, array $args): void
{
    $command = array_merge([PHP_BINARY, $root . '/occ', '--no-interaction', '--no-warnings'], $args);
    $proc = proc_open($command, [0 => ['pipe', 'r'], 1 => STDOUT, 2 => STDERR], $pipes, $root);
    if (!is_resource($proc)) {
        fail('cannot start ' . implode(' ', $command));
    }
    fclose($pipes[0]);
    $code = proc_close($proc);
    if ($code !== 0) {
        fail(implode(' ', $args) . " returned {$code}");
    }
}

$root = rtrim($argv[1] ?? '', '/');
if (!is_file($root . '/occ')) {
    fail("no Nextcloud in '{$root}'");
}
$work = sys_get_temp_dir() . '/codesigning';
if (!is_dir($work) && !mkdir($work, 0700, true)) {
    fail("cannot create {$work}");
}

$options = ['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 4096, 'digest_alg' => 'sha512'];
// Nextcloud checks neither the validity period nor an expiry of the
// certificates; a long one keeps old images verifiable all the same.
$days = 36500;

$caKey = openssl_pkey_new($options) ?: fail('cannot create the CA key: ' . openssl_error_string());
$caRequest = openssl_csr_new(['commonName' => 'mwaeckerlin/nextcloud image build'], $caKey, $options)
    ?: fail('cannot create the CA request: ' . openssl_error_string());
$caCert = openssl_csr_sign($caRequest, null, $caKey, $days, $options + ['x509_extensions' => 'v3_ca'], 1)
    ?: fail('cannot create the CA certificate: ' . openssl_error_string());

$coreKey = openssl_pkey_new($options) ?: fail('cannot create the core key: ' . openssl_error_string());
$coreRequest = openssl_csr_new(['commonName' => 'core'], $coreKey, $options)
    ?: fail('cannot create the core request: ' . openssl_error_string());
$coreCert = openssl_csr_sign($coreRequest, $caCert, $caKey, $days, $options, 2)
    ?: fail('cannot create the core certificate: ' . openssl_error_string());

openssl_pkey_export_to_file($coreKey, $work . '/core.key') || fail('cannot write the core key');
openssl_x509_export_to_file($coreCert, $work . '/core.crt') || fail('cannot write the core certificate');
openssl_x509_export($caCert, $caPem) || fail('cannot export the CA certificate');

// root.crt is part of core, so the CA goes in before core is signed
$rootCrt = $root . '/resources/codesigning/root.crt';
$nextcloudCa = file_get_contents($rootCrt) ?: fail("cannot read {$rootCrt}");
file_put_contents($rootCrt, rtrim($nextcloudCa) . "\n" . $caPem) || fail("cannot write {$rootCrt}");

// occ runs only for the owner of config/config.php; the config folder is not
// part of any signature. The log goes to stderr: the default file logger of
// occ creates data/nextcloud.log, which every new data volume would inherit.
$config = $root . '/config/config.php';
$hadConfig = is_file($config);
if (!$hadConfig) {
    file_put_contents($config, "<?php\n\$CONFIG = ['log_type' => 'errorlog'];\n") || fail("cannot write {$config}");
}

$key = '--privateKey=' . $work . '/core.key';
$certificate = '--certificate=' . $work . '/core.crt';
occ($root, ['integrity:sign-core', $key, $certificate, '--path=' . $root]);
foreach (glob($root . '/apps/*/appinfo/signature.json') as $signature) {
    occ($root, ['integrity:sign-app', $key, $certificate, '--path=' . dirname($signature, 2)]);
}

if (!$hadConfig) {
    unlink($config);
}
unlink($work . '/core.key');
unlink($work . '/core.crt');
rmdir($work);
