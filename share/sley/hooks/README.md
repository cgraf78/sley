# Sley Commit Hooks

Sley owns the generic Git and Sapling launchers that decide when commit
readiness must run. Consumers own hook activation: they may point their VCS
configuration at the Git hook directory, link its complete hook set into a
composite directory, or invoke individual files from a thin host-policy
wrapper. The Git launchers intentionally resolve their default gate as a
sibling file, so an activation that moves only one launcher should set the
override documented below.

## Git

`git/` provides `pre-commit`, `pre-merge-commit`, `pre-applypatch`,
`prepare-commit-msg`, and `commit-msg` entry points. The first three always
delegate to `sley-commit-gate`; `prepare-commit-msg` delegates only for
sequencer commits that bypass the ordinary pre-commit hooks. `commit-msg`
passes the finalized message through Sley's optional structural validator and
then through `sley secrets --message-file`, preserving either blocking result.

Set `SLEY_GIT_COMMIT_GATE` to an executable path when a consumer needs to wrap
the final gate with host policy. This is intentionally a gate override, not a
general shell-command string: the hook executes the path directly and never
evaluates it as shell syntax. Dotfiles uses the override to scope its special
bare-`$HOME` repository without forking Sley's generic behavior.

[`examples/hooks/custom-sley-commit-gate`](../../../examples/hooks/custom-sley-commit-gate)
is a deliberately small consumer-owned wrapper example. Keep the generic hook
launchers here and put only genuinely local scope or performance policy in a
wrapper.

### Commit-message providers

The `commit-msg` launcher accepts one optional consumer-owned provider:

- `SLEY_COMMIT_MESSAGE_TEMPLATE` names a readable Git-compatible plaintext
  template. Markdown headings from `##` through `######`, and labels ending in
  `:`, declare required nonempty sections. Section matching is
  case-insensitive, additional sections are allowed, and exactly one leading
  `#` marks editor guidance rather than content. This intentionally small
  format does not encode title lengths, regular expressions, conditionals, or
  organization policy.
- `SLEY_COMMIT_MESSAGE_VALIDATOR` names an executable for advanced validation.
  Sley invokes it directly with exactly one commit-message file path, passes
  stdout and stderr through, and preserves its exit status. The value is an
  executable path, not a shell command string.

[`examples/commit-message-template.txt`](../../../examples/commit-message-template.txt)
is a ready-to-copy structural template. It includes editor guidance as `#`
comments so the guidance cannot accidentally satisfy a required section.

With neither provider, structural validation is a quiet no-op and the secret
scan still runs. Configuring both providers is an error. The same provider
contract is available without the Git launcher through:

```bash
sley hook validate-message --template /path/to/template --message-file /path/to/message
sley hook validate-message --validator /path/to/executable --message-file /path/to/message
printf '%s\n' "$message" | sley hook validate-message --validator /path/to/executable
```

When stdin is used, Sley stages it in a private temporary directory, removes
the staging file before returning, and leaves the caller's umask and traps
unchanged. This makes the operation usable by Sapling and future SCM adapters
without making Sley's core Git-specific.

## Sapling

`sapling/sley-commit-gate` accepts native hook arguments or Sapling's
shell-encoded `HG_ARGS`. It skips metadata-only and explicitly non-committing
operations, then runs `sley ready --fix --commit` for commands that may create
or rewrite commits.

Both VCS integrations fail closed when `sley` is unavailable. A missing
readiness tool must be visible rather than silently turning a configured commit
gate into a no-op.
