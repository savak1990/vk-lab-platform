#!/usr/bin/env bash
# Generates the Hetzner node SSH key: an ed25519 public key committed as
# public material, and its private key as KMS ciphertext.
# Refuses to overwrite an existing key unless ROTATE=1 (writes *-next files).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$REPO_ROOT/scripts/lib/provider.sh"
ROTATE="${ROTATE:-}"

if [ "$PROVIDER" != hetzner ]; then
  echo "PROVIDER is $PROVIDER. Only the Hetzner target boots servers from an SSH key; aws and civo hand out cluster access through their own APIs." >&2
  exit 1
fi

SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"
mkdir -p "$SECRETS_DIR"

if [ "$ROTATE" = "1" ]; then
  PUB_FILE="$SECRETS_DIR/hetzner-ssh-key-next.pub"
  KEY_NAME="hetzner-ssh-key-next"
else
  PUB_FILE="$SECRETS_DIR/hetzner-ssh-key.pub"
  KEY_NAME="hetzner-ssh-key"
fi

if [ -f "$PUB_FILE" ]; then
  if [ "$ROTATE" = "1" ]; then
    echo "$PUB_FILE already exists; a rotation candidate already exists. Remove it first if you intend to regenerate it." >&2
  else
    echo "$PUB_FILE already exists. Set ROTATE=1 to generate a rotation candidate." >&2
  fi
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  if [ "$(uname -s)" = "Darwin" ]; then
    rm -P "$WORKDIR"/id_ed25519 2>/dev/null || true
  elif command -v shred >/dev/null 2>&1; then
    shred -u "$WORKDIR"/id_ed25519 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM
umask 077

KEY_FILE="$WORKDIR/id_ed25519"

ssh-keygen -t ed25519 -N '' -C "$PROJECT_NAME" -f "$KEY_FILE" >/dev/null

# Command substitution strips ALL trailing newlines, so a bare "; echo"
# does not restore the file's final newline (it gets stripped too). Append
# a sentinel byte instead, then trim it, to preserve the key byte-for-byte.
KEY_VALUE="$(cat "$KEY_FILE"; printf 'x')"
KEY_VALUE="${KEY_VALUE%x}"

# Encrypt the private key before writing the public one to its committed
# path: if KMS encryption fails, no half-written pair is left behind for a
# re-run to trip over (the exists refusal would otherwise block retrying).
SECRET_NAME="$KEY_NAME" SECRET_VALUE="$KEY_VALUE" PROJECT_NAME="$PROJECT_NAME" \
  "$REPO_ROOT/scripts/secret-encrypt.sh"

cp "$KEY_FILE.pub" "$PUB_FILE"
chmod 644 "$PUB_FILE"

echo "Wrote ${PUB_FILE#"$REPO_ROOT"/}"
ssh-keygen -l -f "$PUB_FILE"
