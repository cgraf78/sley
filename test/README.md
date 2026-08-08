# Test Harness

`test/sley-test` is the local and CI entrypoint. Shared fixture helpers live in
`test/helpers.sh`, and focused behavior suites live under `test/suites/`.

Use fake commands and temporary repositories for verification tests so the suite
does not depend on globally installed tools or the caller's workspace state.
When touching Neovim integration, update `test/suites/nvim-test`.

When touching the deployable VS Code integration, update
`test/suites/vscode-test`. That suite validates both the versioned package
contract consumed through shdeps and the extension's formatting, diagnostics,
capability refresh, concurrency, cancellation, and exclusion behavior.

The real Sley-to-Checkrun cancellation boundary is an explicit cross-repository
test. Point it at a Checkrun checkout without making ordinary Sley CI depend on
that checkout:

```bash
SLEY_TEST_CHECKRUN_ROOT=/absolute/path/to/checkrun \
  test/suites/checkrun-cancellation-integration-test
```
