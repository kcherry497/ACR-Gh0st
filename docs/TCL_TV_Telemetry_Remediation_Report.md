# TCL Smart TV Telemetry Remediation

**Security Analysis, Package Removal, and Validation Report**

- **Model:** TCL QD-Mini LED QM765QM7K
- **Platform:** Google TV (Android 12)
- **Build:** STT2.230203.001
- **Date:** March 26, 2026
- **Classification:** Internal / Personal Use

> **Note (October 2026):** Converted to Markdown from the original Word report so it renders on GitHub. One correction was made in conversion: the original text said 13 packages were disabled, but its own table (§5.1) lists 12. Twelve disabled plus one uninstalled accounts for the drop from 132 to 119 enabled packages. Other notes added in conversion are marked the same way.

## 1. Executive Summary

A newly purchased TCL QD-Mini LED television (model QM765QM7K) was subjected to a systematic security audit to identify and remediate privacy-invasive telemetry, Automatic Content Recognition (ACR), and bloatware. The analysis was conducted via Android Debug Bridge (ADB) over the local network, using a phased approach that progressed from read-only reconnaissance to temporary process kills to persistent package disablement.

The investigation identified 31 TCL-specific packages installed as system applications, with the primary telemetry hub (`com.tcl.ttvs` / TTVSCore) running as UID 1000 (system user) with extensive permissions including screen capture, location access, Bluetooth scanning, advertising ID access, and the ability to impersonate other applications. Samba TV ACR integration was found embedded within TTVSCore rather than as a standalone package. The TV was actively transmitting data to Google Cloud Platform endpoints, including a non-standard port (6178) on a GCP IP address.

