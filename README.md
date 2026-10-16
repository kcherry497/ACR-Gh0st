# ACR-Gh0st 👻

**Kill smart TV telemetry.**

ACR-Gh0st eliminates Automatic Content Recognition (ACR), telemetry, usage tracking, and data exfiltration from TCL Google TV televisions by disabling TCL's telemetry packages over ADB. It is reversible (`--rollback`), keeps AirPlay, HDMI inputs and game mode working, and costs nothing.

---

## What We Found

A stock TCL QD-Mini LED QM765QM7K (Google TV, Android 12) was running **31 TCL system packages** with the primary telemetry hub (`com.tcl.ttvs` / TTVSCore) operating as **UID 1000 (system user)** with permissions including:

- **Screen capture every ~500ms** (ACR fingerprinting via Samba TV integration)
- **Fine location, Bluetooth scanning, advertising ID**
- **PACKAGE_USAGE_STATS** — knows every app you use and when
- **FAKE_PACKAGE_SIGNATURE** — can impersonate other apps
- **READ_LOGS** — reads system logs
- Active outbound connections to **Google Cloud Platform on non-standard port 6178**

The `BIService` (Business Intelligence) was **actively bound by the core TV app and Android TV Settings** with WACT flags, meaning the system would always restart it when killed. Even `am force-stop` couldn't keep it dead.

Full technical report: [`docs/TCL_TV_Telemetry_Remediation_Report.md`](docs/TCL_TV_Telemetry_Remediation_Report.md)

> The report (March 2026) also describes an ESP32-S3 USB sinkhole. That approach was dropped: validation showed the firmware cannot present a USB network adapter on its framework, and a DNS blackhole with no uplink can't keep AirPlay or streaming working anyway.

---

## ADB Script

Automated remediation via Android Debug Bridge. One command, tiered execution, verification gates between each phase.

### Prerequisites

1. ADB installed (`apt install adb` / `brew install android-platform-tools`)
2. TV: **Settings > System > About** → tap **Build** 7 times (enables Developer Options)
3. TV: **Settings > System > Developer Options** → enable **USB Debugging**
4. TV: **Settings > System > Developer Options > Select USB Configuration** → set to **RNDIS**
5. TV and computer on the same network

### Usage

```bash
chmod +x tcl_tv_remediate.sh

# Find TVs on your network (no ADB, read-only)
./tcl_tv_remediate.sh --scan

# Remediate — no IP: scans the LAN and lets you pick the TV from a numbered list
./tcl_tv_remediate.sh
./tcl_tv_remediate.sh 192.168.1.100          # or give the IP directly

# Check — read-only; reports each package's state
./tcl_tv_remediate.sh --check                # pick from list
./tcl_tv_remediate.sh 192.168.1.100 --check  # exit 0 = clean, 1 = drift, 2 = can't connect

# Rollback (restore everything)
./tcl_tv_remediate.sh 192.168.1.100 --rollback
```

Discovery uses mDNS (Android/Google TV, Cast, Fire TV) via `avahi-browse` plus a TCP 5555 sweep (`nmap` if installed, otherwise pure bash). It never connects ADB to anything while scanning. Remediate and rollback refuse to run on non-TCL devices, so a Fire TV in the list can't be modified by mistake.

### What it does

**Tier 1 — Telemetry (high priority):**
| Package | What it kills |
|---|---|
| `com.tcl.ttvs` | ACR, Samba TV, BI telemetry, usage stats, Alexa, casting |
| `com.tcl.tv.tclhome_passive` | Cloud account binding, BI telemetry |
| `com.tcl.useragreement` | Consent/telemetry framework |
| `com.tcl.logkit` | Diagnostics collection |
| `com.tcl.onlinesupport` | Remote support agent (uninstalled — persists through disable) |

**Tier 2 — Bloatware:**
`com.tcl.channelplus`, `com.tcl.exhibit`, `com.tcl.smartlink.core`, `com.tcl.tv.plus`

**Tier 3 — Retail/unused:**
`com.tcl.esticker`, `com.tcl.hotelmenu`, `com.tcl.ocean.instructions`, `com.tcl.initsetup`

### What it preserves

These packages are **never touched** — they're required for the TV to function:

- `com.tcl.tvinput` — HDMI/input switching
- `com.tcl.systemserver` — core system services
- `com.tcl.tv` — core TV app
- `com.tcl.airplay2` — AirPlay receiver
- `com.tcl.gamebar` — game mode overlay (PS5)
- `com.tcl.autopair` — remote control pairing
- `com.tcl.dashboard` — system settings UI

---

## Verified Compatible

- **TCL QD-Mini LED QM765QM7K** — Google TV (Android 12), Build STT2.230203.001

Should work on most TCL Google TV models (2023–2026). The ADB script skips packages that don't exist on your model.

---

## Important Notes

**OTA firmware updates are blocked.** To update:
```bash
adb shell pm enable --user 0 com.tcl.ttvs
# Update via TV Settings > System > Software Update
adb shell pm disable-user --user 0 com.tcl.ttvs
```

**Factory reset restores everything.** Re-run the script.

**ADB should be disabled when not in use.** Port 5555 is an attack surface on your local network. Disable via Settings > System > Developer Options > USB Debugging.

**Google platform telemetry** (GMS, Firebase, FCM) is not addressed. The script targets TCL-specific packages only.

---

## Repo Structure

```
ACR-Gh0st/
├── README.md                    # This file
├── LICENSE                      # MIT
├── tcl_tv_remediate.sh          # ADB remediation script
└── docs/
    └── TCL_TV_Telemetry_Remediation_Report.md
```

---

## Background

This project is part of the [Surveillance Aware Network (SAN)](https://github.com/kcherry497) content series documenting the intersection of consumer technology, surveillance capitalism, and practical privacy protection.

The full technical investigation — including 17,000+ line ADB recon logs, service binding analysis, respawn behavior mapping, and phased remediation documentation — is available in the report under `docs/`.

---

## License

MIT — do whatever you want with it.
