# Changelog

- 2026-07-23 **1.1.0**
    - Office (Collabora) app installation is reliable on slow
      connections: the app-store fetch timeout is configurable
      (`APPSTORE_TIMEOUT`, default 600 s — the ~12 MB store index used
      to abort at the 120 s default), a previously failed fetch no
      longer blocks the retry, and install/enable failures now log
      their real error output.
    - The shipped images are pinned headless by a new image-contract
      test (`npm test` runs it before the end-to-end suite).
    - The end-to-end suite no longer dies silently on a start-up race:
      it waits for the office WOPI configuration to appear (app enabled
      does not yet mean configured) and dumps the bootstrap log when it
      never does.
