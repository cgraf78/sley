# VS Code integration

This directory contains Sley's deployable VS Code extension. Sley owns the
adapter because it translates VS Code formatting and diagnostic events into
Sley's public `hook format-file` and `hook lint-file --json` contracts. A
dotfiles repository may decide where to activate the extension, but it should
not carry another copy of this implementation or its behavioral tests.

The published consumer path is:

```text
share/sley/vscode/sley-tools-<version>/
```

Each versioned directory is a complete unpacked VS Code extension whose name
must match `<package.name>-<package.version>`. Keeping the version in both the
manifest and directory name is intentional: VS Code records local extensions
by that directory name, while shdeps consumers can resolve the payload from a
stable repository-relative path without an npm build or registry download.

Consumers should register or symlink the directory as an immutable payload.
They retain ownership of editor selection, local settings, opt-out policy, and
deployment timing. When the extension version changes, add the new versioned
directory here, update consumer declarations deliberately, and remove an older
payload only after those consumers have migrated.

The extension asks Checkrun for its current filetype and editor-language
capabilities rather than duplicating that policy. It then invokes the
PATH-visible `sley` and `checkrun` commands, which keeps local command
resolution and environment policy outside this reusable asset.

`test/suites/vscode-test` owns the package contract and detailed runtime
behavior. Consumer repositories should keep only installation and
cross-component compatibility smoke tests.
