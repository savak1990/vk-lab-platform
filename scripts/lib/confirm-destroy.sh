# Shared by bootstrap-down.sh and account-down.sh: an unconditional destroy
# guard. Applies uniformly to every PROJECT_NAME - no allow-list, no
# interactive-vs-non-interactive branching - because the shared lab-role/kms
# mean every project's destroy path now looks the same, including
# vk-lab-platform's own.
#
# Not sourced standalone - the caller sets PROJECT_NAME first, then calls
# confirm_destroy.

confirm_destroy() {
  local project="${1:?confirm_destroy: PROJECT_NAME required}"
  if [ "${CONFIRM_DESTROY:-}" != "$project" ]; then
    echo "Refusing: set CONFIRM_DESTROY=$project to confirm destroying it." >&2
    exit 1
  fi
}
