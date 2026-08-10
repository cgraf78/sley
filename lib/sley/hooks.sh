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

_sley_hook_lint_needs_bounded_input() {
  local LC_ALL=C files_text="$1" file arg_max
  local count=0 path_bytes=0 environment_bytes environment_pointer_bytes
  local required_bytes pipeline_status preflight_status

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    path_bytes=$((path_bytes + ${#file} + 1))
  done <<<"$files_text"

  # Preserve the established one-file hot path. A valid filesystem path is
  # itself bounded by the host, so it cannot create the aggregate-argv growth
  # this guard is intended to contain.
  [[ "$count" -le 1 ]] && return 1

  if arg_max=$(command getconf ARG_MAX 2>/dev/null); then
    preflight_status=0
  else
    preflight_status=$?
  fi
  # Missing or unsupported getconf has a safe conservative fallback. A signal
  # is different: preserve cancellation instead of continuing into lint work
  # after the caller already asked this operation to stop.
  if [[ "$preflight_status" -ge 128 ]]; then
    return "$preflight_status"
  elif [[ "$preflight_status" -ne 0 ]]; then
    arg_max=131072
  fi
  case "$arg_max" in
    '' | *[!0-9]* | 0) arg_max=131072 ;;
  esac

  # `env` emits one newline in place of each entry's terminating NUL, so its
  # byte count matches exec's string payload even when values contain newlines.
  # Keep the raw environment out of a shell variable: besides wasting memory,
  # Bash would expose every value when a caller enables xtrace. If either side
  # of the count pipeline fails, choose bounded input rather than risk E2BIG.
  if environment_bytes=$(
    command env | command wc -c
    pipeline_status=("${PIPESTATUS[@]}")
    if [[ "${pipeline_status[0]:-1}" -ge 128 ]]; then
      exit "${pipeline_status[0]}"
    elif [[ "${pipeline_status[1]:-1}" -ge 128 ]]; then
      exit "${pipeline_status[1]}"
    elif [[ "${pipeline_status[0]:-1}" -ne 0 ||
      "${pipeline_status[1]:-1}" -ne 0 ]]; then
      exit 2
    fi
  ); then
    preflight_status=0
  else
    preflight_status=$?
  fi
  if [[ "$preflight_status" -ge 128 ]]; then
    return "$preflight_status"
  elif [[ "$preflight_status" -ne 0 ]]; then
    # A non-signal measurement failure leaves the exact size unknown. Prefer
    # bounded transport, which remains correct for both small and large input.
    return 0
  fi
  environment_bytes=${environment_bytes//[[:space:]]/}
  case "$environment_bytes" in
    '' | *[!0-9]*) return 0 ;;
  esac

  # Exec also charges the envp pointer table. Counting it exactly would require
  # reparsing output that may contain newlines inside values, so derive a safe
  # upper bound instead: every valid environment record occupies at least
  # three bytes (`A=\0`). Eight bytes per possible record covers pointers on
  # the supported 64-bit hosts and intentionally overestimates 32-bit hosts.
  environment_pointer_bytes=$(((((environment_bytes + 2) / 3) + 1) * 8))

  # The reserve covers executable/interpreter arguments, auxiliary vectors,
  # alignment, and platform-specific accounting. Sixteen bytes per path
  # conservatively covers its argv pointer plus alignment on 64-bit hosts.
  required_bytes=$((environment_bytes + environment_pointer_bytes + \
    path_bytes + (count + 4) * 16 + 32768))
  [[ "$required_bytes" -ge "$arg_max" ]]
}

_sley_hook_lint_bounded() {
  local files_text="$1" file capability_status
  local -a pipeline_status=()

  # This exit-status-only contract lets old Checkrun installations fail closed
  # without parsing help prose. The capability also promises stdin transport,
  # which avoids an interruptible Sley temp-file lifecycle entirely.
  if command checkrun capabilities --has autolint-files0-stdin \
    >/dev/null 2>&1; then
    capability_status=0
  else
    capability_status=$?
  fi
  case "$capability_status" in
    0) ;;
    1 | 2)
      echo "sley: installed Checkrun does not support bounded autolint stdin; update Checkrun before linting this file set" >&2
      return 2
      ;;
    *)
      if [[ "$capability_status" -ge 128 ]]; then
        # Preserve conventional signal statuses so cancellation remains
        # visible even when it arrives during negotiation rather than backend
        # execution.
        return "$capability_status"
      fi
      echo "sley: Checkrun bounded-input capability probe failed with status $capability_status" >&2
      return 2
      ;;
  esac

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    printf '%s\0' "$file" || exit 2
  done <<<"$files_text" | autolint --files0-from -
  pipeline_status=("${PIPESTATUS[@]}")

  # Autolint owns lint findings, structural errors, and signal statuses. Only
  # replace a clean scanner status when the producer itself could not deliver
  # the complete NUL stream.
  if [[ "${pipeline_status[1]:-2}" -ne 0 ]]; then
    return "${pipeline_status[1]}"
  fi
  if [[ "${pipeline_status[0]:-2}" -ne 0 ]]; then
    echo "sley: could not stream the complete file list to autolint" >&2
    return 2
  fi
  return 0
}

