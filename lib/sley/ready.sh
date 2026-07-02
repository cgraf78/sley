#!/usr/bin/env bash
# ready.sh — aggregate readiness orchestration for the sley workflow API.
#
# Readiness deliberately lives outside the hook hot path. It runs broader
# human/agent-facing phases and summarizes them without hiding individual
# blocking or unavailable results.

_sley_ready_run_phase() {
  local phase=$1 full=$2 force=$3
  shift 3

  case "$phase" in
    verify)
      if [[ "$full" == "1" && "$force" == "1" ]]; then
        sley_main verify --run-required --full --force "$@"
      elif [[ "$full" == "1" ]]; then
        sley_main verify --run-required --full "$@"
      elif [[ "$force" == "1" ]]; then
        sley_main verify --run-required --force "$@"
      else
        sley_main verify --run-required "$@"
      fi
      ;;
    status | check | secrets)
      sley_main "$phase" "$@"
      ;;
    *)
      sley_ext_ready_phase "$phase" "$@"
      ;;
  esac
}

_sley_ready_usage() {
  cat <<'EOF'
Usage: sley ready [OPTIONS]

Run the pre-submit readiness report. Phases run concurrently and results
are collected in declaration order: status, check, secrets, verify
(plus any extension phases).

Execution:
  --fix                format changed files before checking. For git,
                       rejects the commit if any staged file was modified
                       (user must re-stage). For sl, formats in-place.
  --full               include slow/full required verification commands
  --force              rerun verification commands even when a success receipt exists
  --exclude PHASE      skip a named phase (repeatable)
  --quiet              suppress output on pass (rc=0). Failure output is
                       still emitted so callers can relay it.

Scope:
  default              use active change-context changes
  --commit             use VCS commit-input changes
  --include-untracked  include untracked files in the selected change set
  --repo-wide          consider all changed files in the repo
  --path PATH          restrict selected changed files to PATH
  --json               emit machine-readable output
EOF
}

