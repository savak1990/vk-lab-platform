#!/usr/bin/env bash
# Generates the Roles Anywhere root CA: an EC P-256 self-signed certificate
# committed as public material, and its private key as KMS ciphertext.
# Refuses to overwrite an existing CA unless ROTATE=1 (writes *-next files).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
ROTATE="${ROTATE:-}"

SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"
mkdir -p "$SECRETS_DIR"

if [ -n "$ROTATE" ]; then
  CERT_FILE="$SECRETS_DIR/civo-ca-cert-next.pem"
  KEY_NAME="civo-ca-key-next"
else
  CERT_FILE="$SECRETS_DIR/civo-ca-cert.pem"
  KEY_NAME="civo-ca-key"
fi

if [ -f "$CERT_FILE" ] && [ -z "$ROTATE" ]; then
  echo "$CERT_FILE already exists. Set ROTATE=1 to generate a rotation candidate." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  if [ "$(uname -s)" = "Darwin" ]; then
    rm -P "$WORKDIR"/*.key 2>/dev/null || true
  elif command -v shred >/dev/null 2>&1; then
    shred -u "$WORKDIR"/*.key 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
umask 077

KEY_FILE="$WORKDIR/ca.key"
CSR_FILE="$WORKDIR/ca.csr"
CERT_TMP="$WORKDIR/ca.pem"
EXT_FILE="$WORKDIR/ext.cnf"

openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE"

cat > "$EXT_FILE" <<EOF
basicConstraints=critical,CA:true,pathlen:1
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EOF

openssl req -new -key "$KEY_FILE" -sha256 \
  -subj "/O=${PROJECT_NAME}/CN=${PROJECT_NAME}-civo-workload-ca" \
  -out "$CSR_FILE"

# The one-step "req -x509 -extfile" form does not apply extensions on
# LibreSSL (req -x509 has no -extfile flag); this two-step CSR-then-sign
# form is required, not a style choice.
openssl x509 -req -in "$CSR_FILE" -signkey "$KEY_FILE" -sha256 -days 1826 \
  -extfile "$EXT_FILE" \
  -out "$CERT_TMP"

# Command substitution strips ALL trailing newlines, so a bare "; echo"
# does not restore the PEM's final newline (it gets stripped too). Append
# a sentinel byte instead, then trim it, to preserve the file byte-for-byte.
KEY_VALUE="$(cat "$KEY_FILE"; printf 'x')"
KEY_VALUE="${KEY_VALUE%x}"

# Encrypt the key before writing the cert to its committed path: if KMS
# encryption fails, no half-written pair is left behind for a re-run to
# trip over (the cert-exists refusal would otherwise block retrying).
SECRET_NAME="$KEY_NAME" SECRET_VALUE="$KEY_VALUE" PROJECT_NAME="$PROJECT_NAME" \
  "$REPO_ROOT/scripts/secret-encrypt.sh"

cp "$CERT_TMP" "$CERT_FILE"

echo "Wrote ${CERT_FILE#"$REPO_ROOT"/}"
openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256
