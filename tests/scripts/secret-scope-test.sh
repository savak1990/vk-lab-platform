#!/usr/bin/env bash
# Exercises secret-encrypt.sh / secret-decrypt.sh path resolution by SECRET_SCOPE
# against a copy of the scripts in a temp repo root, with a fake `aws` on PATH
# that base64-round-trips instead of calling KMS. Usage: tests/scripts/secret-scope-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/lib" "$TMP/bin"
cp "$REPO_ROOT/scripts/secret-encrypt.sh" "$REPO_ROOT/scripts/secret-decrypt.sh" "$TMP/scripts/"
cp "$REPO_ROOT/scripts/lib/region.sh" "$REPO_ROOT/scripts/lib/secret-scope.sh" "$TMP/scripts/lib/"

cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
# kms encrypt: base64 of stdin; kms decrypt: base64 of the fileb:// blob.
case "$2" in
  encrypt) base64 < /dev/stdin ;;
  decrypt)
    for a in "$@"; do case "$a" in fileb://*) f="${a#fileb://}" ;; esac; done
    base64 < "$f" ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH"
export PROJECT_NAME="test-project"
ENCRYPT="$TMP/scripts/secret-encrypt.sh"
DECRYPT="$TMP/scripts/secret-decrypt.sh"

fail=0
err() { echo "SECRET-SCOPE-TEST: $*" >&2; fail=1; }

# Default scope is project: secrets/<project>/<name>.enc.
SECRET_NAME=alpha SECRET_VALUE=one "$ENCRYPT" >/dev/null || err "encrypt alpha (default scope) failed"
[ -f "$TMP/secrets/test-project/alpha.enc" ] || err "default scope did not write secrets/test-project/alpha.enc"
[ ! -f "$TMP/secrets/alpha.enc" ] || err "default scope wrote a global file"
[ "$("$DECRYPT" alpha)" = "one" ] || err "decrypt alpha (default scope) returned wrong value"

# SECRET_SCOPE=global: secrets/<name>.enc, no project directory.
SECRET_SCOPE=global SECRET_NAME=beta SECRET_VALUE=two "$ENCRYPT" >/dev/null || err "encrypt beta (global) failed"
[ -f "$TMP/secrets/beta.enc" ] || err "global scope did not write secrets/beta.enc"
[ ! -f "$TMP/secrets/test-project/beta.enc" ] || err "global scope wrote a project file"
[ "$(SECRET_SCOPE=global "$DECRYPT" beta)" = "two" ] || err "decrypt beta (global) returned wrong value"

# SECRET_SCOPE=project is the explicit spelling of the default.
[ "$(SECRET_SCOPE=project "$DECRYPT" alpha)" = "one" ] || err "decrypt alpha (explicit project) returned wrong value"

# No hardcoded name list: civo-token without a scope is a project secret.
SECRET_NAME=civo-token SECRET_VALUE=tok "$ENCRYPT" >/dev/null || err "encrypt civo-token (default scope) failed"
[ -f "$TMP/secrets/test-project/civo-token.enc" ] || err "civo-token without scope did not land in the project directory"
[ ! -f "$TMP/secrets/civo-token.enc" ] || err "civo-token without scope landed in the global directory"

# Wrong scope: fail, and name the scope where the file does exist.
out="$("$DECRYPT" beta 2>&1)" && err "decrypt beta without global scope succeeded"
case "$out" in *"secrets/test-project/beta.enc does not exist"*) ;; *) err "wrong-scope error did not name the missing path: $out" ;; esac
case "$out" in *"SCOPE=global"*) ;; *) err "wrong-scope error did not hint SCOPE=global: $out" ;; esac
out="$(SECRET_SCOPE=global "$DECRYPT" alpha 2>&1)" && err "decrypt alpha with global scope succeeded"
case "$out" in *"SCOPE=project"*) ;; *) err "wrong-scope error did not hint SCOPE=project: $out" ;; esac

# Missing everywhere: fail without a hint.
out="$("$DECRYPT" gamma 2>&1)" && err "decrypt of a missing secret succeeded"
case "$out" in *"SCOPE="*) err "missing-everywhere error hinted a scope: $out" ;; esac

# Invalid scope is rejected by both scripts before any KMS call.
SECRET_SCOPE=account SECRET_NAME=delta SECRET_VALUE=x "$ENCRYPT" >/dev/null 2>&1 && err "encrypt accepted SECRET_SCOPE=account"
[ ! -f "$TMP/secrets/delta.enc" ] && [ ! -f "$TMP/secrets/test-project/delta.enc" ] || err "invalid scope still wrote a file"
SECRET_SCOPE=account "$DECRYPT" alpha >/dev/null 2>&1 && err "decrypt accepted SECRET_SCOPE=account"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "secret-scope-test: ok"
