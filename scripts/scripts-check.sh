#!/usr/bin/env bash
# Validates the shell layer: bash -n parses every script, shellcheck lints it,
# then every tests/scripts/*-test.sh runs. Needs no credentials and no cloud.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# Three explicit globs, never a recursive find: terraform/modules/eks/.terraform
# holds vendored scripts that are not ours to lint.
files=(scripts/*.sh scripts/lib/*.sh tests/scripts/*.sh)

echo "SCRIPTS-CHECK: parsing ${#files[@]} scripts with bash -n"
for f in "${files[@]}"; do
  bash -n "$f"
done

echo "SCRIPTS-CHECK: $(shellcheck --version | sed -n 's/^version: /shellcheck /p')"
shellcheck -x -S warning "${files[@]}"

for t in tests/scripts/*-test.sh; do
  echo "SCRIPTS-CHECK: $t"
  "./$t"
done

echo "SCRIPTS-CHECK: shell layer is valid."
