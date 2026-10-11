#!/usr/bin/env bash
# Remove the workstation-vpn client from this machine and its peer from the server.
# Usage: ./uninstall.sh [--config FILE] [--keep-peer]
#   --keep-peer  leave the peer on the server (e.g. when reinstalling with the same key)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. lib/common.sh

config="" keep_peer=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) config="$2"; shift 2 ;;
        --keep-peer) keep_peer=1; shift ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

wv_load_config "${config:-${WV_CONFIG:-}}"
wv_valid_name "$VPN_NAME" && wv_valid_name "$SERVER_IF" || { echo "invalid VPN_NAME/SERVER_IF" >&2; exit 1; }
conf="$WV_AWG_DIR/$VPN_NAME.conf"
rule="$WV_POLKIT_RULE"
ssh_args=(-o BatchMode=yes -o ConnectTimeout=10)
[[ -n "$SSH_KEY" ]] && ssh_args+=(-i "${SSH_KEY/#\~/$HOME}")
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# Remove the peer live and its [Peer] block from the server config (backup kept).
server_remove_peer() {   # pubkey
    ssh "${ssh_args[@]}" "$SERVER_SSH" bash -s -- "$SERVER_IF" "'$1'" <<'REMOTE'
set -eu
IF="$1"; PUB="$2"; C="/etc/amnezia/amneziawg/$IF.conf"
cp -a "$C" "$C.bak-$(date +%Y%m%d-%H%M%S)"
awg set "$IF" peer "$PUB" remove
awk -v pub="$PUB" 'BEGIN { RS = ""; ORS = "\n\n" } index($0, "PublicKey = " pub) == 0' "$C" > "$C.new"
mv "$C.new" "$C"
REMOTE
}

sudo -v
pkill -f "$WV_BIN_DIR/vpn-tray" 2>/dev/null || true
systemctl is-active -q "$WV_UNIT" && sudo systemctl stop "$WV_UNIT"
if sudo test -e "$conf"; then
    pub=$(sudo sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$conf" | awg pubkey)
    if [[ $keep_peer -eq 0 ]]; then
        say "removing peer from $SERVER_SSH:$SERVER_IF"
        server_remove_peer "$pub"
    fi
    sudo rm -f "$conf"
fi
sudo rm -f "$rule"
rm -f "$WV_BIN_DIR/vpn-switch" "$WV_BIN_DIR/vpn-tray" "$WV_AUTOSTART"
rm -rf "$WV_DATA_DIR"
say "removed (config kept: $WV_CONFIG_FILE)"
