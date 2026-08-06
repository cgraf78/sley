#!/usr/bin/env bash
# sley.sh — public API for current-repo workflow operations.
#
# The `sley` executable is intentionally a thin dispatcher over this library so
# humans, agents, hooks, and tests can share the same operation contracts without
# reimplementing CLI parsing or repo scope rules.
#
# Strict-undefined (`set -u`) is applied per public entry point via `local -`
# rather than at file scope, so sourcing this library does not surprise the
# caller's shell with extra strict-mode behavior outside `sley_*` calls.

_SLEY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve sibling libraries from sley.sh's own location. Tests and hooks may
# override HOME to isolate local extensions, but core API resolution should
# follow the library that was actually sourced.
# shellcheck source=repo.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_SLEY_LIB_DIR/repo.sh"
# shellcheck source=scope.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_SLEY_LIB_DIR/scope.sh"
# shellcheck source=hooks.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_SLEY_LIB_DIR/hooks.sh"
# shellcheck source=verify.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_SLEY_LIB_DIR/verify.sh"
# shellcheck source=ready.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_SLEY_LIB_DIR/ready.sh"

# ---------------------------------------------------------------------------
# Public API — stable interface for CLIs, hooks, tests, and local extensions
# ---------------------------------------------------------------------------
# Every public sley.sh function (no leading underscore) is defined here. Keep
# these as thin wrappers so the supported interface is scannable at the top of
# the file; private implementation lives below with _sley_ prefixes.

# Each public wrapper enables `set -u` only for the scope of the call (via
# `local -`) and saves/restores the caller's CWD so a sourced consumer
# (`source sley.sh; sley_status`) does not silently inherit the `cd` that
# `_sley_init_repo` performs into the repo root. `sley_hook_init` is the only
# wrapper without CWD restoration: it sources the local extension into the
# caller's scope and must NOT subshell, but `_sley_hook_init` does not cd.

# _sley_run_with_cwd_restore <impl_fn> [args...]
#   Run `impl_fn "$@"` while the caller's CWD survives an `_sley_init_repo`
#   chdir into the repo root. Internal helper for the public wrappers.
_sley_run_with_cwd_restore() {
  local _saved_pwd="$PWD" _rc=0
  "$@" || _rc=$?
  cd "$_saved_pwd" 2>/dev/null || true
  return "$_rc"
}

# sley_main <command> [args...]
#   Dispatch the human-facing CLI command. The `sley` executable should do
#   nothing except source this library and call sley_main "$@".
sley_main() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_main "$@"
}

# sley_status [scope options]
#   Print repo type, root, ref, and dirty counters. Read-only.
sley_status() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_status "$@"
}

# sley_changes [scope options]
#   List selected changed files for the current Git/Sapling repo. Read-only.
sley_changes() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_changes "$@"
}

# sley_select [scope options]
#   Resolve the current repo and selected changed files for sourced shell
#   consumers. Prints the selected files and populates SLEY_REPO_TYPE,
#   SLEY_REPO_ROOT, SLEY_CHANGE_SCOPE, SLEY_INCLUDE_UNTRACKED, SLEY_REPO_WIDE,
#   SLEY_PATH_SCOPE, and SLEY_SELECTED_FILES. Read-only.
sley_select() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_select "$@"
}

# sley_fix [scope options]
#   Format selected changed files. This is the only mutating public operation.
sley_fix() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_fix "$@"
}

# sley_check [scope options]
#   Run lint and repo validation for selected changed files. Read-only.
sley_check() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_check "$@"
}

# sley_secrets [scope options]
#   Scan selected changes for secrets, including staged Git blobs. Read-only.
sley_secrets() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_secrets "$@"
}

# sley_verify [scope options]
#   Discover local verification commands near selected changes.
sley_verify() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_verify "$@"
}

# sley_ready [scope options]
#   Run the aggregate pre-submit readiness report. Mutates only with --fix.
sley_ready() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_ready "$@"
}

# sley_hook <hook-command> [args...]
#   Dispatch low-level hook plumbing for process-bound consumers such as
#   Neovim. Shell hooks should source this file and call sley_hook_* directly.
sley_hook() {
  local -
  set -u
  _sley_run_with_cwd_restore _sley_hook "$@"
}

# sley_hook_changed_files
#   Return the fast hook file set: Git staged ACM files or Sapling pending ACM
#   files. Hook callers use this instead of broader active-change defaults.
sley_hook_changed_files() {
  local -
  set -u
  _sley_hook_changed_files
}

# sley_hook_format_file <file>
#   Format one file for hash-compare hook workflows. Returns formatter status;
#   latency-sensitive callers may explicitly ignore it when format failures
#   should be advisory.
sley_hook_format_file() {
  local -
  set -u
  _sley_hook_format_file "$@"
}

# sley_hook_lint_file [args...] <file>
#   Lint one file for edit-hook workflows. Extra args pass through to the
#   backing linter so callers can request native output modes such as JSON.
#   Return 2 when the linter is unavailable; callers on hot paths may treat
#   that as a no-op.
sley_hook_lint_file() {
  local -
  set -u
  _sley_hook_lint_file "$@"
}

# sley_hook_format <newline-separated-files>
#   Format a hook-selected file list in batch. Local extensions may override.
sley_hook_format() {
  local -
  set -u
  _sley_hook_format "$@"
}

# sley_hook_lint <newline-separated-files>
#   Lint a hook-selected file list in batch. Return 2 when the linter is
#   unavailable so orchestrators can distinguish missing tools from lint errors.
sley_hook_lint() {
  local -
  set -u
  _sley_hook_lint "$@"
}

# sley_hook_validate
#   Run repo-specific validation for hook/readiness flows. No arguments; callers
#   that need path isolation should skip this if the validator is not scoped.
sley_hook_validate() {
  local -
  set -u
  _sley_hook_validate
}

# sley_ext_ready_phases
#   Print additional `sley ready` phase names, one per line. Local extensions
#   may override this to add human/agent readiness phases.
sley_ext_ready_phases() {
  local -
  set -u
  _sley_ext_ready_phases
}

# sley_ext_ready_phase <phase> [scope options]
#   Run an extension-provided `sley ready` phase. Return 0 for pass, 1 for
#   blocking findings, and 2 for unavailable.
sley_ext_ready_phase() {
  local -
  set -u
  _sley_ext_ready_phase "$@"
}

# sley_ext_verify_commands <newline-separated-files>
#   Print additional `sley verify` command items as JSON lines. Local extensions
#   use this to expose environment-specific required checks without teaching
#   base sley about those tools.
sley_ext_verify_commands() {
  local -
  set -u
  _sley_ext_verify_commands "$@"
}

# sley_hook_init
#   Load optional local hook overrides and run repo detection. Hook
#   callers should call this once and rely on it instead of reaching into
#   private `_repo_detect`. Intentionally NOT subshelled — `_sley_hook_init`
#   sources the optional local extension into the caller's scope so subsequent
#   `sley_hook_*` calls see the override; `_sley_hook_init` itself does not cd.
sley_hook_init() {
  local -
  set -u
  _sley_hook_init
}

# ===========================================================================
# Internal implementation — everything below is private (_sley_ prefix)
# ===========================================================================

_sley_usage() {
  cat <<'EOF'
Usage: sley COMMAND [OPTIONS]

Commands:
  status      show repository status
  changes     list changed files
  fix         format changed files
  check       lint and validate changed files
  secrets     scan changed files (or --message-file <path>) for secrets
  verify      list and run local verification commands
  ready       run the pre-submit readiness report
  hook        run low-level hook plumbing
EOF
}

_sley_die() {
  printf 'sley: %s\n' "$*" >&2
  return 2
}

