#!/usr/bin/env bash
# verify.sh — local verification command discovery for the sley workflow API.
#
# Kept separate from sley.sh so the public API file stays focused on command
# dispatch, scope handling, and hook contracts. `sley verify` owns local check
# discovery and required-check execution; `sley ready` delegates to it instead
# of carrying a separate verification registry.

# Project manifest filenames that map to suggested verify commands. The case in
# _sley_project_manifest_commands owns the per-manifest command vocabulary; this
# is the single list the ancestor-walk and repo-root scans iterate.
_SLEY_MANIFEST_NAMES=(
  package.json pyproject.toml Cargo.toml go.mod
  Makefile makefile justfile Justfile BUCK TARGETS
)

_sley_package_json_commands() {
  local pkg="$1" context="${2:-manifest}" kind cmd
  for kind in test lint build; do
    if command -v jq >/dev/null 2>&1; then
      # Prefer real JSON parsing so normal multi-line package.json files work.
      # The sed fallback keeps discovery usable in stripped-down environments.
      # `--` separates flags from the file path so a top-level directory
      # beginning with `-` (e.g. `-foo/package.json`) is not parsed as a flag.
      cmd=$(jq -r --arg kind "$kind" '.scripts[$kind] // empty' -- "$pkg" 2>/dev/null)
    else
      cmd=$(sed -nE "s/.*\"$kind\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" -- "$pkg" | head -1)
    fi
    [[ -n "$cmd" ]] || continue
    _sley_manifest_command "$cmd" "$pkg" "$kind" "$context"
  done
}

_sley_manifest_command() {
  local command="$1" source="$2" kind="$3" context="${4:-manifest}"
  local esc_source
  esc_source=$(_repo_json_escape "$source")
  printf '{"command":"%s","sources":["%s"],"kind":"%s","required":false,"tier":"suggested","source_contexts":[{"source":"%s","context":"%s"}]}\n' \
    "$(_repo_json_escape "$command")" "$esc_source" "$kind" \
    "$esc_source" "$(_repo_json_escape "$context")"
}

_sley_shell_quote() {
  # Single-quote-wrap a value for safe inclusion in a copy-pasted shell
  # command. Embedded single quotes are escaped via the standard
  # `'\''` sequence so workflow filenames with spaces or quotes survive.
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

_sley_verify_usage() {
  cat <<'EOF'
Usage: sley verify [OPTIONS]

List and run local verification commands for selected changed files.

Execution:
  --run-required       run matching required registry commands
  --full               include slow/full required commands
  --force              rerun commands even when a success receipt exists
  --explain-cache      print cache key inputs and hit/miss decisions
  --cache-stats        print local success receipt cache statistics

Scope:
  default              use active change-context changes
  --commit             use VCS commit-input changes
  --include-untracked  include untracked files in the selected change set
  --repo-wide          consider all changed files in the repo
  --path PATH          restrict selected changed files to PATH
  --json               emit machine-readable output
EOF
}

_sley_make_like_commands() {
  local source="$1" runner="$2" context="${3:-manifest}" target
  for target in test lint format build; do
    grep -Eq "^${target}:" -- "$source" || continue
    _sley_manifest_command "$runner $target" "$source" "$target" "$context"
  done
}

_sley_project_manifest_commands() {
  local source="$1" context="${2:-manifest}" base dir_q
  [[ -f "$source" ]] || return 0
  base=$(basename "$source")
  case "$base" in
    package.json)
      _sley_package_json_commands "$source" "$context"
      ;;
    pyproject.toml)
      # These are conservative hints, not an execution engine. `sley verify`
      # should help humans/agents discover workflow entry points. Formatter,
      # linter, type-checker, and security-analyzer semantics belong to
      # Checkrun or explicit verify registries, not manifest guessing here.
      grep -Eq '\[tool\.pytest|pytest' -- "$source" && _sley_manifest_command "pytest" "$source" test "$context"
      ;;
    Cargo.toml)
      _sley_manifest_command "cargo test" "$source" test "$context"
      _sley_manifest_command "cargo build" "$source" build "$context"
      ;;
    go.mod)
      _sley_manifest_command "go test ./..." "$source" test "$context"
      ;;
    Makefile | makefile)
      _sley_make_like_commands "$source" make "$context"
      ;;
    justfile | Justfile)
      _sley_make_like_commands "$source" just "$context"
      ;;
    BUCK | TARGETS)
      dir_q=$(_sley_shell_quote "$(dirname "$source")")
      _sley_manifest_command "buck2 test ${dir_q}:..." "$source" test "$context"
      ;;
  esac
}

_sley_verify_match() {
  local file="$1" pattern="$2" base="${3:-.}"
  # shellcheck disable=SC2053 # RHS is intentionally a registry glob.
  [[ "$file" == $pattern ]] && return 0
  [[ "$base" == "." ]] && return 1
  # Subtree configs may use either repo-root-relative patterns or patterns
  # relative to the directory containing `.sley`.
  # shellcheck disable=SC2053 # RHS is intentionally a registry glob.
  [[ "$file" == $base/$pattern ]]
}

_sley_verify_config_context() {
  case "$1" in
    repo) printf 'repo-config\n' ;;
    user) printf 'user-config\n' ;;
    *) return 1 ;;
  esac
}

