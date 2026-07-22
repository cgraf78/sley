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

_sley_ready_supervision_error() {
  printf 'sley ready: cannot supervise %s: %s\n' "$1" "$2" >&2
}

_sley_ready_register_owned_process() {
  local process_pid="$1" process_identity="$2" process_group="$3" record_tmp
  _sley_ready_owned_record="$_sley_ready_owned_dir/$process_pid"
  record_tmp=$_sley_ready_owned_record.tmp.$BASHPID
  (umask 077 && printf '%s\t%s\t%s\n' \
    "$process_pid" "$process_identity" "$process_group" >"$record_tmp") || {
    rm -f -- "$record_tmp"
    return 1
  }
  mv -f -- "$record_tmp" "$_sley_ready_owned_record" || {
    rm -f -- "$record_tmp"
    return 1
  }
}

_sley_ready_registered_processes() {
  local owned_dir="$1" record_file process_pid process_identity process_group extra
  [[ -d "$owned_dir" ]] || return 0
  for record_file in "$owned_dir"/*; do
    [[ -f "$record_file" ]] || continue
    process_pid=""
    process_identity=""
    process_group=""
    extra=""
    IFS=$'\t' read -r process_pid process_identity process_group extra <"$record_file" || true
    [[ -z "$extra" && -n "$process_pid" && "$process_pid" != *[!0-9]* ]] || continue
    [[ -n "$process_identity" ]] || continue
    [[ -n "$process_group" && "$process_group" != *[!0-9]* ]] || continue
    printf '%s\t%s\t%s\n' "$process_pid" "$process_identity" "$process_group"
  done
}

_sley_ready_signal_direct_child() {
  local signal_name="$1" process_pid="$2" expected_identity="${3:-}"
  local attempt current_identity
  [[ -n "$process_pid" ]] || return 0
  if [[ -n "$expected_identity" ]]; then
    for ((attempt = 0; attempt < 3; attempt++)); do
      if current_identity=$(_sley_ready_process_identity "$process_pid"); then
        [[ "$current_identity" == "$expected_identity" ]] || return 0
        kill -"$signal_name" "$process_pid" 2>/dev/null || true
        return 0
      fi
      sleep 0.01
    done
  fi
  _sley_ready_process_has_exited "$process_pid" && return 0
  # The direct child was just observed live but identity lookup is unavailable.
  # This bounds cancellation on macOS when ps fails after launch; the retry and
  # exited-state check avoid raw delivery after ordinary completion.
  kill -"$signal_name" "$process_pid" 2>/dev/null || true
}

_sley_ready_wait_for_direct_child() {
  local process_pid="$1" attempts="$2" attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    _sley_ready_process_has_exited "$process_pid" && return 0
    sleep 0.05
  done
  _sley_ready_process_has_exited "$process_pid"
}

_sley_ready_cleanup_registered_processes() {
  local owned_dir="$1" process_pid process_identity process_group process_tree combined_tree=""
  local -a process_pids=() process_identities=() process_groups=() process_trees=()
  while IFS=$'\t' read -r process_pid process_identity process_group; do
    [[ -n "$process_pid" ]] || continue
    process_pids+=("$process_pid")
    process_identities+=("$process_identity")
    process_groups+=("$process_group")
    if ! process_tree=$(_sley_ready_process_tree "$process_pid" "$process_identity"); then
      process_tree="$process_pid"$'\t'"$process_identity"
    fi
    process_trees+=("$process_tree")
    combined_tree+=$'\n'$process_tree
    # Extensions are trusted sourced code. Give their TERM handlers the usual
    # opportunity to release resources, while the immutable group guardian and
    # the escalation below retain ownership of ordinary same-group descendants.
    # Hooks and phases must not daemonize or create a new session while being
    # cancelled; doing so would leave the portable process-group boundary.
    _sley_ready_signal_owned_tree_term \
      "$process_pid" "$process_identity" "$process_group" "$process_tree"
  done < <(_sley_ready_registered_processes "$owned_dir")
  _sley_ready_wait_for_processes "$combined_tree" 10 || true
  for process_pid in "${!process_pids[@]}"; do
    _sley_ready_processes_have_survivor "${process_trees[$process_pid]}" || continue
    _sley_ready_escalate_tree \
      "${process_pids[$process_pid]}" \
      "${process_identities[$process_pid]}" \
      "${process_trees[$process_pid]}" 0 \
      "${process_groups[$process_pid]}"
  done
}

_sley_ready_process_has_exited() {
  local process_pid="$1" stat_line stat_fields state=""
  if [[ -r "/proc/$process_pid/stat" ]]; then
    { stat_line=$(<"/proc/$process_pid/stat"); } 2>/dev/null || return 0
    stat_fields=${stat_line##*) }
    state=${stat_fields%% *}
  else
    state=$(_sley_ready_ps -p "$process_pid" -o stat= 2>/dev/null) || {
      kill -0 "$process_pid" 2>/dev/null && return 1
      return 0
    }
    state=${state#"${state%%[![:space:]]*}"}
  fi
  [[ -z "$state" || "$state" == [ZX]* ]]
}

_sley_ready_worker_fallback_cancel() {
  local signal_status="$1"
  trap '' INT TERM HUP
  # The outer supervisor snapshots the worker tree before delivery and owns
  # identity-validated descendant cleanup. This fallback only covers the short
  # interval before `_sley_ready_impl` installs its full cleanup traps.
  exit "$signal_status"
}

_sley_ready() {
  # `ready` is part of the sourceable API, so temporary signal handlers must
  # not replace traps owned by the calling shell after this invocation ends.
  local _arg _saved_int _saved_term _saved_hup _rc _worker_rc
  local _sley_ready_pid="" _sley_ready_signal_status=0 _sley_ready_signal_name=""
  local _sley_ready_delivery_signal=""
  local _sley_ready_root_identity="" _sley_ready_root_record=""
  local _sley_ready_had_monitor=0 _sley_ready_tree="" _sley_ready_identity_available=0
  local _sley_ready_status_dir="" _sley_ready_owned_dir=""
  local _sley_ready_worker_gate="" _sley_ready_worker_gate_tmp=""
  local _sley_ready_worker_gate_token="" _sley_ready_worker_abort=""
  local _sley_ready_worker_dead="" _sley_ready_gate_attempt
  local _sley_ready_startup_failed=0 _sley_ready_startup_error=""
  local _sley_ready_registered_cleanup_done=0
  for _arg in "$@"; do
    case "$_arg" in
      -h | --help | help)
        _sley_ready_usage
        return 0
        ;;
    esac
  done

  _saved_int=$(trap -p INT)
  _saved_term=$(trap -p TERM)
  _saved_hup=$(trap -p HUP)

  trap '_sley_ready_forward_signal 130 INT' INT
  trap '_sley_ready_forward_signal 143 TERM' TERM
  trap '_sley_ready_forward_signal 129 HUP' HUP

  _sley_ready_status_dir=$(mktemp -d "${TMPDIR:-/tmp}/sley-ready-supervisor.XXXXXX") || {
    eval "${_saved_int:-trap - INT}"
    eval "${_saved_term:-trap - TERM}"
    eval "${_saved_hup:-trap - HUP}"
    _rc=2
    [[ "$_sley_ready_signal_status" == "0" ]] || _rc=$_sley_ready_signal_status
    return "$_rc"
  }
  _sley_ready_owned_dir=$_sley_ready_status_dir/owned
  _sley_ready_worker_gate=$_sley_ready_status_dir/worker-gate
  _sley_ready_worker_gate_tmp=$_sley_ready_status_dir/.worker-gate.$BASHPID
  _sley_ready_worker_gate_token=$BASHPID.$RANDOM.$RANDOM
  _sley_ready_worker_abort=$_sley_ready_status_dir/worker-abort
  _sley_ready_worker_dead=$_sley_ready_status_dir/worker-dead
  if ! mkdir "$_sley_ready_owned_dir"; then
    rm -rf -- "$_sley_ready_status_dir"
    eval "${_saved_int:-trap - INT}"
    eval "${_saved_term:-trap - TERM}"
    eval "${_saved_hup:-trap - HUP}"
    _rc=2
    [[ "$_sley_ready_signal_status" == "0" ]] || _rc=$_sley_ready_signal_status
    return "$_rc"
  fi
  if [[ "$-" == *i* && -t 0 ]]; then
    # Process substitution gives an interactive sourced caller an invisible
    # supervised child: unlike `&`, it does not create a job-table entry or a
    # background process group that would receive SIGTTIN while reading the
    # terminal. Its stdin is the caller's controlling terminal, and stdout and
    # stderr retain any redirections applied to `sley_ready`.
    : > >(
      trap '_sley_ready_worker_fallback_cancel 130' INT
      trap '_sley_ready_worker_fallback_cancel 143' TERM
      trap '_sley_ready_worker_fallback_cancel 129' HUP
      for ((_sley_ready_gate_attempt = 0; _sley_ready_gate_attempt < 300; _sley_ready_gate_attempt++)); do
        [[ ! -e "$_sley_ready_worker_abort" ]] || exit 2
        if [[ -f "$_sley_ready_worker_gate" ]] &&
          [[ "$(<"$_sley_ready_worker_gate")" == "$_sley_ready_worker_gate_token" ]]; then
          break
        fi
        [[ -d "$_sley_ready_status_dir" ]] || exit 2
        sleep 0.01
      done
      [[ -f "$_sley_ready_worker_gate" && ! -e "$_sley_ready_worker_abort" ]] || exit 2
      [[ "$(<"$_sley_ready_worker_gate")" == "$_sley_ready_worker_gate_token" ]] || exit 2
      _sley_ready_impl "$@" </dev/tty
    )
    _sley_ready_pid=$!
  else
    # With job control disabled, an explicitly inherited stdin keeps the
    # worker in the caller's process group without Bash replacing stdin with
    # /dev/null. Restore the caller's monitor option immediately after launch.
    [[ "$-" == *m* ]] && _sley_ready_had_monitor=1
    set +m
    (
      trap '_sley_ready_worker_fallback_cancel 130' INT
      trap '_sley_ready_worker_fallback_cancel 143' TERM
      trap '_sley_ready_worker_fallback_cancel 129' HUP
      for ((_sley_ready_gate_attempt = 0; _sley_ready_gate_attempt < 300; _sley_ready_gate_attempt++)); do
        [[ ! -e "$_sley_ready_worker_abort" ]] || exit 2
        if [[ -f "$_sley_ready_worker_gate" ]] &&
          [[ "$(<"$_sley_ready_worker_gate")" == "$_sley_ready_worker_gate_token" ]]; then
          break
        fi
        [[ -d "$_sley_ready_status_dir" ]] || exit 2
        sleep 0.01
      done
      [[ -f "$_sley_ready_worker_gate" && ! -e "$_sley_ready_worker_abort" ]] || exit 2
      [[ "$(<"$_sley_ready_worker_gate")" == "$_sley_ready_worker_gate_token" ]] || exit 2
      _sley_ready_impl "$@"
    ) <&0 &
    _sley_ready_pid=$!
    [[ "$_sley_ready_had_monitor" == "1" ]] && set -m
  fi
  if _sley_ready_root_identity=$(_sley_ready_process_identity "$_sley_ready_pid"); then
    _sley_ready_root_record="$_sley_ready_pid"$'\t'"$_sley_ready_root_identity"
    _sley_ready_identity_available=1
  else
    _sley_ready_startup_failed=1
    _sley_ready_startup_error="worker process identity is unavailable"
  fi
  [[ "$_sley_ready_signal_status" == "0" ]] || _sley_ready_startup_failed=1
  if [[ "$_sley_ready_startup_failed" == "0" ]]; then
    if ! printf '%s\n' "$_sley_ready_worker_gate_token" >"$_sley_ready_worker_gate_tmp" ||
      ! mv -f -- "$_sley_ready_worker_gate_tmp" "$_sley_ready_worker_gate" ||
      [[ ! -f "$_sley_ready_worker_gate" ]]; then
      _sley_ready_startup_failed=1
      _sley_ready_startup_error="worker launch gate could not be published"
    fi
  fi
  if [[ "$_sley_ready_startup_failed" != "0" ]]; then
    # Identity is a prerequisite for execution. The finite gate also exits if
    # the private directory disappears, so abort publication cannot hang.
    : >"$_sley_ready_worker_abort" 2>/dev/null || true
    rm -rf -- "$_sley_ready_status_dir"
    wait "$_sley_ready_pid" 2>/dev/null || true
    if [[ -n "$_sley_ready_startup_error" && "$_sley_ready_signal_status" == "0" ]]; then
      _sley_ready_supervision_error worker "$_sley_ready_startup_error"
    fi
    eval "${_saved_int:-trap - INT}"
    eval "${_saved_term:-trap - TERM}"
    eval "${_saved_hup:-trap - HUP}"
    _rc=2
    [[ "$_sley_ready_signal_status" == "0" ]] || _rc=$_sley_ready_signal_status
    return "$_rc"
  fi
  if [[ "$_sley_ready_signal_status" != "0" ]]; then
    _sley_ready_delivery_signal=$_sley_ready_signal_name
    [[ "$_sley_ready_delivery_signal" != "INT" ]] || _sley_ready_delivery_signal=TERM
    if [[ -n "$_sley_ready_root_identity" ]] && _sley_ready_tree=$(
      _sley_ready_process_tree "$_sley_ready_pid" "$_sley_ready_root_identity"
    ); then
      _sley_ready_identity_available=1
      _sley_ready_signal_direct_child \
        "$_sley_ready_delivery_signal" "$_sley_ready_pid" "$_sley_ready_root_identity"
    else
      _sley_ready_tree=$_sley_ready_root_record
      if [[ -n "$_sley_ready_tree" ]]; then
        _sley_ready_identity_available=1
        _sley_ready_signal_direct_child \
          "$_sley_ready_delivery_signal" "$_sley_ready_pid" "$_sley_ready_root_identity"
      fi
    fi
  fi
  if wait "$_sley_ready_pid"; then
    _worker_rc=0
  else
    _worker_rc=$?
  fi
  if [[ "$_sley_ready_signal_status" != "0" ]]; then
    # Stop repeat delivery from interrupting the bounded escalation below.
    # Process records include start times, so delayed escalation cannot target
    # a different process that reused a completed descendant's numeric PID.
    # Give cooperative TERM handlers and the worker's deferred cleanup a short,
    # bounded interval before killing only validated survivors.
    trap '' INT TERM HUP
    # Bash defers the worker's trap while it waits for a managed child. Use the
    # journal published before each launch to begin child cleanup immediately,
    # instead of making an interactive cancellation wait for that deferred trap.
    _sley_ready_cleanup_registered_processes "$_sley_ready_owned_dir"
    _sley_ready_registered_cleanup_done=1
    if [[ "$_sley_ready_identity_available" == "1" ]]; then
      if ! _sley_ready_wait_for_direct_child "$_sley_ready_pid" 10; then
        # The worker wrapper owns a pending cancellation trap. Remove its
        # known blocking descendants while it is running so it can reap them;
        # the trap exits before implementation code resumes. If it still does
        # not exit, the strict escalation below stops it and never resumes it.
        _sley_ready_signal_processes KILL \
          "$(_sley_ready_processes_except "$_sley_ready_tree" "$_sley_ready_pid")"
        if ! _sley_ready_wait_for_direct_child "$_sley_ready_pid" 10; then
          _sley_ready_escalate_tree \
            "$_sley_ready_pid" "$_sley_ready_root_identity" "$_sley_ready_tree" 1
        fi
      fi
    fi
    wait "$_sley_ready_pid" 2>/dev/null || true
    : >"$_sley_ready_worker_dead" 2>/dev/null || true
    _sley_ready_signal_processes KILL \
      "$(_sley_ready_processes_except "$_sley_ready_tree" "$_sley_ready_pid")"
    if [[ "$_sley_ready_registered_cleanup_done" == "0" ]]; then
      _sley_ready_cleanup_registered_processes "$_sley_ready_owned_dir"
    fi
    _rc=$_sley_ready_signal_status
  else
    # A PID-specific wait is not held open by descriptors inherited by worker
    # descendants. The worker status is therefore authoritative, including an
    # untrappable signal such as KILL.
    _rc=$_worker_rc
    : >"$_sley_ready_worker_dead" 2>/dev/null || true
    if [[ "$_sley_ready_registered_cleanup_done" == "0" ]]; then
      _sley_ready_cleanup_registered_processes "$_sley_ready_owned_dir"
    fi
  fi
  _sley_ready_pid=""
  rm -rf -- "$_sley_ready_status_dir"

  eval "${_saved_int:-trap - INT}"
  eval "${_saved_term:-trap - TERM}"
  eval "${_saved_hup:-trap - HUP}"
  return "$_rc"
}

_sley_ready_forward_signal() {
  local signal_status="$1" signal_name="$2" delivery_signal="$2"
  if [[ "${_sley_ready_signal_status:-0}" == "0" ]]; then
    _sley_ready_signal_status=$signal_status
    _sley_ready_signal_name=$signal_name
  fi
  [[ -n "${_sley_ready_pid:-}" ]] || return 0
  # Non-interactive Bash starts `&` children with SIGINT ignored, and an
  # ignored signal cannot subsequently be trapped. TERM is the worker's
  # internal cancellation wakeup for an outer INT; the sourced caller still
  # returns the conventional 130 recorded above. Interactive workers receive
  # terminal INT directly and retain their own INT trap.
  [[ "$delivery_signal" != "INT" ]] || delivery_signal=TERM
  if [[ -n "$_sley_ready_root_identity" ]] && _sley_ready_tree=$(
    _sley_ready_process_tree "$_sley_ready_pid" "$_sley_ready_root_identity"
  ); then
    _sley_ready_identity_available=1
    _sley_ready_signal_direct_child \
      "$delivery_signal" "$_sley_ready_pid" "$_sley_ready_root_identity"
  else
    # Topology discovery may fail after launch, but the root identity was
    # captured before publishing `_sley_ready_pid` to the signal handler.
    _sley_ready_tree=$_sley_ready_root_record
    if [[ -n "$_sley_ready_tree" ]]; then
      _sley_ready_identity_available=1
      _sley_ready_signal_direct_child \
        "$delivery_signal" "$_sley_ready_pid" "$_sley_ready_root_identity"
    fi
  fi
}

_sley_ready_ps() {
  local ps_command=""
  if [[ -x /bin/ps ]]; then
    ps_command=/bin/ps
  elif [[ -x /usr/bin/ps ]]; then
    ps_command=/usr/bin/ps
  else
    ps_command=$(command -v ps 2>/dev/null) || return 127
  fi
  "$ps_command" "$@"
}

_sley_ready_process_tree() {
  local status current_identity expected_identity="${2:-}"
  if [[ -r /proc/self/stat ]]; then
    if _sley_ready_proc_children_tree "$@"; then
      return 0
    else
      status=$?
    fi
    # Status 1 means the root itself disappeared or changed identity. Status 2
    # means only that this procfs cannot provide a complete children traversal.
    [[ "$status" == "2" ]] || return "$status"
    # procfs implementations without the children file are common in
    # containers. A single ps snapshot is much cheaper than reading every
    # process stat file in Bash, while identities still come from procfs.
    if _sley_ready_ps_process_tree "$@"; then
      return 0
    fi
    current_identity=$(_sley_ready_process_identity "$1") || return 1
    if [[ -n "$expected_identity" && "$current_identity" != "$expected_identity" ]]; then
      return 1
    fi
    _sley_ready_proc_snapshot_tree "$@"
  else
    _sley_ready_ps_process_tree "$@"
  fi
}

_sley_ready_parse_proc_stat() {
  local expected_pid="$1" stat_line="$2" stat_fields state parent_pid process_group session start_ticks
  [[ "$expected_pid" != *[!0-9]* && -n "$expected_pid" ]] || return 1
  [[ "$stat_line" == "$expected_pid ("* && "$stat_line" == *") "* ]] || return 1
  stat_fields=${stat_line##*) }
  # Linux proc stat fields 1 and 2 were removed above. The remaining fields
  # begin with state (3), ppid (4), pgrp (5), session (6), and end this subset
  # with the immutable process start tick at position 20 (field 22).
  # shellcheck disable=SC2086 # Proc stat fields are intentionally word-split.
  set -- $stat_fields
  [[ $# -ge 20 ]] || return 1
  state=$1
  parent_pid=$2
  process_group=$3
  session=$4
  start_ticks=${20}
  [[ -n "$state" ]] || return 1
  [[ "$parent_pid" != *[!0-9]* && -n "$parent_pid" ]] || return 1
  [[ "$process_group" != *[!0-9]* && -n "$process_group" ]] || return 1
  [[ "$session" != *[!0-9]* && -n "$session" ]] || return 1
  [[ "$start_ticks" != *[!0-9]* && -n "$start_ticks" ]] || return 1
  printf -v _sley_ready_proc_pid '%s' "$expected_pid"
  printf -v _sley_ready_proc_parent '%s' "$parent_pid"
  printf -v _sley_ready_proc_group '%s' "$process_group"
  printf -v _sley_ready_proc_identity 'proc:%s' "$start_ticks"
}

_sley_ready_proc_children_tree() {
  local root_pid="$1" expected_root_identity="${2:-}"
  local root_identity current_root_identity parent_pid child_pid children_file children
  local child_identity index
  local -a frontier_pids=("$root_pid") next_pids=()
  local -a descendants=() descendant_records=()

  root_identity=$(_sley_ready_process_identity "$root_pid") || return 1
  if [[ -n "$expected_root_identity" && "$root_identity" != "$expected_root_identity" ]]; then
    return 1
  fi
  [[ -r "/proc/$root_pid/task/$root_pid/children" ]] || return 2

  while [[ "${#frontier_pids[@]}" -gt 0 ]]; do
    next_pids=()
    for parent_pid in "${frontier_pids[@]}"; do
      children_file=/proc/$parent_pid/task/$parent_pid/children
      # A discovered parent that exits during traversal may reparent an unseen
      # child. Fall back to the full snapshot rather than accept that gap.
      [[ -r "$children_file" ]] || return 2
      children=$(<"$children_file") || return 2
      for child_pid in $children; do
        [[ "$child_pid" != *[!0-9]* && -n "$child_pid" ]] || return 2
        child_identity=$(_sley_ready_process_identity "$child_pid") || return 2
        next_pids+=("$child_pid")
        descendants+=("$child_pid")
        descendant_records+=("$child_pid"$'\t'"$child_identity")
      done
    done
    frontier_pids=("${next_pids[@]}")
  done

  current_root_identity=$(_sley_ready_process_identity "$root_pid") || return 1
  [[ "$current_root_identity" == "$root_identity" ]] || return 1
  for ((index = ${#descendants[@]} - 1; index >= 0; index--)); do
    printf '%s\n' "${descendant_records[$index]}"
  done
  printf '%s\t%s\n' "$root_pid" "$root_identity"
}

_sley_ready_proc_snapshot_tree() {
  local root_pid="$1" expected_root_identity="${2:-}"
  local stat_file stat_line child_pid child_parent child_identity
  local root_identity current_root_identity parent_pid index snapshot_index
  local _sley_ready_proc_pid="" _sley_ready_proc_parent="" _sley_ready_proc_group=""
  local _sley_ready_proc_identity=""
  local -a snapshot_pids=() snapshot_parents=() snapshot_identities=()
  local -a frontier_pids=("$root_pid") next_pids=()
  local -a descendants=() descendant_records=()

  root_identity=$(_sley_ready_process_identity "$root_pid") || return 1
  if [[ -n "$expected_root_identity" && "$root_identity" != "$expected_root_identity" ]]; then
    return 1
  fi
  # Some Linux kernels omit task/PID/children even though proc stat is
  # available. Build one stable-enough process snapshot from stat files using
  # Bash's built-in file read, so minimal systems still do not need ps.
  for stat_file in /proc/[0-9]*/stat; do
    [[ -r "$stat_file" ]] || continue
    stat_line=$(<"$stat_file") || continue
    child_pid=${stat_file#/proc/}
    child_pid=${child_pid%/stat}
    _sley_ready_parse_proc_stat "$child_pid" "$stat_line" || continue
    snapshot_pids+=("$_sley_ready_proc_pid")
    snapshot_parents+=("$_sley_ready_proc_parent")
    snapshot_identities+=("$_sley_ready_proc_identity")
  done

  while [[ "${#frontier_pids[@]}" -gt 0 ]]; do
    next_pids=()
    for parent_pid in "${frontier_pids[@]}"; do
      for snapshot_index in "${!snapshot_pids[@]}"; do
        [[ "${snapshot_parents[$snapshot_index]}" == "$parent_pid" ]] || continue
        child_pid=${snapshot_pids[$snapshot_index]}
        child_identity=${snapshot_identities[$snapshot_index]}
        next_pids+=("$child_pid")
        descendants+=("$child_pid")
        descendant_records+=("$child_pid"$'\t'"$child_identity")
      done
    done
    frontier_pids=("${next_pids[@]}")
  done

  current_root_identity=$(_sley_ready_process_identity "$root_pid") || return 1
  [[ "$current_root_identity" == "$root_identity" ]] || return 1

  for ((index = ${#descendants[@]} - 1; index >= 0; index--)); do
    printf '%s\n' "${descendant_records[$index]}"
  done
  printf '%s\t%s\n' "$root_pid" "$root_identity"
}

_sley_ready_ps_process_tree() {
  local root_pid="$1" expected_root_identity="${2:-}"
  local snapshot parent_pid child_pid child_parent child_identity index
  local day_name month day process_time year session process_group started root_identity=""
  local -a frontier=("$root_pid") next_frontier=() descendants=() descendant_records=()
  snapshot=$(
    _sley_ready_ps -A -o pid= -o ppid= -o lstart= -o sess= -o pgid= 2>/dev/null
  ) || return 1

  while read -r child_pid child_parent day_name month day process_time year session process_group; do
    if [[ "$child_pid" == "$root_pid" ]]; then
      started="$day_name $month $day $process_time $year"
      root_identity=$(
        _sley_ready_process_identity "$root_pid" "$started" "$session" "$process_group"
      ) || return 1
      if [[ -n "$expected_root_identity" && "$root_identity" != "$expected_root_identity" ]]; then
        return 1
      fi
      break
    fi
  done <<<"$snapshot"
  [[ -n "$root_identity" ]] || return 1

  while [[ "${#frontier[@]}" -gt 0 ]]; do
    next_frontier=()
    for parent_pid in "${frontier[@]}"; do
      while read -r child_pid child_parent day_name month day process_time year session process_group; do
        [[ "$child_parent" == "$parent_pid" ]] || continue
        next_frontier+=("$child_pid")
        started="$day_name $month $day $process_time $year"
        if child_identity=$(
          _sley_ready_process_identity "$child_pid" "$started" "$session" "$process_group"
        ); then
          descendants+=("$child_pid")
          descendant_records+=("$child_pid"$'\t'"$child_identity")
        fi
      done <<<"$snapshot"
    done
    frontier=("${next_frontier[@]}")
  done

  for ((index = ${#descendants[@]} - 1; index >= 0; index--)); do
    printf '%s\n' "${descendant_records[$index]}"
  done
  printf '%s\t%s\n' "$root_pid" "$root_identity"
}

_sley_ready_process_identity() {
  local process_pid="$1" fallback_started="${2:-}"
  local stat_line current day_name month day process_time year started
  local _sley_ready_proc_pid="" _sley_ready_proc_parent="" _sley_ready_proc_group=""
  local _sley_ready_proc_identity=""
  if [[ -r "/proc/$process_pid/stat" ]]; then
    { stat_line=$(<"/proc/$process_pid/stat"); } 2>/dev/null || return 1
    _sley_ready_parse_proc_stat "$process_pid" "$stat_line" || return 1
    printf '%s\n' "$_sley_ready_proc_identity"
    return 0
  fi

  # macOS has no procfs start ticks. Launch time is stable across reparenting,
  # setsid, process-group changes, and exec; those mutable fields must not be
  # part of identity. Its one-second resolution leaves a narrow same-second
  # PID-reuse limitation, so callers minimize every delayed-signal interval.
  if [[ -n "$fallback_started" ]]; then
    started=$fallback_started
  else
    current=$(_sley_ready_ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1
    read -r day_name month day process_time year <<<"$current"
    started="$day_name $month $day $process_time $year"
  fi
  [[ -n "$started" ]] || return 1
  printf 'ps:%s\n' "$started"
}

_sley_ready_process_group() {
  local process_pid="$1" stat_line process_group
  local _sley_ready_proc_pid="" _sley_ready_proc_parent="" _sley_ready_proc_group=""
  local _sley_ready_proc_identity=""
  if [[ -r "/proc/$process_pid/stat" ]]; then
    { stat_line=$(<"/proc/$process_pid/stat"); } 2>/dev/null || return 1
    _sley_ready_parse_proc_stat "$process_pid" "$stat_line" || return 1
    printf '%s\n' "$_sley_ready_proc_group"
    return 0
  fi
  process_group=$(_sley_ready_ps -p "$process_pid" -o pgid= 2>/dev/null) || return 1
  process_group=${process_group//[[:space:]]/}
  [[ -n "$process_group" && "$process_group" != *[!0-9]* ]] || return 1
  printf '%s\n' "$process_group"
}

_sley_ready_signal_process_group() {
  local signal_name="$1" process_group="$2"
  [[ -n "$process_group" && "$process_group" != *[!0-9]* && "$process_group" != "0" ]] || return 0
  # A process-group ID cannot be reused while any member survives. Managed
  # wrappers are group leaders, so this still reaches descendants after the
  # wrapper exits and they are reparented.
  kill -"$signal_name" -- "-$process_group" 2>/dev/null || true
}

_sley_ready_signal_owned_tree_term() {
  local root_pid="$1" root_identity="$2" process_group="$3" process_tree="$4"
  local direct_child="${5:-0}"
  # Use the numeric group only while its recorded leader still has the launch
  # identity. Delayed cleanup uses identity-validated tree records exclusively,
  # so a vanished group's PGID cannot be reused underneath a later signal.
  if _sley_ready_process_is_same "$root_pid" "$root_identity" ||
    { [[ "$direct_child" == "1" ]] &&
      ! _sley_ready_process_has_exited "$root_pid"; }; then
    _sley_ready_signal_process_group TERM "$process_group"
  fi
  _sley_ready_signal_processes TERM "$process_tree"
}

_sley_ready_process_is_same() {
  local process_pid="$1" expected_identity="$2" current_identity
  current_identity=$(_sley_ready_process_identity "$process_pid") || return 1
  [[ "$current_identity" == "$expected_identity" ]]
}

_sley_ready_signal_processes() {
  local signal_name="$1" process_list="$2" excluded_pid="${3:-}"
  local process_pid process_identity
  while IFS=$'\t' read -r process_pid process_identity; do
    [[ -n "$process_pid" && "$process_pid" != "$excluded_pid" ]] || continue
    _sley_ready_process_is_same "$process_pid" "$process_identity" || continue
    kill -"$signal_name" "$process_pid" 2>/dev/null || true
  done <<<"$process_list"
}

_sley_ready_processes_except() {
  local process_list="$1" excluded_pid="$2" process_pid process_identity
  while IFS=$'\t' read -r process_pid process_identity; do
    [[ -n "$process_pid" && "$process_pid" != "$excluded_pid" ]] || continue
    printf '%s\t%s\n' "$process_pid" "$process_identity"
  done <<<"$process_list"
}

_sley_ready_reverse_processes() {
  local process_list="$1" process_pid process_identity index
  local -a process_records=()
  while IFS=$'\t' read -r process_pid process_identity; do
    [[ -n "$process_pid" ]] || continue
    process_records+=("$process_pid"$'\t'"$process_identity")
  done <<<"$process_list"
  for ((index = ${#process_records[@]} - 1; index >= 0; index--)); do
    printf '%s\n' "${process_records[$index]}"
  done
}

_sley_ready_processes_contain_all() {
  local process_list="$1" required_list="$2"
  local process_pid process_identity candidate_pid candidate_identity found
  while IFS=$'\t' read -r process_pid process_identity; do
    [[ -n "$process_pid" ]] || continue
    found=0
    while IFS=$'\t' read -r candidate_pid candidate_identity; do
      if [[ "$candidate_pid" == "$process_pid" &&
        "$candidate_identity" == "$process_identity" ]]; then
        found=1
        break
      fi
    done <<<"$process_list"
    [[ "$found" == "1" ]] || return 1
  done <<<"$required_list"
  return 0
}

_sley_ready_process_is_stopped() {
  local process_pid="$1" expected_identity="$2" stat_line stat_fields state
  _sley_ready_process_is_same "$process_pid" "$expected_identity" || return 1
  if [[ -r "/proc/$process_pid/stat" ]]; then
    { stat_line=$(<"/proc/$process_pid/stat"); } 2>/dev/null || return 1
    stat_fields=${stat_line##*) }
    state=${stat_fields%% *}
  else
    state=$(_sley_ready_ps -p "$process_pid" -o stat= 2>/dev/null) || return 1
    state=${state#"${state%%[![:space:]]*}"}
  fi
  [[ "$state" == [Tt]* ]]
}

_sley_ready_stop_process() {
  local process_pid="$1" process_identity="$2" attempt
  local process_record="$process_pid"$'\t'"$process_identity"
  _sley_ready_signal_processes STOP "$process_record"
  for ((attempt = 0; attempt < 20; attempt++)); do
    _sley_ready_process_is_stopped "$process_pid" "$process_identity" && return 0
    _sley_ready_process_is_same "$process_pid" "$process_identity" || return 1
    sleep 0.01
  done
  return 1
}

_sley_ready_escalate_tree() {
  local root_pid="$1" root_identity="$2" saved_tree="$3" direct_child="${4:-0}"
  local process_group="${5:-}"
  local root_record="$root_pid"$'\t'"$root_identity"
  local current_tree="" combined_tree="$saved_tree"
  local descendant_tree="" current_descendants="" scan_attempt stabilized=0

  if [[ -n "$process_group" ]]; then
    if current_tree=$(_sley_ready_process_tree "$root_pid" "$root_identity"); then
      combined_tree+=$'\n'$current_tree
    fi
    # Freeze parents before children, then rescan until no new identity record
    # appears. A TERM handler can fork between a snapshot and its STOP; the next
    # pass freezes that child and discovers anything it created in the window.
    for ((scan_attempt = 0; scan_attempt < 8; scan_attempt++)); do
      descendant_tree=$(_sley_ready_processes_except "$combined_tree" "$root_pid")
      _sley_ready_signal_processes STOP \
        "$(_sley_ready_reverse_processes "$descendant_tree")"
      sleep 0.02
      current_tree=""
      if current_tree=$(_sley_ready_process_tree "$root_pid" "$root_identity"); then
        current_descendants=$(
          _sley_ready_processes_except "$current_tree" "$root_pid"
        )
      else
        current_descendants=""
      fi
      if _sley_ready_processes_contain_all "$descendant_tree" "$current_descendants"; then
        stabilized=1
        break
      fi
      combined_tree+=$'\n'$current_tree
    done
    descendant_tree=$(_sley_ready_processes_except "$combined_tree" "$root_pid")
    if [[ "$stabilized" != "1" ]]; then
      # An owned subtree that defeats the bounded freeze is not allowed to keep
      # running. A raw group signal is safe only while the recorded leader still
      # has its launch identity; otherwise use cached identities exclusively.
      if _sley_ready_process_is_same "$root_pid" "$root_identity"; then
        _sley_ready_signal_process_group KILL "$process_group"
      fi
      _sley_ready_signal_processes KILL "$descendant_tree"
      if [[ "$direct_child" == "1" ]]; then
        _sley_ready_signal_direct_child KILL "$root_pid" "$root_identity"
      else
        _sley_ready_signal_processes KILL "$root_record"
      fi
      return 0
    fi
    _sley_ready_signal_processes KILL \
      "$descendant_tree"
    if [[ "$direct_child" == "1" ]]; then
      if ! _sley_ready_wait_for_direct_child "$root_pid" 10; then
        _sley_ready_signal_direct_child KILL "$root_pid" "$root_identity"
      fi
    else
      if ! _sley_ready_wait_for_processes "$root_record" 10; then
        _sley_ready_signal_processes KILL "$root_record"
      fi
    fi
    # Descendants were stopped before their children were killed, so a TERM
    # handler cannot resume and fork after the final snapshot. Cached identities
    # catch reparented survivors without a delayed raw signal to a reusable PGID.
    _sley_ready_signal_processes KILL \
      "$(_sley_ready_processes_except "$combined_tree" "$root_pid")"
    return 0
  fi

  # The cooperative TERM grace has already elapsed. Freeze the wrapper before
  # the final snapshot, then kill descendants and the still-stopped wrapper.
  # Never resume it: arbitrary hook code could otherwise fork a replacement
  # after the snapshot and exit before another STOP.
  if [[ "$direct_child" == "1" ]]; then
    _sley_ready_signal_direct_child STOP "$root_pid" "$root_identity"
    sleep 0.02
  else
    _sley_ready_stop_process "$root_pid" "$root_identity" || true
  fi
  if current_tree=$(_sley_ready_process_tree "$root_pid" "$root_identity"); then
    combined_tree+=$'\n'$current_tree
  fi
  _sley_ready_signal_processes KILL \
    "$(_sley_ready_processes_except "$combined_tree" "$root_pid")"
  if [[ "$direct_child" == "1" ]]; then
    _sley_ready_signal_direct_child KILL "$root_pid" "$root_identity"
  else
    _sley_ready_signal_processes KILL "$root_record"
  fi

  # Cached identities also cover descendants reparented before either rescan.
  _sley_ready_signal_processes KILL \
    "$(_sley_ready_processes_except "$combined_tree" "$root_pid")"
}

_sley_ready_processes_have_survivor() {
  local process_list="$1" process_pid process_identity
  while IFS=$'\t' read -r process_pid process_identity; do
    [[ -n "$process_pid" ]] || continue
    if _sley_ready_process_is_same "$process_pid" "$process_identity" &&
      ! _sley_ready_process_has_exited "$process_pid"; then
      return 0
    fi
  done <<<"$process_list"
  return 1
}

_sley_ready_wait_for_processes() {
  local process_list="$1" attempts="$2" attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    _sley_ready_processes_have_survivor "$process_list" || return 0
    sleep 0.05
  done
  ! _sley_ready_processes_have_survivor "$process_list"
}

_sley_ready_cleanup_background_jobs() {
  local job_pid job_identity job_group job_tree
  local -a job_pids=() job_identities=() job_groups=() job_trees=()
  while IFS= read -r job_pid; do
    [[ -n "$job_pid" ]] || continue
    job_pids+=("$job_pid")
    if job_identity=$(_sley_ready_process_identity "$job_pid"); then
      job_identities+=("$job_identity")
    else
      job_identities+=("")
    fi
    if job_group=$(_sley_ready_process_group "$job_pid"); then
      job_groups+=("$job_group")
    else
      job_groups+=("")
    fi
    if [[ -n "$job_identity" ]] &&
      job_tree=$(_sley_ready_process_tree "$job_pid" "$job_identity"); then
      job_trees+=("$job_tree")
    else
      job_trees+=("")
    fi
  done < <(jobs -pr)
  [[ "${#job_pids[@]}" -gt 0 ]] || return 0

  for job_pid in "${!job_pids[@]}"; do
    job_identity=${job_identities[$job_pid]}
    job_group=${job_groups[$job_pid]}
    job_tree=${job_trees[$job_pid]}
    # The hook/phase has already returned, so its asynchronous jobs are leaked
    # work rather than an active operation entitled to graceful TERM cleanup.
    # A job-control group is killed immediately while its leader identity is
    # live; this cannot run a TERM handler that forks after the final snapshot.
    if [[ -n "$job_identity" && "$job_group" == "${job_pids[$job_pid]}" ]] &&
      _sley_ready_process_is_same "${job_pids[$job_pid]}" "$job_identity"; then
      _sley_ready_signal_process_group KILL "$job_group"
    else
      _sley_ready_signal_processes KILL "$job_tree"
      _sley_ready_signal_direct_child KILL \
        "${job_pids[$job_pid]}" "$job_identity"
    fi
  done
  for job_pid in "${job_pids[@]}"; do
    wait "$job_pid" 2>/dev/null || true
  done
}

_sley_ready_run_guarded_command() {
  local command_rc
  if "$@"; then
    command_rc=0
  else
    command_rc=$?
  fi
  # A ready hook/phase owns asynchronous jobs it starts. Reap them before this
  # nested runner exits so they cannot outlive the immutable group guardian.
  _sley_ready_cleanup_background_jobs
  return "$command_rc"
}

_sley_ready_run_owned() {
  local child_rc started_pid started_identity started_group child_control child_run child_abort
  local child_had_monitor=0
  local _sley_ready_owned_record=""
  child_control=$(mktemp -d "$_sley_ready_status_dir/child.XXXXXX") || return 2
  child_run=$child_control/run
  child_abort=$child_control/abort
  _sley_ready_launching_child=1
  [[ "$-" == *m* ]] && child_had_monitor=1
  set -m
  (
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while [[ ! -e "$child_run" && ! -e "$child_abort" && ! -e "$_sley_ready_worker_dead" ]]; do
      sleep 0.01
    done
    [[ ! -e "$child_abort" && ! -e "$_sley_ready_worker_dead" ]] || exit 2
    # Keep hook-owned trap changes inside a foreground child. This process-group
    # leader remains a guardian with immutable cancellation traps, so graceful
    # hook cleanup cannot replace the guardian's final escalation behavior.
    (_sley_ready_run_guarded_command "$@")
  ) </dev/null &
  started_pid=$!
  [[ "$child_had_monitor" == "1" ]] || set +m
  if ! started_identity=$(_sley_ready_process_identity "$started_pid"); then
    : >"$child_abort" 2>/dev/null || true
    wait "$started_pid" 2>/dev/null || true
    rm -rf -- "$child_control"
    _sley_ready_finish_child_launch
    _sley_ready_supervision_failure="process identity is unavailable"
    _sley_ready_supervision_error formatter "$_sley_ready_supervision_failure"
    return 2
  fi
  if ! started_group=$(_sley_ready_process_group "$started_pid") ||
    [[ "$started_group" != "$started_pid" ]]; then
    : >"$child_abort" 2>/dev/null || true
    wait "$started_pid" 2>/dev/null || true
    rm -rf -- "$child_control"
    _sley_ready_finish_child_launch
    _sley_ready_supervision_failure="dedicated process group is unavailable"
    _sley_ready_supervision_error formatter "$_sley_ready_supervision_failure"
    return 2
  fi
  active_child_pid=$started_pid
  active_child_identity=$started_identity
  active_child_group=$started_group
  if ! _sley_ready_register_owned_process \
    "$started_pid" "$started_identity" "$started_group"; then
    : >"$child_abort" 2>/dev/null || true
    wait "$started_pid" 2>/dev/null || true
    active_child_pid=""
    active_child_identity=""
    active_child_group=""
    rm -rf -- "$child_control"
    _sley_ready_finish_child_launch
    _sley_ready_supervision_failure="ownership record could not be published"
    _sley_ready_supervision_error formatter "$_sley_ready_supervision_failure"
    return 2
  fi
  active_child_record=$_sley_ready_owned_record
  : >"$child_run" || {
    : >"$child_abort" 2>/dev/null || true
    wait "$started_pid" 2>/dev/null || true
    active_child_pid=""
    active_child_identity=""
    active_child_group=""
    rm -f -- "$active_child_record"
    active_child_record=""
    rm -rf -- "$child_control"
    _sley_ready_finish_child_launch
    _sley_ready_supervision_failure="launch gate could not be published"
    _sley_ready_supervision_error formatter "$_sley_ready_supervision_failure"
    return 2
  }
  _sley_ready_finish_child_launch
  if wait "$active_child_pid"; then
    child_rc=0
  else
    child_rc=$?
  fi
  active_child_pid=""
  active_child_identity=""
  active_child_group=""
  rm -f -- "$active_child_record"
  active_child_record=""
  rm -rf -- "$child_control"
  return "$child_rc"
}

_sley_ready_cancel_impl() {
  local signal_status="$1"
  if [[ "${_sley_ready_launching_child:-0}" == "1" ]]; then
    if [[ "${_sley_ready_pending_status:-0}" == "0" ]]; then
      _sley_ready_pending_status=$signal_status
    fi
    return 0
  fi
  trap '' INT TERM HUP
  _sley_ready_cleanup
  exit "$signal_status"
}

_sley_ready_finish_child_launch() {
  local pending_status
  _sley_ready_launching_child=0
  pending_status=${_sley_ready_pending_status:-0}
  _sley_ready_pending_status=0
  [[ "$pending_status" == "0" ]] || _sley_ready_cancel_impl "$pending_status"
}

_sley_ready_cleanup() {
  # All state is local to `_sley_ready_impl` and reached through Bash's dynamic
  # scope. Clearing it as resources are released keeps repeated cleanup safe
  # and prevents a completed child's PID from being acted on again.
  local child_pid child_identity child_group child_index owned_file child_tree cleanup_tree=""
  local active_child_tree="" active_descendant_tree=""
  local -a cleanup_child_pids=() cleanup_child_identities=() cleanup_child_groups=()
  local -a cleanup_child_trees=()
  [[ "${_sley_ready_cleanup_done:-0}" == "0" ]] || return 0
  _sley_ready_cleanup_done=1

  # Snapshot each owned tree before signaling its root. Start-time identities
  # keep delayed escalation safe even if a descendant exits and its PID is
  # reused, while the saved list still reaches reparented survivors.
  if [[ -n "${active_child_pid:-}" ]]; then
    if ! active_child_tree=$(
      _sley_ready_process_tree "$active_child_pid" "$active_child_identity"
    ); then
      active_child_tree="$active_child_pid"$'\t'"$active_child_identity"
    fi
    active_descendant_tree=$(
      _sley_ready_processes_except "$active_child_tree" "$active_child_pid"
    )
    if [[ -n "$active_descendant_tree" ]]; then
      cleanup_tree+=$'\n'$active_descendant_tree
    fi
    _sley_ready_signal_owned_tree_term \
      "$active_child_pid" "$active_child_identity" "$active_child_group" \
      "$active_child_tree" 1
  fi
  for child_index in "${!phase_pids[@]}"; do
    [[ -n "${phase_pids[$child_index]}" ]] || continue
    cleanup_child_pids+=("${phase_pids[$child_index]}")
    cleanup_child_identities+=("${phase_identities[$child_index]:-}")
    cleanup_child_groups+=("${phase_groups[$child_index]:-}")
  done
  for child_index in "${!cleanup_child_pids[@]}"; do
    child_pid=${cleanup_child_pids[$child_index]}
    child_identity=${cleanup_child_identities[$child_index]}
    child_group=${cleanup_child_groups[$child_index]}
    if ! child_tree=$(_sley_ready_process_tree "$child_pid" "$child_identity"); then
      child_tree="$child_pid"$'\t'"$child_identity"
    fi
    cleanup_child_trees+=("$child_tree")
    cleanup_tree+=$'\n'$child_tree
    _sley_ready_signal_owned_tree_term \
      "$child_pid" "$child_identity" "$child_group" "$child_tree" 1
  done
  _sley_ready_wait_for_processes "$cleanup_tree" 10 || true
  if [[ -n "$active_child_tree" ]] &&
    _sley_ready_processes_have_survivor "$active_child_tree"; then
    _sley_ready_escalate_tree \
      "$active_child_pid" "$active_child_identity" "$active_child_tree" 1 \
      "$active_child_group"
  fi
  for child_index in "${!cleanup_child_pids[@]}"; do
    _sley_ready_processes_have_survivor \
      "${cleanup_child_trees[$child_index]}" || continue
    _sley_ready_escalate_tree \
      "${cleanup_child_pids[$child_index]}" \
      "${cleanup_child_identities[$child_index]}" \
      "${cleanup_child_trees[$child_index]}" 1 \
      "${cleanup_child_groups[$child_index]}"
  done
  for child_pid in \
    "${active_child_pid:-}" \
    "${phase_pids[@]+"${phase_pids[@]}"}"; do
    [[ -n "$child_pid" ]] || continue
    wait "$child_pid" 2>/dev/null || true
  done
  [[ -z "${active_child_record:-}" ]] || rm -f -- "$active_child_record"
  active_child_pid=""
  active_child_identity=""
  active_child_group=""
  active_child_record=""
  phase_pids=()
  phase_identities=()
  phase_groups=()
  for owned_file in "${phase_record_files[@]+"${phase_record_files[@]}"}"; do
    [[ -n "$owned_file" ]] && rm -f -- "$owned_file"
  done
  phase_record_files=()
  for owned_file in "${phase_control_dirs[@]+"${phase_control_dirs[@]}"}"; do
    [[ -n "$owned_file" ]] && rm -rf -- "$owned_file"
  done
  phase_control_dirs=()

  if [[ -n "${_fix_bak:-}" && "${_fix_preserve_backup:-0}" == "0" ]]; then
    if [[ -n "${_fix_active_file:-}" && -e "$_fix_bak" ]]; then
      if ! cp -p "$_fix_bak" "$_fix_active_file"; then
        printf 'sley fix: failed to restore %s from backup %s; the worktree may hold formatter output — recover it from the backup.\n' \
          "$_fix_active_file" "$_fix_bak" >&2
        _fix_preserve_backup=1
      fi
    fi
    if [[ "$_fix_preserve_backup" == "0" ]]; then
      rm -f -- "$_fix_bak"
      _fix_bak=""
      _fix_active_file=""
    fi
  fi

  for owned_file in \
    "${phase_stdout_files[@]+"${phase_stdout_files[@]}"}" \
    "${phase_stderr_files[@]+"${phase_stderr_files[@]}"}" \
    "${stdout_file:-}" \
    "${stderr_file:-}" \
    "${selected_cache_file:-}"; do
    [[ -n "$owned_file" ]] || continue
    rm -f -- "$owned_file"
  done
  phase_stdout_files=()
  phase_stderr_files=()
  stdout_file=""
  stderr_file=""
  selected_cache_file=""
}

_sley_ready_impl() {
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
  local progress=0
  [[ "$quiet" != "1" && "$_SLEY_SCOPE_JSON" != "1" ]] && progress=1

  # Validate the path scope at the orchestrator level. Without this an invalid
  # `--path` would be hidden: each phase subshell would emit exit 2 which the
  # rc handler below downgrades to "unavailable" and the run returns 0 overall,
  # masking a caller usage error. `ready` must fail fast on invalid path scopes.
  #
  # Compute the path filters and the selected file list ONCE here, then hand
  # the precomputed selection to `_sley_warn_out_of_scope` so it does not
  # re-run a VCS pass right after this block.
  local filters selected selected_cache_file=""
  local rc global=0 phase status phases_json="" first=1 blocking=0 unavailable=0 errors=0
  local phase_stdout phase_stderr phase_combined summary_line
  local phase_extra_json status_detail verify_cached verify_total
  local _ready_report="" _verify_observed=0
  local stdout_file="" stderr_file="" pid phase_index child_identity child_group
  local child_control child_run child_abort child_had_monitor
  local _sley_ready_owned_record=""
  local -a phases=("status" "check" "secrets" "verify")
  local -a phase_pids=() phase_identities=() phase_groups=()
  local -a phase_control_dirs=() phase_record_files=()
  local -a phase_stdout_files=() phase_stderr_files=()
  local extension_phases extension_phase
  local _sley_ready_cleanup_done=0 _sley_ready_launching_child=0 _sley_ready_pending_status=0
  local _sley_ready_supervision_failure=""
  local _fix_bak="" _fix_active_file="" _fix_preserve_backup=0
  local active_child_pid="" active_child_identity="" active_child_group=""
  local active_child_record=""
  # shellcheck disable=SC2034 # Dynamically consumed by sourced extensions.
  local SLEY_CALLER="${SLEY_CALLER:-human}" SLEY_SCOPED=1
  local _SLEY_SELECTED_FILES_CACHE_FILE="" _SLEY_SELECTED_FILES_CACHE_KEY=""
  # Install cancellation cleanup before extension initialization or creating
  # invocation-owned files. This implementation runs in the isolated worker,
  # so `exit` cannot terminate a sourced caller.
  trap '_sley_ready_cancel_impl 130' INT
  trap '_sley_ready_cancel_impl 143' TERM
  trap '_sley_ready_cancel_impl 129' HUP
  filters=$(_sley_path_filters) || return $?
  # Initialize before selecting files or creating the shared selection cache.
  # A configuration failure must not launch phases, enumerate extension phases,
  # or leave a cache file behind.
  sley_hook_init || return $?
  [[ "$progress" == "1" ]] && echo "sley ready: selecting changed files" >&2
  selected=$(_sley_selected_files_for_filters "$filters") || return 2
  if [[ "$progress" == "1" ]]; then
    local selected_count
    selected_count=$(_sley_count_file_list "$selected")
    echo "sley ready: selected $selected_count changed files" >&2
  fi
  selected_cache_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-selected.XXXXXX") || return 2
  printf '%s\n' "$selected" >"$selected_cache_file"
  _SLEY_SELECTED_FILES_CACHE_FILE="$selected_cache_file"
  _SLEY_SELECTED_FILES_CACHE_KEY=$(_sley_selected_files_cache_key "$filters")
  _sley_warn_out_of_scope "$selected"
  # _ready_report buffers human-mode output so --quiet can suppress it on
  # pass. _verify_observed tracks whether the verify phase did real work (cached
  # or fresh) so we can write a session marker for SLEY_VERIFY_STATE_DIR
  # consumers without them having to parse our output.
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
        _sley_ready_cleanup
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
  if [[ "$progress" == "1" ]]; then
    local phases_text=""
    for phase in "${phases[@]}"; do
      [[ -z "$phases_text" ]] || phases_text+=", "
      phases_text+="$phase"
    done
    echo "sley ready: running phases: $phases_text" >&2
  fi
  # --fix: format changed files before the concurrent phases so `check`
  # validates already-formatted content. For git (staging area), reject if
  # the formatter modified any file — the committed content would still be
  # the unformatted version until the user re-stages. For sl and other VCS
  # types, formatting in-place is safe (no staging area, the commit sees
  # the result).
  if [[ "$fix" == "1" ]]; then
    local _fix_files _fix_f _fix_pre _fix_post _fix_run_rc
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
              _fix_bak=""
              _fix_partial_modified+=("$_fix_f")
              continue
            fi
            _fix_active_file=$_fix_f
            _fix_pre=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            # Redirect stdin from /dev/null so a formatter that reads stdin can't
            # drain the herestring driving this loop (parity with `_sley_fix`).
            if _sley_ready_run_owned sley_hook_format_file "$_fix_f" </dev/null >/dev/null 2>&1; then
              _fix_run_rc=0
            else
              _fix_run_rc=$?
            fi
            if [[ "$_fix_run_rc" == "2" ]]; then
              _sley_ready_supervision_error formatter \
                "${_sley_ready_supervision_failure:-launch failed}"
              _sley_ready_cleanup
              return 2
            fi
            _fix_post=$(git hash-object -- "$_fix_f" 2>/dev/null || true)
            # Always restore: formatting a partial file is only a probe. If the
            # restore itself fails after the formatter mutated the file, keep the
            # backup and refuse loudly — deleting the only copy that can recover
            # the unstaged hunk would be the exact clobber this guard prevents.
            if ! cp -p "$_fix_bak" "$_fix_f"; then
              printf 'sley fix: failed to restore %s from backup %s; the worktree may hold formatter output — recover it from the backup.\n' \
                "$_fix_f" "$_fix_bak" >&2
              _fix_preserve_backup=1
              _fix_active_file=""
              _sley_ready_cleanup
              return 2
            fi
            rm -f "$_fix_bak"
            _fix_bak=""
            _fix_active_file=""
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
            if _sley_ready_run_owned sley_hook_format_file "$_fix_f" </dev/null >/dev/null 2>&1; then
              _fix_run_rc=0
            else
              _fix_run_rc=$?
            fi
            if [[ "$_fix_run_rc" == "2" ]]; then
              _sley_ready_supervision_error formatter \
                "${_sley_ready_supervision_failure:-launch failed}"
              _sley_ready_cleanup
              return 2
            fi
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
          _sley_ready_cleanup
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
          _sley_ready_cleanup
          return 1
        fi
      else
        if _sley_ready_run_owned sley_hook_format "$_fix_files"; then
          _fix_run_rc=0
        else
          _fix_run_rc=$?
        fi
        if [[ "$_fix_run_rc" == "2" ]]; then
          _sley_ready_cleanup
          return 2
        fi
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
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-stdout.XXXXXX") || {
      _sley_ready_cleanup
      return 2
    }
    phase_stdout_files+=("$stdout_file")
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/sley-ready-stderr.XXXXXX") || {
      _sley_ready_cleanup
      return 2
    }
    phase_stderr_files+=("$stderr_file")
    child_control=$(mktemp -d "$_sley_ready_status_dir/phase.XXXXXX") || {
      _sley_ready_cleanup
      return 2
    }
    child_run=$child_control/run
    child_abort=$child_control/abort
    _sley_ready_launching_child=1
    child_had_monitor=0
    [[ "$-" == *m* ]] && child_had_monitor=1
    set -m
    (
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      while [[ ! -e "$child_run" && ! -e "$child_abort" && ! -e "$_sley_ready_worker_dead" ]]; do
        sleep 0.01
      done
      [[ ! -e "$child_abort" && ! -e "$_sley_ready_worker_dead" ]] || exit 2
      (
        # shellcheck disable=SC2034 # read by `_sley_init_repo` in this subshell.
        SLEY_ORIGINAL_PWD="$_SLEY_CALLER_PWD"
        _sley_ready_run_guarded_command \
          _sley_ready_run_phase "$phase" "$full" "$force" "${scope_args[@]}"
      )
    ) </dev/null >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    [[ "$child_had_monitor" == "1" ]] || set +m
    if ! child_identity=$(_sley_ready_process_identity "$pid"); then
      : >"$child_abort" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -rf -- "$child_control"
      _sley_ready_finish_child_launch
      _sley_ready_supervision_error "phase $phase" "process identity is unavailable"
      _sley_ready_cleanup
      return 2
    fi
    if ! child_group=$(_sley_ready_process_group "$pid") || [[ "$child_group" != "$pid" ]]; then
      : >"$child_abort" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -rf -- "$child_control"
      _sley_ready_finish_child_launch
      _sley_ready_supervision_error "phase $phase" "dedicated process group is unavailable"
      _sley_ready_cleanup
      return 2
    fi
    phase_pids+=("$pid")
    phase_identities+=("$child_identity")
    phase_groups+=("$child_group")
    phase_control_dirs+=("$child_control")
    if ! _sley_ready_register_owned_process "$pid" "$child_identity" "$child_group"; then
      : >"$child_abort" 2>/dev/null || true
      _sley_ready_finish_child_launch
      _sley_ready_supervision_error "phase $phase" "ownership record could not be published"
      _sley_ready_cleanup
      return 2
    fi
    phase_record_files+=("$_sley_ready_owned_record")
    if ! : >"$child_run"; then
      : >"$child_abort" 2>/dev/null || true
      _sley_ready_finish_child_launch
      _sley_ready_supervision_error "phase $phase" "launch gate could not be published"
      _sley_ready_cleanup
      return 2
    fi
    _sley_ready_finish_child_launch
    stdout_file=""
    stderr_file=""
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
    phase_pids[phase_index]=""
    phase_identities[phase_index]=""
    phase_groups[phase_index]=""
    rm -f -- "${phase_record_files[$phase_index]}"
    phase_record_files[phase_index]=""
    rm -rf -- "${phase_control_dirs[$phase_index]}"
    phase_control_dirs[phase_index]=""
    phase_stdout=$(cat "$stdout_file")
    phase_stderr=$(cat "$stderr_file")
    rm -f "$stdout_file" "$stderr_file"
    phase_stdout_files[phase_index]=""
    phase_stderr_files[phase_index]=""
    stdout_file=""
    stderr_file=""

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
  _sley_ready_cleanup

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