_sley_count_file_list() {
  printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

_sley_print_file_summary() {
  local prefix="$1" count="$2" noun="files"
  [[ "$count" == "1" ]] && noun="file"
  printf '%s %s %s\n' "$prefix" "$count" "$noun"
}

_sley_init_repo() {
  # `SLEY_ORIGINAL_PWD` is exported by `_sley_ready` into each phase subshell
  # so a phase running from inside the repo root still resolves `--path .`
  # against the user's caller directory. shellcheck SC2031 fires because the
  # subshell-modified value is read here in the parent dispatcher; the export
  # in `ready.sh` is intentional.
  # shellcheck disable=SC2031
  _SLEY_CALLER_PWD="${SLEY_ORIGINAL_PWD:-$PWD}"
  _repo_detect
  if [[ -z "${_REPO_TYPE:-}" || -z "${_REPO_ROOT:-}" ]]; then
    _sley_die "unsupported repo"
    return 2
  fi
  if ! cd "$_REPO_ROOT"; then
    _sley_die "cannot enter repo root"
    return 2
  fi
}

_sley_changes() {
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?

  local files files_json untracked_set=""
  files=$(_sley_selected_files) || return 2
  if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
    _repo_require_json_encoder || return 2
    # Tracked-vs-untracked is derived from the untracked set alone. Files in
    # the change list that are NOT in the untracked set are tracked by
    # construction (`_repo_changed_names` only emits VCS-tracked changes for
    # the staged/changed/pending scopes; untracked entries appear only when
    # `--include-untracked` is requested). Computing a full `git ls-files`
    # tracked set would walk the entire repo on every `changes --json` call,
    # which is wasted O(repo) work — millions of paths in a monorepo just to
    # answer "is this changed file tracked?".
    if [[ "$_SLEY_SCOPE_INCLUDE_UNTRACKED" == "1" ]]; then
      case "$_REPO_TYPE" in
        git) untracked_set=$(git ls-files --others --exclude-standard 2>/dev/null) ;;
        sl) untracked_set=$(_repo_sl_machine status --no-status -u 2>/dev/null) ;;
      esac
    fi
    files_json=$(_sley_json_files "$files" "$untracked_set") || return $?
    printf '{"repo_type":"%s","root":"%s","scope":"%s","files":%s}\n' \
      "$_REPO_TYPE" "$(_repo_json_escape "$_REPO_ROOT")" \
      "$_SLEY_SCOPE_CHANGE" "$files_json"
  elif [[ -n "$files" ]]; then
    printf '%s\n' "$files"
  fi
}

_sley_dirty_counts() {
  local staged=0 unstaged=0 untracked=0 pending=0 line
  # `SLEY_SKIP_UNTRACKED=1` disables the untracked-file walk in both repo
  # types. This is mainly for bare Git worktrees rooted at large directories:
  # `git status --untracked-files=all` can walk every file under that tree
  # against `.gitignore` rules, which is unusably slow.
  local skip_untracked="${SLEY_SKIP_UNTRACKED:-0}"
  local untracked_flag="all"
  [[ "$skip_untracked" == "1" ]] && untracked_flag="no"
  case "$_REPO_TYPE" in
    git)
      # Long-form `--untracked-files=...` reads more clearly than `-u...` and
      # protects against a future short-flag change.
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "${line:0:2}" == "??" ]]; then
          untracked=$((untracked + 1))
          continue
        fi
        [[ "${line:0:1}" != " " ]] && staged=$((staged + 1))
        [[ "${line:1:1}" != " " ]] && unstaged=$((unstaged + 1))
      done < <(git status --porcelain --untracked-files="$untracked_flag" 2>/dev/null)
      ;;
    sl)
      # `pending` for the dirty signal counts only worktree changes — including
      # the active draft commit's files would conflate "is the worktree dirty?"
      # with "is there unsubmitted work?". Keep the `untracked` count separate
      # because Sapling supports it directly via `sl status -u`.
      pending=$(_sley_count_file_list "$(_repo_sl_changed_names pending 0 2>/dev/null)")
      if [[ "$skip_untracked" != "1" ]]; then
        untracked=$(_sley_count_file_list "$(_repo_sl_machine status --no-status -u 2>/dev/null)")
      fi
      ;;
  esac

  _SLEY_DIRTY_STAGED=$staged
  _SLEY_DIRTY_PENDING=$pending
  _SLEY_DIRTY_UNSTAGED=$unstaged
  _SLEY_DIRTY_UNTRACKED=$untracked
}

_sley_dirty_counts_json_from_values() {
  local staged="$1" pending="$2" unstaged="$3" untracked="$4"
  printf '{"staged":%s,"pending":%s,"unstaged":%s,"untracked":%s}' \
    "$staged" "$pending" "$unstaged" "$untracked"
}

_sley_dirty_from_counts() {
  local staged="$1" pending="$2" unstaged="$3" untracked="$4"

  if ((staged == 0 && pending == 0 && unstaged == 0 && untracked == 0)); then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

_sley_dirty_counts_json() {
  _sley_dirty_counts || return $?
  _sley_dirty_counts_json_from_values \
    "$_SLEY_DIRTY_STAGED" \
    "$_SLEY_DIRTY_PENDING" \
    "$_SLEY_DIRTY_UNSTAGED" \
    "$_SLEY_DIRTY_UNTRACKED"
}

_sley_status() {
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?

  # `status` does not enumerate files, but `--path` is a documented scope
  # contract: an outside-repo or non-existent path must exit 2 here just as it
  # does for `changes`/`fix`/`check`. Run the path-scope validator for its
  # side-effect rc and discard the filter list.
  _sley_path_filters >/dev/null || return $?

  local ref dirty counts
  case "$_REPO_TYPE" in
    git)
      # `git rev-parse --abbrev-ref HEAD` prints "HEAD" then exits non-zero on
      # an unborn branch (a fresh repo before the first commit). Capturing
      # both stdout and the `|| echo unknown` fallback would emit
      # `HEAD\nunknown`, corrupting the JSON `ref` field. Prefer
      # `symbolic-ref` for branches, fall back to a short hash for detached
      # HEAD, and only then to the literal "unknown".
      ref=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
        ref=$(git rev-parse --short HEAD 2>/dev/null) ||
        ref="unknown"
      ;;
    sl)
      # Prefer the active bookmark, which is the closest Sapling analog to a
      # Git branch. Fall back to the short node hash only when no bookmark is
      # active, so status stays useful for anonymous heads.
      ref=$(_repo_sl_machine log -r . -T '{activebookmark}' 2>/dev/null || echo "")
      if [[ -z "$ref" ]]; then
        ref=$(_repo_sl_machine log -r . -T '{node|short}' 2>/dev/null || echo unknown)
      fi
      ;;
  esac
  _sley_dirty_counts || return $?
  # Dirty state is derived from the numeric counts before display JSON is
  # rendered, so changing the JSON field order cannot change control flow.
  dirty=$(_sley_dirty_from_counts \
    "$_SLEY_DIRTY_STAGED" \
    "$_SLEY_DIRTY_PENDING" \
    "$_SLEY_DIRTY_UNSTAGED" \
    "$_SLEY_DIRTY_UNTRACKED")
  counts=$(_sley_dirty_counts_json_from_values \
    "$_SLEY_DIRTY_STAGED" \
    "$_SLEY_DIRTY_PENDING" \
    "$_SLEY_DIRTY_UNSTAGED" \
    "$_SLEY_DIRTY_UNTRACKED")

  if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
    _repo_require_json_encoder || return 2
    printf '{"repo_type":"%s","root":"%s","ref":"%s","counts":%s,"dirty":%s}\n' \
      "$_REPO_TYPE" "$(_repo_json_escape "$_REPO_ROOT")" \
      "$(_repo_json_escape "$ref")" "$counts" "$dirty"
  else
    printf 'repo: %s\nroot: %s\nref: %s\ndirty: %s\n' \
      "$_REPO_TYPE" "$_REPO_ROOT" "$ref" "$dirty"
  fi
}

_sley_git_unstaged_among() {
  local files_text="$1" unstaged f
  # Callers pass the already-selected staged files, so enumerating the index a
  # second time only repeats the scope query. Intersect that trusted selection
  # with the NUL-safe unstaged list to identify partially staged paths.
  unstaged=$(
    set -o pipefail
    git diff -z --name-only --diff-filter=ACM 2>/dev/null | _repo_emit_safe_paths
  ) || unstaged=""
  declare -A _in_unstaged
  while IFS= read -r f; do
    [[ -n "$f" ]] && _in_unstaged["$f"]=1
  done <<<"$unstaged"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -n "${_in_unstaged[$f]:-}" ]] && printf '%s\n' "$f"
  done <<<"$files_text"
}

_sley_git_staged_selected_files() {
  local files_text="$1" staged f
  # NUL-safe staged-name enumeration (see `_repo_emit_safe_paths` in repo.sh).
  # Without `-z`, a staged secret in a file with a `\n` in its name would
  # split into bogus entries that the downstream `_in_files` membership test
  # silently skips, letting the secret slip past `sley secrets --commit`.
  staged=$(
    set -o pipefail
    git diff -z --cached --name-only --diff-filter=ACM 2>/dev/null | _repo_emit_safe_paths
  ) || staged=""
  declare -A _in_files
  while IFS= read -r f; do
    [[ -n "$f" ]] && _in_files["$f"]=1
  done <<<"$files_text"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -n "${_in_files[$f]:-}" ]] && printf '%s\n' "$f"
  done <<<"$staged"
}

