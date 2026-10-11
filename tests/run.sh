#!/usr/bin/env bash
# Plain-bash tests for lib/common.sh (no bats needed). Run: tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh

fails=0
check() {   # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"
    else echo "FAIL $1"; echo "  expected: $(printf %q "$2")"; echo "  actual:   $(printf %q "$3")"; fails=$((fails + 1)); fi
}

# --- pick_free_ip: first free host in the server /24, server and used addresses skipped
check "pick: skips server and used" "10.9.0.4" \
    "$(printf 'USED 10.9.0.2/32\nUSED 10.9.0.3/32\nUSED 10.9.0.10/32\n' | wv_pick_free_ip 10.9.0.1/24)"
check "pick: ignores addresses outside the subnet" "10.9.0.2" \
    "$(printf 'USED 10.99.0.0/24\nUSED 192.168.1.2/32\n' | wv_pick_free_ip 10.9.0.1/24)"
check "pick: rejects non-/24" "" "$(printf '' | wv_pick_free_ip 10.9.0.1/16 2>/dev/null)"
check "pick: full subnet -> nothing" "" \
    "$(for i in $(seq 2 254); do echo "USED 10.9.0.$i/32"; done | wv_pick_free_ip 10.9.0.1/24 2>/dev/null)"

# --- server info parsing
info=$'PUB c2VydmVycHVi\nADDR 10.9.0.1/24\nUSED 10.9.0.3/32\nOBF Jc = 4\nOBF H1 = 123\nPORT 51820'
check "info: pubkey" "c2VydmVycHVi" "$(wv_info_field PUB <<<"$info")"
check "info: address" "10.9.0.1/24" "$(wv_info_field ADDR <<<"$info")"
check "info: obfuscation lines" $'Jc = 4\nH1 = 123' "$(wv_info_lines OBF <<<"$info")"

# --- client config rendering
expected=$'[Interface]\n# workstation-vpn client "pc1"\nPrivateKey = PRIV\nAddress = 10.9.0.4/32\nJc = 4\nH1 = 123\n\n[Peer]\nPublicKey = SPUB\nEndpoint = 203.0.113.10:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25'
check "render: client conf" "$expected" \
    "$(wv_render_client_conf pc1 PRIV 10.9.0.4 SPUB 203.0.113.10:51820 0.0.0.0/0 25 $'Jc = 4\nH1 = 123')"

# --- polkit rule rendering
rule=$(wv_render_polkit alice awg-quick@awgvpn.service)
check "polkit: user" "1" "$(grep -c 'subject.user == "alice"' <<<"$rule")"
check "polkit: unit" "1" "$(grep -c 'action.lookup("unit") == "awg-quick@awgvpn.service"' <<<"$rule")"

# --- icon label font size shrinks with label length
check "icon: 3 chars" "6.6" "$(wv_icon_font_size 186)"
check "icon: 4 chars" "5.2" "$(wv_icon_font_size VPN1)"
check "icon: 2 chars" "8" "$(wv_icon_font_size NL)"

# --- client name validation (goes into a remote command and a config comment)
wv_valid_name "pc-1.home_2" && r=ok || r=bad; check "name: valid" ok "$r"
wv_valid_name 'pc; rm -rf /' && r=ok || r=bad; check "name: invalid" bad "$r"

# --- syntax of the shipped programs
for f in bin/vpn-switch install.sh uninstall.sh; do
    bash -n "$f" 2>/dev/null && r=ok || r=bad; check "syntax: $f" ok "$r"
done
python3 -m py_compile bin/vpn-tray 2>/dev/null && r=ok || r=bad; check "syntax: bin/vpn-tray" ok "$r"

echo; [[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
