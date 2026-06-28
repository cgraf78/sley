# Sley Workflow Contract

## Purpose

Sley is the workflow orchestration layer for humans, agents, editors, Git hooks,
and Sapling hooks. It decides which repo context and changed-file scope apply,
then invokes the appropriate public tool surfaces.

This contract keeps orchestration separate from language policy. Checkrun owns
low-level formatter, linter, filetype, schema, diagnostic, and fast-check
semantics. Sley owns when those semantics run and how they compose with
repository readiness workflows.

## Ownership Model

Sley owns:

- repo detection across Git, Sapling, and supported bare-repo fallbacks
- changed-file, commit-input, path, and repo-wide scope selection
- human, editor, agent, Git-hook, and Sapling-hook command timing
- `sley fix`, `sley check`, `sley hook`, and `sley ready` orchestration
- `sley verify` command discovery from manifests, the built-in Checkrun verify
  bridge, verify registries, and extensions
- verify-registry schema, command metadata, receipts, and readiness aggregation

Checkrun owns:

- normalized filetype inference and editor language-ID aliases
- formatter, linter, schema, spelling, and analyzer tool policy
- the fast automatic check path behind `checkrun lint`, `checkrun check`, and
  `autolint`
- explicit generic project analyzers behind `checkrun verify`
- diagnostic, capability, plan, explanation, and schema-policy JSON contracts

Editor adapters own protocol translation only. They may adapt Sley's hook APIs
and Checkrun's JSON contracts into editor-native formatters, linters,
diagnostics, commands, or settings. They should not choose supported filetypes,
copy language aliases, or rediscover low-level tools.

Dotfiles and project repos own local policy contents: fallback configs,
project-local tool configs, ignore files, schema association instances, and
repo-specific verify registry entries.

## Check, Fix, Verify, And Ready

`sley fix` selects the active file scope and delegates mutating formatting to
the configured formatting backend, which is Checkrun by default.

`sley check` selects the active file scope and delegates fast read-only
validation to the configured lint backend, which is Checkrun by default. The
default path maps to Checkrun's fast automatic lint surface; it is not a second
place to define language-specific tools.

`sley verify` discovers explicit workflow commands. These commands may be test
suites, build commands, project health checks, repo-specific analyzers, or the
built-in `checkrun verify -- <changed-files>` bridge. Verification is allowed
to be broader or slower than `sley check` because callers choose it as an
explicit readiness phase.

`sley ready` composes the selected phases. It may include fix, check, secrets,
and verify according to caller flags and hook policy, but it should continue to
call public Sley and Checkrun surfaces rather than duplicating their internals.

## Low-Level Tool Invocation

Sley should not directly invoke language tools such as `ruff`, `mypy`,
`actionlint`, `zizmor`, `shellcheck`, `cargo-audit`, or `govulncheck` as a way
to infer generic language policy. Those tools belong behind Checkrun when the
behavior is generally useful across repos, or behind a repo-specific verify
command when the workflow is intentionally local.

Direct invocation is appropriate only when the command itself is the
repo-owned workflow being verified, such as a project's `make lint`, `pytest`,
or an explicit verify registry command. That exception keeps Sley useful for
project workflows without making it a second low-level linter registry.

The generic exception is Checkrun itself. Sley may automatically call
`checkrun verify` with the selected changed files because Checkrun owns the
lower-level analyzer decision from there.

## Hook And Editor Contract

Hook and editor integrations should call Sley's public hook APIs when they need
Sley to choose repo scope, caller policy, or extension behavior:

- `sley hook format-file FILE`
- `sley hook lint-file [--json] FILE`
- `sley ready --fix --commit`

Those APIs may delegate to Checkrun, and Checkrun remains the producer of
language-specific formatter/linter decisions and JSON diagnostics. This keeps
VS Code, Neovim, shell hooks, human commands, and agent hooks aligned while
still letting Sley handle when the checks run.

## Change Checklist

When changing workflow behavior:

1. Put filetype, language-alias, formatter, linter, schema, diagnostic, and
   fast-check policy in Checkrun.
2. Put repo scope, hook timing, readiness phase composition, and workflow
   command discovery in Sley.
3. Use generic `checkrun verify` or repo-owned commands for explicit
   verification instead of teaching Sley low-level analyzer details.
4. Keep editor adapters thin: translate public APIs into editor protocols, but
   do not store copied language or tool policy.
5. Add consistency tests when a behavior must be identical for humans, agents,
   editors, and hooks.
