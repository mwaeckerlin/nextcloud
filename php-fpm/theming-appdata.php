<?php
declare(strict_types=1);

// Started by office-bootstrap.php before the first background job: the job
// MigrateBackgroundImages of the app theming reads appdata/theming/global with
// getFolder() and fails with NotFoundException on a fresh installation, where
// that folder does not exist yet; the admin overview then reports an error in
// the log. The folder is created here, empty, as theming creates it itself once
// an administrator changes the design.

require_once '/app/lib/base.php';

use OCP\Files\AppData\IAppDataFactory;
use OCP\Files\NotFoundException;
use OCP\Server;

$theming = Server::get(IAppDataFactory::class)->get('theming');
try {
    $theming->getFolder('global');
} catch (NotFoundException) {
    $theming->newFolder('global');
    fwrite(STDERR, "nextcloud-theming: appdata/theming/global created\n");
}
