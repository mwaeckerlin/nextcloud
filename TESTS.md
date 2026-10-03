# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs the branch contract, the image contract and then the end-to-end suite; no test is skipped.

## End-to-end

`tests/e2e/run-compose-e2e.sh` builds and starts the whole compose stack, with Collabora and MariaDB, and tears it down afterwards.

- **F2** waits until `occ status` reports `installed: true`.
- **F3** waits until `richdocuments` is enabled and its WOPI URLs are set, checks `/hosting/discovery` and `/hosting/capabilities` of Collabora, uploads a document over WebDAV and opens it in the office editor.
- **F4** starts a stand-in backend `e2e-ws` on port 3001 and fetches `/ws/e2e/probe/answer.txt` through nginx.

## Image contract

`tests/image-contract.sh`, run by `npm run test:contract` against the built images.

- **F1** no sh, no bash, no busybox, no perl in either image.
- **F5** the `php-fpm` image carries the Nextcloud major version the branch names in `ARG SOURCE_FILE`.
- **F7** the `php-fpm` image limits its pool to `pm.max_children = 50` in `/etc/php<version>/php-fpm.d/www.conf`.

## Branch contract

`tests/branch-rules.py`, run by `npm run test:branches`, applies the `branch-tags` rules of `.github/workflows/docker.yml` the way the shared workflow does.

- **F5** `new`, `new-33` to `new-35` and `30` to `35` are built with their suffix; `new-30` to `new-32` and `13` to `29` match no rule and stay frozen.

## Workflow contract

- **F6** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the images a repository publishes and the tags of its branch; this repository calls it from `.github/workflows/docker.yml`.
