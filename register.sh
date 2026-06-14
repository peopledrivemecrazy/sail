#!/usr/bin/env bash
#
# sail :: register.sh
# -----------------------------------------------------------------------------
# Attach a baked sail image to a repo OR an org using a single ONE-TIME-USE
# registration token. This is the only step that touches a credential, and it's
# the ephemeral token GitHub hands you — pasted once, consumed immediately.
# Nothing is stored, no env var, no PAT.
#
# Get the token from (it expires in ~1h, single use):
#   repo: Settings -> Actions -> Runners -> New self-hosted runner
#   org:  Org Settings -> Actions -> Runners -> New runner
#
#     sudo ./register.sh --repo owner/name --labels self-hosted,my-canary,linux
#     sudo ./register.sh --org  your-org   --labels self-hosted,linux
#     (omit --token to be prompted, so it never lands in shell history)
# -----------------------------------------------------------------------------
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
GH_REPO="${GH_REPO:-}"
GH_ORG="${GH_ORG:-}"
REPLACE="${REPLACE:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    GH_REPO="$2"; shift 2 ;;
    --org)     GH_ORG="$2"; shift 2 ;;
    --labels)  RUNNER_LABELS="$2"; shift 2 ;;
    --name)    RUNNER_NAME="$2"; shift 2 ;;
    --token)   RUNNER_TOKEN="$2"; shift 2 ;;
    --replace) REPLACE=1; shift ;;
    -h|--help) sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 ..."
[ -f "$RUNNER_DIR/config.sh" ] || die "no baked runner at $RUNNER_DIR — run ./bake.sh first."

#--- resolve the registration URL (repo XOR org) -----------------------------
if [ -n "$GH_REPO" ] && [ -n "$GH_ORG" ]; then
  die "pass --repo OR --org, not both."
elif [ -n "$GH_REPO" ]; then
  case "$GH_REPO" in
    https://github.com/*) GH_URL="${GH_REPO%.git}"; SLUG="${GH_REPO#https://github.com/}" ;;
    */*)                  SLUG="$GH_REPO"; GH_URL="https://github.com/${GH_REPO}" ;;
    *) die "--repo must be 'owner/repo' or a full https URL" ;;
  esac
  SLUG="${SLUG%.git}"; GH_URL="${GH_URL%.git}"
  SCOPE_LABEL="${SLUG//\//-}"
elif [ -n "$GH_ORG" ]; then
  GH_URL="https://github.com/${GH_ORG#https://github.com/}"
  SCOPE_LABEL="${GH_ORG##*/}"
else
  die "set --repo owner/name or --org your-org"
fi
[ -n "$RUNNER_NAME" ] || RUNNER_NAME="sail-${SCOPE_LABEL}"

#--- the one-time token ------------------------------------------------------
if [ -z "$RUNNER_TOKEN" ]; then
  printf 'Paste the one-time registration token (input hidden): '
  read -rs RUNNER_TOKEN; echo
fi
[ -n "$RUNNER_TOKEN" ] || die "no token provided."

#--- (re)register ------------------------------------------------------------
if [ -f "$RUNNER_DIR/.runner" ] && [ "$REPLACE" != 1 ]; then
  log "Already registered; pass --replace to re-register. Ensuring service is up…"
else
  if [ -f "$RUNNER_DIR/.service" ]; then
    log "Stopping existing service before re-register…"
    ( cd "$RUNNER_DIR" && ./svc.sh stop || true; ./svc.sh uninstall || true )
  fi
  log "Registering '$RUNNER_NAME' with $GH_URL (labels: $RUNNER_LABELS)…"
  ( cd "$RUNNER_DIR" && sudo -u "$RUNNER_USER" ./config.sh \
      --url "$GH_URL" \
      --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS" \
      --work _work \
      --unattended \
      --replace )
fi

#--- install + start the systemd service -------------------------------------
SVC_EXISTS=0
if [ -f "$RUNNER_DIR/.service" ] && systemctl cat "$(cat "$RUNNER_DIR/.service")" >/dev/null 2>&1; then
  SVC_EXISTS=1
fi
if [ "$SVC_EXISTS" = 1 ]; then
  ( cd "$RUNNER_DIR" && ./svc.sh start || true )
else
  log "Installing runner as a systemd service (run-as: $RUNNER_USER)…"
  ( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )
fi
SVC_NAME="$(cat "$RUNNER_DIR/.service" 2>/dev/null || true)"

# Order the runner after Xvfb if the browser layer was baked.
if systemctl cat xvfb.service >/dev/null 2>&1 && [ -n "$SVC_NAME" ]; then
  mkdir -p "/etc/systemd/system/${SVC_NAME}.d"
  cat > "/etc/systemd/system/${SVC_NAME}.d/10-xvfb.conf" <<EOF
[Unit]
After=xvfb.service
Wants=xvfb.service
EOF
  systemctl daemon-reload
  systemctl restart "$SVC_NAME"
fi

echo
log "Done. '$RUNNER_NAME' should show Idle/online at $GH_URL (Settings -> Actions -> Runners)."
log "Verify:  sail status   |   target it from a workflow with  runs-on: [$(echo "$RUNNER_LABELS" | sed 's/,/, /g')]"
