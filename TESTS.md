# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs the branch contract, builds the image and runs the image contract; no test is skipped.

## Branch contract

`tests/branch-rules.py`, run by `npm run test:branches`, applies the `branch-tags` rules of `.github/workflows/docker.yml` the way the shared workflow does; the weekly run of `master` starts the workflow on every branch a rule matches.

- **F2** `30` to `35`, `new` and `new-33` to `new-35` are built with their suffix; `13` to `29` and `new-30` to `new-32` match no rule and stay frozen.

## Image contract

`tests/image-contract.sh`, run by `npm run test:contract` against the built image.

- **F1** the PHP modules gd, mysqli, pdo_mysql, curl, mbstring, intl, xml and zip are loaded, `/usr/sbin/apache2` runs, `/start.sh` is executable.
- **F2** the image carries the Nextcloud major version the branch names in `ENV SOURCE_FILE`.
- **F3** `MAX_REQUEST_WORKERS` defaults to 100, `mpm_prefork.conf` takes `MaxRequestWorkers` and `ServerLimit` from it, Apache accepts the configuration with `MAX_REQUEST_WORKERS=37`, and `/start.sh` never changes `max_connections`.

## Workflow contract

- **F4** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the image this repository publishes and the tags of its branch; this repository calls it from `.github/workflows/docker.yml`.
