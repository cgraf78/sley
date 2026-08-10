#!/usr/bin/env bash
# This extension demonstrates dynamic command selection. Prefer verify.json
# when a static path-to-command mapping is enough; shell code is justified only
# when the decision needs runtime context that the registry cannot express.
sley_ext_verify_commands() {
  local selected_files="${1:-}" file

  while IFS= read -r file; do
    case "$file" in
      config/*.schema)
        # Keep the example suggested rather than required so copying it cannot
        # make readiness run the placeholder command before it is customized.
        printf '%s\n' '{"command":"./test/validate-schemas","kind":"test","required":false,"tier":"suggested","sources":["example-extension"],"source_contexts":[{"source":"example-extension","context":"extension"}]}'
        return 0
        ;;
    esac
  done <<<"$selected_files"
}
