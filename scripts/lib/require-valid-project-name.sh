# Guards the free-form PROJECT_NAME before anything derives a name from it.
# Lives here rather than in lab.yml so a local `PROJECT_NAME=foo make up` hits
# the identical check CI does.
#
# Two hard bounds, both measured rather than assumed:
#
#   charset  ${PROJECT_NAME}-tf-state must be a valid S3 bucket name - the
#            tightest of the three consumers (EKS cluster names and DNS labels
#            are both looser), so satisfying S3 satisfies all of them.
#
#   length   23. The binding name is the EKS system nodegroup's IAM role, not
#            the longest-looking one: the upstream module defaults
#            iam_role_use_name_prefix=true, so "${cluster}-system-ng" becomes a
#            *prefix* and the provider appends 26 characters. Observed live:
#            vk-lab-platform-eks-system-ng-0e920644b931d87e47cb82f33a = 56
#            chars, i.e. 15 project + 15 fixed + 26 suffix. IAM caps role names
#            at 64, so 64 - 15 - 26 = 23.
#
# Not sourced standalone - the caller sets PROJECT_NAME first, then calls
# require_valid_project_name.

PROJECT_NAME_MAX_LENGTH=23
PROJECT_NAME_PATTERN='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'

require_valid_project_name() {
  local project="${1:?require_valid_project_name: PROJECT_NAME required}"

  local errors=()

  if [ "${#project}" -gt "$PROJECT_NAME_MAX_LENGTH" ]; then
    errors+=("${#project} characters, max is $PROJECT_NAME_MAX_LENGTH")
  fi
  if ! [[ $project =~ $PROJECT_NAME_PATTERN ]]; then
    errors+=("must be lowercase letters, digits and hyphens, starting and ending alphanumeric")
  fi

  # Both bounds are reported together: a name can fail either, and a CI
  # operator who can't see what they typed shouldn't need a second run.
  if [ "${#errors[@]}" -gt 0 ]; then
    echo "Refusing: invalid PROJECT_NAME \"$project\"" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    exit 1
  fi
}
