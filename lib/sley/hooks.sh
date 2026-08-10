#!/usr/bin/env bash
# hooks.sh — hook-facing API and extension loading for sley.
#
# Hooks are intentionally narrower than human-facing commands. They call this
# module's low-level functions so commit/edit paths stay fast and predictable
# while still sharing repo detection and environment-extension policy.

_sley_hook_changed_files() {
  # Hook callers intentionally use the narrowest safe default: Git only checks
  # the staged index, while Sapling checks pending changes because it has no
  # staging area. Broader "active change context" behavior belongs to the
  # human-facing CLI, not latency-sensitive hooks.
  case "$_REPO_TYPE" in
    sl) _repo_changed_names pending 0 ;;
    git) _repo_changed_names staged 0 ;;
    *) return 2 ;;
  esac
}

_sley_hook_format_file() {
  # The Git hook wraps this in a hash comparison. Keep this single-file and
  # policy-neutral: callers decide whether a formatter failure is advisory
  # (edit/commit hooks) or blocking (`sley fix`). Returning 2 for a missing
  # formatter gives human-facing orchestration a clean "tool unavailable"
  # signal without forcing hot hooks to block on it.
  command -v autoformat >/dev/null 2>&1 || return 2
  autoformat -- "$1" 2>/dev/null
}

_sley_hook_lint_file() {
  command -v autolint >/dev/null 2>&1 || return 2
  # Edit hooks need the same policy source as commit hooks, but on a one-file
  # hot path. Keep this primitive narrow: diagnostics only, no validation or
  # broader readiness checks. Extra args intentionally pass through so editor
  # integrations can request tool-native modes such as `autolint --json`.
  autolint "$@"
}

_sley_hook_run_batch() {
  local cmd="$1" files_text="$2" f
  local batch_files=()

  while IFS= read -r f; do
    [[ -n "$f" ]] && batch_files+=("$f")
  done <<<"$files_text"

  [[ "${#batch_files[@]}" -eq 0 ]] && return 0
  # `--` separates flags from filenames so hostile or unusual filenames that
  # begin with `-` are treated as positional paths, not as flags. autoformat
  # and autolint both accept `--` (they parse known flags first and treat the
  # rest as files).
  "$cmd" -- "${batch_files[@]}"
}

_sley_hook_format() {
  # Format is intentionally quiet in the hook batch path: the git pre-commit
  # hook detects formatter-driven file changes via hash comparison and reports
  # those changes itself, so swallowing autoformat's own output keeps the hook
  # log uncluttered. The lint counterpart below leaves stderr visible because
  # `sley check` reuses it for human-facing diagnostics.
  _sley_hook_run_batch autoformat "$1" 2>/dev/null || true
}

_sley_hook_lint() {
  command -v autolint >/dev/null 2>&1 || return 2
  # Let autolint's stderr pass through. `sley check` is a human-facing read-
  # only command and must surface the diagnostics that explain a non-zero exit;
  # hook callers can wrap their own redirection if they want quieter output.
  _sley_hook_run_batch autolint "$1"
}

_sley_hook_validate() { :; }

