# NetDroid

**NetDroid** is a zero-dependency **KernelSU (KSU) module** paired with an offline-first **Material 3 Expressive WebUI** that transforms a rooted Android device into a dedicated, battery-efficient portable pocket router.

Manage your host router both locally on the device (`localhost:8765` or KernelSU Manager's native WebUI) and remotely from any tethered client over the hotspot LAN (`http://<hotspot-gateway>:8765`).

---

## Features

- **Zero-Dependency Backend:** Powered by KernelSU's built-in BusyBox `httpd` and POSIX shell CGI scripts—no Python, Node.js, or external runtime required.
- **Dual Operation Modes (`Normal` & `Tethering`):**
  - One-tap switch to **Tethering Mode** enabling IPv4 forwarding, `TTL=65` / IPv6 `Hop-Limit=65`, optional kernel-checked `iptables`/`ip6tables` `mangle` `POSTROUTING` TTL/HL failsafe, background app restriction (`appops` + `am set-inactive` + light Doze), and optional auto-sync pause.
  - Clean full restoration when switching back to **Normal Mode**.
- **Router-Grade Network & Quota Monitoring:**
  - Live Download (`Rx`) & Upload (`Tx`) throughput graph (Cellular & Hotspot interfaces) with 64-bit `/proc/net/dev` counters.
  - Persistent Session, Daily, and Monthly quota tracking (`/data/adb/netdroid/quota.json`) with customizable caps and warning/critical alerts.
  - Unified Connected Clients table combining `ip neigh`, legacy `dnsmasq.leases`, and Android 11–16 `NetworkStack` DHCP leases.
- **Per-App & LAN Client Firewall:**
  - Toggle Wi-Fi and Mobile Data per installed app UID via `iptables`/`ip6tables` `OUTPUT` rules.
  - Block/unblock individual tethered clients by MAC or IPv4 on the `FORWARD` chain.
  - Strict WAN Security Boundary (`NETDROID_IN`) blocking WebUI (`:8765`) and local DNS (`:5353`) on public cellular interfaces (`rmnet+`, `r_rmnet+`, `ccmni+`, `wwan+`, `pdp+`) plus PIN/token authentication for non-localhost LAN access.
- **Smart Battery & Charging Control:**
  - Auto-detects kernel charging sysfs nodes (`charging_enabled`, `battery_charging_enabled`, `input_suspend`) and current-limit nodes (`constant_charge_current_max`, `input_current_limit`, `current_max`).
  - Supports Qualcomm **Idle / Power-Bypass** mode, configurable Stop/Resume charge thresholds with hysteresis, Thermal Guard cutoff (`max_temp` with `-3°C` recovery), charging current capping, and **Active Only in Tethering Mode**.
- **Network-Wide DNS & Adblock:**
  - Dedicated port-5353 `dnsmasq` resolver so reloading rules never drops active Android hotspot/tethering sessions.
  - Upstream presets (`AdGuard`, `Cloudflare`, `Quad9`, `Google`, or `Custom` IPv4/IPv6), downloadable hosts blocklist engine, instant custom Whitelist/Blacklist, transparent `iptables` port-53 redirection, and optional **Force Router DNS** (DoT port 853 blocking).
- **Dropbear SSH Server & Embedded Web Console:**
  - Bundled static ARM64 Dropbear (`dropbear` + `dropbearkey` + `scp`) with Android `root` fallback, full KSU/BusyBox `PATH`, Authorized Public Keys manager (`/data/adb/modules/netdroid/config/authorized_keys`), NetDroid PIN password auth toggle, and strict LAN-only WAN blocking (`NETDROID_IN`).
  - PIN-protected **Embedded Web Console** with persistent working directory, ANSI color output, Tab completion, `Ctrl+C` abort, history (`↑`/`↓`), and mobile shortcut buttons.
- **LAN Shared Folder (Pocket NAS):**
  - Fast local file server defaulting to `/sdcard/NetDroidShare` (plus `/sdcard/Download`, `/sdcard`, and auto-detected USB OTG mounts under `/mnt/media_rw/*`) with Read & Write / Read-Only mode toggle.
  - Zero-RAM chunked multi-file uploads, resumable `Accept-Ranges` / `206 Partial Content` downloads, strict path-traversal protection, List/Grid file browser, offline SVG QR code share modal, and optional native WebDAV (`rclone`) support.
- **Material 3 Expressive WebUI:**
  - Offline-first 6-tab SPA (`Home`, `Clients`, `Firewall`, `Files`, `Console`, `Settings`) with mobile-first vertical layout, tablet tier, and desktop navigation rail.
  - **Appearance & Wallpaper Studio** with 6 curated mesh gradients, synced custom wallpaper upload (`/data/adb/netdroid/custom_bg.*`), live Blur/Dim/Glass Opacity sliders, and automatic Material You dynamic color extraction.

---

## Installation

1. Download the latest `NetDroid-v*.zip` from [Releases](https://github.com/iprjkt/NetDroid/releases).
2. Flash it in **KernelSU Manager** (Modules → Install) and reboot.
3. Open the WebUI:
   - **On host device:** `http://127.0.0.1:8765` or via KernelSU Manager → Modules → **NetDroid** → **WebUI**
   - **From tethered client over LAN:** `http://<hotspot-gateway>:8765` (default LAN PIN: `1234` — change under **Settings → Server & LAN Security**)

---

## CLI Helper

Run as root via `su`:

```sh
netdroid status              # Full router, TTL, battery, quota & daemon status
netdroid mode tethering      # Enable Tethering Mode (TTL=65 + Battery Saver)
netdroid mode normal         # Restore Normal Mode (TTL=64 + background apps)
netdroid ttl 65              # Set custom TTL / Hop-Limit (1-255)
netdroid clients             # List connected hotspot / USB tethered devices
netdroid firewall reapply    # Reapply security boundary & saved firewall rules
netdroid restart             # Restart NetDroid HTTP & background daemons
```

---

## Building from Source

```sh
cd netdroid
zip -r9 ../NetDroid-v1.2.zip .
```

All persistent configs, quota history, firewall rules, blocklists, and uploaded wallpapers live in `/data/adb/netdroid/` (with `/data/adb/modules/netdroid/config` symlinked to `/data/adb/netdroid/config`) so your data survives module updates.
