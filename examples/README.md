# Sley examples

These files demonstrate the inputs a Sley consumer may reasonably own. They
do not copy Sley's runtime launchers: generic Git and Sapling hooks already
ship under [`share/sley/hooks/`](../share/sley/hooks/), and activating those
files directly keeps behavior on the installed Sley version.

| Example | Use | Typical consumer location |
| --- | --- | --- |
| `commit-message-template.txt` | Declare required commit-message sections | Any managed config path named by `SLEY_COMMIT_MESSAGE_TEMPLATE` |
| `verify.json` | Map selected paths to project workflow commands | `.sley/verify.json` or `$XDG_CONFIG_HOME/sley/verify.json` |
| `extensions.d/80-verify-command.sh` | Select a workflow command dynamically when a static registry is insufficient | `$XDG_CONFIG_HOME/sley/extensions.d/` |
| `hooks/custom-sley-commit-gate` | Add consumer policy around Sley's Git readiness gate | Any executable path named by `SLEY_GIT_COMMIT_GATE` |

## Commit-message template

`commit-message-template.txt` is both a Git-compatible editor template and a
Sley structural-validation template. The `##` headings declare required,
nonempty sections. Single-`#` lines are guidance: Git strips them by default,
and Sley never counts them as section content.

Copy the file to a consumer-managed location, then point both Git and Sley at
that same file if you want editor guidance and commit-time enforcement:

```bash
git config commit.template /path/to/commit-message-template.txt
export SLEY_COMMIT_MESSAGE_TEMPLATE=/path/to/commit-message-template.txt
```

Sley does not auto-discover this file because choosing a commit-message format
is consumer policy. For rules that cannot be represented as required sections,
set `SLEY_COMMIT_MESSAGE_VALIDATOR` to your own executable; Sley passes it
exactly one opaque message-file path and preserves its exit status. A validator
implementation is intentionally not included here because any useful advanced
rule—title lengths, issue keys, trailers, or organization conventions—is policy
that Sley should not prescribe.

## Verify registry

`verify.json` shows the declarative path for a project command. Its example is
suggested rather than required, so copying the file cannot make `sley ready`
run a placeholder command automatically. Replace the paths and command first,
then set `required` according to the repository's policy. The installed schema
is exposed as `SLEY_VERIFY_SCHEMA` for editors and validation tooling.

Prefer a repository-owned `.sley/verify.json` when the command belongs to that
repository. Use the XDG user registry only for reusable local policy that
should apply across repositories.

## Dynamic extension

`extensions.d/80-verify-command.sh` demonstrates the advanced case where the
selected command depends on runtime file selection. It emits a suggested JSON
item only when a matching file is selected. Static mappings are easier to read
and should stay in `verify.json`; use an extension only when code is genuinely
needed.

## Git hook policy wrapper

Sley's provider-owned hooks live in `share/sley/hooks/git/`. A consumer can
activate that directory as its complete Git hook set or link the files into a
composite hook directory. Do not copy their implementations into this examples
directory, because copies would drift from Sley's sequencer and failure policy.

`hooks/custom-sley-commit-gate` shows the narrow exception: a consumer-owned
wrapper selected with `SLEY_GIT_COMMIT_GATE`. The example skips untracked-file
discovery for very large worktrees, then returns to Sley's public readiness
command. Replace or remove that environment choice to match local policy.
