#!/usr/bin/env bash
# Install the workstation-vpn client on this machine:
#   key pair (generated here) + peer on the AmneziaWG server (over SSH),
#   /etc/amnezia/amneziawg/<VPN_NAME>.conf, a polkit rule, vpn-switch and the tray icon.
# Usage: ./install.sh [--config FILE] [--user-only] [--dry-run]
#   --user-only  only (re)install vpn-switch, the tray icon and autostart; no sudo, no server changes
#   --dry-run    read the server, pick an address, print what would be installed; change nothing
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. lib/common.sh

config="" user_only=0 dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) config="$2"; shift 2 ;;
        --user-only) user_only=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

wv_load_config "${config:-${WV_CONFIG:-}}"
for name in "$VPN_NAME" "$SERVER_IF" "$CLIENT_NAME"; do
    wv_valid_name "$name" || { echo "invalid name '$name' (allowed: A-Z a-z 0-9 . _ -, up to 32)" >&2; exit 1; }
done
conf="$WV_AWG_DIR/$VPN_NAME.conf"
rule="$WV_POLKIT_RULE"
ssh_args=(-o BatchMode=yes -o ConnectTimeout=10)
[[ -n "$SSH_KEY" ]] && ssh_args+=(-i "${SSH_KEY/#\~/$HOME}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# Read what the client needs from the server. Filtering happens on the server, so the server's
# private key and PostUp/PostDown never leave it.
server_info() {
    ssh "${ssh_args[@]}" "$SERVER_SSH" bash -s -- "$SERVER_IF" "'$WV_OBF_REGEX'" <<'REMOTE'
set -eu
IF="$1"; OBF="$2"; C="/etc/amnezia/amneziawg/$IF.conf"
echo "PUB $(awg show "$IF" public-key)"
echo "ADDR $(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$C" | head -n1 | cut -d, -f1 | tr -d ' ')"
awg show "$IF" allowed-ips | cut -f2 | tr ' ' '\n' | sed -n 's/^\(..*\)$/USED \1/p'
sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' "$C" | tr ',' '\n' | tr -d ' ' | sed -n 's/^\(..*\)$/USED \1/p'
grep -E "$OBF" "$C" | sed 's/^/OBF /'
REMOTE
}

# Add this machine as a peer: live (no restart, other peers keep their sessions) and in the config.
server_add_peer() {   # pubkey address
    ssh "${ssh_args[@]}" "$SERVER_SSH" bash -s -- "$SERVER_IF" "'$1'" "$2" "$CLIENT_NAME" <<'REMOTE'
set -eu
IF="$1"; PUB="$2"; IP="$3"; NAME="$4"; C="/etc/amnezia/amneziawg/$IF.conf"
grep -qF "$PUB" "$C" && { echo "this key is already a peer in $C" >&2; exit 3; }
awg show "$IF" allowed-ips | grep -qF "$IP/32" && { echo "$IP is already in use" >&2; exit 4; }
cp -a "$C" "$C.bak-$(date +%Y%m%d-%H%M%S)"
awg set "$IF" peer "$PUB" allowed-ips "$IP/32"
printf '\n[Peer]\n# %s (workstation-vpn)\nPublicKey = %s\nAllowedIPs = %s/32\n' "$NAME" "$PUB" "$IP" >> "$C"
REMOTE
}

check_packages() {
    local missing=0
    command -v awg >/dev/null && command -v awg-quick >/dev/null || missing=1
    modinfo amneziawg >/dev/null 2>&1 || command -v amneziawg-go >/dev/null || missing=1
    if [[ $missing -eq 1 ]]; then
        cat >&2 <<'EOF'
AmneziaWG is not installed. Install it first, then re-run:
  Arch:          yay -S amneziawg-dkms amneziawg-tools      (needs linux-headers)
  Debian/Ubuntu: sudo add-apt-repository ppa:amnezia/ppa && sudo apt install amneziawg
EOF
        exit 1
    fi
}

conf_exists() {   # dry-run never prompts for a password: unreadable counts as absent
    if [[ $dry_run -eq 1 ]]; then sudo -n test -e "$conf" 2>/dev/null; else sudo test -e "$conf"; fi
}

