# workstation-vpn

A one-click AmneziaWG client for a Linux desktop: a tray icon that shows whether the tunnel is up
and toggles it, without `sudo` after the one-time setup. The installer registers the machine as a
peer on your own AmneziaWG server over SSH, so adding another computer is a single command.

- **Tray icon** (StatusNotifierItem / AppIndicator): green shield = tunnel up, grey outline = down.
  It polls the real unit state every 3 s, so it stays right when the tunnel is switched from a
  terminal or drops on its own. Click → menu with the state and *Turn on / Turn off*;
  middle click toggles.
- **`vpn-switch on|off|toggle|status`** — the same from a terminal; after switching it checks the
  public IP and shows a desktop notification.
- **No sudo for switching**: a polkit rule allows *your user* to `start`/`stop`/`restart`
  *only* `awg-quick@<VPN_NAME>.service`. Nothing else is granted.
- Other VPNs (e.g. NetworkManager OpenVPN) are left alone. With both up, the AmneziaWG tunnel wins
  (awg-quick policy routing).

UI strings are Russian when `LANG=ru*`, English otherwise.

## How it works

```
your machine                                             AmneziaWG server
------------                                             ----------------
install.sh ── ssh ──> reads: server public key, address, used peer IPs,
                             obfuscation params (Jc, Jmin, Jmax, S*, H*, I*)
                             (filtered on the server: its private key and
                              PostUp/PostDown never leave it)
           ── generates a key pair locally (private key never leaves this machine)
           ── picks the first free address in the server /24
           ── /etc/amnezia/amneziawg/<VPN_NAME>.conf          (root, 600)
           ── ssh ──> awg set <if> peer <pub> allowed-ips <ip>/32   (live, no restart)
                      + [Peer] block appended to <if>.conf    (backup kept)
           ── /etc/polkit-1/rules.d/50-workstation-vpn.rules
           ── ~/.local/bin/{vpn-switch,vpn-tray}, ~/.local/share/workstation-vpn/,
              ~/.config/autostart/vpn-tray.desktop
```

Routing is plain `awg-quick`: with `AllowedIPs = 0.0.0.0/0` it adds a fwmark rule, table 51820 and
`suppress_prefixlength 0`, so more specific routes in the main table (your LAN, any bypass routes)
still go direct. DNS is not touched (the config has no `DNS =` line).

The tunnel is **not** enabled at boot; it is switched from the tray. To make it permanent:
`sudo systemctl enable awg-quick@<VPN_NAME>`.

## Requirements

- An AmneziaWG server managed with `awg-quick`, config at `/etc/amnezia/amneziawg/<if>.conf`,
  a /24 client subnet, and root SSH access to it.
- On the desktop: AmneziaWG (`awg`, `awg-quick`, kernel module or `amneziawg-go`), `curl`,
  `notify-send`, Python 3 with PyGObject and an AppIndicator typelib, polkit, systemd.
  - Arch: `yay -S amneziawg-dkms amneziawg-tools` (plus `linux-headers`); `python-gobject`,
    `libappindicator` (KDE has both).
  - Debian/Ubuntu: `ppa:amnezia/ppa` → `amneziawg`; `python3-gi`, `gir1.2-ayatanaappindicator3-0.1`.
  - GNOME needs the *AppIndicator and KStatusNotifierItem Support* extension to show tray icons.

## Install

```bash
mkdir -p ~/.config/workstation-vpn
cp site.example.env ~/.config/workstation-vpn/site.env
chmod 600 ~/.config/workstation-vpn/site.env
$EDITOR ~/.config/workstation-vpn/site.env

./install.sh --dry-run     # reads the server, prints the config it would install; changes nothing
./install.sh               # asks for sudo once
```

`~/.local/bin` must be in your `PATH` for `vpn-switch` in a terminal (fish: `fish_add_path ~/.local/bin`).

Another computer: clone the repo there, copy `site.env` (set a different `CLIENT_NAME`), run
`./install.sh`. Each machine gets its own key and address — never copy the tunnel `.conf` between
machines: two clients with one key knock each other off the server.

Re-running is safe: an existing tunnel config keeps its key and server peer; only the polkit rule
and the user files are refreshed. `./install.sh --user-only` refreshes just the user files (no sudo).

## Uninstall

```bash
./uninstall.sh             # stops the tunnel, removes the peer from the server, local files and the rule
./uninstall.sh --keep-peer # same, but leaves the peer on the server
```

## Tests

```bash
tests/run.sh
```

Plain bash, no dependencies: address picking, server-info parsing, config/polkit/icon rendering,
name validation, syntax of the shipped scripts.
