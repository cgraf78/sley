# sley

![Tests](https://github.com/cgraf78/sley/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D4.0-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey.svg)](#)

`sley` owns the repo workflow API used by humans, editors, agent hooks, Git
hooks, and Sapling hooks. The generic CLI entry point is `bin/sley`; the shared
API is `sley.sh`.

`shdeps` installs `bin/sley` as the PATH-visible `~/.local/bin/sley` symlink.
The entry point is self-contained and resolves its dependency libraries through
that symlink.

## Commands

```text
sley status       # repo type, root, ref, and dirty counts
sley changes      # changed-file listing
sley fix          # mutating format phase
sley check        # read-only lint/validation phase
sley secrets      # redacted secret scan where supported
sley verify       # local verification command discovery and execution
sley ready        # aggregate pre-submit readiness report
```

`sley verify` reports where each suggested command came from. Human output labels
sources such as `ancestor: sub/package.json` and `repo-root: package.json`;
`sley verify --json` includes the same data in `source_contexts`.

Registry rules and individual command objects may set `"enabled": false` to
temporarily suppress entries without deleting their configuration.

The default scope follows the active change context, not the current working
directory. Use `--path .`, `--path PATH`, `--repo-wide`, and
`--include-untracked` to override that scope.

No default `sley` command formats or checks the whole repository. In large
repos, the active diff is the useful project signal even when commands are run
from the repo root.

`sley fix --commit` formats commit-input files: staged files in Git and pending
files in Sapling. In Git, it formats worktree files but does not update the
index. If formatting changes a staged file, it reports the file and tells the
caller to run `git add`. If a selected file has both staged and unstaged
changes, it refuses the whole operation to preserve partial-staging intent.

## Dependencies

- Bash for the CLI entry point and sourceable API.
- `git` or `sl` depending on the repository type being inspected.
- `python3` for required-check receipt caching and command grouping.
- `jq` for JSON output, verify registries, and ready JSON summaries. A few
  manifest hints have limited fallback parsing without `jq`, but verify
  registry files require it.
- `cgraf78/checkrun` is the default formatting and linting backend. Base Sley
  invokes the PATH-visible `autoformat` and `autolint` CLIs for `sley fix`,
  `sley check`, and `sley hook` commands unless an extension overrides the hook
  policy.
- `gitleaks` is required for `sley secrets`.

Optional verification commands such as `pytest`, `cargo`, `go`, `make`, `just`,
`buck2`, `actionlint`, and `zizmor` are discovered from project manifests or
verify registries and are only required when a selected rule asks Sley to run
them.

Consumers that want Sley to operate on a bare Git worktree can set the standard
`GIT_DIR` and `GIT_WORK_TREE` environment variables before invoking it. Set
`SLEY_SKIP_UNTRACKED=1` when the worktree is large and untracked-file discovery
would be too expensive for status or readiness checks.

For shells and editor integrations that want the PATH-visible `sley` command to
fall back to a bare Git worktree when no normal repo owns the current directory,
Sley also exposes an optional fallback contract:

```bash
export SLEY_BARE_REPO_GIT_DIR="$HOME/.my-bare-git-dir"
export SLEY_BARE_REPO_WORK_TREE="$HOME" # optional; defaults to $HOME
```

The fallback is off unless `SLEY_BARE_REPO_GIT_DIR` is set. When the current
directory is inside `SLEY_BARE_REPO_WORK_TREE`, the launcher exports `GIT_DIR`,
`GIT_WORK_TREE`, and `SLEY_SKIP_UNTRACKED=1` before running the shared Sley API.
Editor probes that need to ask only "is this a normal repo?" can set
`SLEY_SKIP_BARE_REPO_FALLBACK=1` to ignore an inherited fallback.

## Public API

New integrations should source `sley.sh` through shdeps and call public
`sley_*` functions:

```bash
. "$(shdeps dep-file cgraf78/sley lib/sley/sley.sh)"
```

- `bin/sley` is the PATH-visible CLI.
- `lib/sley/sley.sh` is the sourceable Bash API.
- `share/sley/shell.sh` is the sourceable interactive shell loader.
- `share/sley/schemas/verify.schema.json` is the JSON Schema for
  `sley verify` registry files.
- `sley_select` resolves repo and scope context.
- `sley_hook_format_file` and `sley_hook_lint_file` are the narrow save-time
  hook APIs.
- `sley ready --fix --quiet --commit` is the commit-gate API used by agent
  hooks.
- `_sley_shell_complete` and `_sley_zsh_complete` are the Bash and zsh
  completion functions installed by the shell loader.
- `SLEY_VERIFY_SCHEMA` is exported by the shell loader as the absolute path to
  the verify-registry schema; `sley_verify_schema_path` prints the same value
  for consumers that prefer a function API.
- `SLEY_BARE_REPO_GIT_DIR`, `SLEY_BARE_REPO_WORK_TREE`, and
  `SLEY_SKIP_BARE_REPO_FALLBACK=1` are the optional bare-repo fallback API for
  PATH-visible CLI integrations.
- zsh completion registration defers until `compinit` is available, so shell
  startup files may source the loader before their zsh completion phase.
- Native VCS hooks delegate mechanical checks to
  `sley ready --fix --exclude verify --commit`.

`sley_select` sets `SLEY_REPO_TYPE`, `SLEY_REPO_ROOT`, `SLEY_CHANGE_SCOPE`,
`SLEY_INCLUDE_UNTRACKED`, `SLEY_REPO_WIDE`, `SLEY_PATH_SCOPE`, and
`SLEY_SELECTED_FILES`.

Hook integrations should call `sley_hook_*` functions and use `SLEY_CALLER` and
`SLEY_SCOPED` for extension context.

## Extension Policy

Environment-specific hook policy lives in ordered files under
`${XDG_CONFIG_HOME:-~/.config}/sley/extensions.d/*.sh`. These files may
override the documented `sley_hook_*` functions. Set `SLEY_EXTENSION_DIR` when
an integration needs to source extensions from a test fixture or another
managed config location.

Extensions may also provide `sley_ext_verify_commands <files>` to print additional
`sley verify` command items as JSON lines. Those items use the same shape as
verification registry commands, including `required`, `tier`, and optional
`cache` metadata, so `sley ready` can run environment-specific checks without
base sley knowing about those tools.

The former `repo-check` surface has been removed. New code should not introduce
`_repo_*` or `_REPO_CHECK_*` hook APIs.

## Implementation Layout

- `bin/sley` is the self-contained CLI entry point.
- `repo.sh` owns VCS primitives.
- `scope.sh` owns scope and file selection.
- `hooks.sh` owns hook APIs.
- `verify.sh` owns local verification discovery.
- `ready.sh` owns aggregate readiness orchestration.

Neovim exposes `:SleyStatus`, `:SleyCheck`, and `:SleyReady` for human-facing
repo workflows. Save-time formatting and diagnostics use the same hook APIs as
agent and VCS hooks.

## License

MIT. See [`LICENSE`](LICENSE).
