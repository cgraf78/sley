# Sley Libraries

This directory owns reusable Sley behavior.

## Files

- `sley.sh` is the shared shell entrypoint loaded by the command.
- `repo.sh` resolves repository context.
- `scope.sh` owns file and change-scope selection.
- `ready.sh` evaluates whether a workspace is ready for handoff.
- `verify.sh` and `verify-cache.py` own verification planning and cache
  behavior.
- `hooks.sh` owns shell hook integration.
- `nvim.lua` provides the optional Neovim adapter.

Keep checkrun integration at the boundary where formatting and linting are
requested. Sley should ask checkrun for plans or execution rather than
duplicating formatter/linter registry knowledge.
