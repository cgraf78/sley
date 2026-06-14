#!/usr/bin/env bash
# repo.sh — repository primitives for the sley workflow API.
#
# This library is intentionally small and shell-only because it sits under
# hooks and human-facing CLIs. The user-facing command is `sley`; these private
# helpers keep VCS detection and changed-file enumeration in one place.

_repo_git_root() {
  command -v git >/dev/null 2>&1 || return 1
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  # Bare Git worktrees are accepted only when the caller made that context
  # explicit. Otherwise a PATH-visible launcher can make a directory look like a
  # repo even though no .git metadata belongs to that worktree.
  if ! _repo_has_explicit_git_env && [[ ! -e "$root/.git" ]]; then
    return 1
  fi
  printf '%s\n' "$root"
}

_repo_sl_machine() {
  # sley parses Sapling stdout as data. User configs may intentionally force
  # color for interactive Sapling commands; keep that preference out of
  # machine contracts so path matching never depends on terminal color state.
  sl "$@" --config ui.color=never
}

_repo_sl_root() {
  command -v sl >/dev/null 2>&1 || return 1
  _repo_sl_machine root 2>/dev/null
}

_repo_physical_dir() {
  cd "$1" 2>/dev/null && pwd -P
}

_repo_has_real_sl_metadata() {
  local root="$1"
  [[ -d "$root/.sl" || -d "$root/.hg" ]]
}

