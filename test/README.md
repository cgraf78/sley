# Test Harness

`test/sley-test` is the local and CI entrypoint. Shared fixture helpers live in
`test/helpers.sh`, and focused behavior suites live under `test/suites/`.

Use fake commands and temporary repositories for verification tests so the suite
does not depend on globally installed tools or the caller's workspace state.
When touching Neovim integration, update `test/suites/nvim-test`.