install_tunnel() {
    if conf_exists; then
        say "$conf exists: keeping its key and server peer"
    else
        local info server_pub server_addr obf address priv pub
        say "reading server $SERVER_SSH ($SERVER_IF)"
        info=$(server_info)
        server_pub=$(wv_info_field PUB <<<"$info")
        server_addr=$(wv_info_field ADDR <<<"$info")
        obf=$(wv_info_lines OBF <<<"$info")
        [[ -n "$server_pub" && -n "$server_addr" ]] || { echo "could not read server key/address" >&2; exit 1; }
        address=$(wv_info_lines USED <<<"$info" | sed 's/^/USED /' | wv_pick_free_ip "$server_addr")
        say "client address: $address (server $server_addr)"
        (umask 077; awg genkey > "$tmp/priv")
        priv=$(cat "$tmp/priv"); pub=$(awg pubkey < "$tmp/priv")
        (umask 077; wv_render_client_conf "$CLIENT_NAME" "$priv" "$address" "$server_pub" \
            "$SERVER_ENDPOINT" "$ALLOWED_IPS" "$KEEPALIVE" "$obf" > "$tmp/client.conf")
        if [[ $dry_run -eq 1 ]]; then
            say "would install $conf:"; sed 's/^PrivateKey = .*/PrivateKey = <generated>/' "$tmp/client.conf"
            say "would add peer $CLIENT_NAME $address to $SERVER_SSH:$SERVER_IF"
        else
            sudo install -d -m 700 "$WV_AWG_DIR"
            sudo install -m 600 -o root -g root "$tmp/client.conf" "$conf"
            say "adding peer $CLIENT_NAME to the server"
            server_add_peer "$pub" "$address" \
                || { sudo rm -f "$conf"; echo "server refused the peer; $conf removed" >&2; exit 1; }
        fi
    fi
    local rendered; rendered=$(wv_render_polkit "$USER" "$WV_UNIT")
    if [[ $dry_run -eq 1 ]]; then say "would install $rule:"; echo "$rendered"; return; fi
    printf '%s\n' "$rendered" | sudo install -m 644 -o root -g root /dev/stdin "$rule"
    say "polkit: $USER may start/stop $WV_UNIT"
}

install_user() {
    [[ $dry_run -eq 1 ]] && { say "would install vpn-switch, vpn-tray, icons, autostart"; return; }
    install -Dm755 bin/vpn-switch "$WV_BIN_DIR/vpn-switch"
    install -Dm755 bin/vpn-tray "$WV_BIN_DIR/vpn-tray"
    install -Dm644 lib/common.sh "$WV_DATA_DIR/common.sh"
    mkdir -p "$WV_DATA_DIR/icons" "$(dirname "$WV_AUTOSTART")"
    wv_render_icon on "$VPN_LABEL" > "$WV_DATA_DIR/icons/vpn-on.svg"
    wv_render_icon off "$VPN_LABEL" > "$WV_DATA_DIR/icons/vpn-off.svg"
    if [[ "$(readlink -f "$WV_CONFIG_FILE")" != "$(readlink -f "$WV_CONFIG_DEFAULT")" ]]; then
        install -Dm600 "$WV_CONFIG_FILE" "$WV_CONFIG_DEFAULT"
    fi
    cat > "$WV_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=VPN $VPN_LABEL (tray)
Exec=$WV_BIN_DIR/vpn-tray
Icon=$WV_DATA_DIR/icons/vpn-on.svg
X-KDE-autostart-phase=2
Terminal=false
EOF
    pkill -f "$WV_BIN_DIR/vpn-tray" 2>/dev/null || true
    if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
        setsid -f "$WV_BIN_DIR/vpn-tray" >/dev/null 2>&1
        say "tray icon started (autostarts on login)"
    fi
    say "done: use the tray icon or 'vpn-switch on|off|toggle|status'"
}

if [[ $user_only -eq 0 ]]; then
    check_packages
    [[ $dry_run -eq 1 ]] || sudo -v
    install_tunnel
fi
install_user
