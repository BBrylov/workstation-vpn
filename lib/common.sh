# Shared helpers for workstation-vpn. Pure functions (no I/O besides stdin/stdout) unless noted.
# shellcheck shell=bash

WV_CONFIG_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/workstation-vpn/site.env"
WV_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/workstation-vpn"
WV_BIN_DIR="$HOME/.local/bin"
WV_AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/vpn-tray.desktop"
WV_AWG_DIR=/etc/amnezia/amneziawg
WV_POLKIT_RULE=/etc/polkit-1/rules.d/50-workstation-vpn.rules   # one tunnel per machine
# Obfuscation parameters copied from the server interface (AmneziaWG 1.x and 2.x names).
WV_OBF_REGEX='^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|J[1-3]|Itime)[[:space:]]*='

# Load site config (I/O). Sets defaults for optional keys.
wv_load_config() {
    local file="${1:-$WV_CONFIG_DEFAULT}"
    [[ -f "$file" ]] || { echo "config not found: $file (copy site.example.env there)" >&2; return 1; }
    # shellcheck disable=SC1090
    . "$file"
    : "${SERVER_SSH:?SERVER_SSH is required in $file}"
    : "${SERVER_ENDPOINT:?SERVER_ENDPOINT is required in $file}"
    SERVER_IF="${SERVER_IF:-awg0}"
    VPN_NAME="${VPN_NAME:-awgvpn}"
    VPN_LABEL="${VPN_LABEL:-VPN}"
    ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0}"
    KEEPALIVE="${KEEPALIVE:-25}"
    CLIENT_NAME="${CLIENT_NAME:-$(uname -n)}"
    EXPECT_IP="${EXPECT_IP:-}"
    SSH_KEY="${SSH_KEY:-}"
    WV_UNIT="awg-quick@${VPN_NAME}.service"
    WV_CONFIG_FILE="$file"
}

# Peer comment / unit name go into remote commands and config files: keep them boring.
wv_valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }

# stdin: "USED <cidr>" lines. $1: server address with prefix, e.g. 10.9.0.1/24.
# stdout: first free host address (.2-.254) in that /24, excluding the server and used /32s.
wv_pick_free_ip() {
    local server="$1" ip prefix net used=" " line cidr host
    ip="${server%/*}"; prefix="${server#*/}"
    [[ "$prefix" == 24 ]] || { echo "only /24 server subnets are supported (got /$prefix)" >&2; return 1; }
    net="${ip%.*}"
    used+="${ip##*.} "
    while read -r line; do
        cidr="${line#USED }"
        [[ "$cidr" == "$net".*/32 ]] || continue
        host="${cidr%/32}"; used+="${host##*.} "
    done
    for host in $(seq 2 254); do
        [[ "$used" == *" $host "* ]] || { echo "$net.$host"; return 0; }
    done
    echo "no free address left in $net.0/24" >&2
    return 1
}

# stdin: server info ("<KEY> <value>" lines). Print the value of the first KEY line.
wv_info_field() { sed -n "s/^$1 //p" | head -n1; }
# stdin: server info. Print the values of all KEY lines.
wv_info_lines() { sed -n "s/^$1 //p"; }

# Render the client awg-quick config.
# Args: name private_key address server_pubkey endpoint allowed_ips keepalive obfuscation_lines
wv_render_client_conf() {
    printf '[Interface]\n# workstation-vpn client "%s"\nPrivateKey = %s\nAddress = %s/32\n%s\n\n' "$1" "$2" "$3" "$8"
    printf '[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = %s\n' "$4" "$5" "$6" "$7"
}

# Render the polkit rule: <user> may start/stop/restart <unit> without a password, nothing else.
wv_render_polkit() {
    cat <<EOF
// workstation-vpn: let $1 switch the VPN tunnel without a password.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "$2" &&
        ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
        subject.user == "$1") {
        return polkit.Result.YES;
    }
});
EOF
}

# Font size for the tray icon label so it fits the 22px shield.
wv_icon_font_size() {
    case ${#1} in
        1|2) echo 8 ;;
        3) echo 6.6 ;;
        *) echo 5.2 ;;
    esac
}

# Render a tray icon SVG. Args: on|off label
wv_render_icon() {
    local fill stroke text size
    size=$(wv_icon_font_size "$2")
    if [[ "$1" == on ]]; then fill='#2e9e4f'; stroke='#1d6b34'; text='#ffffff'
    else fill='none'; stroke='#8a8f96'; text='#8a8f96'; fi
    cat <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">
  <path d="M11 1.5 L19 4.5 V10 C19 15 15.5 18.8 11 20.5 C6.5 18.8 3 15 3 10 V4.5 Z" fill="$fill" stroke="$stroke" stroke-width="1.2"/>
  <text x="11" y="13.6" font-family="sans-serif" font-size="$size" font-weight="bold" fill="$text" text-anchor="middle">$2</text>
</svg>
EOF
}
