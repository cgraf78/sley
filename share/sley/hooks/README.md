# Sley Commit Hooks

Sley owns the generic Git and Sapling launchers that decide when commit
readiness must run. Consumers own hook activation: they may point their VCS
configuration at the Git hook directory, link its complete hook set into a
composite directory, or invoke individual files from a thin host-policy
wrapper. The Git launchers intentionally resolve their default gate as a
sibling file, so an activation that moves only one launcher should set the
override documented below.

## Git

`git/` provides `pre-commit`, `pre-merge-commit`, `pre-applypatch`, and
`prepare-commit-msg` entry points. The first three always delegate to
`sley-commit-gate`; `prepare-commit-msg` delegates only for sequencer commits
that bypass the ordinary pre-commit hooks.

Set `SLEY_GIT_COMMIT_GATE` to an executable path when a consumer needs to wrap
the final gate with host policy. This is intentionally a gate override, not a
general shell-command string: the hook executes the path directly and never
evaluates it as shell syntax. Dotfiles uses the override to scope its special
bare-`$HOME` repository without forking Sley's generic behavior.

## Sapling

`sapling/sley-commit-gate` accepts native hook arguments or Sapling's
shell-encoded `HG_ARGS`. It skips metadata-only and explicitly non-committing
operations, then runs `sley ready --fix --commit` for commands that may create
or rewrite commits.

Both VCS integrations fail closed when `sley` is unavailable. A missing
readiness tool must be visible rather than silently turning a configured commit
gate into a no-op.