_sley_verify_config_source() {
  case "$1" in
    "$_REPO_ROOT"/*) printf '%s\n' "${1#"$_REPO_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_sley_verify_config_base() {
  local source="$1" context="$2" rel dir
  [[ "$context" == "repo-config" ]] || {
    printf '.\n'
    return
  }
  case "$source" in
    "$_REPO_ROOT"/*)
      rel="${source#"$_REPO_ROOT"/}"
      dir="${rel%/.sley/*}"
      [[ "$dir" == "$rel" ]] && dir="."
      printf '%s\n' "$dir"
      ;;
    *) printf '.\n' ;;
  esac
}

_sley_verify_user_config_files() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}" config

  if [[ -n "${SLEY_VERIFY_CONFIG:-}" ]]; then
    if [[ -f "$SLEY_VERIFY_CONFIG" ]]; then
      printf '%s\n' "$SLEY_VERIFY_CONFIG"
    elif [[ -d "$SLEY_VERIFY_CONFIG" ]]; then
      # User configs are often symlinked from a private config repo. Follow
      # symlinks here so materialized files are first-class registry entries,
      # while dangling links stay ignored.
      find -L "$SLEY_VERIFY_CONFIG" -maxdepth 1 -name '*.json' -type f -print 2>/dev/null | LC_ALL=C sort
    fi
  fi

  config="$xdg/sley/verify.json"
  [[ -f "$config" ]] && printf '%s\n' "$config"
  if [[ -d "$xdg/sley/verify.d" ]]; then
    find -L "$xdg/sley/verify.d" -maxdepth 1 -name '*.json' -type f -print 2>/dev/null | LC_ALL=C sort
  fi
}

_sley_verify_repo_config_files() {
  local files="$1" file dir source
  declare -A _seen_configs

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      */*) dir="${file%/*}" ;;
      *) dir="." ;;
    esac
    while :; do
      for source in "$dir/.sley/verify.json" "$dir/.sley/verify.d"/*.json; do
        [[ -f "$source" ]] || continue
        [[ -n "${_seen_configs[$source]:-}" ]] && continue
        _seen_configs[$source]=1
        if [[ "$source" == ./* ]]; then
          printf '%s/%s\n' "$_REPO_ROOT" "${source#./}"
        else
          printf '%s/%s\n' "$_REPO_ROOT" "$source"
        fi
      done
      [[ "$dir" == "." ]] && break
      case "$dir" in
        */*) dir="${dir%/*}" ;;
        *) dir="." ;;
      esac
    done
  done <<<"$files"
}

_sley_verify_remote() {
  case "$_REPO_TYPE" in
    git) git config --get remote.origin.url 2>/dev/null || true ;;
    *) printf '\n' ;;
  esac
}

_sley_verify_rules_for_config() {
  local config="$1" context="$2" root_name remote
  root_name="${_REPO_ROOT##*/}"
  remote=$(_sley_verify_remote)
  if [[ "$context" == "repo-config" ]]; then
    jq -c '
      if (.rules | type) == "array" then .rules[] | select(.enabled != false)
      elif (.repos | type) == "array" then .repos[]?.rules[]? | select(.enabled != false)
      else empty end
    ' "$config"
  else
    jq -c --arg root "$_REPO_ROOT" --arg name "$root_name" --arg remote "$remote" '
      def has_value($v; $needle):
        if $v == null then false
        elif ($v | type) == "array" then (($v | index($needle)) != null)
        else $v == $needle end;
      def repo_match($m):
        ($m != null) and (
          has_value($m.root; $root) or
          has_value($m.roots; $root) or
          has_value($m.name; $name) or
          has_value($m.names; $name) or
          (($remote | length) > 0 and (
            has_value($m.remote; $remote) or
            has_value($m.remotes; $remote)
          ))
        );
      if (.rules | type) == "array" then .rules[] | select(.enabled != false)
      elif (.repos | type) == "array" then
        .repos[]? | select(repo_match(.match)) | .rules[]? | select(.enabled != false)
      else empty end
    ' "$config"
  fi
}