_sley_message_validate_template() {
  local template="$1" message_file="$2"

  # A Git-compatible template is a deliberately small structural contract,
  # not a policy language. Markdown headings (## through ######) and
  # colon-terminated labels declare required, non-empty sections. Single-#
  # lines remain editor guidance and never satisfy a section body.
  awk -v template_path="$template" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function single_hash_comment(line, text) {
      text = trim(line)
      return substr(text, 1, 1) == "#" && substr(text, 2, 1) != "#"
    }

    function markdown_heading(line, text, hashes, name) {
      text = trim(line)
      if (match(text, /^#+/) == 0) {
        return ""
      }
      hashes = RLENGTH
      if (hashes < 2 || hashes > 6 || substr(text, hashes + 1, 1) !~ /[[:space:]]/) {
        return ""
      }
      name = trim(substr(text, hashes + 1))
      sub(/:[[:space:]]*$/, "", name)
      return trim(name)
    }

    NR == FNR {
      line = trim($0)
      if (line == "" || single_hash_comment(line)) {
        next
      }

      name = markdown_heading(line)
      if (name == "") {
        colon = index(line, ":")
        if (colon > 1 && trim(substr(line, colon + 1)) == "") {
          name = trim(substr(line, 1, colon - 1))
        }
      }
      if (name == "") {
        next
      }

      key = tolower(name)
      if (!(key in required)) {
        required[key] = name
        order[++required_count] = key
      }
      next
    }

    {
      line = trim($0)
      if (line == "" || single_hash_comment(line)) {
        next
      }

      name = markdown_heading(line)
      if (name != "") {
        section_started = 1
        key = tolower(name)
        if (key in required) {
          seen[key] = 1
          current = key
        } else {
          # An extra Markdown section is allowed, but it ends the previous
          # required section so its body cannot be borrowed accidentally.
          current = ""
        }
        next
      }

      colon = index(line, ":")
      if (colon > 1) {
        key = tolower(trim(substr(line, 1, colon - 1)))
        if (key in required) {
          section_started = 1
          seen[key] = 1
          current = key
          inline = trim(substr(line, colon + 1))
          if (inline != "") {
            content[key] = 1
          }
          next
        }
      }

      if (!title_seen && !section_started) {
        title_seen = 1
        next
      }
      if (current != "") {
        content[current] = 1
      }
    }

    END {
      if (required_count == 0) {
        printf "sley: message template defines no required sections: %s\n", template_path > "/dev/stderr"
        exit 2
      }

      errors = 0
      if (!title_seen) {
        print "sley: commit message has no title" > "/dev/stderr"
        errors = 1
      }
      for (i = 1; i <= required_count; i++) {
        key = order[i]
        if (!seen[key]) {
          printf "sley: commit message is missing '\''%s'\'' section\n", required[key] > "/dev/stderr"
          errors = 1
        } else if (!content[key]) {
          printf "sley: commit message '\''%s'\'' section is empty\n", required[key] > "/dev/stderr"
          errors = 1
        }
      }
      exit errors
    }
  ' "$template" "$message_file"
}

_sley_message_run_provider() {
  local template="$1" validator="$2" message_file="$3"

  if [[ -n "$template" ]]; then
    _sley_message_validate_template "$template" "$message_file"
  else
    # The executable provider contract is intentionally just one opaque path.
    # Consumers that need profiles or strictness keep those policy choices in
    # their own environment or wrapper instead of teaching Sley their schema.
    "$validator" "$message_file"
  fi
}

_sley_hook_validate_message() {
  local template="" validator="" message_file="" tmp_root tmp_dir

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template)
        [[ $# -ge 2 ]] || {
          _sley_die "hook validate-message requires a path after --template"
          return 2
        }
        template="$2"
        shift 2
        ;;
      --validator)
        [[ $# -ge 2 ]] || {
          _sley_die "hook validate-message requires a path after --validator"
          return 2
        }
        validator="$2"
        shift 2
        ;;
      --message-file)
        [[ $# -ge 2 ]] || {
          _sley_die "hook validate-message requires a path after --message-file"
          return 2
        }
        message_file="$2"
        shift 2
        ;;
      *)
        _sley_die "unknown hook validate-message option: $1"
        return 2
        ;;
    esac
  done

  if [[ -n "$template" && -n "$validator" ]]; then
    _sley_die "message validation accepts only one of --template or --validator"
    return 2
  fi

  # Optional means genuinely optional: callers can always route through this
  # operation and let absent configuration remain a quiet no-op.
  [[ -n "$template" || -n "$validator" ]] || return 0

  if [[ -n "$template" && (! -f "$template" || ! -r "$template") ]]; then
    _sley_die "message template is not readable: $template"
    return 2
  fi
  if [[ -n "$template" && ! -s "$template" ]]; then
    _sley_die "message template defines no required sections: $template"
    return 2
  fi
  if [[ -n "$validator" && (! -f "$validator" || ! -x "$validator") ]]; then
    _sley_die "message validator is not executable: $validator"
    return 2
  fi
  if [[ -n "$message_file" ]]; then
    if [[ ! -f "$message_file" || ! -r "$message_file" ]]; then
      _sley_die "commit message file is not readable: $message_file"
      return 2
    fi
    _sley_message_run_provider "$template" "$validator" "$message_file"
    return $?
  fi

  # External validators uniformly receive a file even when the caller owns
  # only stdin. Keep staging in a private directory and in a subshell so umask,
  # traps, and cleanup cannot leak into a sourceable Sley consumer.
  (
    umask 077
    tmp_root=${TMPDIR:-/tmp}
    tmp_root=${tmp_root%/}
    [[ -d "$tmp_root" ]] || {
      _sley_die "temporary directory is unavailable: $tmp_root"
      exit 2
    }
    tmp_dir=$(mktemp -d "$tmp_root/sley-message.XXXXXX") || {
      _sley_die "cannot create private commit-message staging directory"
      exit 2
    }
    message_file="$tmp_dir/message"
    trap 'rm -f -- "$message_file"; rmdir -- "$tmp_dir" 2>/dev/null || true' EXIT
    cat >"$message_file" || {
      _sley_die "cannot stage commit message from stdin"
      exit 2
    }
    _sley_message_run_provider "$template" "$validator" "$message_file"
  )
}

