#!/usr/bin/env bash
#
# sail :: bake.sh
# -----------------------------------------------------------------------------
# Turn a fresh Debian/Ubuntu box into the GENERIC sail runner image: the GitHub
# Actions runner agent + Node + pnpm + git + gh + Xvfb + Playwright (system libs
# + a baked Chromium), with a persistent virtual display and autostart wiring.
#
# Contains NO secrets and is repo-agnostic — run it once to make the image, then
# `register.sh` attaches it to a repo/org with a one-time token. On Proxmox you
# can snapshot the container as a template afterwards so clones are instant.
#
#     sudo ./bake.sh              # full image (browser layer included)
#     sudo ./bake.sh --no-browser # lean image, no Xvfb/Playwright
# -----------------------------------------------------------------------------
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-}"                       # empty => latest release
NODE_MAJOR="${NODE_MAJOR:-22}"
INSTALL_BROWSER="${INSTALL_BROWSER:-1}"
PW_PACKAGE="${PW_PACKAGE:-playwright}"                     # npm pkg for install-deps/install
PW_BROWSERS_PATH="${PW_BROWSERS_PATH:-/opt/ms-playwright}" # shared, runner-owned (writable) browser cache
XVFB_DISPLAY="${XVFB_DISPLAY:-:99}"
XVFB_RESOLUTION="${XVFB_RESOLUTION:-1920x1080x24}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-browser) INSTALL_BROWSER=0; shift ;;
    --node-major) NODE_MAJOR="$2"; shift 2 ;;
    --version)    RUNNER_VERSION="$2"; shift 2 ;;
    --user)       RUNNER_USER="$2"; shift 2 ;;
    -h|--help)    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 ..."
command -v apt-get >/dev/null 2>&1 || die "sail targets Debian/Ubuntu (apt-get not found)"

case "$(uname -m)" in
  x86_64|amd64)  RUNNER_ARCH=x64 ;;
  aarch64|arm64) RUNNER_ARCH=arm64 ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND=noninteractive

#--- base packages -----------------------------------------------------------
log "Installing base packages…"
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl ca-certificates tar git jq sudo

#--- GitHub CLI (gh) ---------------------------------------------------------
# Workflows that drive `gh` (issues, labels, releases) need it, and it isn't in
# Debian's default repos — add GitHub's apt source. Idempotent.
if ! command -v gh >/dev/null 2>&1; then
  log "Installing GitHub CLI (gh)…"
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y gh
fi

#--- Node + pnpm -------------------------------------------------------------
if ! command -v node >/dev/null 2>&1 || \
   [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt "$NODE_MAJOR" ] 2>/dev/null; then
  log "Installing Node ${NODE_MAJOR}…"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
log "Enabling pnpm via corepack…"
corepack enable >/dev/null 2>&1 || npm i -g pnpm >/dev/null 2>&1 || true
corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true

#--- runner user -------------------------------------------------------------
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  log "Creating service user '$RUNNER_USER'…"
  useradd -m -s /bin/bash "$RUNNER_USER"
fi

#--- download the actions-runner agent ---------------------------------------
if [ -z "$RUNNER_VERSION" ]; then
  RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r .tag_name | sed 's/^v//')"
  [ -n "$RUNNER_VERSION" ] && [ "$RUNNER_VERSION" != null ] \
    || die "could not resolve latest runner version (set --version X.Y.Z)"
fi
mkdir -p "$RUNNER_DIR"
if [ ! -f "$RUNNER_DIR/config.sh" ]; then
  log "Downloading actions-runner v$RUNNER_VERSION…"
  curl -fsSL -o /tmp/actions-runner.tgz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  tar xzf /tmp/actions-runner.tgz -C "$RUNNER_DIR"
  rm -f /tmp/actions-runner.tgz
else
  log "Runner agent already present; skipping download."
fi
log "Installing runner native dependencies…"
"$RUNNER_DIR/bin/installdependencies.sh" >/dev/null
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

#--- a persistent .env every job inherits ------------------------------------
# Written at bake time (before any registration); the runner injects these into
# every job regardless of how it's launched.
write_env_line() { # key value
  touch "$RUNNER_DIR/.env"
  sed -i "/^$1=/d" "$RUNNER_DIR/.env"
  echo "$1=$2" >> "$RUNNER_DIR/.env"
}

#--- browser layer -----------------------------------------------------------
if [ "$INSTALL_BROWSER" = 1 ]; then
  log "Installing Xvfb + Playwright Chromium (libs + browser)…"
  apt-get install -y --no-install-recommends xvfb
  npx -y "${PW_PACKAGE}" install-deps chromium
  mkdir -p "$PW_BROWSERS_PATH"
  PLAYWRIGHT_BROWSERS_PATH="$PW_BROWSERS_PATH" npx -y "${PW_PACKAGE}" install chromium
  # Runner-owned (not root-owned read-only): lets jobs `playwright install` the
  # exact Chromium revision their pinned Playwright wants (cached) without EACCES.
  # Avoids a baked-vs-consumer version skew without coupling the image to any project.
  chown -R "$RUNNER_USER:$RUNNER_USER" "$PW_BROWSERS_PATH"

  log "Writing xvfb.service (display $XVFB_DISPLAY as $RUNNER_USER)…"
  cat > /etc/systemd/system/xvfb.service <<EOF
[Unit]
Description=Xvfb virtual framebuffer for sail headed-browser CI
After=network.target

[Service]
User=$RUNNER_USER
ExecStart=/usr/bin/Xvfb $XVFB_DISPLAY -screen 0 $XVFB_RESOLUTION -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xvfb.service

  write_env_line DISPLAY "$XVFB_DISPLAY"
  write_env_line PLAYWRIGHT_BROWSERS_PATH "$PW_BROWSERS_PATH"
  # /etc/environment so interactive shells + non-job processes see the cache too.
  sed -i '/^PLAYWRIGHT_BROWSERS_PATH=/d' /etc/environment 2>/dev/null || true
  echo "PLAYWRIGHT_BROWSERS_PATH=$PW_BROWSERS_PATH" >> /etc/environment
fi
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.env" 2>/dev/null || true

#--- done --------------------------------------------------------------------
echo
log "Image baked. Utilities ready (runner agent, Node $NODE_MAJOR, pnpm, git, gh$([ "$INSTALL_BROWSER" = 1 ] && echo ", Xvfb, Playwright/Chromium"))."
log "Next: attach it to a repo or org with a one-time token:"
echo "    sudo ./register.sh --repo owner/name --labels self-hosted,linux --token <ONE-TIME>"
echo "    sudo ./register.sh --org  your-org   --labels self-hosted,linux --token <ONE-TIME>"
echo
log "On Proxmox, snapshot now for instant clones:  pct template <ctid>   (run on the host)"