_sley_verify_validate_config() {
  local config="$1"
  jq -e '
    def keys_in($allowed):
      (keys_unsorted - $allowed) | length == 0;
    def string_or_strings:
      (type == "string" and length > 0) or
      (type == "array" and all(.[]; type == "string" and length > 0));
    def cache_identity:
      type == "object" and
      keys_in(["commands", "env"]) and
      ((.commands? // []) | type == "array") and
      all((.commands? // [])[]; type == "string" and length > 0) and
      ((.env? // []) | type == "array") and
      all((.env? // [])[]; type == "string" and length > 0);
    def cache:
      type == "object" and
      keys_in(["enabled", "salt", "base_policy", "shell", "identity_timeout", "identity"]) and
      ((.enabled? // false) | type == "boolean") and
      ((has("salt") | not) or (.salt | type == "string")) and
      ((has("base_policy") | not) or (.base_policy | IN("upstream-tip", "merge-base", "selected-content"))) and
      ((has("shell") | not) or (.shell | IN("default", "login"))) and
      ((has("identity_timeout") | not) or (.identity_timeout | type == "number" and . >= 1 and floor == .)) and
      ((has("identity") | not) or (.identity | cache_identity));
    def command_item:
      (type == "string" and length > 0) or
      (
        type == "object" and
        keys_in(["cmd", "command", "enabled", "kind", "required", "tier", "cache"]) and
        ((has("cmd") | not) or (.cmd | type == "string" and length > 0)) and
        ((has("command") | not) or (.command | type == "string" and length > 0)) and
        (
          (.enabled? == false) or
          has("cmd") or
          has("command")
        ) and
        ((has("enabled") | not) or (.enabled | type == "boolean")) and
        ((has("kind") | not) or (.kind | type == "string")) and
        ((has("required") | not) or (.required | type == "boolean")) and
        ((has("tier") | not) or (.tier | IN("fast", "slow", "full", "suggested"))) and
        ((has("cache") | not) or (.cache | cache))
      );
    def rule:
      type == "object" and
      keys_in(["enabled", "paths", "commands"]) and
      ((has("enabled") | not) or (.enabled | type == "boolean")) and
      ((.enabled? == false) or (has("commands") and (.commands | type == "array"))) and
      ((has("paths") | not) or (.paths | type == "array" and all(.[]; type == "string"))) and
      ((has("commands") | not) or (.commands | type == "array" and all(.[]; command_item)));
    def repo_match:
      type == "object" and
      length > 0 and
      keys_in(["root", "roots", "name", "names", "remote", "remotes"]) and
      all(.[]; string_or_strings);
    def repo:
      type == "object" and
      keys_in(["match", "rules"]) and
      (.match | repo_match) and
      (.rules | type == "array" and all(.[]; rule));
    type == "object" and
    keys_in(["$schema", "rules", "repos"]) and
    ((has("$schema") | not) or (.["$schema"] | type == "string")) and
    ((has("rules") and (has("repos") | not) and (.rules | type == "array" and all(.[]; rule))) or
     (has("repos") and (has("rules") | not) and (.repos | type == "array" and all(.[]; repo))))
  ' "$config" >/dev/null
}

_sley_verify_registry_commands() {
  local files="$1" configs origin config context source base rules rule matched file pattern
  local -a patterns

  configs=$(
    {
      _sley_verify_repo_config_files "$files" | sed 's/^/repo	/'
      _sley_verify_user_config_files | sed 's/^/user	/'
    } | awk 'NF && !seen[$0]++'
  )
  [[ -n "$configs" ]] || return 0

  command -v jq >/dev/null 2>&1 || {
    echo "sley verify: jq is required for sley verify registry files" >&2
    return 1
  }

  while IFS=$'\t' read -r origin config; do
    [[ -n "$config" ]] || continue
    context=$(_sley_verify_config_context "$origin")
    source=$(_sley_verify_config_source "$config")
    base=$(_sley_verify_config_base "$config" "$context")
    if ! _sley_verify_validate_config "$config" 2>/dev/null; then
      echo "sley verify: invalid verify registry: $source" >&2
      return 1
    fi
    rules=$(_sley_verify_rules_for_config "$config" "$context" 2>/dev/null) || {
      echo "sley verify: invalid verify registry: $source" >&2
      return 1
    }
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      if ! printf '%s' "$rule" | jq -e '
        type == "object" and
        (((.paths // []) | type) == "array") and
        ((.commands // null) | type) == "array"
      ' >/dev/null 2>&1; then
        echo "sley verify: invalid verify registry: $source" >&2
        return 1
      fi
      readarray -t patterns < <(printf '%s' "$rule" | jq -r '.paths[]?')
      [[ "${#patterns[@]}" -gt 0 ]] || patterns=("*")
      matched=0
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        for pattern in "${patterns[@]}"; do
          if _sley_verify_match "$file" "$pattern" "$base"; then
            matched=1
            break 2
          fi
        done
      done <<<"$files"
      [[ "$matched" -eq 1 ]] || continue

      while IFS= read -r command_item; do
        if [[ -z "$command_item" ]] ||
          ! printf '%s' "$command_item" | jq -e '(.command // "") | length > 0' >/dev/null 2>&1; then
          echo "sley verify: invalid verify registry: $source" >&2
          return 1
        fi
        printf '%s\n' "$command_item"
      done < <(
        printf '%s' "$rule" | jq -c --arg source "$source" --arg context "$context" '
          .commands[]? |
          select((type != "object") or (.enabled != false)) |
          if type == "string" then
            {
              "command": .,
              "kind": "test",
              "required": true,
              "tier": "fast"
            }
          elif type == "object" then
            {
              "command": (.cmd // .command // ""),
              "kind": (.kind // "test"),
              "required": (.required // true),
              "tier": (.tier // "fast")
            }
            + (if ((.cache // null) | type) == "object" then {"cache": .cache} else {} end)
          else
            {"command": ""}
          end
          | .required = (.required == true)
          | .sources = [$source]
          | .source_contexts = [{"source": $source, "context": $context}]
        '
      )
    done <<<"$rules"
  done <<<"$configs"
}

_sley_verify_extension_commands() {
  local files="$1" output
  output=$(sley_ext_verify_commands "$files") || {
    echo "sley verify: verification extension command discovery failed" >&2
    return 1
  }
  [[ -n "$output" ]] || return 0

  # Environment extensions emit the same JSON-line command items as registry
  # files. Keep the contract generic here; repo/tool-specific detection belongs
  # in the extension, not in base sley.
  printf '%s\n' "$output"
}

_sley_verify_group_python() {
  # Deduplicating equivalent commands needs an ordered group-by, not a
  # per-line uniq or jq `group_by` sort. Preserve first-discovered command and
  # source order so nearest manifests stay visually ahead of repo-root fallbacks.
  local mode="$1"
  python3 - "$mode" 3<&0 <<'PY'
import json, os, sys
mode = sys.argv[1]
groups = {}
order = []

def tier(current, new):
    order = {"suggested": 0, "fast": 1, "slow": 2, "full": 2}
    current = current or "suggested"
    new = new or current
    return new if order.get(new, 0) > order.get(current, 0) else current

for line in os.fdopen(3):
    line = line.strip()
    if not line:
        continue
    item = json.loads(line)
    cache = item.get("cache")
    key = json.dumps(
        {
            "command": item["command"],
            "kind": item["kind"],
            "cache": cache if isinstance(cache, dict) else None,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    if key not in groups:
        groups[key] = {
            "command": item["command"],
            "kind": item["kind"],
            "required": bool(item.get("required")),
            "tier": item.get("tier") or "suggested",
            "sources": [],
            "source_contexts": [],
        }
        if isinstance(cache, dict):
            groups[key]["cache"] = cache
        order.append(key)
    for src in item.get("sources", []):
        if src not in groups[key]["sources"]:
            groups[key]["sources"].append(src)
    for ctx in item.get("source_contexts", []):
        marker = (ctx.get("source"), ctx.get("context"))
        if marker not in [
            (existing.get("source"), existing.get("context"))
            for existing in groups[key]["source_contexts"]
        ]:
            groups[key]["source_contexts"].append(ctx)
    if item.get("required"):
        groups[key]["required"] = True
    groups[key]["tier"] = tier(groups[key].get("tier"), item.get("tier"))
items = [groups[k] for k in order]
if mode == "json":
    sys.stdout.write(json.dumps({"commands": items}, separators=(",", ":")) + "\n")
elif mode == "required-jsonl":
    for item in items:
        if item.get("required"):
            sys.stdout.write(json.dumps(item, separators=(",", ":")) + "\n")
else:
    for item in items:
        contexts = item.get("source_contexts") or [
            {"source": src, "context": "manifest"} for src in item["sources"]
        ]
        sources = ", ".join(
            f"{ctx.get('context', 'manifest')}: {ctx.get('source', '')}"
            for ctx in contexts
        )
        if item.get("required"):
            sys.stdout.write(
                f"{item['kind']} required {item.get('tier', 'fast')}: "
                f"{item['command']} [{sources}]\n"
            )
        else:
            sys.stdout.write(f"{item['kind']}: {item['command']} [{sources}]\n")
PY
}

_sley_verify_cache_helper() {
  local helper_dir
  helper_dir="${BASH_SOURCE[0]%/*}"
  [[ "$helper_dir" == "${BASH_SOURCE[0]}" ]] && helper_dir=.
  python3 "$helper_dir/verify-cache.py" "$@"
}

_sley_verify_json_array_from_lines() {
  jq -Rsc 'split("\n") | map(select(length > 0))'
}

_sley_verify_cache_payload() {
  local files="$1" command_item="$2" paths files_json paths_json include_untracked repo_wide
  paths=$(_sley_path_filters) || return $?
  # Keep the cache helper's input as JSON. The selected-file stream is still
  # line-oriented because the rest of sley exposes it that way, but once we
  # cross into cache-key construction we avoid shell string framing entirely.
  files_json=$(printf '%s\n' "$files" | _sley_verify_json_array_from_lines) || return 1
  paths_json=$(printf '%s\n' "$paths" | _sley_verify_json_array_from_lines) || return 1
  [[ "$_SLEY_SCOPE_INCLUDE_UNTRACKED" == "1" ]] && include_untracked=true || include_untracked=false
  [[ "$_SLEY_SCOPE_REPO_WIDE" == "1" ]] && repo_wide=true || repo_wide=false
  jq -cn \
    --arg repo_type "$_REPO_TYPE" \
    --arg repo_root "$_REPO_ROOT" \
    --arg scope_change "$_SLEY_SCOPE_CHANGE" \
    --argjson include_untracked "$include_untracked" \
    --argjson repo_wide "$repo_wide" \
    --argjson files "$files_json" \
    --argjson paths "$paths_json" \
    --argjson command "$command_item" \
    '{
      repo_type: $repo_type,
      repo_root: $repo_root,
      scope_change: $scope_change,
      include_untracked: $include_untracked,
      repo_wide: $repo_wide,
      files: $files,
      paths: $paths,
      command: $command
    }'
}

_sley_verify_cache_lock_acquire() {
  local receipt="$1" lock_root lock_dir attempts=0
  [[ -n "$receipt" ]] || return 1
  lock_root="$(dirname "$(dirname "$receipt")")/locks"
  mkdir -p "$lock_root" 2>/dev/null || return 1
  lock_dir="$lock_root/$(basename "$receipt").lock"
  # Use mkdir as the cross-platform lock primitive. Stock macOS does not ship
  # the Linux `flock(1)` CLI, and a short best-effort lock is enough to avoid
  # duplicate same-key executions without making cache unavailability fatal.
  while [[ "$attempts" -lt 50 ]]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      # Stamp owner metadata so a future invocation can reclaim a stale lock
      # whose holder was SIGKILLed (or died to OOM / power loss) before
      # reaching the release path. Hostname is recorded alongside the PID
      # because lock files live under `XDG_CACHE_HOME` — per-user and
      # per-machine in practice, but a network-mounted cache (rare) would
      # otherwise let one host reclaim a still-alive PID on another. Failure
      # to write metadata is non-fatal: the lock still works, it just falls
      # back to the pre-fix behavior (no stale reclaim) for this acquisition.
      {
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "${HOSTNAME:-$(uname -n 2>/dev/null)}"
        printf 'started=%s\n' "$(date +%s 2>/dev/null)"
      } >"$lock_dir/owner.meta" 2>/dev/null || true
      printf '%s\n' "$lock_dir"
      return 0
    fi
    # An existing lock dir may be stale (holder SIGKILLed, OOM, power loss
    # between acquire and release, or the SIGINT/SIGTERM trap in
    # `_sley_verify_run_required` did not get to run). If `owner.meta` names a
    # PID that is no longer alive on this host, treat the lock as abandoned
    # and reclaim it. Without this every future run for the same cache key
    # paid the full 5-second mkdir-polling penalty before falling through
    # unlocked AND a duplicate same-key execution could occur.
    #
    # CRITICAL: reclaim uses an atomic `mv`-to-tombstone, NOT `rm -rf` + retry.
    # Two waiters can both pass `_sley_verify_cache_lock_is_stale` (the meta
    # is unchanged until someone removes the dir), so a naive
    # `is_stale ? rm -rf` lets the second waiter's `rm` destroy the FIRST
    # waiter's freshly-acquired lock — exactly the duplicate-execution bug
    # this whole fix is meant to eliminate. `mv` is atomic on the same
    # filesystem: only one waiter's rename wins; the loser's `mv` fails
    # cleanly (source already gone) and falls through to retry mkdir.
    # The winner deletes a private tombstone path that can never collide
    # with a subsequent fresh acquire on the original `$lock_dir`.
    if _sley_verify_cache_lock_is_stale "$lock_dir"; then
      local tombstone="$lock_dir.stale.$$.$RANDOM"
      if mv "$lock_dir" "$tombstone" 2>/dev/null; then
        printf 'sley verify: reclaiming stale cache lock (owner PID gone): %s\n' "$lock_dir" >&2
        rm -rf "$tombstone" 2>/dev/null || true
      fi
      # Fall through to the next iteration's mkdir attempt.
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

_sley_verify_cache_lock_release() {
  local lock_dir="$1"
  [[ -n "$lock_dir" ]] || return 0
  # `rm -rf` (not `rmdir`) because the lock dir now contains the owner.meta
  # stamp; rmdir would fail on non-empty dirs and silently leak the lock.
  rm -rf "$lock_dir" 2>/dev/null || true
}

# Return success (rc=0) iff `lock_dir` looks abandoned by a dead PID on this
# host. The caller is expected to remove the directory and retry mkdir.
# Conservative: locks without metadata, locks owned by another host, and
# locks whose recorded PID is still alive all return rc=1 (NOT stale).
_sley_verify_cache_lock_is_stale() {
  # Split the locals so `meta_file` actually sees `$lock_dir` — same-statement
  # `local a="$1" b="$a/..."` does not take effect for `b` (shellcheck SC2318).
  local lock_dir="$1"
  local meta_file="$lock_dir/owner.meta"
  local pid host current_host
  [[ -f "$meta_file" ]] || return 1
  pid=$(awk -F= '$1=="pid" {print $2; exit}' "$meta_file" 2>/dev/null)
  host=$(awk -F= '$1=="host" {print $2; exit}' "$meta_file" 2>/dev/null)
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  current_host="${HOSTNAME:-$(uname -n 2>/dev/null)}"
  # Cross-host lock — may still be held by a live process elsewhere. Don't
  # reclaim. The shared-cache scenario is rare but worth the conservatism.
  [[ -n "$host" && -n "$current_host" && "$host" != "$current_host" ]] && return 1
  # `kill -0 PID` is the POSIX way to test "is this process still alive and
  # signalable from here". Success means alive (not stale); failure means
  # ESRCH (no such PID, i.e. stale) or EPERM (alive but unsignalable, treated
  # as not-stale to stay conservative — `kill -0` returns rc=1 for EPERM but
  # the only way to distinguish that from ESRCH is `errno`, which bash can't
  # see, so we accept the false-negative).
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

_sley_verify_explain_cache_lookup() {
  local lookup="$1"
  # Keep the explanatory surface compact and deterministic. The Python helper
  # owns key material; bash only extracts stable summary fields for humans and
  # agents trying to understand why a command did or did not hit.
  jq -r '
    "sley verify: cache key: \(.key // "unavailable")",
    "sley verify: cache base policy: \(.material.base.policy // "unavailable")",
    "sley verify: cache selected files: \((.material.scope.files // []) | length)",
    "sley verify: cache path scopes: \(((.material.scope.paths // []) | if length == 0 then ["<none>"] else . end) | join(", "))",
    "sley verify: cache identity env: \((.material.command.identity.env // []) | length)",
    "sley verify: cache identity commands: \((.material.command.identity.commands // []) | length)"
  ' <<<"$lookup"
}

_sley_verify_run_required() {
  # Thin trap-discipline wrapper around the real implementation.
  #
  # Two problems would exist if the signal traps were installed directly in
  # the impl function:
  #   1. The trap is set on the caller's shell (the function is not a
  #      subshell), so it persists after the function returns. Callers /
  #      tests that rely on default INT/TERM/HUP behavior would be quietly
  #      mutated for the rest of the session.
  #   2. A handler without `exit` swallows Ctrl-C and lets the loop march on
  #      to the next required command — user-hostile and gives the appearance
  #      that Ctrl-C is broken.
  #
  # The wrapper captures the caller's prior trap state for each signal,
  # delegates to the impl (which installs its own traps with `exit` codes
  # matching the standard 128+signum convention), and restores the prior
  # traps on every normal return path. The signal path bypasses the
  # restore (we `exit` directly), which is the right thing for an
  # interactive CLI but means signal-during-test cases will terminate the
  # test shell — documented tradeoff.
  local _saved_int _saved_term _saved_hup _rc
  _saved_int=$(trap -p INT)
  _saved_term=$(trap -p TERM)
  _saved_hup=$(trap -p HUP)
  _sley_verify_run_required_impl "$@"
  _rc=$?
  # `trap -p SIG` prints the literal command to reinstate the trap (e.g.
  # `trap -- 'cmd' SIG`); when no prior trap was set it prints nothing, so
  # we fall back to `trap - SIG` (reset to default).
  eval "${_saved_int:-trap - INT}"
  eval "${_saved_term:-trap - TERM}"
  eval "${_saved_hup:-trap - HUP}"
  return "$_rc"
}

# Emit a cached-pass result for the current command: log it, bump the cached
# counter, and (in JSON mode) append the structured result. Runs the same
# pre-lock and post-lock cache-hit paths through one implementation. Mutates the
# caller's cached_count / results_json / first / json via dynamic scope, matching
# the inline blocks it replaces.
_sley_verify_emit_cache_hit() {
  local tier="$1" command="$2" receipt="$3"
  echo "sley verify: cached pass $tier: $command" >&2
  [[ -z "$receipt" ]] || echo "sley verify: receipt: $receipt" >&2
  cached_count=$((cached_count + 1))
  if [[ "$json" == "1" ]]; then
    [[ "$first" == "1" ]] || results_json+=","
    first=0
    results_json+=$(printf '{"command":"%s","tier":"%s","status":"cached-pass","exit_code":0,"receipt":"%s"}' \
      "$(_repo_json_escape "$command")" "$(_repo_json_escape "$tier")" \
      "$(_repo_json_escape "$receipt")")
  fi
}

_sley_verify_run_required_impl() {
  local commands="$1" files="$2" full="$3" json="$4" force="$5" explain_cache="$6"
  local required command_item command tier exit_code failed=0 status result_status
  local results_json="" first=1 cache_enabled payload lookup cache_status receipt pre_key post_lookup post_key write_result lock_dir
  local passed_count=0 cached_count=0 failed_count=0 skipped_slow_count=0
  local shell_mode shell_flag

  # Cleanup-on-signal traps. Normal control flow releases `lock_dir` at every
  # branch below, but a SIGINT (Ctrl-C), SIGTERM, or SIGHUP between the
  # `mkdir` in `_sley_verify_cache_lock_acquire` and the matching release
  # would otherwise leak the lock dir. Every future run for the same cache
  # key then paid the full 5-second mkdir-polling penalty before falling
  # through unlocked AND a duplicate same-key execution could occur. The
  # PID-based stale reclaim in `_sley_verify_cache_lock_acquire` is the
  # defensive backstop for the SIGKILL / power-loss case where the trap
  # cannot fire.
  #
  # Each handler clears the trap first (so a signal during cleanup doesn't
  # recurse), releases the current `$lock_dir` (idempotent — empty value is
  # a no-op), then exits with the conventional `128 + signum` code so the
  # caller sees a real signal-style exit rather than a swallowed Ctrl-C.
  # The wrapper above restores the caller's prior trap state on normal
  # return; signal exits bypass that restore, which is correct for an
  # interactive sley CLI (the shell is terminating anyway).
  trap 'trap - INT TERM HUP; _sley_verify_cache_lock_release "$lock_dir"; exit 130' INT
  trap 'trap - INT TERM HUP; _sley_verify_cache_lock_release "$lock_dir"; exit 143' TERM
  trap 'trap - INT TERM HUP; _sley_verify_cache_lock_release "$lock_dir"; exit 129' HUP

  command -v jq >/dev/null 2>&1 || {
    echo "sley verify: jq is required to run required verification commands" >&2
    return 1
  }

  required=$(
    printf '%s\n' "$commands" |
      _sley_verify_group_python required-jsonl
  )

  if [[ -z "$required" ]]; then
    if [[ "$json" == "1" ]]; then
      echo '{"status":"no-required","results":[]}'
    else
      echo "sley verify: no required verification commands mapped"
    fi
    return 0
  fi

  if [[ "$json" == "0" ]]; then
    echo "sley verify: selected changed files:"
    printf '%s\n' "$files" | sed '/^$/d; s/^/  /'
    echo "sley verify: required verification commands:"
    printf '%s\n' "$required" |
      jq -r '"  " + (.tier // "fast") + ": " + .command'
  fi

  while IFS= read -r command_item; do
    [[ -n "$command_item" ]] || continue
    lock_dir=""
    command=$(printf '%s' "$command_item" | jq -r '.command')
    tier=$(printf '%s' "$command_item" | jq -r '.tier // "fast"')
    [[ -n "$command" ]] || continue
    cache_enabled=0
    shell_mode="login"
    if printf '%s' "$command_item" | jq -e '.cache.enabled == true' >/dev/null 2>&1; then
      cache_enabled=1
      # Non-cached commands keep the historical login-shell behavior. Cached
      # commands default to `bash -c` so startup files are not invisible cache
      # inputs; `cache.shell: "login"` is an explicit registry choice.
      shell_mode=$(printf '%s' "$command_item" | jq -r '.cache.shell // "default"')
      payload=$(_sley_verify_cache_payload "$files" "$command_item") || {
        echo "sley verify: failed to build cache key input for command: $command" >&2
        return 1
      }
      lookup=$(printf '%s\n' "$payload" | _sley_verify_cache_helper lookup) || {
        echo "sley verify: failed to compute cache key for command: $command" >&2
        printf '%s\n' "$lookup" >&2
        return 1
      }
      cache_status=$(printf '%s' "$lookup" | jq -r '.status')
      receipt=$(printf '%s' "$lookup" | jq -r '.receipt // empty')
      pre_key=$(printf '%s' "$lookup" | jq -r '.key // empty')
      if [[ "$explain_cache" == "1" ]]; then
        if [[ "$force" == "1" ]]; then
          echo "sley verify: cache decision: force $tier: $command"
        else
          echo "sley verify: cache decision: $cache_status $tier: $command"
        fi
        _sley_verify_explain_cache_lookup "$lookup"
        [[ -z "$receipt" ]] || echo "sley verify: cache receipt: $receipt"
      fi
      if [[ "$cache_status" == "identity-error" ]]; then
        # A failed identity input means the cache proof is unavailable, not
        # that the verification command failed. Run uncached and avoid writing a receipt
        # whose key could not include the declared identity input.
        echo "sley verify: cache disabled for $tier command: $(printf '%s' "$lookup" | jq -r '.error')" >&2
        cache_enabled=0
      fi
      if [[ "$force" != "1" && "$cache_status" == "hit" ]]; then
        _sley_verify_emit_cache_hit "$tier" "$command" "$receipt"
        continue
      fi
      if [[ "$cache_enabled" != "1" ]]; then
        lock_dir=""
      else
        lock_dir=$(_sley_verify_cache_lock_acquire "$receipt" || true)
      fi
      if [[ "$force" != "1" && -n "$lock_dir" ]]; then
        # Re-check after acquiring the lock. If another agent finished the same
        # command while we were waiting, use its receipt instead of rerunning.
        lookup=$(printf '%s\n' "$payload" | _sley_verify_cache_helper lookup) || {
          _sley_verify_cache_lock_release "$lock_dir"
          echo "sley verify: failed to compute cache key for command: $command" >&2
          printf '%s\n' "$lookup" >&2
          return 1
        }
        cache_status=$(printf '%s' "$lookup" | jq -r '.status')
        receipt=$(printf '%s' "$lookup" | jq -r '.receipt // empty')
        pre_key=$(printf '%s' "$lookup" | jq -r '.key // empty')
        if [[ "$cache_status" == "identity-error" ]]; then
          _sley_verify_cache_lock_release "$lock_dir"
          lock_dir=""
          echo "sley verify: cache disabled for $tier command: $(printf '%s' "$lookup" | jq -r '.error')" >&2
          cache_enabled=0
        fi
        if [[ "$cache_status" == "hit" ]]; then
          _sley_verify_cache_lock_release "$lock_dir"
          lock_dir=""
          _sley_verify_emit_cache_hit "$tier" "$command" "$receipt"
          continue
        fi
      fi
    fi

    case "$tier:$full" in
      slow:0 | full:0)
        # Cache lookup deliberately happens before this slow gate. A slow
        # command that already passed for this exact input should satisfy a
        # normal readiness run without requiring `--full` every time.
        _sley_verify_cache_lock_release "$lock_dir"
        lock_dir=""
        echo "sley verify: slow required command not run (use --full): $command" >&2
        failed=1
        skipped_slow_count=$((skipped_slow_count + 1))
        if [[ "$json" == "1" ]]; then
          [[ "$first" == "1" ]] || results_json+=","
          first=0
          results_json+=$(printf '{"command":"%s","tier":"%s","status":"skipped-slow","exit_code":null}' \
            "$(_repo_json_escape "$command")" "$(_repo_json_escape "$tier")")
        fi
        continue
        ;;
    esac

    echo "sley verify: running required $tier command: $command" >&2
    case "$shell_mode" in
      default | "")
        shell_flag="-c"
        ;;
      login)
        shell_flag="-lc"
        ;;
      *)
        _sley_verify_cache_lock_release "$lock_dir"
        lock_dir=""
        echo "sley verify: unsupported cache.shell for command: $command" >&2
        return 1
        ;;
    esac
    if [[ "$json" == "1" ]]; then
      bash "$shell_flag" "$command" >&2
    else
      bash "$shell_flag" "$command"
    fi
    exit_code=$?
    [[ "$json" == "1" ]] || echo "sley verify: exit code: $exit_code"
    if [[ "$exit_code" -eq 0 ]]; then
      result_status="passed"
      if [[ "$cache_enabled" == "1" ]]; then
        # Recompute the key after the command succeeds. If the selected content
        # changed while the test was running, the success no longer proves the
        # current input and must not be written as a receipt.
        post_lookup=$(printf '%s\n' "$payload" | _sley_verify_cache_helper lookup) || {
          _sley_verify_cache_lock_release "$lock_dir"
          lock_dir=""
          echo "sley verify: failed to recompute cache key for command: $command" >&2
          printf '%s\n' "$post_lookup" >&2
          return 1
        }
        post_key=$(printf '%s' "$post_lookup" | jq -r '.key // empty')
        if [[ -z "$pre_key" || "$post_key" != "$pre_key" ]]; then
          echo "sley verify: changes changed during required command; not caching receipt: $command" >&2
          failed=1
          failed_count=$((failed_count + 1))
          result_status="failed"
        else
          write_result=$(printf '%s\n' "$payload" | _sley_verify_cache_helper write) || {
            _sley_verify_cache_lock_release "$lock_dir"
            lock_dir=""
            echo "sley verify: failed to write success receipt for command: $command" >&2
            printf '%s\n' "$write_result" >&2
            return 1
          }
        fi
      fi
    else
      result_status="failed"
      failed=1
      failed_count=$((failed_count + 1))
    fi
    _sley_verify_cache_lock_release "$lock_dir"
    lock_dir=""
    [[ "$result_status" == "passed" ]] && passed_count=$((passed_count + 1))
    if [[ "$json" == "1" ]]; then
      [[ "$first" == "1" ]] || results_json+=","
      first=0
      results_json+=$(printf '{"command":"%s","tier":"%s","status":"%s","exit_code":%s}' \
        "$(_repo_json_escape "$command")" "$(_repo_json_escape "$tier")" \
        "$result_status" "$exit_code")
    fi
  done <<<"$required"

  if [[ "$json" == "1" ]]; then
    [[ "$failed" -eq 0 ]] && status="passed" || status="failed"
    printf '{"status":"%s","results":[%s],"summary":{"passed":%s,"cached_passed":%s,"failed":%s,"skipped_slow":%s}}\n' \
      "$status" "$results_json" "$passed_count" "$cached_count" "$failed_count" "$skipped_slow_count"
  fi

  [[ "$failed" -eq 0 ]]
}

_sley_verify() {
  case "${1:-}" in
    -h | --help | help)
      _sley_verify_usage
      return 0
      ;;
  esac

  _sley_init_repo || return $?
  local run_required=0 full=0 force=0 explain_cache=0 cache_stats=0
  local -a scope_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-required)
        run_required=1
        shift
        ;;
      --full)
        full=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --explain-cache)
        explain_cache=1
        shift
        ;;
      --cache-stats)
        cache_stats=1
        shift
        ;;
      *)
        scope_args+=("$1")
        shift
        ;;
    esac
  done

  _sley_parse_scope "${scope_args[@]}" || return $?
  _repo_require_json_encoder || return 2
  command -v python3 >/dev/null 2>&1 || {
    _sley_die "sley verify requires python3 to group commands"
    return 2
  }
  if [[ "$cache_stats" == "1" ]]; then
    local stats
    stats=$(_sley_verify_cache_helper stats) || return 1
    if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
      printf '%s\n' "$stats"
    else
      printf 'sley verify cache: receipts: %s\n' "$(printf '%s' "$stats" | jq -r '.receipts')"
      printf 'sley verify cache: bytes: %s\n' "$(printf '%s' "$stats" | jq -r '.bytes')"
      printf 'sley verify cache: root: %s\n' "$(printf '%s' "$stats" | jq -r '.root')"
    fi
    return 0
  fi
  local files commands="" file dir source
  files=$(_sley_selected_files) || return 2
  if [[ -z "$files" ]]; then
    [[ "$_SLEY_SCOPE_JSON" == "1" ]] && echo '{"commands":[]}' || echo "sley verify: no matching changed files"
    return 0
  fi

  SLEY_CALLER="${SLEY_CALLER:-human}"
  # shellcheck disable=SC2034 # consumed by sourced local extensions.
  SLEY_SCOPED=1
  sley_hook_init

  declare -A _seen_dirs
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    # A changed file may itself be a manifest with workflow commands; nearby
    # manifest discovery below handles broader project-local test/build hints.
    commands+=$(_sley_project_manifest_commands "$file" changed-file)$'\n'
    # Parameter-expansion `dirname` — `${file%/*}` when there's a slash, else
    # ".". Saves a fork per file (a 100-file change set walking 5 levels deep
    # otherwise spawns ~600 `dirname` subprocesses).
    case "$file" in
      */*) dir="${file%/*}" ;;
      *) dir="." ;;
    esac
    while [[ "$dir" != "." && "$dir" != "/" ]]; do
      # Walk upward from touched files to nearby project manifests. This uses
      # the diff as context, which is the important signal when commands are
      # run from a monorepo root. Hitting an already-visited dir means every
      # ancestor of that dir was already scanned — break instead of re-walking
      # to root, so a 100-file change set under one project doesn't traverse
      # the project root 100 times.
      [[ -n "${_seen_dirs[$dir]:-}" ]] && break
      _seen_dirs[$dir]=1
      for source in "${_SLEY_MANIFEST_NAMES[@]/#/$dir/}"; do
        [[ -f "$source" ]] && commands+=$(_sley_project_manifest_commands "$source" ancestor)$'\n'
      done
      case "$dir" in
        */*) dir="${dir%/*}" ;;
        *) dir="." ;;
      esac
    done
  done <<<"$files"

  # Repo-root manifests are independent of which files changed; scan them once
  # outside the per-file loop so a large change set does not re-stat every
  # top-level manifest for every touched file.
  for source in "${_SLEY_MANIFEST_NAMES[@]}"; do
    [[ -f "$source" ]] && commands+=$(_sley_project_manifest_commands "$source" repo-root)$'\n'
  done
  commands+=$(_sley_verify_extension_commands "$files")$'\n' || return 1
  commands+=$(_sley_verify_registry_commands "$files")$'\n' || return 1

  commands=$(printf '%s\n' "$commands" | sed '/^$/d' | awk '!seen[$0]++')
  if [[ "$run_required" == "1" ]]; then
    _sley_verify_run_required "$commands" "$files" "$full" "$_SLEY_SCOPE_JSON" "$force" "$explain_cache"
    return $?
  fi

  if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
    printf '%s\n' "$commands" | _sley_verify_group_python json
  else
    if [[ -z "$commands" ]]; then
      echo "sley verify: no local verification commands detected"
    else
      printf '%s\n' "$commands" | _sley_verify_group_python human
    fi
  fi
}