_sley_ready() {
  # Pre-scan for --help before _sley_init_repo because init fails with
  # "unsupported repo" when the cwd isn't a recognized VCS checkout.
  # --help should work from anywhere.
  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      -h | --help | help)
        _sley_ready_usage
        return 0
        ;;
    esac
  done

  _sley_init_repo || return $?
  local full=0 force=0 fix=0 quiet=0
  local -a scope_args=() exclude_phases=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)
        full=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --fix)
        fix=1
        shift
        ;;
      --quiet)
        quiet=1
        shift
        ;;
      --exclude)
        [[ $# -ge 2 ]] || {
          echo "sley ready: --exclude requires a phase name" >&2
          return 2
        }
        exclude_phases+=("$2")
        shift 2
        ;;
      *)
        scope_args+=("$1")
        shift
        ;;
    esac
  done

  _sley_parse_scope "${scope_args[@]}" || return $?
  [[ "$_SLEY_SCOPE_JSON" == "0" ]] || _repo_require_json_encoder || return 2

  # Validate the path scope at the orchestrator level. Without this an invalid
  # `--path` would be hidden: each phase subshell would emit exit 2 which the
  # rc handler below downgrades to "unavailable" and the run returns 0 overall,
  # masking a caller usage error. `ready` must fail fast on invalid path scopes.
  #
  # Compute the path filters and the selected file list ONCE here, then hand
  # the precomputed selection to `_sley_warn_out_of_scope` so it does not
  # re-run a VCS pass right after this block.
  local filters selected selected_cache_file
  filters=$(_sley_path_filters) || return $?
  selected=$(_sley_selected_files_for_filters "$filters") || return 2
  selected_cache_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-selected.XXXXXX") || return 2
  printf '%s\n' "$selected" >"$selected_cache_file"
  _SLEY_SELECTED_FILES_CACHE_FILE="$selected_cache_file"
  _SLEY_SELECTED_FILES_CACHE_KEY=$(_sley_selected_files_cache_key "$filters")
  _sley_warn_out_of_scope "$selected"
  local rc global=0 phase status phases_json="" first=1 blocking=0 unavailable=0 errors=0
  local phase_stdout phase_stderr phase_combined summary_line
  local phase_extra_json status_detail verify_cached verify_total
  # _ready_report buffers human-mode output so --quiet can suppress it on
  # pass. _verify_observed tracks whether the verify phase did real work (cached
  # or fresh) so we can write a session marker for SLEY_VERIFY_STATE_DIR
  # consumers without them having to parse our output.
  local _ready_report="" _verify_observed=0
  local stdout_file stderr_file pid phase_index
  local -a phases=("status" "check" "secrets" "verify")
  local -a phase_pids=() phase_stdout_files=() phase_stderr_files=()
  local extension_phases extension_phase
  SLEY_CALLER="${SLEY_CALLER:-human}"
  # shellcheck disable=SC2034 # consumed by sourced local extensions.
  SLEY_SCOPED=1
  sley_hook_init
  extension_phases=$(sley_ext_ready_phases || true)
  while IFS= read -r extension_phase; do
    [[ -n "$extension_phase" ]] && phases+=("$extension_phase")
  done <<<"$extension_phases"
  if [[ "${#exclude_phases[@]}" -gt 0 ]]; then
    local -a _filtered=() _ex
    local _skip _known
    for _ex in "${exclude_phases[@]}"; do
      _known=0
      for phase in "${phases[@]}"; do
        [[ "$phase" == "$_ex" ]] && {
          _known=1
          break
        }
      done
      if [[ "$_known" -eq 0 ]]; then
        echo "sley ready: unknown phase for --exclude: $_ex" >&2
        rm -f "$selected_cache_file"
        return 2
      fi
    done
    for phase in "${phases[@]}"; do
      _skip=0
      for _ex in "${exclude_phases[@]}"; do
        [[ "$phase" == "$_ex" ]] && {
          _skip=1
          break
        }
      done
      [[ "$_skip" -eq 0 ]] && _filtered+=("$phase")
    done
    phases=("${_filtered[@]}")
  fi
  # --fix: format changed files before the concurrent phases so `check`
  # validates already-formatted content. For git (staging area), reject if
  # the formatter modified any file — the committed content would still be
  # the unformatted version until the user re-stages. For sl and other VCS
  # types, formatting in-place is safe (no staging area, the commit sees
  # the result).
  if [[ "$fix" == "1" ]]; then
    local _fix_files _fix_f _fix_pre _fix_post
    local -a _fix_modified=()
    _fix_files=$(_sley_selected_files) || true
    if [[ -n "$_fix_files" ]]; then
      if [[ "$_REPO_TYPE" == "git" ]]; then
        # A partially staged file (both staged AND unstaged hunks) is the one
        # hazard: formatting rewrites the whole worktree file, folding the
        # formatter's output across the unstaged hunk. But refusing every
        # partial file upfront would block the common "stage some hunks, keep
        # editing, commit" flow even when the staged content is already clean.
        # So decide per file by result: back the worktree copy up, format, and
        # if formatting WOULD change it, restore the copy (no clobber) and
        # refuse just those files. A clean partial file formats to a no-op and
        # commits fine. (`sley fix`, the explicit command, still refuses partial
        # files outright; the commit gate is deliberately more permissive.)
        local _fix_partial=""
        if [[ "$_SLEY_SCOPE_CHANGE" == "staged" ]]; then
          local _fix_runnable
          _fix_runnable=$(printf '%s\n' "$_fix_files" | _repo_existing_regular_files)
          _fix_partial=$(_sley_git_staged_partial_files "$_fix_runnable")
        fi
        # Pass 1: partially staged files are probed, never mutated. Format a
        # backup-protected copy to learn whether formatting would change the
        # file, then always restore the worktree — so a refusal leaves nothing
        # touched, and a clean partial file is a pure no-op. If any partial file
        # would be reformatted, refuse before touching the rest of the batch.
        local -a _fix_partial_modified=()
        local _fix_bak
        if [[ -n "$_fix_partial" ]]; then
          while IFS= read -r _fix_f; do
            [[ -n "$_fix_f" ]] || continue
            [[ -f "$_fix_f" ]] || continue
            [[ ! -L "$_fix_f" ]] || continue
            printf '%s\n' "$_fix_partial" | grep -qxF -- "$_fix_f" || continue
            # Refuse without formatting if we cannot back up, rather than risk an
            # unrecoverable clobber of the unstaged hunk.
            if ! { _fix_bak=$(mktemp "${TMPDIR:-/tmp}/sley-fix-bak.XXXXXX") &&
              cp -p "$_fix_f" "$_fix_bak"; }; then
              [[ -n "${_fix_bak:-}" ]] && rm -f "$_fix_bak"
              _fix_partial_modified+=("$_fix_f")
              continue
            fi
            _fix_pre=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            sley_hook_format_file "$_fix_f" >/dev/null 2>&1 || true
            _fix_post=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            cp -p "$_fix_bak" "$_fix_f" # always restore: formatting here is only a probe
            rm -f "$_fix_bak"
            if [[ -n "$_fix_pre" ]] && [[ "$_fix_pre" != "$_fix_post" ]]; then
              _fix_partial_modified+=("$_fix_f")
            fi
          done <<<"$_fix_files"
        fi
        # Pass 2: everything else formats in place as usual (skip the partial
        # files handled above). Reached only when no partial file was refused.
        if [[ "${#_fix_partial_modified[@]}" -eq 0 ]]; then
          while IFS= read -r _fix_f; do
            [[ -n "$_fix_f" ]] || continue
            [[ -f "$_fix_f" ]] || continue
            [[ ! -L "$_fix_f" ]] || continue
            if [[ -n "$_fix_partial" ]] &&
              printf '%s\n' "$_fix_partial" | grep -qxF -- "$_fix_f"; then
              continue
            fi
            _fix_pre=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            sley_hook_format_file "$_fix_f" >/dev/null 2>&1 || true
            _fix_post=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            if [[ -n "$_fix_pre" ]] && [[ "$_fix_pre" != "$_fix_post" ]]; then
              _fix_modified+=("$_fix_f")
            fi
          done <<<"$_fix_files"
        fi
        if [[ "${#_fix_partial_modified[@]}" -gt 0 ]]; then
          _ready_report+="sley fix: refusing to format files with staged and unstaged changes"$'\n'
          _ready_report+="(formatting would fold changes across the unstaged hunk):"$'\n'
          local _fpm
          for _fpm in "${_fix_partial_modified[@]}"; do
            _ready_report+="  $_fpm"$'\n'
          done
          _ready_report+="stage or stash the rest of these files, then re-run the commit."$'\n'
          printf '%s' "$_ready_report" >&2
          rm -f "$selected_cache_file"
          return 2
        fi
        if [[ "${#_fix_modified[@]}" -gt 0 ]]; then
          _ready_report+="sley fix: formatter modified staged files:"$'\n'
          local _fm
          for _fm in "${_fix_modified[@]}"; do
            _ready_report+="  $_fm"$'\n'
          done
          _ready_report+="stage the formatting changes and re-run the commit."$'\n'
          # Fix found mutations — always emit the report (even in quiet
          # mode) so the caller knows what to re-stage.
          printf '%s' "$_ready_report" >&2
          rm -f "$selected_cache_file"
          return 1
        fi
      else
        sley_hook_format "$_fix_files" || true
      fi
    fi
  fi
  # Ready phases are independent report/check producers. Start them together
  # so a slow formatter startup and a slow secret scan overlap, but collect
  # them below in declaration order so humans and agents keep a stable report.
  for phase in "${phases[@]}"; do
    # Call the library dispatcher in a subshell instead of reinvoking $0. That
    # keeps `sley_ready` usable for API consumers that source sley.sh directly,
    # while still isolating each phase's cd/env mutations. Capture stdout AND
    # stderr separately: passing phases like `verify` produce useful human
    # content on stdout that we want to surface in the report; failing phases
    # produce a diagnostic on stderr that we want to surface as the summary.
    # Discarding either would hide the actionable parts of `ready`.
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-stdout.XXXXXX")
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-stderr.XXXXXX")
    (
      # shellcheck disable=SC2034 # read by `_sley_init_repo` in this subshell.
      SLEY_ORIGINAL_PWD="$_SLEY_CALLER_PWD"
      _sley_ready_run_phase "$phase" "$full" "$force" "${scope_args[@]}"
    ) >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    phase_pids+=("$pid")
    phase_stdout_files+=("$stdout_file")
    phase_stderr_files+=("$stderr_file")
  done

  for phase_index in "${!phases[@]}"; do
    phase=${phases[$phase_index]}
    stdout_file=${phase_stdout_files[$phase_index]}
    stderr_file=${phase_stderr_files[$phase_index]}
    pid=${phase_pids[$phase_index]}
    if wait "$pid"; then
      rc=0
    else
      rc=$?
    fi
    phase_stdout=$(cat "$stdout_file")
    phase_stderr=$(cat "$stderr_file")
    rm -f "$stdout_file" "$stderr_file"

    case "$rc" in
      0)
        status="pass"
        ;;
      1)
        status="blocking"
        blocking=$((blocking + 1))
        [[ "$global" -lt 1 ]] && global=1
        ;;
      2)
        if [[ "$phase" == "status" || "$phase" == "verify" ]]; then
          # `status` proves that the repo can be evaluated at all. `verify` is the
          # readiness gate for required checks, so an rc 2 there is a hard
          # error rather than optional tool unavailability.
          status="error"
          errors=$((errors + 1))
          global=2
        else
          # Direct phase invocations can fail hard for missing tools or
          # unsupported scopes, but `ready` is a report. Keep those gaps visible
          # without hiding successful required phases behind one absent tool.
          status="unavailable"
          unavailable=$((unavailable + 1))
        fi
        ;;
      *)
        status="error"
        errors=$((errors + 1))
        global=2
        ;;
    esac

    # Summary surfaces the most useful one-line signal. For a non-pass phase,
    # the first stderr line is typically the `sley X: <reason>` message. For
    # a pass phase, the first stdout line is more informative (e.g. the first
    # `verify` command or the first `status:` line).
    if [[ "$status" == "pass" ]]; then
      summary_line=$(printf '%s\n' "$phase_stdout" | sed '/^$/d' | head -1)
    else
      summary_line=$(printf '%s\n' "$phase_stderr" | sed '/^$/d' | head -1)
      [[ -n "$summary_line" ]] || summary_line=$(printf '%s\n' "$phase_stdout" | sed '/^$/d' | head -1)
    fi
    phase_extra_json=""
    status_detail="$status"
    if [[ "$phase" == "verify" && "$status" == "pass" ]]; then
      if [[ "$_SLEY_SCOPE_JSON" == "1" ]] &&
        printf '%s' "$phase_stdout" | jq -e '.summary.cached_passed? != null' >/dev/null 2>&1; then
        phase_extra_json=$(printf '%s' "$phase_stdout" | jq -r '
          .summary |
          ",\"passed\":" + (.passed | tostring) +
          ",\"cached_passed\":" + (.cached_passed | tostring) +
          ",\"failed\":" + (.failed | tostring) +
          ",\"skipped_slow\":" + (.skipped_slow | tostring)
        ')
        local _jp _jcp
        _jp=$(printf '%s' "$phase_stdout" | jq -r '.summary.passed // 0')
        _jcp=$(printf '%s' "$phase_stdout" | jq -r '.summary.cached_passed // 0')
        [[ $((_jp + _jcp)) -gt 0 ]] && _verify_observed=1
      else
        verify_cached=$(printf '%s\n%s\n' "$phase_stderr" "$phase_stdout" |
          awk '/^sley verify: cached pass / {count += 1} END {print count + 0}')
        verify_total=$(printf '%s\n%s\n' "$phase_stderr" "$phase_stdout" |
          awk '/^sley verify: (cached pass |running required .* command:)/ {count += 1} END {print count + 0}')
        if [[ "$verify_cached" -gt 0 ]]; then
          [[ "$verify_total" -gt 0 ]] || verify_total="$verify_cached"
          status_detail="$status, cached $verify_cached/$verify_total"
        fi
        [[ "$verify_total" -gt 0 ]] && _verify_observed=1
      fi
    fi

    if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
      [[ "$first" == "1" ]] || phases_json+=","
      first=0
      if [[ -n "$summary_line" ]]; then
        phases_json+=$(printf '{"name":"%s","status":"%s","exit_code":%s,"summary":"%s"%s}' \
          "$phase" "$status" "$rc" "$(_repo_json_escape "$summary_line")" "$phase_extra_json")
      else
        phases_json+=$(printf '{"name":"%s","status":"%s","exit_code":%s,"summary":null%s}' \
          "$phase" "$status" "$rc" "$phase_extra_json")
      fi
    else
      _ready_report+="$phase: $rc ($status_detail)"$'\n'
      phase_combined=""
      [[ -n "$phase_stderr" ]] && phase_combined+="$phase_stderr"$'\n'
      [[ -n "$phase_stdout" ]] && phase_combined+="$phase_stdout"
      if [[ -n "$phase_combined" ]]; then
        _ready_report+="$(printf '%s\n' "$phase_combined" | sed '/^$/d' | sed 's/^/  /')"$'\n'
      fi
    fi
  done
  rm -f "$selected_cache_file"

  # Write verify marker when the verify phase did real work and the
  # caller provided a state directory. Agents use this so session-scoped
  # "did the agent run tests?" warnings can recognize gate-verified runs
  # without parsing sley's output.
  if [[ "$_verify_observed" == "1" ]] && [[ -n "${SLEY_VERIFY_STATE_DIR:-}" ]]; then
    mkdir -p "$SLEY_VERIFY_STATE_DIR" 2>/dev/null || true
    : >"$SLEY_VERIFY_STATE_DIR/last-verify-pass" 2>/dev/null || true
  fi

  # Emit buffered human-mode output. --quiet suppresses on pass (rc=0);
  # failure output is always emitted so callers can relay it.
  if [[ "$_SLEY_SCOPE_JSON" != "1" ]] && [[ -n "$_ready_report" ]]; then
    if [[ "$quiet" != "1" ]] || [[ "$global" != "0" ]]; then
      printf '%s' "$_ready_report"
    fi
  fi

  if [[ "$_SLEY_SCOPE_JSON" == "1" ]]; then
    printf '{"phases":[%s],"summary":{"blocking":%s,"unavailable":%s,"errors":%s,"exit_code":%s}}\n' \
      "$phases_json" "$blocking" "$unavailable" "$errors" "$global"
  fi
  return "$global"
}
