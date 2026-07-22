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
  local extension_dir
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
  _sley_source_extensions_from "$extension_dir"
}