# Extra gitleaks config paths for the secrets phase, one per line. Default: none
# (base sley ships no extra rules). An environment extension can override this to
# add independent gitleaks passes — e.g. an overlay that scans for forbidden
# work-specific vocabulary in repos where it must not appear. The override
# decides its own applicability (repo type, remote, markers); base sley just
# runs a pass per returned config and MAX-preserves the exit code.
_sley_hook_secrets_extra_configs() { :; }

_sley_ext_ready_phases() { :; }

_sley_ext_ready_phase() { return 2; }

_sley_ext_verify_commands() { :; }

_sley_source_extensions_from() {
  local extension_dir="$1"
  local extension
  local had_nullglob=0
  local extensions=()

  [[ -d "$extension_dir" ]] || return 0

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  extensions=("$extension_dir"/*.sh)
  [[ "$had_nullglob" -eq 1 ]] || shopt -u nullglob

  for extension in "${extensions[@]}"; do
    # shellcheck disable=SC1090
    source "$extension"
  done
}

_sley_xdg_dir() {
  local output_name="$1" xdg_name="$2" home_suffix="$3" app_suffix="$4" purpose="$5"
  local root="${!xdg_name:-}" resolved

  if [[ -n "$root" && "$root" == /* ]]; then
    resolved="$root/$app_suffix"
  elif [[ -n "${HOME:-}" ]]; then
    resolved="$HOME/$home_suffix/$app_suffix"
  else
    printf 'sley: HOME is not set and %s is not an absolute path; cannot resolve %s\n' \
      "$xdg_name" "$purpose" >&2
    return 1
  fi

  # Assign into the caller rather than printing. Command substitution removes
  # trailing newlines, which can silently retarget an explicit filesystem path.
  printf -v "$output_name" '%s' "$resolved"
}

_sley_extension_dir() {
  local output_name="$1" path_value

  if [[ -n "${SLEY_EXTENSION_DIR:-}" ]]; then
    path_value="$SLEY_EXTENSION_DIR"
  else
    # Extension policy is user configuration, not an installed code asset.
    # Standalone shdeps installs therefore use XDG config rather than a host
    # repository's historical library layout.
    _sley_xdg_dir path_value XDG_CONFIG_HOME .config sley/extensions.d \
      "Sley extension directory" || return $?
  fi

  printf -v "$output_name" '%s' "$path_value"
}

_sley_hook_init() {
  local extension_dir extension has_extensions=0
  local current_format_file_definition current_format_definition
  local current_private_format_file_definition
  _sley_extension_dir extension_dir || return $?

  # Native hooks only speak the SLEY_* extension contract. Deprecated
  # compatibility names were intentionally removed so hook policy has a single
  # owner: this module plus optional environment extensions.
  SLEY_CALLER="${SLEY_CALLER:-unknown}"

  # Run repo detection here so hook callers no longer need to reach across the
  # public/private boundary by calling `_repo_detect` directly. Pre-set
  # `_REPO_TYPE` is still honored as a perf shortcut by `_repo_detect`.
  _repo_detect

  # Extensions are ordered by filename so overlays can pick predictable numeric
  # prefixes without the base implementation knowing anything about the
  # environment that provided them. This keeps base sley generic while still
  # allowing local repo policy to override `sley_hook_*` functions directly.
  for extension in "$extension_dir"/*.sh; do
    if [[ -f "$extension" ]]; then
      has_extensions=1
      break
    fi
  done
  if [[ -n "${_SLEY_BASE_FORMAT_FILE_DEFINITION+x}" ]]; then
    # Each reload starts from the original public hooks. Without this, removing
    # or replacing an extension leaves its old function definition resident in
    # a long-lived shell and can make a stale batch override win indefinitely.
    eval "$_SLEY_BASE_FORMAT_FILE_DEFINITION"
    eval "$_SLEY_BASE_FORMAT_DEFINITION"
    if [[ -n "${_SLEY_BASE_PRIVATE_FORMAT_FILE_DEFINITION+x}" ]]; then
      eval "$_SLEY_BASE_PRIVATE_FORMAT_FILE_DEFINITION"
    else
      # Shells initialized by an older Sley have only the two public baseline
      # definitions. Sourcing this version restored the private base function,
      # so capture it before extensions are loaded instead of failing under -u.
      _SLEY_BASE_PRIVATE_FORMAT_FILE_DEFINITION=$(declare -f _sley_hook_format_file)
    fi
  elif [[ "$has_extensions" == "1" ]]; then
    # Capture the base definitions only when extensions exist. Comparing Bash's
    # own function serialization detects overrides without parsing extension
    # source. The common no-extension hook path pays no detection subprocesses.
    _SLEY_BASE_FORMAT_FILE_DEFINITION=$(declare -f sley_hook_format_file)
    _SLEY_BASE_FORMAT_DEFINITION=$(declare -f sley_hook_format)
    _SLEY_BASE_PRIVATE_FORMAT_FILE_DEFINITION=$(declare -f _sley_hook_format_file)
  fi
  _sley_source_extensions_from "$extension_dir"

  _SLEY_HOOK_FORMAT_FILE_OVERRIDDEN=0
  _SLEY_HOOK_FORMAT_OVERRIDDEN=0
  _SLEY_HOOK_PRIVATE_FORMAT_FILE_OVERRIDDEN=0
  if [[ -n "${_SLEY_BASE_FORMAT_FILE_DEFINITION+x}" ]]; then
    current_format_file_definition=$(declare -f sley_hook_format_file)
    current_format_definition=$(declare -f sley_hook_format)
    current_private_format_file_definition=$(declare -f _sley_hook_format_file)
    [[ "$current_format_file_definition" == "$_SLEY_BASE_FORMAT_FILE_DEFINITION" ]] ||
      _SLEY_HOOK_FORMAT_FILE_OVERRIDDEN=1
    [[ "$current_format_definition" == "$_SLEY_BASE_FORMAT_DEFINITION" ]] ||
      _SLEY_HOOK_FORMAT_OVERRIDDEN=1
    [[ "$current_private_format_file_definition" == "$_SLEY_BASE_PRIVATE_FORMAT_FILE_DEFINITION" ]] ||
      _SLEY_HOOK_PRIVATE_FORMAT_FILE_OVERRIDDEN=1
  fi
}
