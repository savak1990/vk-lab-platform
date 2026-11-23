#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$LOG"
case "$*" in
  "config current-context") echo lab ;;
  *contexts*) echo lab ;;
  *certificate-authority-data*) echo Q0EK ;;
  *clusters*) echo https://203.0.113.10:6443 ;;
  "create token "*) echo token-for-"$3" ;;
esac
EOF
cat > "$tmp/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
EOF
chmod +x "$tmp/kubectl" "$tmp/aws"

export PATH="$tmp:$PATH" LOG="$tmp/log" PROJECT_NAME=p PROVIDER=hetzner LAB_REGION=eu-west-1 LAB_FQDN=lab.example.com REPO_ROOT
# shellcheck source=../../scripts/lib/deploy-credential.sh
source "$REPO_ROOT/scripts/lib/deploy-credential.sh"

deploy_credential_publish_all
grep -q -- "create token ahorro-deploy -n ahorro-dev" "$LOG" || { echo "FAIL: no ahorro-deploy token minted"; exit 1; }
grep -q -- "--name /p/cluster/ahorro-deploy/token --type SecureString" "$LOG" || { echo "FAIL: ahorro token not published"; exit 1; }
grep -q -- "--name /p/cluster/ahorro-deploy/fqdn --type String" "$LOG" || { echo "FAIL: ahorro fqdn not published"; exit 1; }
grep -q -- "create token llm-deploy -n llm-dev" "$LOG" || { echo "FAIL: no llm-deploy token minted"; exit 1; }
grep -q -- "--name /p/cluster/llm-deploy/token --type SecureString" "$LOG" || { echo "FAIL: llm token not published"; exit 1; }

: > "$LOG"
deploy_credential_forget_all
grep -q -- "delete-parameter --region eu-west-1 --name /p/cluster/ahorro-deploy/endpoint" "$LOG" || { echo "FAIL: ahorro credential not forgotten"; exit 1; }
grep -q -- "delete-parameter --region eu-west-1 --name /p/cluster/llm-deploy/endpoint" "$LOG" || { echo "FAIL: llm credential not forgotten"; exit 1; }

: > "$LOG"
PROVIDER=local deploy_credential_publish_all
[ ! -s "$LOG" ] || { echo "FAIL: local must publish nothing"; exit 1; }
echo "deploy-credential-test: ok"
