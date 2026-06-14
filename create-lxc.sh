#!/usr/bin/env bash
#
# sail :: create-lxc.sh
# -----------------------------------------------------------------------------
# Run on the PROXMOX HOST. Creates a Debian unprivileged LXC for sail, with
# onboot autostart. Fully non-interactive (passwordless root — use `pct enter`).
# Then, inside it: ./bake.sh  and  ./register.sh.
#
#     CTID=9001 ./create-lxc.sh
#
# Override via env: CTID, HOSTNAME, CORES, MEMORY, DISK, SWAP, STORAGE, BRIDGE,
# TEMPLATE, TEMPLATE_STORAGE, PASSWORD, SSH_PUBKEY (path to a .pub file).
# -----------------------------------------------------------------------------
set -euo pipefail
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

command -v pct >/dev/null 2>&1 || die "pct not found — run this on the Proxmox host."

CTID="${CTID:-9001}"
HOSTNAME="${HOSTNAME:-sail}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"          # MB
SWAP="${SWAP:-512}"               # MB
DISK="${DISK:-16}"                # GB
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
PASSWORD="${PASSWORD:-}"          # empty => passwordless root (pct enter still works)
SSH_PUBKEY="${SSH_PUBKEY:-}"      # optional path to an authorized .pub key

pct status "$CTID" >/dev/null 2>&1 && die "CTID $CTID already exists. Pick another CTID."

if [ -z "$TEMPLATE" ]; then
  TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
    | awk '/debian-1[23]-standard/ {print $1}' | sort -V | tail -1)"
  if [ -z "$TEMPLATE" ]; then
    echo "[!] No debian-12/13-standard template on '$TEMPLATE_STORAGE'." >&2
    echo "    Get one:  pveam update && pveam available | grep debian-13" >&2
    echo "    Then:     pveam download $TEMPLATE_STORAGE <template-name>" >&2
    die "no template available"
  fi
fi
echo "==> Using template: $TEMPLATE"

CREATE_ARGS=(
  "$CTID" "$TEMPLATE"
  --hostname "$HOSTNAME"
  --cores "$CORES"
  --memory "$MEMORY"
  --swap "$SWAP"
  --rootfs "${STORAGE}:${DISK}"
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
  --unprivileged 1
  --features nesting=1,keyctl=1
  --onboot 1
)
[ -n "$PASSWORD" ]   && CREATE_ARGS+=(--password "$PASSWORD")
[ -n "$SSH_PUBKEY" ] && CREATE_ARGS+=(--ssh-public-keys "$SSH_PUBKEY")

echo "==> Creating LXC $CTID ($HOSTNAME): ${CORES} cores / ${MEMORY}MB / ${DISK}GB on $STORAGE"
pct create "${CREATE_ARGS[@]}"

echo "==> Starting LXC $CTID (onboot=1 — autostarts after host reboot)…"
pct start "$CTID"
