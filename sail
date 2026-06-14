#!/usr/bin/env bash
#
# sail :: unified CLI
#   sail bake [--no-browser ...]      build the generic image (no secrets)
#   sail register --repo|--org ...    attach to a repo/org with a one-time token
#   sail status                       show runner + xvfb service health
#   sail help
# -----------------------------------------------------------------------------
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"

case "${1:-help}" in
  bake)     shift; exec "$DIR/bake.sh" "$@" ;;
  register) shift; exec "$DIR/register.sh" "$@" ;;
  status)
    if [ -f "$RUNNER_DIR/.service" ]; then
      systemctl status "$(cat "$RUNNER_DIR/.service")" --no-pager || true
    else
      echo "No registered runner at $RUNNER_DIR (run: sail register …)"
    fi
    systemctl cat xvfb.service >/dev/null 2>&1 && { echo; systemctl status xvfb.service --no-pager || true; }
    echo; echo "Public egress IP:"
    curl -fsSL https://api.ipify.org 2>/dev/null && echo || echo "(no network?)"
    ;;
  -h|--help|help)
    sed -n '3,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *) echo "unknown command: $1 (try: sail help)" >&2; exit 1 ;;
esac
