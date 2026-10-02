# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` builds the image and runs the image contract; no test is skipped.

## Image contract

`tests/image-contract.sh`, run by `npm run test:contract` against the built image.

- **F1** the PHP modules gd, mysqli, pdo_mysql, curl, mbstring, intl, xml and zip are loaded, `/usr/sbin/apache2` runs, `/start.sh` is executable.
- **F2** the image carries the Nextcloud major version the branch names in `ENV SOURCE_FILE`.
- **F3** `MAX_REQUEST_WORKERS` defaults to 100, `mpm_prefork.conf` takes `MaxRequestWorkers` and `ServerLimit` from it, Apache accepts the configuration with `MAX_REQUEST_WORKERS=37`, and `/start.sh` never changes `max_connections`.

## Workflow contract

- **F4** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the image this repository publishes and the tags of its branch; this repository calls it from `.github/workflows/docker.yml`.
