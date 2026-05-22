#!/usr/bin/env bash
# scope.sh — scope parsing and changed-file selection for sley.
#
# Scope is the core safety contract for large repos: command callers choose
# "which changed files?" separately from "which subtree?". Keeping that logic
# isolated makes it harder for future commands to accidentally walk a monorepo.

_sley_parse_scope() {
  local change_scope_count=0
  # Change scope and path scope are deliberately separate. This keeps
  # large-repo root usage safe: "which files changed?" is derived from VCS
  # state, while "which part of the repo?" is opt-in via --path/--repo-wide.
  _SLEY_SCOPE_JSON=0
  _SLEY_SCOPE_CHANGE="changed"
  _SLEY_SCOPE_INCLUDE_UNTRACKED=0
  _SLEY_SCOPE_REPO_WIDE=0
  _SLEY_SCOPE_PATHS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        _SLEY_SCOPE_JSON=1
        shift
        ;;
      --commit)
        change_scope_count=$((change_scope_count + 1))
        case "$_REPO_TYPE" in
          git) _SLEY_SCOPE_CHANGE="staged" ;;
          sl) _SLEY_SCOPE_CHANGE="pending" ;;
          *)
            _sley_die "unsupported repo type for commit scope"
            return 2
            ;;
        esac
        shift
        ;;
      --include-untracked)
        _SLEY_SCOPE_INCLUDE_UNTRACKED=1
        shift
        ;;
      --repo-wide)
        _SLEY_SCOPE_REPO_WIDE=1
        shift
        ;;
      --path)
        if [[ $# -lt 2 ]]; then
          _sley_die "--path requires an argument"
          return 2
        fi
        # A flag-shaped argument here is almost certainly a typo (`--path
        # --json`) rather than an intentional path that begins with `-`. Reject
        # to avoid silently consuming a real flag as the path scope.
        case "$2" in
          -?*)
            _sley_die "--path argument looks like a flag: $2 (use ./$2 for paths beginning with '-')"
            return 2
            ;;
        esac
        _SLEY_SCOPE_PATHS+=("$2")
        shift 2
        ;;
      *)
        _sley_die "unknown option: $1"
        return 2
        ;;
    esac
  done

  if [[ "$change_scope_count" -gt 1 ]]; then
    _sley_die "specify only one change scope"
    return 2
  fi

  case "$_REPO_TYPE:$_SLEY_SCOPE_CHANGE" in
    git:pending | sl:staged)
      _sley_die "unsupported change scope '$_SLEY_SCOPE_CHANGE' for $_REPO_TYPE"
      return 2
      ;;
  esac
}

