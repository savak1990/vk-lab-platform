# Shared by bootstrap-down.sh and state-down.sh: decides whether a given
# PROJECT_NAME's destroy run gets the existing interactive confirmation, or
# a non-interactive path suitable for an ephemeral CI environment.
#
# Not sourced standalone - the caller sets PROJECT_NAME first, then calls
# confirm_destroy with the message it already prints before the prompt.

# Registered ephemeral projects, space-separated. Empty today - add a
# PROJECT_NAME here only once it's genuinely meant to be fully disposable
# (e.g. "vk-lab-ci"), never for the personal lab. Adding a name here is a
# real access decision, made deliberately at deploy time, not something a
# workflow input should ever be able to change.
EPHEMERAL_PROJECTS=""

is_ephemeral_project() {
  local name="$1" p
  for p in $EPHEMERAL_PROJECTS; do
    [ "$p" = "$name" ] && return 0
  done
  return 1
}

confirm_destroy() {
  local message="$1"
  echo "$message"

  if is_ephemeral_project "$PROJECT_NAME"; then
    # Must equal PROJECT_NAME exactly, not "yes"/"y" - an unset or
    # copy-pasted CONFIRM_DESTROY value then can't accidentally confirm a
    # destroy against a different project. Reachable in practice only
    # behind a GitHub Environment's required-reviewer approval on the
    # workflow job that sets this - that approval is the actual "separate
    # confirmation step" spec 001 requirement 8 asks for; this check just
    # confirms the right project was the one approved.
    if [ "${CONFIRM_DESTROY:-}" = "$PROJECT_NAME" ]; then
      echo "Non-interactive confirmation accepted for ephemeral project $PROJECT_NAME."
      return 0
    fi
    echo "Refusing: PROJECT_NAME=$PROJECT_NAME is registered ephemeral but CONFIRM_DESTROY doesn't match it." >&2
    exit 1
  fi

  read -r -p "Continue? (y/n): " confirm
  [ "$confirm" = "y" ] || { echo "Aborted."; exit 1; }
}
