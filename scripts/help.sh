#!/usr/bin/env bash
# Lists the Makefile's targets, from the `## ` comment blocks already written
# above each one, under the `### ` group headings. With a target name it prints
# that target's whole block. Reads one file in this repository: no cloud call,
# no credentials, no Terraform state.
set -euo pipefail

MAKEFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Makefile"

# Bold only for a terminal: `make help > notes.txt` and a CI log would
# otherwise collect literal escape sequences.
if [ -t 1 ]; then
  B=$'\033[1m'; H=$'\033[1;4m'; R=$'\033[0m'
else
  B=""; H=""; R=""
fi

# A doc block attaches to the next target line, however many lines away: an
# ifeq/else/export between the two is normal here, so nothing but a target line
# may end a block. The first target line consumes the block, so each ifeq
# branch's repeat of the same name is skipped.
awk -v want="${1:-}" -v b="$B" -v h="$H" -v r="$R" '
  /^### / { if (want == "") head = substr($0, 5); next }
  /^## /  { if (!n) delete doc; doc[++n] = substr($0, 4); next }
  /^[a-zA-Z0-9][a-zA-Z0-9_.-]*:/ {
    if (!n) next
    split($0, f, ":"); t = f[1]
    if (want == "") {
      if (head != "") { printf "\n%s%s%s\n", h, head, r; head = "" }
      printf "  %s%-26s%s %s\n", b, t, r, doc[1]
    } else if (want == t) {
      printf "%s%s%s\n", b, t, r
      for (i = 1; i <= n; i++) print "  " doc[i]
      found = 1
    }
    n = 0
    next
  }
  END {
    if (want != "" && !found) {
      printf "help: no documented target named \"%s\" - run make help\n", want > "/dev/stderr"
      exit 1
    }
  }
' "$MAKEFILE"

if [ -z "${1:-}" ]; then
  printf '\n  %s\n  %s\n' \
    "PROVIDER=aws|civo|hetzner|local selects the target; see README.md for the inputs." \
    "One command in full: make help-<target>"
fi