_sley_file_hash() {
  local file="$1"
  # Individual fixes and Sapling batches use this raw-byte hash. Git batches
  # use `hash-object --no-filters` below, so every path detects formatter-only
  # byte changes without attributes or EOL normalization hiding them.
  { cksum <"$file"; } 2>/dev/null || true
}

_sley_hash_git_chunk() {
  local output hash

  output=$(git hash-object --no-filters -- "$@" 2>/dev/null) || {
    _SLEY_HASH_BATCH_FAILED=1
    return 1
  }
  while IFS= read -r hash; do
    [[ -n "$hash" ]] && _SLEY_HASH_BATCH_HASHES+=("$hash")
  done <<<"$output"
}

_sley_hash_files() {
  local files_text="$1" file index=0 existing_text=""
  local _SLEY_HASH_BATCH_FAILED=0
  local -a files=() existing_files=() existing_indices=() hashes=()
  local -a _SLEY_HASH_BATCH_HASHES=()

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
    hashes+=("")
    if [[ -e "$file" || -L "$file" ]]; then
      existing_files+=("$file")
      existing_indices+=("$index")
      existing_text+="$file"$'\n'
    fi
    index=$((index + 1))
  done <<<"$files_text"

  if [[ "${#existing_files[@]}" -gt 0 && "${_REPO_TYPE:-}" == "git" ]]; then
    _sley_run_file_chunks _sley_hash_git_chunk 65536 256 \
      <<<"$existing_text" || true
  else
    _SLEY_HASH_BATCH_FAILED=1
  fi

  if [[ "$_SLEY_HASH_BATCH_FAILED" == "0" &&
    "${#_SLEY_HASH_BATCH_HASHES[@]}" == "${#existing_files[@]}" ]]; then
    for index in "${!existing_indices[@]}"; do
      hashes[${existing_indices[$index]}]=${_SLEY_HASH_BATCH_HASHES[$index]}
    done
  else
    # Keep one hash scheme across pre/post passes. A Git batch failure retries
    # with Git per file; Sapling consistently uses the VCS-independent hash.
    # Mixing Git object ids with cksum output would report every file modified.
    for index in "${!files[@]}"; do
      if [[ "${_REPO_TYPE:-}" == "git" ]]; then
        hashes[index]=$(git hash-object --no-filters -- "${files[$index]}" 2>/dev/null || true)
      else
        hashes[index]=$(_sley_file_hash "${files[$index]}")
      fi
    done
  fi

  for index in "${!files[@]}"; do
    printf '%s\t%s\n' "$index" "${hashes[$index]}"
  done
}

_sley_byte_length() {
  local output_name="$1" value="$2"
  local LC_ALL=C

  # Bash counts characters under a multibyte locale. Limit C locale to this
  # expansion so formatters still inherit the caller's locale unchanged.
  printf -v "$output_name" '%s' "${#value}"
}

_sley_run_file_chunks() {
  local callback="$1" max_bytes="$2" max_files="$3" file file_bytes
  local chunk_bytes=3
  local -a chunk=()

  if ! [[ "$max_bytes" =~ ^[1-9][0-9]{0,4}$ ]] ||
    [[ "$max_bytes" -gt 65536 ]]; then
    max_bytes=65536
  fi
  if ! [[ "$max_files" =~ ^[1-9][0-9]{0,2}$ ]] ||
    [[ "$max_files" -gt 256 ]]; then
    max_files=256
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    _sley_byte_length file_bytes "$file"
    file_bytes=$((file_bytes + 1))
    if [[ "${#chunk[@]}" -gt 0 ]] &&
      { [[ "${#chunk[@]}" -ge "$max_files" ]] ||
        [[ "$((chunk_bytes + file_bytes))" -gt "$max_bytes" ]]; }; then
      "$callback" "${chunk[@]}" || return $?
      chunk=()
      chunk_bytes=3
    fi
    chunk+=("$file")
    chunk_bytes=$((chunk_bytes + file_bytes))
  done

  [[ "${#chunk[@]}" -eq 0 ]] || "$callback" "${chunk[@]}"
}

_sley_fix_run_base_format_chunk() {
  local format_rc=0

  autoformat -- "$@" </dev/null >/dev/null 2>/dev/null || format_rc=$?
  case "$format_rc" in
    0) ;;
    2) _SLEY_FIX_SKIPPED+=("$@") ;;
    *) _SLEY_FIX_FAILED+=("$@") ;;
  esac
  # Never retry a mutating batch: formatters are expected to be idempotent but
  # that is not an enforceable contract. Continue so later bounded chunks still
  # get an attempt, and report the whole failed chunk conservatively.
  return 0
}

_sley_fix_run_individual_files() {
  local f pre post format_rc

  for f in "$@"; do
    pre=$(_sley_file_hash "$f")
    # Redirect stdin so an interactive or probing formatter cannot consume the
    # caller's file-list stream and silently skip later paths.
    format_rc=0
    sley_hook_format_file "$f" </dev/null >/dev/null || format_rc=$?
    post=$(_sley_file_hash "$f")
    [[ -n "$pre" && "$pre" != "$post" ]] && _SLEY_FIX_MODIFIED+=("$f")
    case "$format_rc" in
      0) ;;
      2)
        _SLEY_FIX_SKIPPED+=("$f")
        continue
        ;;
      *)
        _SLEY_FIX_FAILED+=("$f")
        continue
        ;;
    esac
  done
}

_sley_fix() {
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?

  local files partial runnable f unavailable=0 hash_records index hash
  local use_batch=0
  local -a runnable_files=() _SLEY_FIX_MODIFIED=() _SLEY_FIX_FAILED=() _SLEY_FIX_SKIPPED=()
  local -a pre_hashes=() post_hashes=()
  files=$(_sley_selected_files) || return 2
  _sley_warn_out_of_scope "$files"
  runnable=$(printf '%s\n' "$files" | _repo_existing_regular_files)
  if [[ -z "$runnable" ]]; then
    echo "sley fix: no matching changed files" >&2
    return 0
  fi

  SLEY_CALLER="${SLEY_CALLER:-human}"
  # shellcheck disable=SC2034 # consumed by sourced local extensions.
  SLEY_SCOPED=1
  # `sley fix` must use the same formatting policy as editor, agent, Git, and
  # Sapling hooks. Base installs route through autoformat; environment
  # extensions may override `sley_hook_format_file` for repo-native tools.
  sley_hook_init || return $?

  if [[ "$_REPO_TYPE" == "git" && "$_SLEY_SCOPE_CHANGE" == "staged" ]]; then
    # Formatting a partially staged file rewrites the whole worktree file,
    # mixing unstaged hunks with formatter output. Refuse all files instead of
    # producing a half-helpful, half-dangerous result.
    partial=$(_sley_git_unstaged_among "$runnable")
    if [[ -n "$partial" ]]; then
      echo "sley fix: refusing files with staged and unstaged changes:" >&2
      printf '%s\n' "$partial" | sed 's/^/  /' >&2
      return 2
    fi
  fi

  while IFS= read -r f; do
    [[ -n "$f" ]] && runnable_files+=("$f")
  done <<<"$runnable"

  if [[ "${#runnable_files[@]}" -gt 1 &&
    "${_SLEY_HOOK_FORMAT_OVERRIDDEN:-0}" == "0" &&
    "${_SLEY_HOOK_FORMAT_FILE_OVERRIDDEN:-0}" == "0" &&
    "${_SLEY_HOOK_PRIVATE_FORMAT_FILE_OVERRIDDEN:-0}" == "0" ]]; then
    command -v autoformat >/dev/null 2>&1 && use_batch=1
  fi

  if [[ "$use_batch" == "0" ]]; then
    # Single-file fixes and extension-owned hooks retain their exact historical
    # per-file execution and failure attribution. Only the unextended
    # multi-file base path speculates with a batch.
    _sley_fix_run_individual_files "${runnable_files[@]}"
  else
    hash_records=$(_sley_hash_files "$runnable")
    while IFS=$'\t' read -r index hash; do
      [[ -n "$index" ]] && pre_hashes[index]="$hash"
    done <<<"$hash_records"

    _sley_run_file_chunks _sley_fix_run_base_format_chunk 65536 256 <<<"$runnable"

    hash_records=$(_sley_hash_files "$runnable")
    while IFS=$'\t' read -r index hash; do
      [[ -n "$index" ]] && post_hashes[index]="$hash"
    done <<<"$hash_records"
    for index in "${!runnable_files[@]}"; do
      f=${runnable_files[$index]}
      if [[ -n "${pre_hashes[$index]:-}" &&
        "${pre_hashes[$index]:-}" != "${post_hashes[$index]:-}" ]]; then
        _SLEY_FIX_MODIFIED+=("$f")
      fi
    done
  fi
  [[ "${#_SLEY_FIX_SKIPPED[@]}" -eq 0 ]] || unavailable=1

  if [[ "${#_SLEY_FIX_MODIFIED[@]}" -gt 0 ]]; then
    echo "sley fix: formatted files:" >&2
    printf '  %s\n' "${_SLEY_FIX_MODIFIED[@]}" >&2
    if [[ "$_REPO_TYPE" == "git" && "$_SLEY_SCOPE_CHANGE" == "staged" ]]; then
      # Unlike the automatic pre-commit hook, the interactive CLI does not
      # update the index. Humans and agents should make the staging decision
      # explicitly after reviewing formatter changes. The `<…>` placeholder
      # tells the reader which name to substitute (any of the formatted files
      # listed above).
      echo "sley fix: run 'git add <one-of-the-listed-files>' to stage formatting changes." >&2
    fi
  fi
  if [[ "${#_SLEY_FIX_FAILED[@]}" -gt 0 ]]; then
    echo "sley fix: formatter failed for:" >&2
    printf '  %s\n' "${_SLEY_FIX_FAILED[@]}" >&2
    return 1
  fi
  if [[ "$unavailable" -eq 1 ]]; then
    _sley_die "formatter unavailable"
    return 2
  fi
}