_sley_hook_lint() {
  local sizing_status
  command -v autolint >/dev/null 2>&1 || return 2
  # Let autolint's stderr pass through. `sley check` is a human-facing read-
  # only command and must surface the diagnostics that explain a non-zero exit;
  # hook callers can wrap their own redirection if they want quieter output.
  # Keep ordinary batches on the established direct path. Larger path sets use
  # bounded transport only when the complete inherited exec payload would
  # approach the current host's limit.
  if _sley_hook_lint_needs_bounded_input "$1"; then
    sizing_status=0
  else
    sizing_status=$?
  fi
  case "$sizing_status" in
    0) _sley_hook_lint_bounded "$1" ;;
    1) _sley_hook_run_batch autolint "$1" ;;
    *) return "$sizing_status" ;;
  esac
}

_sley_hook_validate() { :; }

_sley_message_validate_template() {
  local template="$1" message_file="$2"
  local template_operand="$template" message_operand="$message_file"

  # POSIX awk treats a bare NAME=value operand as a variable assignment, not
  # a filename. Prefix only bare relative paths so every path accepted by the
  # CLI remains opaque to awk without changing the diagnostic spelling.
  [[ "$template_operand" == */* ]] || template_operand="./$template_operand"
  [[ "$message_operand" == */* ]] || message_operand="./$message_operand"

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
        inline = trim(substr(line, colon + 1))
        if (key in required) {
          section_started = 1
          seen[key] = 1
          current = key
          if (inline != "") {
            content[key] = 1
          }
          next
        }
        if (inline == "") {
          # A colon-terminated label is an extra section just like an unknown
          # Markdown heading. It must not donate its body to the preceding
          # required section.
          section_started = 1
          current = ""
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
  ' "$template_operand" "$message_operand"
}

_sley_message_run_provider() {
  local template="$1" validator="$2" message_file="$3"
  local validator_operand="$validator"

  if [[ -n "$template" ]]; then
    _sley_message_validate_template "$template" "$message_file"
  else
    # The executable provider contract is intentionally just one opaque path.
    # Consumers that need profiles or strictness keep those policy choices in
    # their own environment or wrapper instead of teaching Sley their schema.
    # A slashless value still names the file that was checked above. Prefix it
    # explicitly so Bash cannot substitute a same-named builtin or PATH entry.
    [[ "$validator_operand" == */* ]] || validator_operand="./$validator_operand"
    "$validator_operand" "$message_file"
  fi
}

_sley_hook_validate_message() {
  local template="" validator="" message_file="" tmp_root tmp_dir

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
          _sley_die "hook validate-message requires a path after --template"
          return 2
        }
        template="$2"
        shift 2
        ;;
      --validator)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
          _sley_die "hook validate-message requires a path after --validator"
          return 2
        }
        validator="$2"
        shift 2
        ;;
      --message-file)
        [[ $# -ge 2 && -n "${2:-}" ]] || {
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