Remediation successfully disabled 12 packages and uninstalled 1 additional package, reducing the enabled package count from 132 to 119. All changes survived reboot testing. Television functionality (HDMI input switching, remote control, AirPlay, Google TV navigation, and PS5 game mode) was verified intact after each phase. The remediation techniques have been packaged into an open source project called ACR-Gh0st ([github.com/kcherry497/ACR-Gh0st](https://github.com/kcherry497/ACR-Gh0st)), providing both an automated ADB script and an ESP32-S3 USB hardware sinkhole for consumer use.

## 2. Device Information

| Attribute | Value |
|---|---|
| **Manufacturer** | TCL |
| **Model** | QD-Mini LED QM765QM7K |
| **Device Name** | Smart TV Pro |
| **Platform** | Google TV (Android 12) |
| **Build Number** | STT2.230203.001 |
| **TCL Packages (pre-remediation)** | 31 system-level packages |
| **Enabled Packages (pre-remediation)** | 132 |
| **USB RNDIS Support** | Confirmed (Developer Options > Select USB Configuration > RNDIS) |
| **Primary Use Case** | External display for Apple TV 4K and PlayStation 5 |

## 3. Methodology

The remediation followed a four-phase approach designed to minimize risk at each stage, with each phase building on validated results from the prior phase.

### 3.1 Phase 1: Read-Only Reconnaissance

ADB debugging was enabled via the Developer Options menu (Settings > System > About > tap Build 7 times). Under Developer Options, USB Debugging was enabled and the USB Configuration was set to RNDIS (Settings > System > Developer Options > Select USB Configuration > RNDIS). This RNDIS setting is significant — it confirms the TV’s kernel supports USB RNDIS networking, which enabled the hardware sinkhole solution described in Section 9. ADB over TCP/IP was connected from a Linux workstation on the same local network. A comprehensive recon script collected:

- Full device identification (model, build, Android version)
- Complete package inventory with TCL-specific filtering
- Known telemetry and ACR package search (Samba TV, datatrack, etc.)
- Running services and service binding analysis
- Active outbound network connections with UID attribution
- Listening ports on all interfaces
- Per-package permission audit (screen capture, audio recording, network, location)
- Boot receiver analysis and per-UID network usage statistics

The recon log exceeded 17,000 lines and was analyzed to build a prioritized target list.

### 3.2 Phase 2: Temporary Process Kill (Force-Stop)

Each target package was stopped using `am force-stop`, which kills the process for the current session only. A TV reboot restores all processes. This phase served as a safe dry run to identify which packages could be killed without breaking core functionality, and which packages would respawn due to system-level service bindings. Packages were stopped in three tiers (high-priority telemetry, network-capable bloatware, retail/unused), with manual functional verification gates between each tier.

### 3.3 Phase 3: Persistent Disable

Based on Phase 2 results, all target packages were persistently disabled using `pm disable-user --user 0`. This prevents the Android package manager from resolving intents to the disabled packages, breaking service bindings that caused respawning in Phase 2. Changes survive reboot. Rollback is available via `pm enable --user 0 <package>`.

### 3.4 Phase 4: Targeted Uninstall

One package (`com.tcl.onlinesupport`) persisted as a running process even after disable-user, due to its system UID and BOOT_COMPLETED temporary allowlist privilege. This package was removed using `pm uninstall -k --user 0`, which uninstalls for the current user while preserving APK data. Restoration is possible via `cmd package install-existing` or factory reset.

## 4. Findings

### 4.1 Primary Telemetry Hub: com.tcl.ttvs (TTVSCore)

TTVSCore is the central telemetry and services package for TCL televisions. It runs as UID 1000 (system user), granting it unrestricted access to the device. The following services were found actively running at the time of reconnaissance:

- **BackgroundTaskService** (oversea.usagest.core.service) — usage statistics collection running as a foreground service
- **BIService** (bi.core) — Business Intelligence telemetry, actively bound by `com.tcl.tv` and `com.android.tv.settings` with WACT (wait-for-activity) flags
- **UsagestService** — additional usage data collection
- **DeviceAuthenService** — device authentication and registration
- **AlexaService** — Amazon Alexa voice assistant integration, running as foreground service
- **CastService** — TCL casting/screen mirroring
- **ProtocolService** (allcast.sdk) — multi-protocol discovery
- **PlayerService** (multiscreeninteractiontv) — multi-screen interaction

**Critical permissions granted to TTVSCore:**

- INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE
- ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION
- READ_PHONE_STATE, READ_PRIVILEGED_PHONE_STATE
- PACKAGE_USAGE_STATS — tracks all app usage and timing
- READ_LOGS — can read system logs
- LOCAL_MAC_ADDRESS, PEERS_MAC_ADDRESS
- `com.google.android.gms.permission.AD_ID` — advertising ID
- BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
- FAKE_PACKAGE_SIGNATURE — can impersonate other applications
- INJECT_EVENTS, MASTER_CLEAR, WRITE_SECURE_SETTINGS
- `com.tcl.bi.permission.access` / `com.tcl.bi.param` — BI telemetry access

TTVSCore also embeds Firebase analytics (`com.google.firebase.provider.FirebaseInitProvider`) and declares the permission `tcl.permission.SambaVideoService`, confirming that Samba TV ACR functionality is integrated directly into this package rather than deployed as a separate application. A broadcast receiver for `com.ttvs.datatrack.fetchdata` was also registered, confirming active data tracking infrastructure.

### 4.2 Active Outbound Connections

At the time of Phase 1 reconnaissance, the television had established connections to:

| Destination IP | Port | UID | Attribution |
|---|---|---|---|
| 142.250.113.95 | 443 | 10053 | Google Services |
| 216.239.36.223 | 443 | 10056 | Google Mobile Services |
| 35.222.218.167 | 6178 | 1000 | GCP — system/TTVS telemetry ingest (non-standard port) |
| 142.250.31.188 | 5228 | 2000 | Google FCM push messaging |

The connection to 35.222.218.167 on port 6178 is particularly notable as it originates from UID 1000 (system/TTVS) and uses a non-standard port, consistent with a dedicated telemetry ingestion endpoint on Google Cloud Platform.

### 4.3 Listening Ports (Pre-Remediation)

| Port | Service | Interface |
|---|---|---|
| 7000 | AirPlay service | All (IPv4 + IPv6) |
| 6553 | TCL casting service | LAN IP only |
| 6466/6467 | Google TV remote service | All IPv6 |
| 10003 | Unknown service | All IPv4 |
| 5555 | ADB (debug connection) | All IPv6 |
| 17022 | Unknown / TCL-related | LAN IP only |

### 4.4 Phase 2 Force-Stop Results (Respawn Analysis)

Phase 2 temporary kills revealed which packages have system-level dependencies that force Android to respawn them:

| Package | Status | Notes |
|---|---|---|
| **`com.tcl.ttvs`** | **RESPAWNS** | BIService bound by `com.tcl.tv` and `com.android.tv.settings` with WACT flags; system restarts it immediately |
| `com.tcl.tv.tclhome_passive` | **DEAD** | Stayed dead after force-stop |
| `com.tcl.useragreement` | **DEAD** | Stayed dead after force-stop |
| `com.tcl.logkit` | **RESIDUAL** | Java process killed; native LogkitInputEvent daemon (root, child of init) persists |
| **`com.tcl.onlinesupport`** | **RESPAWNS** | System UID process, something keeps rebinding it |
| `com.tcl.channelplus` | **DEAD** | Stayed dead after force-stop |
| `com.tcl.smartlink.core` | **DEAD** | Stayed dead after force-stop |
| `com.tcl.tv.plus` | **DEAD** | Stayed dead after force-stop |

## 5. Remediation Actions

### 5.1 Packages Disabled (`pm disable-user --user 0`)

All 12 packages below were confirmed disabled and verified to persist through reboot:

| Tier | Package | Status | Function Eliminated |
|---|---|---|---|
| 1 | **`com.tcl.ttvs`** | **DISABLED** | ACR, Samba TV, BI telemetry, usage stats, Alexa, casting |
| 1 | `com.tcl.tv.tclhome_passive` | **DISABLED** | Cloud account binding, BI telemetry, SaaS token service |
| 1 | `com.tcl.useragreement` | **DISABLED** | Consent/telemetry framework with BI access |
| 1 | `com.tcl.logkit` | **DISABLED** | Diagnostics collection (Java side; native daemon orphaned) |
| 2 | `com.tcl.channelplus` | **DISABLED** | TCL Live streaming service |
| 2 | `com.tcl.exhibit` | **DISABLED** | T-Exhibition digital art display |
| 2 | `com.tcl.smartlink.core` | **DISABLED** | Cross-device discovery and linking |
| 2 | `com.tcl.tv.plus` | **DISABLED** | TCL TV+ streaming service |
| 3 | `com.tcl.esticker` | **DISABLED** | Electronic store demo price tag |
| 3 | `com.tcl.hotelmenu` | **DISABLED** | Hotel mode interface |
| 3 | `com.tcl.ocean.instructions` | **DISABLED** | Setup wizard documentation |
| 3 | `com.tcl.initsetup` | **DISABLED** | Initial setup wizard |

### 5.2 Package Uninstalled (`pm uninstall -k --user 0`)

| Package | Status | Reason |
|---|---|---|
| **`com.tcl.onlinesupport`** | **UNINSTALLED** | Persisted as running process after disable-user due to system UID and BOOT_COMPLETED allowlist; required full uninstall |

## 6. Validation

### 6.1 Functional Testing

The following functional checks were performed after each phase and after the final reboot:

| Test | Phase 2 | Phase 3 | Reboot |
|---|---|---|---|
| HDMI input switching (PS5 / Apple TV) | **PASS** | **PASS** | **PASS** |
| Remote control responsiveness | **PASS** | **PASS** | **PASS** |
| Google TV home screen navigation | **PASS** | **PASS** | **PASS** |
| AirPlay receiver functionality | **PASS** | **PASS** | **PASS** |
| PS5 game mode / gamebar | **PASS** | **PASS** | **PASS** |
| Overall UI responsiveness | **PASS** | **PASS** | **PASS** |

A notable improvement in overall UI responsiveness and speed was observed immediately after Phase 2 force-stops, consistent with reduced CPU, memory, and I/O load from eliminated background processes.

### 6.2 Post-Reboot Verification

After reboot, the following was confirmed:

- All 12 disabled packages remained in disabled-user state
- `com.tcl.ttvs` showed zero running processes (BIService binding successfully broken)
- Enabled package count remained at 119 (down from 132)
- The GCP telemetry endpoint (35.222.218.167:6178) was no longer present in active connections
- Listening port 6553 (TCL casting) and port 17022 were eliminated
- Remaining TCL processes were exclusively DO-NOT-TOUCH packages (tvinput, systemserver, tv, airplay2, gamebar) and native HAL daemons

### 6.3 Remaining Enabled TCL Packages (Expected/Safe)

The following 18 TCL packages remain enabled and are required for core TV functionality or are benign:

- **`com.tcl.tvinput`** — HDMI/input switching (critical)
- **`com.tcl.systemserver`** — core system services (critical)
- **`com.tcl.tv`** — core TV application (critical)
- **`com.tcl.airplay2`** — AirPlay receiver (required for Apple TV mirroring)
- **`com.tcl.gamebar`** — game mode overlay (required for PS5)
- **`com.tcl.autopair`** — remote control pairing
- **`com.tcl.dashboard`** — system dashboard / settings UI
- Additional: factory.view, UpdatePeripheral, suspension, hearaid, android.webview, partnercustomizer, interactive, globalkeyoverlay, providers.config, ui_mediaCenter, t_solo

## 7. Potential Risks and Known Residuals

### 7.1 Firmware Updates Blocked

Disabling `com.tcl.ttvs` eliminates the OTA firmware update mechanism and the TCL app store. If a critical firmware update is required (panel-level fixes, security patches, HDMI compatibility updates), `com.tcl.ttvs` must be temporarily re-enabled via ADB:

```bash
adb shell pm enable --user 0 com.tcl.ttvs
# Apply update via TV Settings > System > Software Update
adb shell pm disable-user --user 0 com.tcl.ttvs
```

### 7.2 Native LogkitInputEvent Daemon

The native LogkitInputEvent daemon runs as root, spawned by init rather than the Android application framework. It cannot be killed via `pm disable-user` or `am force-stop`. With `com.tcl.logkit` disabled, the Java-side processing and transmission layer is severed, effectively orphaning this daemon. However, it remains a resident process. Permanent removal would require modifying init.rc, which necessitates root remount of /system. Network monitoring should confirm whether this daemon makes independent outbound connections.

### 7.3 Stale BIService Binding Records

The Phase 3 log shows residual ConnectionRecord entries for `com.tcl.ttvs` BIService bindings from `com.tcl.tv` and `com.android.tv.settings`. These are stale references in Android’s activity manager — the TTVS process is confirmed dead and no longer running. The binding records persist in memory until the binding components (`com.tcl.tv`, `com.android.tv.settings`) are restarted or the TV is rebooted. Post-reboot verification confirmed zero TTVS processes, indicating the bindings are not being re-established.

### 7.4 Google Platform Telemetry Unaffected

This remediation targets TCL-specific telemetry only. Google TV platform telemetry (Google Mobile Services, Firebase, Google Analytics, FCM push messaging, advertising ID) remains active. Post-reboot network connections still show multiple established connections to Google infrastructure, including a GCP endpoint at 35.208.56.156:443 with multiple sessions. Remediating Google-level telemetry would require either disconnecting the TV from WiFi entirely (using it as a dumb display) or deploying network-level blocking via DNS or firewall rules.

### 7.5 ADB Left Enabled

ADB over TCP/IP remains enabled on port 5555 for ongoing maintenance. This represents an attack surface on the local network — any device on the same subnet can connect to the TV via ADB and execute commands as shell user. If the local network is untrusted, ADB should be disabled after remediation is complete (Settings > System > Developer Options > disable USB Debugging). Re-enable only when maintenance is needed.

### 7.6 Factory Reset Restores Everything

A factory reset will restore all disabled packages to their default enabled state and reinstall the uninstalled `com.tcl.onlinesupport` package. The entire remediation procedure would need to be re-executed. This is relevant if the TV is sent for warranty service, sold, or if a software issue triggers a recovery/reset.

### 7.7 com.tcl.onlinesupport Restoration

The uninstalled `com.tcl.onlinesupport` package was removed with the `-k` flag, preserving APK data on disk. If restoration is needed without a factory reset:

```bash
adb shell cmd package install-existing com.tcl.onlinesupport
```

## 8. Rollback Procedures

### 8.1 Re-enable Individual Packages

```bash
adb shell pm enable --user 0 <package.name>
```

### 8.2 Full Rollback (All Packages)

```bash
adb shell pm enable --user 0 com.tcl.ttvs
adb shell pm enable --user 0 com.tcl.tv.tclhome_passive
adb shell pm enable --user 0 com.tcl.useragreement
adb shell pm enable --user 0 com.tcl.logkit
adb shell pm enable --user 0 com.tcl.channelplus
adb shell pm enable --user 0 com.tcl.exhibit
adb shell pm enable --user 0 com.tcl.smartlink.core
adb shell pm enable --user 0 com.tcl.tv.plus
adb shell pm enable --user 0 com.tcl.esticker
adb shell pm enable --user 0 com.tcl.hotelmenu
adb shell pm enable --user 0 com.tcl.ocean.instructions
adb shell pm enable --user 0 com.tcl.initsetup
adb shell cmd package install-existing com.tcl.onlinesupport
adb shell reboot
```

### 8.3 Nuclear Rollback

Perform a factory reset via Settings > System > About > Reset. This restores all packages to their factory-default state, including reinstalling `com.tcl.onlinesupport` and re-enabling all disabled packages.

## 9. ACR-Gh0st — Open Source Remediation Tools

The findings and remediation techniques from this investigation have been packaged into an open source project called **ACR-Gh0st**, published to GitHub for public use. The project provides two complementary approaches to neutralizing smart TV telemetry, suitable for different user profiles and use cases.

**GitHub Repository:** <https://github.com/kcherry497/ACR-Gh0st>

### 9.1 Software Approach: ADB Remediation Script

**`tcl_tv_remediate.sh`** — A single bash script that automates the entire four-phase remediation process documented in this report. The user provides their TV’s IP address and the script handles connection, verification, tiered package disabling, and validation with manual check prompts between each tier.

**Usage:**

```bash
chmod +x tcl_tv_remediate.sh
./tcl_tv_remediate.sh <TV_IP_ADDRESS>
./tcl_tv_remediate.sh <TV_IP_ADDRESS> --rollback
```

**Prerequisites:**

- ADB installed on the user’s computer
- TV Developer Options enabled (Settings > System > About > tap Build 7 times)
- USB Debugging enabled (Settings > System > Developer Options)
- USB Configuration set to RNDIS (Settings > System > Developer Options > Select USB Configuration > RNDIS)
- TV and computer on the same local network

**Best for:** Users who need the TV connected to WiFi for AirPlay, casting, or streaming apps, but want TCL-specific telemetry eliminated. Google platform telemetry remains active with this approach.

### 9.2 Hardware Approach: ESP32-S3 USB Sinkhole

> **Note (October 2026):** This hardware approach was dropped and is not part of the repository. Validation showed the firmware cannot present a USB network adapter on its framework, and a DNS blackhole with no uplink can't keep AirPlay or streaming working anyway. The RNDIS setting cited in §2 and §3.1 is the TV's own USB device mode; it does not show that the TV can use a USB network adapter as a host. Sections 9.2 and 9.3 are kept as originally written.

A firmware image for the ESP32-S3 microcontroller that presents as a USB RNDIS Ethernet adapter when plugged into the TV’s USB port. The ESP32 runs a minimal DHCP server and DNS sinkhole — the TV receives a valid network configuration with the ESP32 as its gateway and DNS resolver, but every DNS query is answered with 127.0.0.1 (the TV’s own loopback). All outbound telemetry fails silently.

**How it works:**

1. ESP32-S3 presents as RNDIS USB Ethernet device via TinyUSB
2. TV gets DHCP lease: IP=10.10.10.2, Gateway=10.10.10.1, DNS=10.10.10.1
3. TV sends DNS queries to ESP32 — all answered with 127.0.0.1
4. TV attempts connections to 127.0.0.1 — connection refused (its own loopback)
5. Telemetry, ACR, and analytics all fail silently with no user-visible errors

**Hardware required:**

- ESP32-S3 DevKitC-1 or equivalent (~\$5–8)
- USB data cable (must be data-capable, not charge-only)

**Best for:** Users who want a plug-and-forget hardware solution that blocks all telemetry (both TCL and Google) without modifying anything on the TV. No ADB access, no scripts, no technical knowledge required after initial flash. Remove the dongle to restore full network access instantly.

**AirPlay caveat:** The sinkhole approach disconnects the TV from the local network. AirPlay, casting, and any features requiring LAN connectivity will not function while the sinkhole is active. Users who need AirPlay should use the ADB script approach instead.

### 9.3 Approach Comparison

| | ADB Script | ESP32 Sinkhole |
|---|---|---|
| **Difficulty** | Moderate (ADB required) | Easy (flash once, plug in) |
| **TCL Telemetry** | Blocked | Blocked |
| **Google Telemetry** | Active | Blocked |
| **AirPlay / Casting** | Works (WiFi connected) | Does not work |
| **WiFi Streaming Apps** | Work normally | Do not work |
| **TV Modifications** | Packages disabled on TV | None (external only) |
| **Rollback** | Script --rollback or factory reset | Unplug the dongle |
| **Survives Factory Reset** | No (must re-run script) | Yes (hardware solution) |
| **Cost** | Free | ~\$5–10 |