_sley_check() {
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?
  local files runnable checked_count
  files=$(_sley_selected_files) || return 2
  _sley_warn_out_of_scope "$files"
  runnable=$(printf '%s\n' "$files" | _repo_existing_regular_files)
  if [[ -z "$runnable" ]]; then
    echo "sley check: no matching changed files" >&2
    return 0
  fi
  checked_count=$(_sley_count_file_list "$runnable")

  SLEY_CALLER="${SLEY_CALLER:-human}"
  # shellcheck disable=SC2034 # consumed by sourced local extensions.
  SLEY_SCOPED=1
  # `sley check` owns the scoped file list. Extensions may swap in repo-local
  # lint/validate behavior, but must preserve this sley-selected scope when the
  # scoped flag is set; hooks can still use their faster hook defaults.
  sley_hook_init || return $?
  sley_hook_lint "$runnable"
  case $? in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  if [[ "$_SLEY_SCOPE_REPO_WIDE" == "1" || "${#_SLEY_SCOPE_PATHS[@]}" -eq 0 ]]; then
    # Explicit --path scopes promise isolation. Some repo validators are
    # change-wide and cannot honor a file list, so skip them rather than letting
    # out-of-scope files block a scoped check.
    # shellcheck disable=SC2119 # validate is a no-arg lifecycle hook.
    sley_hook_validate || return 1
  fi
  _sley_print_file_summary "sley check: checked" "$checked_count"
}

_sley_secrets_default_jobs() {
  local cores
  if command -v getconf >/dev/null 2>&1; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4\n')
  elif command -v sysctl >/dev/null 2>&1; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null || printf '4\n')
  else
    cores=4
  fi
  case "$cores" in
    '' | *[!0-9]*) cores=4 ;;
  esac
  if [[ "$cores" -gt 8 ]]; then
    printf '8\n'
  elif [[ "$cores" -lt 1 ]]; then
    printf '1\n'
  else
    printf '%s\n' "$cores"
  fi
}

_sley_gitleaks_args() {
  _SLEY_GITLEAKS_ARGS=(--redact --no-banner)
  if [[ -f "$_REPO_ROOT/.gitleaks.toml" ]]; then
    _SLEY_GITLEAKS_ARGS+=(--config "$_REPO_ROOT/.gitleaks.toml")
  fi
}

# Existing, validated extra gitleaks config paths (one per line) from the
# secrets extension hook. Extensions are sourced here so a standalone
# `sley secrets` sees an overlay override even without a `sley ready` parent
# (re-sourcing under `sley ready` is idempotent). Missing files are dropped so a
# stale override can never abort the scan.
_sley_secrets_extra_config_list() {
  local extension_dir="$1" cfg
  _sley_source_extensions_from "$extension_dir"
  while IFS= read -r cfg; do
    [[ -n "$cfg" && -f "$cfg" ]] && printf '%s\n' "$cfg"
  done < <(_sley_hook_secrets_extra_configs 2>/dev/null || true)
}