_repo_has_explicit_git_env() {
  [[ -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" ]]
}

_repo_detect() {
  _REPO_TYPE="${_REPO_TYPE:-}"
  _REPO_ROOT="${_REPO_ROOT:-}"

  # Honor a pre-set `_REPO_TYPE` for hook callers that force one VCS to
  # disambiguate dual-managed repos, but always re-probe `_REPO_ROOT`.
  # Caching `_REPO_ROOT` across calls
  # would let a stale value survive a `cd` to a different repo when consumers
  # use the sourced API; clear both when the probe fails so callers cannot see
  # a "type set, root empty" half-state from a prior run.
  case "$_REPO_TYPE" in
    git)
      _REPO_ROOT=$(_repo_git_root) || {
        _REPO_TYPE=""
        _REPO_ROOT=""
      }
      return 0
      ;;
    sl)
      _REPO_ROOT=$(_repo_sl_root) || {
        _REPO_TYPE=""
        _REPO_ROOT=""
      }
      return 0
      ;;
  esac

  local git_root
  git_root=$(_repo_git_root || true)
  if [[ -n "$git_root" ]] && _repo_has_explicit_git_env; then
    # The local launcher presents the base bare repo to sley via
    # GIT_DIR/GIT_WORK_TREE.
    # Treat that explicit Git context as authoritative so an unrelated ambient
    # Sapling checkout in the caller's cwd cannot steal repo detection.
    _REPO_TYPE="git"
    _REPO_ROOT="$git_root"
    return 0
  fi

  local sl_root sl_physical git_physical
  sl_root=$(_repo_sl_root || true)

  if [[ -n "$sl_root" && -n "$git_root" ]] && _repo_has_real_sl_metadata "$sl_root"; then
    sl_physical=$(_repo_physical_dir "$sl_root" || printf '%s' "$sl_root")
    git_physical=$(_repo_physical_dir "$git_root" || printf '%s' "$git_root")
    case "$git_physical" in
      "$sl_physical"/*)
        # A nested Git checkout inside a larger Sapling checkout should behave
        # as that Git repo, not as the outer Sapling checkout. Pick the nearest
        # enclosing root. Use physical paths for the comparison so macOS's
        # /var -> /private/var symlink does not make nested roots look
        # unrelated.
        _REPO_TYPE="git"
        _REPO_ROOT="$git_root"
        return 0
        ;;
      *)
        _REPO_TYPE="sl"
        _REPO_ROOT="$sl_root"
        return 0
        ;;
    esac
  fi

  if [[ -n "$sl_root" ]] && _repo_has_real_sl_metadata "$sl_root"; then
    _REPO_TYPE="sl"
    _REPO_ROOT="$sl_root"
    return 0
  fi

  if [[ -n "$git_root" ]]; then
    _REPO_TYPE="git"
    _REPO_ROOT="$git_root"
    return 0
  fi

  _REPO_TYPE=""
  _REPO_ROOT=""
}

_repo_json_escape() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    # JSON is a machine contract; use a real encoder when available so tabs,
    # carriage returns, and other control bytes cannot corrupt output.
    printf '%s' "$s" | jq -Rs . | sed 's/^"//; s/"$//'
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    # Python's json.dumps is RFC 8259-compliant: escapes every U+0000-U+001F
    # control byte plus 0x7F as `\u00XX`, plus the named escapes. This keeps
    # the no-jq path from emitting invalid JSON when filenames carry control
    # characters or unicode surrogates. `printf '%s'` (not a herestring) is
    # required so the encoded value does not silently gain a trailing `\n`
    # from bash adding one to `<<<` input.
    printf '%s' "$s" |
      python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
    return
  fi
  # No encoder: emit the shared requirement message from its single owner.
  _repo_require_json_encoder
  return 2
}

_repo_require_json_encoder() {
  command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
    echo "sley: jq or python3 is required for JSON output" >&2
    return 2
  }
}

_repo_relpath_for_existing_dir() {
  local root="$1" path="$2"
  local abs root_abs abs_input parent tail
  root_abs=$(cd "$root" 2>/dev/null && pwd -P) || return 1

  # Reject obvious lexical escapes before checking existence. A missing
  # "../foo" is still outside the repo from the caller's point of view, and
  # reporting "missing" would hide the more important safety boundary.
  case "$path" in
    ../* | */../* | */.. | ..) return 2 ;;
  esac

  case "$path" in
    /*) abs_input="$path" ;;
    *) abs_input="$PWD/$path" ;;
  esac

  # If the caller passed a regular file, peel off the basename so the parent
  # walk operates on a directory. Without this, `cd "$abs_input"` below would
  # ENOTDIR on the file and the function would falsely report "does not exist"
  # for an existing file passed via `--path some/file.ext`.
  parent="$abs_input"
  tail=""
  if [[ -e "$parent" && ! -d "$parent" ]]; then
    tail="${parent##*/}"
    parent="${parent%/*}"
    [[ -z "$parent" ]] && parent="/"
  fi

  # Walk up to the deepest existing ancestor and resolve THAT with pwd -P,
  # which follows parent-chain symlinks. `realpath -m` would canonicalize
  # lexically and miss a symlink in the parent chain, letting `--path
  # subdir/missing` slip past the repo boundary check when subdir is a symlink
  # to /etc. Re-attach the missing tail after resolving the existing parent.
  while [[ "$parent" != "/" && ! -e "$parent" ]]; do
    if [[ -z "$tail" ]]; then
      tail="${parent##*/}"
    else
      tail="${parent##*/}/$tail"
    fi
    parent="${parent%/*}"
    [[ -z "$parent" ]] && parent="/"
  done

  if [[ ! -e "$parent" ]]; then
    return 1
  fi

  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  if [[ -n "$tail" ]]; then
    abs="$parent/$tail"
  else
    abs="$parent"
  fi

  case "$abs" in
    "$root_abs") printf '.' ;;
    "$root_abs"/*) printf '%s' "${abs#"$root_abs"/}" ;;
    *) return 2 ;;
  esac
}

# Read NUL-delimited paths from stdin and emit them newline-delimited on
# stdout, dropping (with a stderr warning) any name that contains a literal
# newline. Sley's changed-file pipeline is newline-delimited end-to-end; a
# filename with `\n` would otherwise survive the VCS query and then split
# into multiple entries downstream, silently bypassing format/lint/secret
# scans. Convert the silent fail-open into a loud drop so reviewers see the
# issue immediately.
_repo_emit_safe_paths() {
  local name dropped=0
  while IFS= read -r -d '' name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      *$'\n'*)
        dropped=$((dropped + 1))
        printf 'sley: warning: skipping file with embedded newline in name (would bypass changed-file scans): %q\n' "$name" >&2
        continue
        ;;
    esac
    printf '%s\n' "$name"
  done
  if ((dropped > 0)); then
    printf 'sley: warning: %d file(s) skipped due to embedded newlines in their names; rename or omit them before re-running for full coverage.\n' "$dropped" >&2
  fi
}

_repo_git_changed_names() {
  local scope="$1" include_untracked="$2" rc=0
  # Staged callers operate on existing-file content. The secrets scanner in
  # particular depends on the ACM filter so it never tries to read a deleted
  # blob from the index.
  local staged_filter="ACM"

  case "$scope" in
    staged)
      # `git diff -z` emits NUL-delimited path records; route through
      # `_repo_emit_safe_paths` so filenames with control characters
      # (newline in particular) cannot evade downstream changed-file checks.
      # `set -o pipefail` in the subshell so a failing git invocation is
      # not masked by the safe-paths filter.
      (
        set -o pipefail
        git diff -z --cached --name-only --diff-filter="$staged_filter" 2>/dev/null | _repo_emit_safe_paths
      ) || return 2
      ;;
    changed)
      # `set -o pipefail` inside the subshell so a failing `git diff` propagates
      # through the `awk` dedup. Without this, an inaccessible repo or locked
      # index would emit an empty list and the caller would silently report
      # "no matching changed files" — a fail-open quality gate.
      (
        set -o pipefail
        {
          _repo_git_unpushed_names ACMDR
          git diff -z --cached --name-only --diff-filter=ACMDR 2>/dev/null | _repo_emit_safe_paths
          git diff -z --name-only --diff-filter=ACMDR 2>/dev/null | _repo_emit_safe_paths
        } | awk 'NF && !seen[$0]++'
      ) || return 2
      ;;
    *)
      return 2
      ;;
  esac

  if [[ "$include_untracked" == "1" ]]; then
    (
      set -o pipefail
      git ls-files -z --others --exclude-standard 2>/dev/null | _repo_emit_safe_paths
    ) || rc=2
  fi
  return "$rc"
}

_repo_git_upstream_base() {
  local upstream head base
  upstream=$(git rev-parse --verify --quiet '@{upstream}') || return 1
  head=$(git rev-parse --verify --quiet HEAD) || return 1
  base=$(git merge-base "$upstream" "$head" 2>/dev/null) || return 1
  [[ "$base" != "$head" ]] || return 1
  printf '%s\n' "$base"
}

_repo_git_unpushed_names() {
  local diff_filter="$1" base
  base=$(_repo_git_upstream_base) || return 0
  # See `_repo_emit_safe_paths` and the `staged` branch above for why we route
  # every changed-name source through the NUL-safe pipeline.
  (
    set -o pipefail
    git diff -z --name-only --diff-filter="$diff_filter" "$base"...HEAD 2>/dev/null | _repo_emit_safe_paths
  ) || return 2
}

_repo_sl_current_phase() {
  _repo_sl_machine log -r . -T '{phase}' 2>/dev/null
}

_repo_sl_draft_stack_revs() {
  _repo_sl_machine log -r 'sort(draft() & ::., topo)' -T '{node}\n' 2>/dev/null
}

_repo_sl_draft_stack_changed_names() {
  local revs rev
  revs=$(_repo_sl_draft_stack_revs) || return 2
  [[ -n "$revs" ]] || return 2
  while IFS= read -r rev; do
    [[ -n "$rev" ]] || continue
    # `changed` in a Sapling stack must mean the whole draft stack, not only
    # `.`. A receipt keyed on the tip commit alone can miss changes in lower
    # diffs and incorrectly satisfy `sley ready` for stacked changes.
    _repo_sl_machine status --change "$rev" --no-status "$@" 2>/dev/null || return 2
  done <<<"$revs"
}

_repo_sl_changed_names() {
  local scope="$1" include_untracked="$2" rc=0
  # Pending/draft callers operate on existing-file content.
  local pending_flags=("-a" "-m")
  case "$scope" in
    pending)
      _repo_sl_machine status --no-status "${pending_flags[@]}" 2>/dev/null || return 2
      ;;
    changed)
      # `set -o pipefail` inside the subshell so a failing `sl status` cannot
      # be masked by `awk`'s clean exit — see the matching guard in
      # `_repo_git_changed_names` for the silent-fail-open hazard.
      (
        set -o pipefail
        {
          # In Sapling, the active draft commit is part of the change context
          # even when the working copy is clean. Include the full draft stack so
          # stacked diffs cannot reuse a cache key that only proved the active
          # commit.
          if [[ "$(_repo_sl_current_phase)" == "draft" ]]; then
            _repo_sl_draft_stack_changed_names "${pending_flags[@]}"
          fi
          _repo_sl_machine status --no-status "${pending_flags[@]}" 2>/dev/null
        } | awk 'NF && !seen[$0]++'
      ) || return 2
      ;;
    *)
      return 2
      ;;
  esac
  if [[ "$include_untracked" == "1" ]]; then
    _repo_sl_machine status --no-status -u 2>/dev/null || rc=2
  fi
  return "$rc"
}

_repo_changed_names() {
  local scope="$1" include_untracked="${2:-0}"
  case "$_REPO_TYPE" in
    git) _repo_git_changed_names "$scope" "$include_untracked" ;;
    sl) _repo_sl_changed_names "$scope" "$include_untracked" ;;
    *) return 2 ;;
  esac
}

_repo_filter_paths() {
  local filters_text="$1" file filter
  if [[ -z "$filters_text" ]]; then
    cat
    return 0
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    while IFS= read -r filter; do
      [[ -n "$filter" ]] || continue
      if [[ "$filter" == "." || "$file" == "$filter" || "$file" == "$filter"/* ]]; then
        printf '%s\n' "$file"
        break
      fi
    done <<<"$filters_text"
  done
}

_repo_existing_regular_files() {
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" ]] || continue
    printf '%s\n' "$file"
  done
}
