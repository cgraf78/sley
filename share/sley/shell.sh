# shellcheck shell=bash
# sley shell integration.
#
# Source this file from an interactive shell to install lightweight completion
# and future shell-facing sley behavior:
#   . "$(shdeps dep-file cgraf78/sley share/sley/shell.sh)"

# shellcheck disable=SC2034 # public marker for callers that verify the loader ran.
SLEY_SHELL_LOADED=1

_sley_shell_source_path() {
  if [ -n "${BASH_VERSION:-}" ]; then
    printf '%s\n' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    eval 'printf "%s\n" "${(%):-%x}"'
  else
    return 1
  fi
}

_sley_shell_dir() {
  local source path
  source=$(_sley_shell_source_path) || return 1
  case "$source" in
    */*) path="${source%/*}" ;;
    *) path="." ;;
  esac
  (cd -P -- "$path" 2>/dev/null && pwd)
}

_sley_verify_schema_default() {
  local dir schema
  # Integration harnesses may cache this loader by copying its contents.
  # Prefer the dependency manager's public asset resolver so copied shell-init
  # files still point back at the versioned schema in the sley repo.
  if command -v shdeps >/dev/null 2>&1; then
    schema=$(shdeps dep-file cgraf78/sley share/sley/schemas/verify.schema.json 2>/dev/null) &&
      [ -n "$schema" ] &&
      printf '%s\n' "$schema" &&
      return 0
  fi

  dir=$(_sley_shell_dir) || return 1
  schema="$dir/schemas/verify.schema.json"
  [ -f "$schema" ] || return 1
  printf '%s\n' "$schema"
}

if [ -z "${SLEY_VERIFY_SCHEMA:-}" ]; then
  SLEY_VERIFY_SCHEMA=$(_sley_verify_schema_default 2>/dev/null || true)
fi
export SLEY_VERIFY_SCHEMA

# ---------------------------------------------------------------------------
# Public API - stable shell integration surface
# ---------------------------------------------------------------------------
# SLEY_VERIFY_SCHEMA
#   Absolute path to sley's verify-registry JSON Schema. Consumers can use this
#   for editor integration or validation while keeping the schema itself owned
#   and versioned by the sley dependency repo.
# sley_verify_schema_path
#   Prints SLEY_VERIFY_SCHEMA for shells or tools that prefer a function API.
# _sley_shell_complete
#   Bash completion function for the PATH-visible `sley` command. It is static
#   by design: completion must not inspect VCS state or scan large repos.
# _sley_zsh_complete
#   Zsh completion function for the same command set. It expects compinit to
#   have run before registration; the loader defers registration to the first
#   prompt when startup files source it before zsh's compinit phase.

sley_verify_schema_path() {
  printf '%s\n' "$SLEY_VERIFY_SCHEMA"
}

_sley_shell_commands() {
  printf '%s\n' "status changes fix check secrets verify ready help"
}

_sley_shell_options() {
  case "$1" in
    status)
      printf '%s\n' "--json"
      ;;
    ready)
      printf '%s\n' "--fix --full --force --exclude --quiet --commit --include-untracked --repo-wide --path --json"
      ;;
    changes | fix | check | secrets | verify)
      printf '%s\n' "--commit --include-untracked --repo-wide --path --json"
      ;;
  esac
}

_sley_shell_complete_reply() {
  local candidates="$1" cur="$2" match
  COMPREPLY=()
  for match in $candidates; do
    [[ "$match" == "$cur"* ]] && COMPREPLY+=("$match")
  done
}

_sley_shell_complete() {
  local cur cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  cmd="${COMP_WORDS[1]:-}"

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    _sley_shell_complete_reply "$(_sley_shell_commands)" "$cur"
    return 0
  fi

  _sley_shell_complete_reply "$(_sley_shell_options "$cmd")" "$cur"
}

_sley_zsh_complete() {
  [ -n "${ZSH_VERSION:-}" ] || return 0
  setopt localoptions shwordsplit

  local cmd candidates match
  if ((CURRENT == 2)); then
    candidates="$(_sley_shell_commands)"
  else
    cmd="${words[2]:-}"
    candidates="$(_sley_shell_options "$cmd")"
  fi

  for match in $candidates; do
    compadd -- "$match"
  done
}

_sley_zsh_register() {
  [ -n "${ZSH_VERSION:-}" ] || return 0
  typeset -f compdef >/dev/null 2>&1 || return 0

  compdef _sley_zsh_complete sley
  if typeset -f add-zsh-hook >/dev/null 2>&1; then
    add-zsh-hook -d precmd _sley_zsh_register 2>/dev/null || true
  fi
}

if [ -n "${ZSH_VERSION:-}" ]; then
  if typeset -f compdef >/dev/null 2>&1; then
    _sley_zsh_register
  else
    autoload -Uz add-zsh-hook 2>/dev/null || true
    if typeset -f add-zsh-hook >/dev/null 2>&1; then
      add-zsh-hook precmd _sley_zsh_register 2>/dev/null || true
    fi
  fi
elif command -v complete >/dev/null 2>&1; then
  complete -F _sley_shell_complete sley
fi
