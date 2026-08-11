# Test Harness

`test/sley-test` is the local and CI entrypoint. Shared fixture helpers live in
`test/helpers.sh`, and focused behavior suites live under `test/suites/`.

Use fake commands and temporary repositories for verification tests so the suite
does not depend on globally installed tools or the caller's workspace state.
When touching Neovim integration, update `test/suites/nvim-test`.

`test/suites/install-test` covers direct and curl-bootstrapped checkout-backed
command and manpage links, the PATH-selected Bash runtime guard, idempotent
retargeting, custom destinations, complete source preflight, and refusal to
overwrite user-owned paths.

When touching the deployable VS Code integration, update
`test/suites/vscode-test`. That suite validates both the versioned package
contract consumed through shdeps and the extension's formatting, diagnostics,
capability refresh, concurrency, cancellation, and exclusion behavior.

`test/suites/commit-hooks-test` owns the generic Git and Sapling launcher
behavior shipped under `share/sley/hooks/`. Consumer repositories should keep
only activation and genuinely local policy tests instead of duplicating this
suite.

`test/suites/message-validation-test` owns the SCM-neutral template and
executable-provider contracts, including private stdin staging and cleanup.
Consumer tests should characterize their own policy executable separately and
use cross-repository tests only to prove that activation selects it correctly.

The real Sley-to-Checkrun cancellation boundary is an explicit cross-repository
test. Point it at a Checkrun checkout without making ordinary Sley CI depend on
that checkout:

```bash
SLEY_TEST_CHECKRUN_ROOT=/absolute/path/to/checkrun \
  test/suites/checkrun-cancellation-integration-test
```