# One independent gitleaks pass over an extra config, applied to the same inputs
# as the base scan: the staged diff (git) plus each worktree file. `--verbose`
# keeps failures actionable — with `--redact` the value stays hidden but the
# RuleID is shown, which matters for rules whose whole point is naming what was
# found. MAX-preserves rc so a later leak (rc=1) cannot mask a scanner error.
_sley_secrets_scan_extra_config() {
  local cfg="$1" staged_files="$2"
  shift 2
  local -a wfiles=("$@")
  local -a args=(--redact --no-banner --verbose --config "$cfg")
  # Declare _SLEY_ARRAY locally per the _sley_to_array contract so the staged
  # file list does not leak into or clobber the caller's scope.
  local -a _SLEY_ARRAY=()
  local rc=0 scan_rc out file
  if [[ -n "$staged_files" ]]; then
    _sley_to_array "$staged_files"
    if out=$(
      (
        set -o pipefail
        git diff --cached -- "${_SLEY_ARRAY[@]}" | gitleaks stdin "${args[@]}"
      ) 2>&1
    ); then
      scan_rc=0
    else
      scan_rc=$?
      [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    fi
    [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  fi
  if [[ "${#wfiles[@]}" -gt 0 ]]; then
    for file in "${wfiles[@]}"; do
      [[ -n "$file" ]] || continue
      if out=$(gitleaks dir "${args[@]}" -- "$file" </dev/null 2>&1); then
        scan_rc=0
      else
        scan_rc=$?
        [[ -n "$out" ]] && printf '%s\n' "$out" >&2
      fi
      [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
    done
  fi
  return "$rc"
}

# Scan a blob of text (via stdin) through one gitleaks invocation. Used by the
# commit-message path. Surfaces gitleaks output on failure and returns its rc.
_sley_gitleaks_scan_text() {
  local text="$1"
  shift
  local out scan_rc=0
  # gitleaks is last in the pipe, so the command-substitution rc is its rc.
  # Capture via `|| scan_rc=$?` (not `if ...; then`, whose false-no-else branch
  # resets $? to 0 and would swallow a "leaks found" exit).
  out=$(printf '%s\n' "$text" | gitleaks stdin "$@" 2>&1) || scan_rc=$?
  [[ "$scan_rc" -ne 0 && -n "$out" ]] && printf '%s\n' "$out" >&2
  return "$scan_rc"
}

# Prepare a commit message for scanning. Only the `commit -v` scissors region
# (`# ... >8 ...` and everything after) is removed — Git always strips that, and
# its diff is already covered by the staged-content scan. Comment (`#`) lines are
# deliberately KEPT: Git's non-interactive cleanup (`git commit -m`/`-F`, and the
# message a `commit-msg` hook receives) is `whitespace`, which commits `#` lines
# verbatim — so stripping them would let a secret on a committed `#` line slip
# the scan (a fail-open). Scanning the retained comments of an editor commit
# (where Git would `strip` them) is at worst a rare, safe false positive.
_sley_clean_commit_message() {
  local file="$1"
  sed '/^#.*>8/,$d' "$file"
}

# `sley secrets --message-file <path>`: scan a (to-be-committed) commit message
# for secrets and any extension-provided extra rules. Runs the base config pass
# plus one pass per extra config over the git-cleaned message text.
_sley_secrets_message_file() {
  local msg_file="$1" extension_dir="$2"
  _sley_init_repo || return $?
  command -v gitleaks >/dev/null 2>&1 || {
    _sley_die "gitleaks not found"
    return 2
  }
  [[ -r "$msg_file" ]] || {
    _sley_die "message file not readable: $msg_file"
    return 2
  }
  local cleaned
  cleaned=$(_sley_clean_commit_message "$msg_file") || return 2
  # An empty message (after cleanup) has nothing to scan; e.g. an aborted or
  # comment-only buffer. Let the commit proceed — message emptiness is Git's
  # concern, not the secrets gate's.
  [[ -n "$cleaned" ]] || return 0

  local rc=0 scan_rc cfg
  local -a base_args
  _sley_gitleaks_args
  base_args=("${_SLEY_GITLEAKS_ARGS[@]}" --verbose)
  _sley_gitleaks_scan_text "$cleaned" "${base_args[@]}" || scan_rc=$?
  scan_rc=${scan_rc:-0}
  [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  while IFS= read -r cfg; do
    [[ -n "$cfg" ]] || continue
    scan_rc=0
    _sley_gitleaks_scan_text "$cleaned" --redact --no-banner --verbose --config "$cfg" || scan_rc=$?
    [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  done < <(_sley_secrets_extra_config_list "$extension_dir")
  return "$rc"
}

_sley_secrets_replay_scan_output() {
  local path="$1" line=""

  [[ -s "$path" ]] || return 0
  # Keep replay in the sourced parent. Waiting on an unrelated foreground
  # `cat` would defer the parent's terminal-signal trap until that process
  # exits, outside the exact scanner-child cleanup protocol below.
  while IFS= read -r line; do
    [[ "${_sley_secrets_parallel_signal_status:-0}" -eq 0 ]] || return 0
    printf '%s\n' "$line"
  done <"$path"
  [[ "${_sley_secrets_parallel_signal_status:-0}" -eq 0 ]] || return 0
  # `read` returns nonzero for a final unterminated line but still publishes
  # its bytes. Preserve the scanner's original trailing-newline behavior.
  [[ -z "$line" ]] || printf '%s' "$line"
}

_sley_secrets_print_failed_scan_output() {
  local scan_rc="$1" stdout_file="$2" stderr_file="$3"
  [[ "$scan_rc" -eq 0 ]] && return 0
  _sley_secrets_replay_scan_output "$stdout_file"
  _sley_secrets_replay_scan_output "$stderr_file" >&2
}

_sley_secrets_parallel_job_is_active() {
  local expected_pid="$1" job_pid
  while IFS= read -r job_pid; do
    [[ "$job_pid" == "$expected_pid" ]] && return 0
  done < <(
    # Sley is sourced, so ordinary command lookup may select caller functions.
    # Ask Bash's builtin dispatcher for its own job table: only that table can
    # prove the numeric PID is still our exact, unreaped asynchronous child.
    builtin jobs -pr
    builtin jobs -ps
  )
  return 1
}

_sley_secrets_parallel_record_signal() {
  local status="$1" wait_pid="${_sley_secrets_parallel_wait_pid:-}"

  if [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]]; then
    _sley_secrets_parallel_signal_status=$status
  fi
  # A signal can be handled after the guard but before `wait` starts. Wake that
  # exact unreaped Bash job even if its scanner ignores TERM; normal cleanup
  # still gives every other scanner the bounded cooperative TERM grace period.
  if [[ -n "$wait_pid" ]] &&
    _sley_secrets_parallel_job_is_active "$wait_pid"; then
    # Keep the exact-child proof and signal in one shell. A caller-defined
    # `kill` function must not turn cancellation into an unbounded wait.
    builtin kill -KILL "$wait_pid" 2>/dev/null || true
  fi
}

_sley_secrets_parallel_stop_children() {
  local attempt index pid any_running sleep_executable=""

  # Fractional sleep is not a Bash builtin. Resolve the real utility once so a
  # sourced caller's `sleep` function cannot collapse or extend the 250 ms
  # cooperative grace period. If unavailable, skip directly to bounded KILL.
  sleep_executable=$(builtin type -P sleep 2>/dev/null || true)

  # The operation owns only direct scanner children. Keep their unreaped slots
  # active until the exact wait below so a numeric PID cannot be reused between
  # the cooperative TERM and bounded KILL phases.
  for index in "${!_sley_secrets_parallel_pids[@]}"; do
    pid=${_sley_secrets_parallel_pids[$index]}
    [[ -n "$pid" ]] || continue
    if _sley_secrets_parallel_job_is_active "$pid"; then
      builtin kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  for ((attempt = 0; attempt < 25; attempt++)); do
    any_running=0
    for index in "${!_sley_secrets_parallel_pids[@]}"; do
      pid=${_sley_secrets_parallel_pids[$index]}
      [[ -n "$pid" ]] || continue
      if _sley_secrets_parallel_job_is_active "$pid"; then
        any_running=1
        break
      fi
    done
    [[ "$any_running" == 1 ]] || break
    [[ -n "$sleep_executable" ]] || break
    "$sleep_executable" 0.01 || break
  done

  for index in "${!_sley_secrets_parallel_pids[@]}"; do
    pid=${_sley_secrets_parallel_pids[$index]}
    [[ -n "$pid" ]] || continue
    if _sley_secrets_parallel_job_is_active "$pid"; then
      builtin kill -KILL "$pid" 2>/dev/null || true
    fi
    # Reap through Bash itself; an external process cannot wait for this
    # shell's child, and a caller function could falsely claim it did.
    builtin wait "$pid" 2>/dev/null || true
    _sley_secrets_parallel_pids[index]=""
  done
}

_sley_secrets_parallel_remove_files() {
  local rc=0 rm_executable="${_sley_secrets_parallel_rm:-}"
  if [[ "${#_sley_secrets_parallel_output_files[@]}" -gt 0 ]]; then
    # `command rm` is insufficient in a sourced library because callers may
    # define a function named `command` too. Pin the real utility before use so
    # no caller function can claim success while secret output remains.
    [[ -n "$rm_executable" ]] ||
      rm_executable=$(builtin type -P rm 2>/dev/null) || return 1
    "$rm_executable" -f -- "${_sley_secrets_parallel_output_files[@]}" || rc=$?
    [[ "$rc" -ne 0 ]] || _sley_secrets_parallel_output_files=()
  fi
  return "$rc"
}

_sley_secrets_parallel_remove_output() {
  local path rc=0 rmdir_executable="${_sley_secrets_parallel_rmdir:-}"

  _sley_secrets_parallel_remove_files || rc=$?
  # Remove only empty directories after their exact output files are gone. If
  # anything foreign appeared, rmdir fails closed instead of recursively
  # deleting content that this operation did not create.
  if [[ "$rc" -eq 0 && "${#_sley_secrets_parallel_output_dirs[@]}" -gt 0 ]]; then
    for path in "${_sley_secrets_parallel_output_dirs[@]}"; do
      # Match file removal's sourced-shell boundary. Resolve only when needed
      # so direct helper tests retain the same contract as the full operation.
      [[ -n "$rmdir_executable" ]] ||
        rmdir_executable=$(builtin type -P rmdir 2>/dev/null) || return 1
      "$rmdir_executable" "$path" || rc=$?
    done
    [[ "$rc" -ne 0 ]] || _sley_secrets_parallel_output_dirs=()
  fi

  return "$rc"
}

_sley_secrets_parallel_create_directory() {
  local path="$1" mkdir_executable="${_sley_secrets_parallel_mkdir:-}"
  local allocator_pid="" allocator_read_fd="" allocator_write_fd=""
  local rc=1 status_received=0
  local -a _sley_secrets_allocator=()
  local _sley_secrets_allocator_PID=""

  [[ -n "$mkdir_executable" ]] ||
    mkdir_executable=$(type -P mkdir 2>/dev/null) || return 1
  # The child installs ignored dispositions before invoking mkdir, so a
  # terminal-group signal either arrives before any filesystem operation or is
  # ignored until exclusive directory creation completes. Launch it as an
  # asynchronous coprocess so interactive Bash keeps the parent as the
  # terminal's foreground receiver; a real Ctrl-C can then latch cancellation
  # instead of being swallowed by the signal-ignoring allocator process group.
  #
  # The pipe is also the authoritative completion channel. Bash versions do
  # not agree on whether a second `wait` after an interrupted first wait yields
  # the child's eventual status or repeats the synthetic signal status. Worse,
  # a real child status such as 130 is numerically indistinguishable from that
  # synthetic status. Publishing mkdir's result before the child exits makes
  # ownership independent of those wait semantics. The acknowledgement keeps
  # the named coprocess alive until its local descriptors and exact PID have
  # been copied, avoiding Bash's fast-exit coprocess-variable race.
  {
    coproc _sley_secrets_allocator {
      local allocator_rc=0

      builtin trap '' HUP INT TERM
      if "$mkdir_executable" -m 700 -- "$path" >/dev/null 2>&1; then
        allocator_rc=0
      else
        allocator_rc=$?
      fi
      builtin printf '%s\n' "$allocator_rc"
      IFS= builtin read -r _ || true
      builtin exit "$allocator_rc"
    }
    allocator_pid=${_sley_secrets_allocator_PID:-}
    allocator_read_fd=${_sley_secrets_allocator[0]:-}
    allocator_write_fd=${_sley_secrets_allocator[1]:-}
  } 2>/dev/null
  [[ -n "$allocator_pid" && -n "$allocator_read_fd" &&
    -n "$allocator_write_fd" ]] || return 1

  # A terminal signal can interrupt the parent's builtin read, but it cannot
  # consume the line already buffered in the pipe. Retry only while the exact
  # coprocess remains active; EOF without a published result is a hard failure.
  while :; do
    if IFS= builtin read -r rc <&"$allocator_read_fd"; then
      status_received=1
      break
    fi
    _sley_secrets_parallel_job_is_active "$allocator_pid" || break
  done

  if [[ "$status_received" -eq 1 ]]; then
    { builtin printf 'received\n' >&"$allocator_write_fd"; } 2>/dev/null || true
  fi
  # The pipe result above decides ownership, and the acknowledgement releases
  # the child directly into exit. Wait exactly once while its PID still names
  # our unreaped child. After any wait can reap it, polling `jobs` by that
  # numeric value loses the identity guarantee: another asynchronous helper or
  # stale platform job-table entry can claim the same value and keep a retry
  # loop alive forever. An interrupted wait cannot alter the published mkdir
  # result, and the acknowledged child no longer has work left to abandon.
  builtin wait "$allocator_pid" 2>/dev/null || true

  [[ "$status_received" -eq 1 ]] || return 1
  case "$rc" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [[ "$rc" -le 255 ]] || return 1
  return "$rc"
}

_sley_secrets_parallel_create_output_files() {
  local path="$1" output_count="$2" old_umask="" output=""
  local index stream rc=0

  # Create and record each output while the parent owns the directory. If a
  # later open or signal aborts setup, cleanup still has every path Sley made
  # and can use exact unlink/rmdir operations instead of recursive deletion.
  # Keep those files private independently of the caller's umask.
  old_umask=$(builtin umask) || return 1
  builtin umask 077 || return 1
  for ((index = 0; index < output_count; index++)); do
    for stream in stdout stderr; do
      output="$path/$stream.$index"
      if : >"$output"; then
        _sley_secrets_parallel_output_files+=("$output")
      else
        rc=1
        break 2
      fi
    done
  done
  builtin umask "$old_umask" || rc=1
  return "$rc"
}

_sley_secrets_parallel_allocate_directory() {
  local output_name="$1" stem="$2" output_count="${3:-1}"
  local path="" attempt=0

  # Choose the final path in the parent before the signal-ignoring child runs.
  # That removes a child-output publication gap: after mkdir succeeds, the
  # parent already knows the only path it may claim. Record the directory
  # before consulting the signal latch or creating files so every later return
  # leaves an exact cleanup ledger.
  printf -v "$output_name" '%s' ""
  while ((attempt < 20)); do
    path="$stem.${BASHPID:-$$}.$RANDOM.$RANDOM.$attempt"
    if _sley_secrets_parallel_create_directory "$path"; then
      _sley_secrets_parallel_output_dirs+=("$path")
      [[ "${_sley_secrets_parallel_signal_status:-0}" -eq 0 ]] || return 1
      _sley_secrets_parallel_create_output_files "$path" "$output_count" || return 1
      printf -v "$output_name" '%s' "$path"
      return 0
    fi
    [[ "${_sley_secrets_parallel_signal_status:-0}" -eq 0 ]] || return 1
    # Retry only a genuine name collision. A failed mkdir with no path left
    # behind is an allocator failure, not a reason to hide the error in a loop.
    [[ -e "$path" || -L "$path" ]] || return 1
    attempt=$((attempt + 1))
  done

  return 1
}

_sley_secrets_scan_batch() {
  local gitleaks_executable="$1"
  local combine_diagnostics="$2"
  shift 2
  local rc=0 scan_rc file stdout_file stderr_file pid index offset
  local -a files=("$@")
  local -a gitleaks_args
  _sley_gitleaks_args
  gitleaks_args=("${_SLEY_GITLEAKS_ARGS[@]}")

  _sley_secrets_parallel_pids=()
  # The allocator creates one output pair per concurrent slot, not per file.
  # This function waits the entire wave before returning, so the serial outer
  # loop can safely reuse each offset without retaining a second path ledger.
  for offset in "${!files[@]}"; do
    [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || return 0
    index=$offset
    file=${files[$offset]}
    stdout_file="$_sley_secrets_parallel_scratch_dir/stdout.$offset"
    stderr_file="$_sley_secrets_parallel_scratch_dir/stderr.$offset"
    [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || return 0

    # Interactive Bash writes `[job] PID` for the asynchronous syntax itself,
    # independently of the child's stderr redirect and even with `set +m`.
    # Contain only that shell bookkeeping while publishing `$!` in the same
    # parent shell. The historical sequential paths merged both scanner streams
    # to stderr; preserve that contract while parallel scans retain distinct,
    # file-ordered stdout/stderr replay.
    {
      if [[ "$combine_diagnostics" == 1 ]]; then
        "$gitleaks_executable" dir "${gitleaks_args[@]}" -- "$file" </dev/null \
          >|"$stderr_file" 2>&1 &
      else
        "$gitleaks_executable" dir "${gitleaks_args[@]}" -- "$file" </dev/null \
          >|"$stdout_file" 2>|"$stderr_file" &
      fi
      pid=$!
    } 2>/dev/null
    _sley_secrets_parallel_pids[index]=$pid
    [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || return 0
  done

  for offset in "${!files[@]}"; do
    index=$offset
    pid=${_sley_secrets_parallel_pids[$index]}
    stdout_file="$_sley_secrets_parallel_scratch_dir/stdout.$offset"
    stderr_file="$_sley_secrets_parallel_scratch_dir/stderr.$offset"
    _sley_secrets_parallel_wait_pid=$pid
    if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
      _sley_secrets_parallel_wait_pid=""
      return 0
    fi
    # Select Bash's wait builtin explicitly. The library shares its namespace
    # with the caller, and a same-named function must not clear PID ownership
    # while the exact scanner child is still running.
    # A signal can kill the job at the instruction boundary immediately before
    # wait. Bash may then print its asynchronous "Killed" bookkeeping while
    # returning the child's status; the status is the API, not shell job noise.
    if builtin wait "$pid" 2>/dev/null; then
      scan_rc=0
    else
      scan_rc=$?
    fi
    _sley_secrets_parallel_wait_pid=""
    if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
      # The signal handler KILLs only this exact unreaped Bash job. Finish its
      # PID-specific wait directly instead of consulting `jobs` after the kill:
      # that consultation makes Bash print its own "Killed" status on stderr.
      # An already-completed child is also safe here because the first wait has
      # reaped it, and a second wait merely reports that no such child remains.
      builtin wait "$pid" 2>/dev/null || true
      _sley_secrets_parallel_pids[index]=""
      return 0
    fi
    _sley_secrets_parallel_pids[index]=""
    _sley_secrets_print_failed_scan_output "$scan_rc" "$stdout_file" "$stderr_file"
    [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || return 0
    # Preserve the MAX exit code across batch members. gitleaks's exit-code
    # protocol overloads severity onto the numeric value (1 = leaks found,
    # ≥2 = scanner / IO error). Last-non-zero-wins would let a later
    # "leaks found" (rc=1) silently downgrade an earlier "scanner failed"
    # (rc≥2) and ship a green secrets verdict on a half-broken scan. The
    # same max-preserve discipline is applied in
    # `_sley_secrets_scan_worktree_files` and matches `_sley_ready`'s
    # global-severity aggregation.
    [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  done

  return "$rc"
}

_sley_secrets_scan_worktree_files() {
  local cancellation_output_name=""
  # Scanner failures may use the same numeric statuses as shell signals. Keep
  # parent cancellation on a separate output channel so callers do not infer
  # control flow from an ordinary scanner exit code.
  if [[ "${1:-}" == --cancellation-output ]]; then
    cancellation_output_name="${2:-}"
    shift 2
    [[ -n "$cancellation_output_name" ]] || return 2
    printf -v "$cancellation_output_name" '%s' 0
  fi
  local rc=0 jobs scratch_slots start scan_rc remove_rc combine_diagnostics=0
  local gitleaks_type gitleaks_executable
  local _sley_secrets_parallel_signal_status=0
  local _sley_secrets_parallel_saved_hup=""
  local _sley_secrets_parallel_saved_int=""
  local _sley_secrets_parallel_saved_term=""
  local _sley_secrets_parallel_wait_pid=""
  local _sley_secrets_parallel_mkdir=""
  local _sley_secrets_parallel_rm=""
  local _sley_secrets_parallel_rmdir=""
  local _sley_secrets_parallel_scratch_dir=""
  local -a files=("$@")
  local -a _sley_secrets_parallel_pids=()
  local -a _sley_secrets_parallel_output_files=()
  local -a _sley_secrets_parallel_output_dirs=()
  [[ "${#files[@]}" -eq 0 ]] && return 0
  jobs=${SLEY_SECRETS_JOBS:-$(_sley_secrets_default_jobs)}
  case "$jobs" in
    '' | *[!0-9]*) jobs=1 ;;
  esac
  [[ "$jobs" -lt 1 ]] && jobs=1

  gitleaks_type=$(type -t gitleaks 2>/dev/null || true)
  if [[ "$gitleaks_type" == function ]]; then
    # A function cannot be resolved to an executable, but it can run as an
    # exact background child in Bash. Force one-at-a-time waves to preserve
    # the compatibility path's sequential semantics while giving it the same
    # signal latch, PID ownership, and scratch cleanup as executable scans.
    gitleaks_executable=gitleaks
    jobs=1
    combine_diagnostics=1
  elif [[ "$gitleaks_type" == file ]]; then
    if ! gitleaks_executable=$(type -P gitleaks 2>/dev/null); then
      _sley_die "unable to resolve gitleaks executable"
      return 2
    fi
    [[ "$gitleaks_executable" == /* ]] || gitleaks_executable="$PWD/$gitleaks_executable"
  else
    _sley_die "unable to resolve supported gitleaks command"
    return 2
  fi
  # Before cancellation hardening, an explicit one-job scan used command
  # substitution with `2>&1` and surfaced every failure diagnostic on stderr in
  # authored cross-stream order. Keep that compatibility behavior; only true
  # parallel waves use the split-descriptor replay contract.
  [[ "$jobs" -ne 1 ]] || combine_diagnostics=1

  # Every worktree scan, including a configured one-job wave, now uses the
  # cancellable ownership protocol. Resolve the filesystem primitives up front
  # and fail before launching a scanner if exact cleanup cannot be guaranteed.
  _sley_secrets_parallel_mkdir=$(builtin type -P mkdir 2>/dev/null || true)
  _sley_secrets_parallel_rm=$(builtin type -P rm 2>/dev/null || true)
  _sley_secrets_parallel_rmdir=$(builtin type -P rmdir 2>/dev/null || true)
  if [[ -z "$_sley_secrets_parallel_mkdir" ||
    -z "$_sley_secrets_parallel_rm" ||
    -z "$_sley_secrets_parallel_rmdir" ]]; then
    _sley_die "unable to resolve secret scan scratch utilities"
    return 2
  fi
  scratch_slots=$jobs
  [[ "$scratch_slots" -le "${#files[@]}" ]] || scratch_slots=${#files[@]}

  # `gitleaks dir <single-file>` has high process startup overhead compared
  # with the bytes scanned. Overlap independent worktree scans, but collect
  # output in file order so the human `ready` report stays deterministic. A
  # single operation-scoped signal latch owns every wave: handlers only
  # record the first signal, while normal control flow reaps exact scanner
  # PIDs and removes exact temp paths before restoring caller traps.
  _sley_secrets_parallel_saved_hup=$(trap -p HUP)
  _sley_secrets_parallel_saved_int=$(trap -p INT)
  _sley_secrets_parallel_saved_term=$(trap -p TERM)
  # `jobs` is used only to prove that the wait PID is still an exact unreaped
  # child before the handler wakes it. Bash can flush a completed job status
  # while answering that query, so contain that shell-owned diagnostic inside
  # the handler rather than leaking it through this sourced API.
  trap '_sley_secrets_parallel_record_signal 129 2>/dev/null' HUP
  trap '_sley_secrets_parallel_record_signal 130 2>/dev/null' INT
  trap '_sley_secrets_parallel_record_signal 143 2>/dev/null' TERM

  if ! _sley_secrets_parallel_allocate_directory \
    _sley_secrets_parallel_scratch_dir "${TMPDIR:-/tmp}/sley-secrets" "$scratch_slots"; then
    rc=2
    if [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]]; then
      _sley_die "unable to allocate secret scan scratch under ${TMPDIR:-/tmp}"
    fi
  else
    for ((start = 0; start < ${#files[@]}; start += jobs)); do
      [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || break
      # Reset per-batch rc so the previous iteration's value cannot leak in
      # when the current batch passes cleanly. Then promote to `rc` only if
      # the batch was worse than what we've seen so far — same severity
      # protocol as the single-job path above.
      scan_rc=0
      _sley_secrets_scan_batch \
        "$gitleaks_executable" "$combine_diagnostics" \
        "${files[@]:start:jobs}" || scan_rc=$?
      [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || break
      [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
    done
  fi

  # Once a signal is latched, ignore repeated delivery while bounded cleanup
  # runs. With no signal yet, retain the latch handlers through cleanup so the
  # first HUP/INT/TERM cannot disappear in this final ownership window.
  if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
    trap '' HUP INT TERM
  fi
  if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
    # Establish stderr containment before TERM/KILL changes job state. A later
    # `jobs` probe otherwise makes Bash emit asynchronous status text even
    # with monitor mode disabled (and more visibly for `set -m` callers).
    _sley_secrets_parallel_stop_children 2>/dev/null
  fi
  if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
    trap '' HUP INT TERM
  fi
  remove_rc=0
  _sley_secrets_parallel_remove_output || remove_rc=$?
  if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
    trap '' HUP INT TERM
    # A terminal-group signal may have interrupted the first rm before Bash
    # ran the latch handler. Retry exact owned paths with repeats ignored.
    if [[ "$remove_rc" -ne 0 ]]; then
      remove_rc=0
      _sley_secrets_parallel_remove_output || remove_rc=$?
    fi
  fi

  # Do not base the final ownership decision on a signal value sampled before
  # removal. TERM may arrive between that test and the failure branch. The
  # arrays are the authoritative ledger: if either still owns a path, always
  # name the retained private scratch, preserve cancellation's 128+signal
  # status when present, and otherwise fail the secrets verdict closed.
  if [[ "${#_sley_secrets_parallel_output_files[@]}" -gt 0 ||
    "${#_sley_secrets_parallel_output_dirs[@]}" -gt 0 ]]; then
    [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]] || trap '' HUP INT TERM
    _sley_die "unable to remove secret scan scratch: ${_sley_secrets_parallel_output_dirs[0]:-unknown}" || true
    if [[ "$_sley_secrets_parallel_signal_status" -eq 0 ]]; then
      # Never report a clean secrets verdict while owned output remains.
      # Preserve unexpected foreign content for inspection rather than
      # recursively deleting anything outside the operation's exact ledger.
      [[ "$rc" -ge 2 ]] || rc=2
    fi
  elif [[ "$remove_rc" -ne 0 ]]; then
    # A helper that reports failure after clearing the exact ownership ledger
    # is still an operational error, but there is no retained path to name.
    [[ "$rc" -ge 2 ]] || rc=2
  fi

  eval "${_sley_secrets_parallel_saved_hup:-trap - HUP}"
  eval "${_sley_secrets_parallel_saved_int:-trap - INT}"
  eval "${_sley_secrets_parallel_saved_term:-trap - TERM}"

  if [[ "$_sley_secrets_parallel_signal_status" -ne 0 ]]; then
    [[ -z "$cancellation_output_name" ]] ||
      printf -v "$cancellation_output_name" '%s' 1
    return "$_sley_secrets_parallel_signal_status"
  fi

  return "$rc"
}

_sley_secrets() {
  local extension_dir
  _sley_extension_dir extension_dir || return $?

  # Commit-message scan mode: `sley secrets --message-file <path>`. Handled
  # before scope parsing since it takes a file, not a change/path scope.
  if [[ "${1:-}" == "--message-file" ]]; then
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
      _sley_die "--message-file requires an argument"
      return 2
    fi
    _sley_secrets_message_file "$2" "$extension_dir"
    return $?
  fi
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?
  local files runnable staged_files file rc=0 out scan_rc worktree_cancelled=0
  local -a worktree_files=()
  declare -A _scanned_set=()
  files=$(_sley_selected_files) || return 2
  _sley_warn_out_of_scope "$files"
  runnable=$(printf '%s\n' "$files" | _repo_existing_regular_files)
  staged_files=""
  if [[ "$_REPO_TYPE" == "git" ]]; then
    staged_files=$(_sley_git_staged_selected_files "$files")
  fi
  if [[ -z "$runnable" && -z "$staged_files" ]]; then
    echo "sley secrets: no matching changed files" >&2
    return 0
  fi
  command -v gitleaks >/dev/null 2>&1 || {
    _sley_die "gitleaks not found"
    return 2
  }
  local -a gitleaks_args
  _sley_gitleaks_args
  gitleaks_args=("${_SLEY_GITLEAKS_ARGS[@]}")
  declare -A _staged_set
  if [[ -n "$staged_files" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] && _staged_set["$file"]=1
    done <<<"$staged_files"
    # Scan staged blobs from the index, not the worktree. The staged version
    # is what would actually commit, so this catches secrets even when the
    # worktree copy was later edited or deleted. Index-staged DELETES are not
    # scanned — `--diff-filter=ACM` excludes them upstream of this code path,
    # and there is no staged blob to read for a deletion.
    # `pipefail` is forced inside a subshell so a `git diff` failure cannot be
    # masked by a clean gitleaks run; the outer rc still captures the result.
    local -a _SLEY_ARRAY
    _sley_to_array "$staged_files"
    for file in "${_SLEY_ARRAY[@]}"; do
      _scanned_set["$file"]=1
    done
    if out=$(
      (
        set -o pipefail
        git diff --cached -- "${_SLEY_ARRAY[@]}" |
          gitleaks stdin "${gitleaks_args[@]}"
      ) 2>&1
    ); then
      scan_rc=0
    else
      scan_rc=$?
    fi
    if [[ "$scan_rc" -ne 0 ]]; then
      [[ -n "$out" ]] && printf '%s\n' "$out" >&2
      # MAX-preserve at the outer aggregator too. The inner functions
      # (`_sley_secrets_scan_batch`, `_sley_secrets_scan_worktree_files`)
      # already preserve max severity inside their own loops, but a higher
      # severity from this staged-blob scan must not be downgraded by a
      # later "leaks found" (rc=1) from the worktree scan below — the very
      # severity-downgrade bug the inner fixes claimed to eliminate.
      [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
    fi
  fi
  if [[ "$_SLEY_SCOPE_CHANGE" != "staged" ]]; then
    # Path-scoped and non-staged scans intentionally use selected worktree
    # files rather than a broad repository scan, preserving monorepo safety.
    # When the worktree content matches the staged blob exactly, the staged
    # scan above already covered the file — skip the redundant worktree pass
    # for the common case where staged == worktree.
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if [[ "$_REPO_TYPE" == "git" && -n "${_staged_set[$file]:-}" ]] &&
        git diff --quiet -- "$file" 2>/dev/null; then
        continue
      fi
      worktree_files+=("$file")
      _scanned_set["$file"]=1
    done <<<"$runnable"
  elif [[ "$_SLEY_SCOPE_INCLUDE_UNTRACKED" == "1" ]]; then
    # `--commit --include-untracked` in Git: commit scope maps to staged
    # changes, and `_repo_changed_names("staged", 1)` added
    # untracked files to `runnable`, but the staged-blob scan above only ran
    # over the index — untracked files have no index entry, so they were
    # silently skipped. Run a worktree pass over the untracked subset so the
    # documented secret-scan gate covers them. Files already in `_staged_set`
    # were scanned via the index path; skip them here.
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      [[ -n "${_staged_set[$file]:-}" ]] && continue
      worktree_files+=("$file")
      _scanned_set["$file"]=1
    done <<<"$runnable"
  fi
  # MAX-preserve across the staged-blob scan above and the worktree scan
  # here. Reset `scan_rc` first so a successful worktree scan can't inherit
  # a stale value from the staged path; then promote to `rc` only when the
  # worktree result is strictly worse. Mirrors the per-batch discipline
  # inside `_sley_secrets_scan_worktree_files` itself.
  scan_rc=0
  _sley_secrets_scan_worktree_files \
    --cancellation-output worktree_cancelled "${worktree_files[@]}" || scan_rc=$?
  [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  # A parallel scan restores the caller's traps before returning. Its explicit
  # cancellation bit, rather than the overloaded scanner status, decides
  # whether an extension pass may start after the base scan.
  [[ "$worktree_cancelled" -eq 0 ]] || return "$scan_rc"
  # Extra secrets configs: independent gitleaks passes (e.g. an overlay's
  # forbidden-vocabulary rules) over the same staged + worktree inputs. Base
  # sley returns none, so this is a no-op unless an extension opts in.
  local _cfg
  while IFS= read -r _cfg; do
    [[ -n "$_cfg" ]] || continue
    scan_rc=0
    _sley_secrets_scan_extra_config "$_cfg" "$staged_files" "${worktree_files[@]}" || scan_rc=$?
    [[ "$scan_rc" -gt "$rc" ]] && rc=$scan_rc
  done < <(_sley_secrets_extra_config_list "$extension_dir")
  if [[ "$rc" -eq 0 ]]; then
    _sley_print_file_summary "sley secrets: scanned" "${#_scanned_set[@]}"
  fi
  return "$rc"
}

_sley_hook_usage() {
  cat >&2 <<'EOF'
Usage: sley hook COMMAND [ARGS]

Commands:
  changed-files          list hook-selected files
  format-file FILE       format one file
  lint-file [ARGS...]    lint one file, passing ARGS through
  format --stdin         format newline-separated files from stdin
  lint --stdin           lint newline-separated files from stdin
  validate               run repo-specific hook validation
EOF
}

_sley_hook_cd_for_absolute_file_arg() {
  local last="${*: -1}" dir
  [[ $# -gt 0 ]] || return 2
  # Editor integrations often pass an absolute buffer path while their process
  # cwd may be outside the edited repo. In that case, enter the file directory
  # before hook init so repo detection and local hook overrides resolve against
  # the buffer's repo. Relative paths already carry caller intent, so leave both
  # cwd and args untouched to preserve normal CLI pass-through behavior.
  case "$last" in
    /*) ;;
    *) return 0 ;;
  esac
  dir=$(dirname "$last")
  [[ -d "$dir" ]] || return 0
  cd "$dir" || return 0
}

_sley_hook() {
  local cmd="${1:-}" files
  [[ -n "$cmd" ]] || {
    _sley_hook_usage
    return 2
  }
  shift || true

  SLEY_CALLER="${SLEY_CALLER:-cli}"

  case "$cmd" in
    changed-files)
      sley_hook_init || return $?
      sley_hook_changed_files
      ;;
    format-file)
      [[ $# -ge 1 ]] || {
        _sley_die "hook format-file requires a file"
        return 2
      }
      _sley_hook_cd_for_absolute_file_arg "$@" || return $?
      sley_hook_init || return $?
      sley_hook_format_file "$@"
      ;;
    lint-file)
      [[ $# -ge 1 ]] || {
        _sley_die "hook lint-file requires arguments"
        return 2
      }
      _sley_hook_cd_for_absolute_file_arg "$@" || return $?
      sley_hook_init || return $?
      sley_hook_lint_file "$@"
      ;;
    format)
      [[ "${1:-}" == "--stdin" ]] || {
        _sley_die "hook format supports only --stdin"
        return 2
      }
      files=$(cat)
      sley_hook_init || return $?
      sley_hook_format "$files"
      ;;
    lint)
      [[ "${1:-}" == "--stdin" ]] || {
        _sley_die "hook lint supports only --stdin"
        return 2
      }
      files=$(cat)
      sley_hook_init || return $?
      sley_hook_lint "$files"
      ;;
    validate)
      sley_hook_init || return $?
      sley_hook_validate
      ;;
    -h | --help | help)
      _sley_hook_usage
      ;;
    *)
      _sley_die "unknown hook command: $cmd"
      return 2
      ;;
  esac
}

_sley_main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || {
    _sley_usage
    return 0
  }
  shift || true

  case "$cmd" in
    status) sley_status "$@" ;;
    changes) sley_changes "$@" ;;
    fix) sley_fix "$@" ;;
    check) sley_check "$@" ;;
    secrets) sley_secrets "$@" ;;
    verify) sley_verify "$@" ;;
    ready) sley_ready "$@" ;;
    hook) sley_hook "$@" ;;
    -h | --help | help) _sley_usage ;;
    *)
      _sley_die "unknown command: $cmd"
      return 2
      ;;
  esac
}