_sley_path_filters() {
  local p rel scoped_path
  # No filters means "active change context only", not "walk the repository".
  # `--repo-wide` widens to all changed files, still never all files.
  [[ "$_SLEY_SCOPE_REPO_WIDE" == "0" ]] || return 0
  for p in "${_SLEY_SCOPE_PATHS[@]}"; do
    case "$p" in
      /*) scoped_path="$p" ;;
      *)
        # Parse explicit path scope relative to the caller's directory, not the
        # repo root we cd into for command execution. That makes `--path .`
        # useful from subprojects while preserving root-safe defaults.
        scoped_path="${_SLEY_CALLER_PWD:-$PWD}/$p"
        ;;
    esac
    rel=$(_repo_relpath_for_existing_dir "$_REPO_ROOT" "$scoped_path")
    case $? in
      0) printf '%s\n' "$rel" ;;
      2)
        _sley_die "--path points outside repo: $p"
        return 2
        ;;
      *)
        _sley_die "--path does not exist: $p"
        return 2
        ;;
    esac
  done
}

_sley_selected_files() {
  local filters rc
  filters=$(_sley_path_filters)
  rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  _sley_selected_files_for_filters "$filters"
}

_sley_selected_files_cache_key() {
  local filters="$1"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "${_REPO_TYPE:-}" \
    "${_REPO_ROOT:-}" \
    "${_SLEY_SCOPE_CHANGE:-}" \
    "${_SLEY_SCOPE_INCLUDE_UNTRACKED:-}" \
    "$filters"
}

_sley_selected_files_for_filters() {
  local filters="$1" files
  # `sley ready` runs phases concurrently. Without a shared snapshot, each
  # phase independently asks the VCS for the same changed-file list; in large
  # Sapling repos that burns seconds and makes phases contend with each other.
  # Reuse only when the full scope key matches so direct commands still query
  # the current repo state.
  if [[ -n "${_SLEY_SELECTED_FILES_CACHE_FILE:-}" &&
    -f "${_SLEY_SELECTED_FILES_CACHE_FILE:-}" &&
    "${_SLEY_SELECTED_FILES_CACHE_KEY:-}" == "$(_sley_selected_files_cache_key "$filters")" ]]; then
    cat "$_SLEY_SELECTED_FILES_CACHE_FILE"
    return 0
  fi
  files=$(_repo_changed_names "$_SLEY_SCOPE_CHANGE" "$_SLEY_SCOPE_INCLUDE_UNTRACKED") || return 2
  # All commands compose from this changed-file stream so mutating operations
  # cannot accidentally rediscover unrelated files by walking a massive repo.
  printf '%s\n' "$files" |
    awk 'NF && !seen[$0]++' |
    _repo_filter_paths "$filters"
}

_sley_select() {
  _sley_init_repo || return $?
  _sley_parse_scope "$@" || return $?

  local filters files
  filters=$(_sley_path_filters) || return $?
  files=$(_sley_selected_files_for_filters "$filters") || return 2

  # Public shell API state. Keep these facts in one documented SLEY_* namespace
  # so integrations consume repo/scope context without reimplementing parsing.
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_REPO_TYPE="$_REPO_TYPE"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_REPO_ROOT="$_REPO_ROOT"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_CHANGE_SCOPE="$_SLEY_SCOPE_CHANGE"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_INCLUDE_UNTRACKED="$_SLEY_SCOPE_INCLUDE_UNTRACKED"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_REPO_WIDE="$_SLEY_SCOPE_REPO_WIDE"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_PATH_SCOPE="$filters"
  # shellcheck disable=SC2034 # public sourced API variables for callers.
  SLEY_SELECTED_FILES="$files"

  [[ -n "$files" ]] && printf '%s\n' "$files"
}

_sley_to_array() {
  # Writes the parsed file list into `_SLEY_ARRAY` via bash dynamic scope.
  # Callers MUST declare `local -a _SLEY_ARRAY` before calling so the array
  # does not leak into the surrounding shell when sley.sh is sourced.
  local files_text="$1" f
  _SLEY_ARRAY=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && _SLEY_ARRAY+=("$f")
  done <<<"$files_text"
}

_sley_warn_out_of_scope() {
  # Optional first arg: the already-computed selected-file list. Callers that
  # have just run `_sley_selected_files` should pass it through to avoid a
  # second VCS pass. With no arg, the warn helper falls back to recomputing.
  local all selected outside
  [[ "$_SLEY_SCOPE_REPO_WIDE" == "0" && "${#_SLEY_SCOPE_PATHS[@]}" -gt 0 ]] || return 0
  all=$(_repo_changed_names "$_SLEY_SCOPE_CHANGE" "$_SLEY_SCOPE_INCLUDE_UNTRACKED") || return 0
  if [[ $# -ge 1 ]]; then
    selected="$1"
  else
    selected=$(_sley_selected_files) || return 0
  fi
  # `comm` requires both inputs sorted in the SAME locale collating order as
  # `comm` itself. Force `LC_ALL=C` for the whole pipeline so a user with a
  # locale like `en_US.UTF-8` (where `sort -u` may treat punctuation
  # differently than the default `comm`) does not produce a misleading
  # out-of-scope count.
  outside=$(LC_ALL=C comm -23 \
    <(LC_ALL=C printf '%s\n' "$all" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(LC_ALL=C printf '%s\n' "$selected" | sed '/^$/d' | LC_ALL=C sort -u) |
    wc -l | tr -d ' ')
  if [[ "$outside" -gt 0 ]]; then
    echo "sley: changed files outside selected path scope: $outside" >&2
  fi
}

_sley_json_files() {
  local files_text="$1" untracked_set="${2:-}"
  local first=1 file esc status tracked exists f
  # Tracked-vs-untracked is derived from the untracked set alone: every file
  # in the change list comes from a VCS-tracked source by construction
  # (`_repo_changed_names` only emits tracked changes for staged/changed/
  # pending scopes), with untracked entries appended only when the caller
  # opted into `--include-untracked`. Computing a separate tracked set would
  # require walking the whole repo manifest (`git ls-files` with no args),
  # which is wasted O(repo) work in monorepos.
  declare -A _is_untracked
  if [[ -n "$untracked_set" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && _is_untracked["$f"]=1
    done <<<"$untracked_set"
  fi
  printf '['
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ "$first" == "1" ]] || printf ','
    first=0
    esc=$(_repo_json_escape "$file")
    # Status is intentionally coarse in v1. The stable part of the JSON
    # contract is path/tracked/exists; callers should not infer exact VCS state
    # from this placeholder until richer statuses are specified.
    status="M"
    tracked=true
    [[ -n "${_is_untracked[$file]:-}" ]] && tracked=false
    [[ -e "$file" ]] && exists=true || exists=false
    printf '{"path":"%s","status":"%s","tracked":%s,"exists":%s}' \
      "$esc" "$status" "$tracked" "$exists"
  done <<<"$files_text"
  printf ']'
}
