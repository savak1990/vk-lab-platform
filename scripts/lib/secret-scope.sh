# Shared by secret-encrypt.sh / secret-decrypt.sh. Requires REPO_ROOT and
# PROJECT_NAME to be set by the caller.

# Prints the validated scope from SECRET_SCOPE (default: project).
secret_scope() {
  local scope="${SECRET_SCOPE:-project}"
  case "$scope" in
    project|global) echo "$scope" ;;
    *) echo "SECRET_SCOPE must be project or global, got: $scope" >&2; return 1 ;;
  esac
}

# Prints the ciphertext path for <name> in <scope>.
secret_path() {
  local name="$1" scope="$2"
  if [ "$scope" = global ]; then
    echo "$REPO_ROOT/secrets/$name.enc"
  else
    echo "$REPO_ROOT/secrets/$PROJECT_NAME/$name.enc"
  fi
}
