#!/bin/bash
# =============================================================================
# TCL Smart TV Telemetry Remediation Script
# =============================================================================
# Model tested: TCL QD-Mini LED QM765QM7K (Google TV / Android 12)
# Expected to work on: Most TCL Google TV models (2023-2026)
#
# This script disables telemetry, ACR (Automatic Content Recognition), 
# bloatware, and data collection packages on TCL Google TV televisions.
#
# PREREQUISITES:
#   1. ADB installed on your computer (apt install adb / brew install android-platform-tools)
#   2. TV: Settings > System > About > tap "Build" 7 times to enable Developer Options
#   3. TV: Settings > System > Developer Options > enable "USB Debugging"
#   4. TV and computer on the same network
#
# USAGE:
#   chmod +x tcl_tv_remediate.sh
#   ./tcl_tv_remediate.sh <TV_IP_ADDRESS>
#   ./tcl_tv_remediate.sh                         # Discover and select a TV
#   ./tcl_tv_remediate.sh --scan                  # LAN discovery only; no ADB
#   ./tcl_tv_remediate.sh [TV_IP_ADDRESS] --check  # Read-only audit
#   ./tcl_tv_remediate.sh [TV_IP_ADDRESS] --rollback
#   Options/IP may appear in any order. --force-non-tcl is remediate-only.
#
# ROLLBACK:
#   ./tcl_tv_remediate.sh <TV_IP_ADDRESS> --rollback
#
# WHAT THIS DOES:
#   - Disables TCL telemetry (ACR, Samba TV, usage tracking, BI analytics)
#   - Disables TCL bloatware (streaming apps, remote support, retail mode)
#   - Uninstalls the persistent remote support agent
#   - Preserves all core TV functionality (HDMI, remote, AirPlay, game mode)
#
# WHAT THIS DOES NOT DO:
#   - Does not affect Google platform telemetry (GMS, Firebase, etc.)
#   - Does not require root access
#   - Does not modify system partitions
#   - Does not void warranty
#
# RISKS:
#   - OTA firmware updates are blocked (re-enable com.tcl.ttvs when needed)
#   - Factory reset restores all packages to default
#   - ADB must be re-enabled for future maintenance
#
# =============================================================================

set -eo pipefail
set -E
trap 'printf "Error at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Packages organized by tier
TIER1_PACKAGES=(
    "com.tcl.ttvs"                # ACR/telemetry mothership (Samba TV, BI, usage stats, Alexa)
    "com.tcl.tv.tclhome_passive"  # Cloud account binding, BI telemetry
    "com.tcl.useragreement"       # Consent/telemetry framework
    "com.tcl.logkit"              # Diagnostics collection
)

TIER2_PACKAGES=(
    "com.tcl.channelplus"         # TCL Live streaming
    "com.tcl.exhibit"             # T-Exhibition art mode
    "com.tcl.smartlink.core"      # Cross-device discovery/linking
    "com.tcl.tv.plus"             # TCL TV+ streaming
)

TIER3_PACKAGES=(
    "com.tcl.esticker"            # Retail demo price tag
    "com.tcl.hotelmenu"           # Hotel mode
    "com.tcl.ocean.instructions"  # Setup wizard docs
    "com.tcl.initsetup"           # Initial setup wizard
)

# Package that requires uninstall (persists through disable)
UNINSTALL_PACKAGE="com.tcl.onlinesupport"  # Remote support agent

# Log file
LOGFILE="tcl_remediation_$(date +%Y%m%d_%H%M%S).log"
ADB_TARGET=""
ADB_OUTPUT=""
BASELINE_COUNT="?"
TV_BUILD=""
FORCE_NON_TCL=false
TV_IPS=()
TV_NAMES=()
TV_TYPES=()
TV_ADB=()
TV_NAME_RANKS=()
SELECTED_IP=""
REPLY=""
DISCOVERY_DIR=""
LOCAL_IP=""
LOCAL_CIDR=""

# =============================================================================
# Functions
# =============================================================================

log() {
    if ! printf '%b\n' "$1" | tee -a "$LOGFILE"; then
        printf 'Could not write output/log: %s\n' "$LOGFILE" >&2
        exit 1
    fi
}

header() {
    log ""
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BOLD}  $1${NC}"
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

success() {
    log "  ${GREEN}✓${NC} $1"
}

warn() {
    log "  ${YELLOW}⚠${NC} $1"
}

fail() {
    log "  ${RED}✗${NC} $1"
}

info() {
    log "  ${CYAN}→${NC} $1"
}

count_matches(){ grep -c "$@" || [ $? -eq 1 ]; }

adbs() {
    if [ -z "$ADB_TARGET" ]; then
        fail "ADB target is unset; refusing an untargeted command."
        return 1
    fi
    adb -s "$ADB_TARGET" "$@"
}

read_adb_output() {
    local context="$1"
    shift
    if ! ADB_OUTPUT=$(adbs "$@" 2>&1); then
        ADB_OUTPUT=${ADB_OUTPUT//$'\r'/}
        fail "${context} failed on ${ADB_TARGET}: ${ADB_OUTPUT}"
        return 1
    fi
    ADB_OUTPUT=${ADB_OUTPUT//$'\r'/}
    if [[ "$ADB_OUTPUT" =~ ^([Ee]rror:|adb:|[Ee]xception|SecurityException|Failure) ]]; then
        fail "${context} failed on ${ADB_TARGET}: ${ADB_OUTPUT}"
        return 1
    fi
}

fetch_packages() {
    local context="$1" line
    shift
    read_adb_output "$context" shell pm list packages "$@" || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ ! "$line" =~ ^package:[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*$ ]]; then
            fail "${context}: invalid package-list output: ${line}"
            return 1
        fi
    done <<< "$ADB_OUTPUT"
    if [ "$context" = "Installed packages" ] && [ -z "$ADB_OUTPUT" ]; then
        fail "Installed packages: empty list from ${ADB_TARGET}; cannot determine package state."
        return 1
    fi
}

package_in_list() {
    local pkg="$1" packages="$2"
    case $'\n'"$packages"$'\n' in
        *$'\n'"package:$pkg"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

fetch_processes() {
    local heading
    read_adb_output "Process snapshot" shell ps -A || return 1
    heading=${ADB_OUTPUT%%$'\n'*}
    if [[ ! "$heading" =~ (^|[[:space:]])PID([[:space:]]|$) ]]; then
        fail "Invalid ps -A output from ${ADB_TARGET}: ${ADB_OUTPUT}"
        return 1
    fi
}

check_adb() {
    if ! command -v adb &> /dev/null; then
        fail "ADB is not installed."
        log ""
        log "  Install ADB:"
        log "    Ubuntu/Debian: ${BOLD}sudo apt install adb${NC}"
        log "    macOS:         ${BOLD}brew install android-platform-tools${NC}"
        log "    Windows:       Download from developer.android.com"
        return 1
    fi
    success "ADB found: $(command -v adb)"
}

show_adb_fingerprint() {
    local key_file="$HOME/.android/adbkey.pub" fingerprint
    if [ ! -r "$key_file" ]; then
        warn "ADB public key is unavailable at ${key_file}; compare the prompt on the TV."
        return 0
    fi
    if ! command -v base64 >/dev/null || ! command -v md5sum >/dev/null; then
        warn "base64/md5sum unavailable; cannot display this computer's ADB key fingerprint."
        return 0
    fi
    if ! fingerprint=$(awk '{print $1}' "$key_file" | base64 -d | md5sum); then
        warn "Could not decode this computer's ADB public key."
        return 0
    fi
    fingerprint=${fingerprint//$'\r'/}
    fingerprint=${fingerprint%% *}
    if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{32}$ ]]; then
        warn "Could not validate this computer's ADB key fingerprint."
        return 0
    fi
    if ! fingerprint=$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]' | sed 's/../&:/g; s/:$//'); then
        warn "Could not format this computer's ADB key fingerprint."
        return 0
    fi
    info "This computer's ADB key fingerprint: ${BOLD}${fingerprint}${NC}"
}

connect_tv() {
    local tv_ip="$1" output state attempt disconnect_output
    local auth_shown=false
    ADB_TARGET="${tv_ip}:5555"
    info "Connecting to TV at ${BOLD}${ADB_TARGET}${NC}..."
    if ! disconnect_output=$(adb disconnect "$ADB_TARGET" 2>&1); then
        disconnect_output=${disconnect_output//$'\r'/}
        warn "Targeted disconnect failed for ${ADB_TARGET}: ${disconnect_output}; trying connect."
    fi
    if ! output=$(adb connect "$ADB_TARGET" 2>&1); then
        output=${output//$'\r'/}
        warn "ADB connect returned an error for ${ADB_TARGET}: ${output}"
    fi
    output=${output//$'\r'/}
    if grep -Fxq -e "connected to ${ADB_TARGET}" -e "already connected to ${ADB_TARGET}" <<< "$output"; then
        info "ADB transport connected; waiting for device authorization."
    else
        warn "ADB connect response for ${ADB_TARGET}: ${output:-<empty>}; checking device state."
    fi
    for ((attempt=0; attempt<30; attempt++)); do
        state=$(adb -s "$ADB_TARGET" get-state 2>&1) || true
        state=${state//$'\r'/}
        if [ "$state" = "device" ]; then
            success "Connected and authorized: ${ADB_TARGET}"
            return 0
        fi
        if [[ "$state" == *unauthorized* ]] && [ "$auth_shown" = false ]; then
            warn "TV is unauthorized. Accept \"Allow USB debugging?\" on the TV."
            info "Tick \"Always allow from this computer\"."
            show_adb_fingerprint
            auth_shown=true
        fi
        sleep 1 || { fail "Authorization polling interrupted for ${ADB_TARGET}."; return 2; }
    done
    fail "Could not authorize/connect to ${ADB_TARGET} within 30s. Last state: ${state:-<empty>}"
    log ""
    log "  Troubleshooting:"
    log "    1. Is the TV on and connected to the same network?"
    log "    2. Did you enable Developer Options? (Settings > System > About > tap Build 7x)"
    log "    3. Did you enable USB Debugging? (Settings > System > Developer Options)"
    log "    4. Check if the TV is prompting you to authorize the ADB connection"
    log "    5. Verify the IP address (Settings > Network & Internet on the TV)"
    return 2
}

read_property() {
    local property="$1"
    read_adb_output "Read ${property}" shell getprop "$property" || return 1
    if [ -z "$ADB_OUTPUT" ] || [[ "$ADB_OUTPUT" == *$'\n'* ]]; then
        fail "Read ${property}: expected a nonempty single value, got '${ADB_OUTPUT}'."
        return 1
    fi
}

verify_tcl_tv() {
    local mode="$1" manufacturer brand model android_ver
    info "Verifying this is a TCL Google TV..."
    read_property ro.product.manufacturer || return 1
    manufacturer="$ADB_OUTPUT"
    read_property ro.product.brand || return 1
    brand="$ADB_OUTPUT"
    info "Manufacturer: ${BOLD}${manufacturer}${NC}"
    info "Brand:        ${BOLD}${brand}${NC}"
    if [[ "${manufacturer} ${brand}" != *[Tt][Cc][Ll]* ]]; then
        if [ "$mode" = "check" ]; then
            info "not a TCL TV — N/A (manufacturer: ${manufacturer}; brand: ${brand})"
            return 2
        elif [ "$mode" = "remediate" ] && [ "$FORCE_NON_TCL" = true ]; then
            warn "Non-TCL device explicitly allowed by --force-non-tcl."
        else
            fail "Refusing ${mode} on ${ADB_TARGET}: neither manufacturer '${manufacturer}' nor brand '${brand}' identifies TCL."
            return 1
        fi
    fi
    read_property ro.product.model || return 1
    model="$ADB_OUTPUT"
    read_property ro.build.version.release || return 1
    android_ver="$ADB_OUTPUT"
    read_property ro.build.display.id || return 1
    TV_BUILD="$ADB_OUTPUT"
    info "Model:        ${BOLD}${model}${NC}"
    info "Android:      ${BOLD}${android_ver}${NC}"
    info "Build:        ${BOLD}${TV_BUILD}${NC}"
}

get_baseline() {
    local tcl_procs
    header "BASELINE SNAPSHOT"
    fetch_packages "Enabled packages" -e --user 0 || return 1
    BASELINE_COUNT=$(count_matches '^package:' <<< "$ADB_OUTPUT") || { fail "Could not count baseline enabled packages."; return 1; }
    info "Enabled packages: ${BOLD}${BASELINE_COUNT}${NC}"
    fetch_processes || return 1
    tcl_procs=$(count_matches -i 'tcl\|ttvs' <<< "$ADB_OUTPUT") || { fail "Could not count baseline TCL processes."; return 1; }
    info "Running TCL processes: ${BOLD}${tcl_procs}${NC}"
}

disable_package() {
    local pkg="$1"
    local desc="$2"
    
    # Check if package exists
    fetch_packages "Installed packages" --user 0 || return 1
    if ! package_in_list "$pkg" "$ADB_OUTPUT"; then
        warn "${pkg} — not found on this device, skipping"
        return 0
    fi
    
    # Check if already disabled
    fetch_packages "Disabled packages" -d --user 0 || return 1
    if package_in_list "$pkg" "$ADB_OUTPUT"; then
        info "${pkg} — already disabled"
        return 0
    fi
    
    local result
    read_adb_output "Disable ${pkg}" shell pm disable-user --user 0 "$pkg" || return 1
    result="$ADB_OUTPUT"
    
    if grep -Fxq "Package ${pkg} new state: disabled-user" <<< "$result"; then
        success "${pkg} — disabled (${desc})"
    else
        fail "${pkg} — disable failed: ${result}"
        return 1
    fi
}

enable_package() {
    local pkg="$1"
    
    # Check if package exists
    fetch_packages "Installed packages" --user 0 || return 1
    if ! package_in_list "$pkg" "$ADB_OUTPUT"; then
        info "${pkg} — not installed for user 0, skipping"
        return 0
    fi
    
    local result
    read_adb_output "Enable ${pkg}" shell pm enable --user 0 "$pkg" || return 1
    result="$ADB_OUTPUT"
    
    if grep -Fxq "Package ${pkg} new state: enabled" <<< "$result"; then
        success "${pkg} — re-enabled"
    else
        fail "${pkg} — enable failed: ${result}"
        return 1
    fi
}

restore_package() {
    local pkg="$1"
    read_adb_output "Restore ${pkg}" shell cmd package install-existing --user 0 "$pkg" || return 1
    if ! grep -Fxq "Package ${pkg} installed for user: 0" <<< "$ADB_OUTPUT"; then
        fail "${pkg} — restore failed: ${ADB_OUTPUT}"
        return 1
    fi
    success "${pkg} — restored for user 0"
}

uninstall_package() {
    local pkg="$1"
    local desc="$2"
    
    fetch_packages "Installed packages" --user 0 || return 1
    if ! package_in_list "$pkg" "$ADB_OUTPUT"; then
        info "${pkg} — already removed or not found"
        return 0
    fi
    
    local result
    read_adb_output "Uninstall ${pkg}" shell pm uninstall -k --user 0 "$pkg" || return 1
    result="$ADB_OUTPUT"
    
    if [ "$result" = "Success" ]; then
        success "${pkg} — uninstalled (${desc})"
        info "  Restore with: adb -s ${ADB_TARGET} shell cmd package install-existing --user 0 ${pkg}"
    else
        fail "${pkg} — uninstall failed: ${result}"
        return 1
    fi
}

verify_results() {
    local disabled_count ttvs_running support_running new_count line pname processes
    header "VERIFICATION"
    
    fetch_packages "Disabled packages" -d --user 0 || return 1
    disabled_count=$(count_matches -i tcl <<< "$ADB_OUTPUT") || { fail "Could not count disabled TCL packages."; return 1; }
    info "Disabled TCL packages: ${BOLD}${disabled_count}${NC}"
    
    fetch_processes || return 1
    processes="$ADB_OUTPUT"
    ttvs_running=$(count_matches -E '(^|[[:space:]])com\.tcl\.ttvs(:[^[:space:]]+)?$' <<< "$processes") || { fail "Could not count TTVS processes."; return 1; }
    if [ "$ttvs_running" -eq 0 ]; then
        success "com.tcl.ttvs (ACR/telemetry) — NOT RUNNING"
    else
        warn "com.tcl.ttvs still has ${ttvs_running} process(es) — will be gone after reboot"
    fi
    
    support_running=$(count_matches -E '(^|[[:space:]])com\.tcl\.onlinesupport(:[^[:space:]]+)?$' <<< "$processes") || { fail "Could not count remote-support processes."; return 1; }
    if [ "$support_running" -eq 0 ]; then
        success "com.tcl.onlinesupport (remote support) — NOT RUNNING"
    else
        warn "com.tcl.onlinesupport still in memory — will be gone after reboot"
    fi
    
    fetch_packages "Enabled packages" -e --user 0 || return 1
    new_count=$(count_matches '^package:' <<< "$ADB_OUTPUT") || { fail "Could not count enabled packages during verification."; return 1; }
    info "Enabled packages: ${BOLD}${BASELINE_COUNT} → ${new_count}${NC}"
    
    # Check remaining TCL processes
    log ""
    info "Remaining TCL processes (expected — these are safe):"
    while IFS= read -r line; do
        if [[ "$line" == *[Tt][Cc][Ll]* ]]; then
            pname=${line##*[[:space:]]}
            info "  ${pname}"
        fi
    done <<< "$processes"
}

prompt_continue() {
    local msg="$1" confirmation
    log ""
    log "${YELLOW}  ${msg}${NC}"
    log ""
    if ! read -rp "  Press ENTER to continue, or Ctrl+C to abort... " confirmation; then
        fail "Confirmation input ended; aborting further changes."
        exit 1
    fi
}

# =============================================================================
# LAN discovery — mDNS and TCP probes only; no ADB connections
# =============================================================================

validate_ipv4() {
    local value="$1" octet
    local octets=()
    [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

physical_interface() {
    local interface="$1"
    [[ "$interface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || return 1
    case "$interface" in
        lo|docker*|br-*|virbr*|tun*|wg*|veth*|tailscale*|zt*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_cidr() {
    local cidr="$1" prefix
    [[ "$cidr" == */* ]] || return 1
    validate_ipv4 "${cidr%/*}" || return 1
    prefix=${cidr##*/}
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    [ "$((10#$prefix))" -le 32 ]
}

detect_local_subnet() {
    local route_output address_output interface="" source="" line cidr candidate index
    local fields=()
    LOCAL_IP=""
    LOCAL_CIDR=""
    if command -v ip >/dev/null; then
        if route_output=$(ip -4 route get 1.1.1.1 2>&1); then
            route_output=${route_output//$'\r'/}
            read -r -a fields <<< "$route_output"
            for ((index=0; index<${#fields[@]}-1; index++)); do
                case "${fields[index]}" in
                    dev) interface=${fields[index+1]} ;;
                    src) source=${fields[index+1]} ;;
                esac
            done
        else
            route_output=${route_output//$'\r'/}
            warn "Route lookup failed: ${route_output}; trying an UP physical interface." >&2
        fi
        if ! physical_interface "$interface" || ! validate_ipv4 "$source"; then
            interface=""
            if ! address_output=$(ip -o -4 addr show up 2>&1); then
                address_output=${address_output//$'\r'/}
                warn "UP interface lookup failed: ${address_output}." >&2
                return 0
            fi
            address_output=${address_output//$'\r'/}
            while IFS= read -r line; do
                read -r -a fields <<< "$line"
                candidate=${fields[1]%%@*}
                cidr=${fields[3]}
                if [ "${fields[2]}" = inet ] && physical_interface "$candidate" && validate_cidr "$cidr"; then
                    interface="$candidate"
                    source=${cidr%/*}
                    break
                fi
            done <<< "$address_output"
        fi
        [ -n "$interface" ] || return 0
        if ! address_output=$(ip -o -4 addr show dev "$interface" 2>&1); then
            address_output=${address_output//$'\r'/}
            warn "IPv4 lookup for ${interface} failed: ${address_output}." >&2
            return 0
        fi
        address_output=${address_output//$'\r'/}
        while IFS= read -r line; do
            read -r -a fields <<< "$line"
            cidr=${fields[3]}
            if [ "${fields[2]}" = inet ] && validate_cidr "$cidr" && [ "${cidr%/*}" = "$source" ]; then
                LOCAL_IP="$source"
                LOCAL_CIDR="$cidr"
                return 0
            fi
        done <<< "$address_output"
        warn "No valid IPv4 CIDR for ${interface} and source '${source}'." >&2
    elif command -v ipconfig >/dev/null; then
        for interface in en0 en1; do
            if source=$(ipconfig getifaddr "$interface" 2>/dev/null); then
                source=${source//$'\r'/}
                if validate_ipv4 "$source"; then
                    LOCAL_IP="$source"
                    LOCAL_CIDR="${source}/24"
                    info "Using ${interface}; assuming /24 on macOS." >&2
                    return 0
                fi
            fi
        done
        warn "No usable IPv4 address from ipconfig en0/en1." >&2
    else
        warn "Neither ip nor ipconfig is available for subnet discovery." >&2
    fi
    return 0
}

decode_avahi_name() {
    local encoded="$1" decoded="" character digits byte
    while [ -n "$encoded" ]; do
        character=${encoded:0:1}
        encoded=${encoded:1}
        if [ "$character" = '\' ] && [ -n "$encoded" ]; then
            digits=${encoded:0:3}
            if [[ "$digits" =~ ^[0-9]{3}$ ]] && [ "$((10#$digits))" -le 255 ]; then
                printf -v byte '%03o' "$((10#$digits))"
                printf -v character '%b' "\\${byte}"
                encoded=${encoded:3}
            else
                character=${encoded:0:1}
                encoded=${encoded:1}
            fi
        fi
        # Keep names on one table row and strip terminal control characters.
        if [[ "$character" == [[:cntrl:]] ]]; then
            character=' '
        fi
        decoded+="$character"
    done
    REPLY="$decoded"
}

merge_tv() {
    local address="$1" name="$2" type="$3" rank="$4" index
    validate_ipv4 "$address" || return 1
    [ "$address" != "$LOCAL_IP" ] || return 0
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        if [ "${TV_IPS[index]}" = "$address" ]; then
            case ",${TV_TYPES[index]}," in
                *",${type},"*) ;;
                *) TV_TYPES[index]+=",${type}" ;;
            esac
            if [ "$rank" -gt "${TV_NAME_RANKS[index]}" ] && [ -n "$name" ]; then
                TV_NAMES[index]="$name"
                TV_NAME_RANKS[index]="$rank"
            fi
            return 0
        fi
    done
    index=${#TV_IPS[@]}
    TV_IPS[index]="$address"
    TV_NAMES[index]="${name:--}"
    TV_TYPES[index]="$type"
    TV_ADB[index]=closed
    TV_NAME_RANKS[index]="$rank"
}

parse_mdns_file() {
    local file="$1" service="$2" label="$3" default_rank="$4" rank
    local line address name txt pattern index
    local fields=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line//$'\r'/}
        [[ "$line" == '=;'* ]] || continue
        IFS=';' read -r -a fields <<< "$line"
        [ "${fields[2]}" = IPv4 ] || continue
        [ "${fields[4]}" = "$service" ] || continue
        address=${fields[7]}
        rank="$default_rank"
        if ! validate_ipv4 "$address"; then
            warn "Ignoring invalid ${label} mDNS address: '${address}'." >&2
            continue
        fi
        decode_avahi_name "${fields[3]}"
        name="$REPLY"
        txt=""
        for ((index=9; index<${#fields[@]}; index++)); do
            txt+="${fields[index]};"
        done
        case "$service" in
            _googlecast._tcp) pattern='"fn=([^"]*)"' ;;
            _amzn-wplay._tcp) pattern='"n=([^"]*)"' ;;
            *) pattern="" ;;
        esac
        if [ -n "$pattern" ] && [[ "$txt" =~ $pattern ]] && [ -n "${BASH_REMATCH[1]}" ]; then
            decode_avahi_name "${BASH_REMATCH[1]}"
            name="$REPLY"
        elif [ "$service" != _androidtvremote2._tcp ]; then
            # Opaque instances are not friendly names; try reverse DNS later.
            name=-
            rank=-1
        fi
        if [ -z "$name" ]; then
            name=-
            rank=-1
        fi
        merge_tv "$address" "$name" "$label" "$rank" || return 1
    done < "$file" || { fail "Could not parse ${label} mDNS results from ${file}." >&2; return 1; }
}

browse_mdns() {
    local service pid index status diagnostic workers_failed=false
    local services=(_androidtvremote2._tcp _googlecast._tcp _amzn-wplay._tcp)
    local labels=('Android/Google TV' Cast 'Fire TV')
    local ranks=(2 3 1)
    local pids=()
    if ! command -v avahi-browse >/dev/null; then
        info "avahi-browse unavailable; using TCP discovery only." >&2
        return 0
    fi
    info "Browsing Android/Google TV, Cast and Fire TV mDNS (up to 6s)..." >&2
    for service in "${services[@]}"; do
        (
            trap - EXIT INT TERM
            if timeout 6 avahi-browse -rptk "$service" > "$DISCOVERY_DIR/$service" 2> "$DISCOVERY_DIR/$service.err"; then
                printf '0\n' > "$DISCOVERY_DIR/$service.status"
            else
                printf '%s\n' "$?" > "$DISCOVERY_DIR/$service.status"
            fi
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            fail "mDNS worker ${pid} failed; cannot read discovery results." >&2
            workers_failed=true
        fi
    done
    [ "$workers_failed" = false ] || return 1
    for ((index=0; index<${#services[@]}; index++)); do
        service=${services[index]}
        if ! IFS= read -r status < "$DISCOVERY_DIR/$service.status" || [[ ! "$status" =~ ^[0-9]+$ ]]; then
            fail "Invalid/missing mDNS worker status for ${service}." >&2
            return 1
        fi
        if ! diagnostic=$(< "$DISCOVERY_DIR/$service.err"); then
            fail "Could not read mDNS diagnostic output for ${service}." >&2
            return 1
        fi
        diagnostic=${diagnostic//$'\r'/}
        if [ "$status" != 0 ]; then
            warn "${labels[index]} mDNS exited ${status}; using any partial results. ${diagnostic}" >&2
        fi
        parse_mdns_file "$DISCOVERY_DIR/$service" "$service" "${labels[index]}" "${ranks[index]}" || return 1
    done
}

probe_adb_port() {
    local address="$1"
    validate_ipv4 "$address" || return 1
    timeout 1 bash -c 'exec 3<>/dev/tcp/$1/5555' _ "$address" >/dev/null 2>&1
}

mark_adb_open() {
    local address="$1" index
    validate_ipv4 "$address" || return 1
    [ "$address" != "$LOCAL_IP" ] || return 0
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        if [ "${TV_IPS[index]}" = "$address" ]; then
            TV_ADB[index]=open
            return 0
        fi
    done
    merge_tv "$address" - ADB 0 || return 1
    TV_ADB[${#TV_IPS[@]}-1]=open
}

sweep_adb_ports() {
    local prefix="$((10#${LOCAL_CIDR##*/}))" subnet="$LOCAL_CIDR"
    local network=${LOCAL_IP%.*} address line index status diagnostic
    local fields=()
    if [ "$prefix" -lt 22 ]; then
        subnet="${network}.0/24"
        warn "Subnet ${LOCAL_CIDR} is larger than /22; limiting the sweep to ${subnet}." >&2
    fi
    info "Probing TCP 5555 on ${subnet}..." >&2
    if command -v nmap >/dev/null; then
        if timeout 45 nmap -n -Pn -p5555 --open -oG - "$subnet" > "$DISCOVERY_DIR/ports" 2> "$DISCOVERY_DIR/ports.err"; then
            status=0
        else
            status=$?
            if ! diagnostic=$(< "$DISCOVERY_DIR/ports.err"); then
                fail "Could not read nmap diagnostic output." >&2
                return 1
            fi
            diagnostic=${diagnostic//$'\r'/}
            warn "nmap exited ${status}; using partial results. ${diagnostic}" >&2
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line//$'\r'/}
            [[ "$line" == Host:* ]] && [[ "$line" == *5555/open/* ]] || continue
            read -r -a fields <<< "$line"
            address=${fields[1]}
            if validate_ipv4 "$address"; then
                mark_adb_open "$address" || return 1
            else
                warn "Ignoring invalid nmap address: '${address}'." >&2
            fi
        done < "$DISCOVERY_DIR/ports" || { fail "Could not parse nmap results." >&2; return 1; }
    else
        if ! command -v xargs >/dev/null; then
            fail "Neither nmap nor xargs is available for the TCP sweep." >&2
            return 1
        fi
        info "nmap unavailable; probing ${network}.1–254 with 64 TCP workers." >&2
        for ((index=1; index<=254; index++)); do
            printf '%s.%s\n' "$network" "$index" || { fail "Could not write TCP sweep address ${index}." >&2; return 1; }
        done > "$DISCOVERY_DIR/addresses" || { fail "Could not write TCP sweep addresses." >&2; return 1; }
        if ! xargs -P 64 -n 1 bash -c 'if timeout 1 bash -c '\''exec 3<>/dev/tcp/$1/5555'\'' _ "$1" >/dev/null 2>&1; then printf "%s\n" "$1"; fi' _ < "$DISCOVERY_DIR/addresses" > "$DISCOVERY_DIR/open"; then
            fail "Parallel TCP discovery failed on ${network}.0/24." >&2
            return 1
        fi
        while IFS= read -r address; do
            address=${address//$'\r'/}
            mark_adb_open "$address" || return 1
        done < "$DISCOVERY_DIR/open" || { fail "Could not read parallel TCP probe results." >&2; return 1; }
    fi
    # mDNS hosts may lie outside the sweep; test their advertised IP once.
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        if [ "${TV_ADB[index]}" != open ] && probe_adb_port "${TV_IPS[index]}"; then
            TV_ADB[index]=open
        fi
    done
}

resolve_tv_names() {
    local index output address hostname extra
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        [ "${TV_NAMES[index]}" = - ] || continue
        address=${TV_IPS[index]}
        output=""
        if command -v getent >/dev/null; then
            output=$(timeout 1 getent hosts "$address" 2>/dev/null) || true
            output=${output//$'\r'/}
            read -r address hostname extra <<< "$output"
            if validate_ipv4 "$address" && [ "$address" = "${TV_IPS[index]}" ] && [[ "$hostname" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                TV_NAMES[index]="$hostname"
            fi
        elif command -v host >/dev/null; then
            output=$(timeout 1 host "${TV_IPS[index]}" 2>/dev/null) || true
            output=${output//$'\r'/}
            hostname=${output##* pointer }
            if [[ "$output" == *' pointer '* ]] && [[ "$hostname" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                TV_NAMES[index]=${hostname%.}
            fi
        fi
    done
}

sort_tvs() {
    local address index
    local ips=() names=() types=() ports=() ranks=()
    [ "${#TV_IPS[@]}" -gt 0 ] || return 0
    if ! printf '%s\n' "${TV_IPS[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n > "$DISCOVERY_DIR/sorted"; then
        fail "Could not sort TV discovery results." >&2
        return 1
    fi
    while IFS= read -r address; do
        for ((index=0; index<${#TV_IPS[@]}; index++)); do
            if [ "${TV_IPS[index]}" = "$address" ]; then
                ips+=("$address")
                names+=("${TV_NAMES[index]}")
                types+=("${TV_TYPES[index]}")
                ports+=("${TV_ADB[index]}")
                ranks+=("${TV_NAME_RANKS[index]}")
                break
            fi
        done
    done < "$DISCOVERY_DIR/sorted" || { fail "Could not read sorted TV results." >&2; return 1; }
    TV_IPS=("${ips[@]}")
    TV_NAMES=("${names[@]}")
    TV_TYPES=("${types[@]}")
    TV_ADB=("${ports[@]}")
    TV_NAME_RANKS=("${ranks[@]}")
}

cleanup_discovery() {
    if [ -n "$DISCOVERY_DIR" ] && [ -d "$DISCOVERY_DIR" ]; then
        if ! rm -rf -- "$DISCOVERY_DIR"; then
            printf 'Could not clean discovery directory: %s\n' "$DISCOVERY_DIR" >&2
            return 1
        fi
    fi
    DISCOVERY_DIR=""
}

discover_tvs() {
    TV_IPS=(); TV_NAMES=(); TV_TYPES=(); TV_ADB=(); TV_NAME_RANKS=()
    detect_local_subnet || return 1
    if [ -z "$LOCAL_CIDR" ]; then
        warn "Discovery unavailable: no usable local subnet. Pass the TV IP manually." >&2
        return 0
    fi
    if ! command -v timeout >/dev/null; then
        warn "Discovery unavailable: timeout is required for bounded network probes. Pass the TV IP manually." >&2
        return 0
    fi
    if ! DISCOVERY_DIR=$(mktemp -d); then
        fail "Could not create a temporary directory for LAN discovery." >&2
        return 1
    fi
    trap cleanup_discovery EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    browse_mdns || return 1
    sweep_adb_ports || return 1
    resolve_tv_names || return 1
    sort_tvs || return 1
    cleanup_discovery || return 1
}

print_tv_table() {
    local index name_width=4 type_width=4 line color
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        [ "${#TV_NAMES[index]}" -le "$name_width" ] || name_width=${#TV_NAMES[index]}
        [ "${#TV_TYPES[index]}" -le "$type_width" ] || type_width=${#TV_TYPES[index]}
    done
    printf -v line '  %-3s  %-*s  %-*s  %-15s  %s' '#' "$name_width" NAME "$type_width" TYPE IP ADB
    log "$line"
    for ((index=0; index<${#TV_IPS[@]}; index++)); do
        color="$RED"
        [ "${TV_ADB[index]}" != open ] || color="$GREEN"
        printf -v line '  %-3s  %-*s  %-*s  %-15s  ' "$((index+1))" "$name_width" "${TV_NAMES[index]}" "$type_width" "${TV_TYPES[index]}" "${TV_IPS[index]}"
        printf '%s%b%s%b\n' "$line" "$color" "${TV_ADB[index]}" "$NC" | tee -a "$LOGFILE"
    done
}

select_tv() {
    local choice index count=${#TV_IPS[@]}
    SELECTED_IP=""
    print_tv_table
    if [ "$count" -eq 0 ]; then
        fail "No TVs found. Find the IP in TV Settings > Network & Internet."
        info "Rerun with: ./tcl_tv_remediate.sh <ip>"
        if [ ! -t 0 ]; then
            info "non-interactive: pass the IP explicitly"
        fi
        exit 1
    fi
    if [ ! -t 0 ]; then
        fail "non-interactive: pass the IP explicitly"
        exit 1
    fi
    while true; do
        if ! read -rp "Select TV [1-${count}] (q to quit): " choice </dev/tty; then
            fail "TV selection input ended."
            exit 1
        fi
        case "$choice" in
            q|Q) info "Selection cancelled."; exit 0 ;;
        esac
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "${#choice}" -gt 9 ]; then
            warn "Enter a number from 1 to ${count}, or q."
            continue
        fi
        index=$((10#$choice-1))
        if [ "$index" -lt 0 ] || [ "$index" -ge "$count" ]; then
            warn "Enter a number from 1 to ${count}, or q."
            continue
        fi
        if [ "${TV_ADB[index]}" != open ]; then
            fail "TCP 5555 is closed on ${TV_IPS[index]}. Enable debugging on the TV first."
            info "Settings > System > About > tap Build 7x; Developer Options > USB debugging."
            info "Some Google TV builds also need Network debugging or ADB debugging."
            exit 1
        fi
        SELECTED_IP=${TV_IPS[index]}
        return 0
    done
}

# =============================================================================
# Main: Remediate
# =============================================================================

do_remediate() {
    local tv_ip="$1" pkg desc
    
    header "TCL SMART TV TELEMETRY REMEDIATION"
    log "  Date:   $(date)"
    log "  Target: ${tv_ip}"
    log "  Log:    ${LOGFILE}"
    
    check_adb || exit 1
    connect_tv "$tv_ip" || exit 2
    verify_tcl_tv remediate || exit 1
    get_baseline || exit 1
    
    # ── Tier 1: Telemetry ──
    header "TIER 1 — TELEMETRY & TRACKING"
    log "  ${RED}These packages collect and transmit viewing data, usage statistics,${NC}"
    log "  ${RED}ACR screen captures, and device analytics to TCL/third-party servers.${NC}"
    log ""
    
    for pkg in "${TIER1_PACKAGES[@]}"; do
        case "$pkg" in
            "com.tcl.ttvs")                desc="ACR, Samba TV, BI telemetry, usage stats, Alexa" ;;
            "com.tcl.tv.tclhome_passive")  desc="cloud account binding, BI telemetry" ;;
            "com.tcl.useragreement")       desc="consent/telemetry framework" ;;
            "com.tcl.logkit")              desc="diagnostics collection" ;;
        esac
        disable_package "$pkg" "$desc" || exit 1
    done
    
    # Uninstall the persistent remote support agent
    log ""
    uninstall_package "$UNINSTALL_PACKAGE" "remote support agent (persists through disable)" || exit 1
    
    # Verify Tier 1
    log ""
    info "Waiting 10s to check for respawns..."
    sleep 10
    local ttvs_check
    fetch_processes || exit 1
    ttvs_check=$(count_matches -E '(^|[[:space:]])com\.tcl\.ttvs(:[^[:space:]]+)?$' <<< "$ADB_OUTPUT") || { fail "Could not count TTVS respawns."; exit 1; }
    if [ "$ttvs_check" -eq 0 ]; then
        success "TTVS confirmed dead — BIService binding broken"
    else
        warn "TTVS may still be in memory — will be fully gone after reboot"
    fi
    
    prompt_continue "TEST YOUR TV NOW: Switch HDMI inputs, use the remote, check the home screen."
    
    # ── Tier 2: Bloatware ──
    header "TIER 2 — BLOATWARE WITH NETWORK ACCESS"
    log "  ${YELLOW}These are redundant streaming/connectivity apps you don't need${NC}"
    log "  ${YELLOW}if using Apple TV, Roku, or other external streaming devices.${NC}"
    log ""
    
    for pkg in "${TIER2_PACKAGES[@]}"; do
        case "$pkg" in
            "com.tcl.channelplus")     desc="TCL Live streaming" ;;
            "com.tcl.exhibit")         desc="T-Exhibition art mode" ;;
            "com.tcl.smartlink.core")  desc="cross-device linking" ;;
            "com.tcl.tv.plus")         desc="TCL TV+ streaming" ;;
        esac
        disable_package "$pkg" "$desc" || exit 1
    done
    
    prompt_continue "TEST AGAIN: Verify HDMI switching and home screen still work."
    
    # ── Tier 3: Retail/Unused ──
    header "TIER 3 — RETAIL & UNUSED"
    log "  ${CYAN}Safe cleanup — retail demo modes and completed setup wizards.${NC}"
    log ""
    
    for pkg in "${TIER3_PACKAGES[@]}"; do
        case "$pkg" in
            "com.tcl.esticker")            desc="retail demo price tag" ;;
            "com.tcl.hotelmenu")           desc="hotel mode" ;;
            "com.tcl.ocean.instructions")  desc="setup wizard docs" ;;
            "com.tcl.initsetup")           desc="initial setup wizard" ;;
        esac
        disable_package "$pkg" "$desc" || exit 1
    done
    
    # ── Verification ──
    verify_results || exit 1
    
    # ── Reboot prompt ──
    header "REBOOT RECOMMENDED"
    log ""
    log "  All changes are ${BOLD}persistent${NC} — they survive reboot."
    log "  Reboot the TV to fully clear any residual processes from memory."
    log ""
    log "  ${BOLD}To reboot via ADB:${NC}  adb -s ${ADB_TARGET} shell reboot"
    log "  ${BOLD}Or:${NC} Use the TV remote (Settings > System > Restart)"
    log ""
    log "  After reboot, you can verify with:"
    log "    adb connect ${tv_ip}:5555"
    log "    adb -s ${ADB_TARGET} shell ps -A | grep -i ttvs    ${CYAN}# should be empty${NC}"
    log "    adb -s ${ADB_TARGET} shell pm list packages -d --user 0 | grep tcl"
    log ""
    
    header "IMPORTANT NOTES"
    log ""
    log "  ${YELLOW}1. OTA firmware updates are blocked.${NC}"
    log "     To update firmware:"
    log "       adb -s ${ADB_TARGET} shell pm enable --user 0 com.tcl.ttvs"
    log "       # Update via TV Settings > System > Software Update"
    log "       adb -s ${ADB_TARGET} shell pm disable-user --user 0 com.tcl.ttvs"
    log ""
    log "  ${YELLOW}2. Factory reset restores everything.${NC}"
    log "     You would need to run this script again."
    log ""
    log "  ${YELLOW}3. Google telemetry is NOT affected.${NC}"
    log "     This script removes TCL-specific telemetry only."
    log "     For full privacy, disconnect WiFi and use as a dumb display."
    log ""
    log "  ${YELLOW}4. Consider disabling ADB when done.${NC}"
    log "     Settings > System > Developer Options > disable USB Debugging"
    log ""
    log "  ${GREEN}Full log saved to: ${LOGFILE}${NC}"
    log ""
    
    header "ROLLBACK"
    log ""
    log "  To undo everything:"
    log "    ${BOLD}./tcl_tv_remediate.sh ${tv_ip} --rollback${NC}"
    log ""
    log "  Or factory reset the TV."
    log ""
}

# =============================================================================
# Main: Rollback
# =============================================================================

do_rollback() {
    local tv_ip="$1" pkg
    
    header "TCL TV REMEDIATION — FULL ROLLBACK"
    log "  Date:   $(date)"
    log "  Target: ${tv_ip}"
    log "  Log:    ${LOGFILE}"
    
    check_adb || exit 1
    connect_tv "$tv_ip" || exit 2
    verify_tcl_tv rollback || exit 1
    
    log ""
    info "Re-enabling all disabled packages..."
    log ""
    
    for pkg in "${TIER1_PACKAGES[@]}" "${TIER2_PACKAGES[@]}" "${TIER3_PACKAGES[@]}"; do
        enable_package "$pkg" || exit 1
    done
    
    # Restore uninstalled package
    info "Restoring uninstalled package..."
    fetch_packages "All packages (including uninstalled)" -u --user 0 || exit 1
    if package_in_list "$UNINSTALL_PACKAGE" "$ADB_OUTPUT"; then
        restore_package "$UNINSTALL_PACKAGE" || exit 1
        enable_package "$UNINSTALL_PACKAGE" || exit 1
    else
        info "${UNINSTALL_PACKAGE} — not present on this model, skipping restore"
    fi
    
    log ""
    success "All packages re-enabled."
    log ""
    log "  Reboot the TV to fully restore all services:"
    log "    ${BOLD}adb -s ${ADB_TARGET} shell reboot${NC}"
    log ""
}

# =============================================================================
# Main: Read-only check
# =============================================================================

do_check() {
    local tv_ip="$1" installed disabled all_packages processes enabled_count ttvs_running
    local pkg tier index status color drift_count=0 ok_count=0 absent_count=0
    local packages=("${TIER1_PACKAGES[@]}" "${TIER2_PACKAGES[@]}" "${TIER3_PACKAGES[@]}" "$UNINSTALL_PACKAGE")
    local drift=()
    header "TCL TV REMEDIATION — READ-ONLY CHECK"
    log "  Date:   $(date)"
    log "  Target: ${tv_ip}"
    log "  Log:    ${LOGFILE}"
    check_adb || exit 2
    connect_tv "$tv_ip" || exit 2
    verify_tcl_tv check || exit 2
    fetch_packages "Installed packages" --user 0 || exit 2
    installed="$ADB_OUTPUT"
    fetch_packages "Disabled packages" -d --user 0 || exit 2
    disabled="$ADB_OUTPUT"
    fetch_packages "All packages (including uninstalled)" -u --user 0 || exit 2
    all_packages="$ADB_OUTPUT"
    header "PACKAGE STATE — USER 0"
    for ((index=0; index<${#packages[@]}; index++)); do
        pkg=${packages[index]}
        if [ "$index" -lt "${#TIER1_PACKAGES[@]}" ]; then
            tier=T1
        elif [ "$index" -lt "$((${#TIER1_PACKAGES[@]}+${#TIER2_PACKAGES[@]}))" ]; then
            tier=T2
        elif [ "$index" -lt "$((${#TIER1_PACKAGES[@]}+${#TIER2_PACKAGES[@]}+${#TIER3_PACKAGES[@]}))" ]; then
            tier=T3
        else
            tier=UNINSTALL
        fi
        color="$GREEN"
        if package_in_list "$pkg" "$disabled"; then
            status=DISABLED
            ok_count=$((ok_count+1))
        elif ! package_in_list "$pkg" "$installed" && package_in_list "$pkg" "$all_packages"; then
            status='UNINSTALLED for user 0'
            ok_count=$((ok_count+1))
        elif package_in_list "$pkg" "$installed"; then
            status=ENABLED
            color="$RED"
            drift+=("$pkg")
            drift_count=$((drift_count+1))
        else
            status='NOT PRESENT (ok)'
            color="$CYAN"
            absent_count=$((absent_count+1))
        fi
        log "  [${tier}] ${pkg}: ${color}${status}${NC}"
    done
    fetch_processes || exit 2
    processes="$ADB_OUTPUT"
    ttvs_running=$(count_matches -E '(^|[[:space:]])com\.tcl\.ttvs(:[^[:space:]]+)?$' <<< "$processes") || { fail "Could not count TTVS processes during check."; exit 2; }
    if [ "$ttvs_running" -eq 0 ]; then
        success "com.tcl.ttvs process: NOT RUNNING"
    else
        warn "com.tcl.ttvs process: RUNNING (${ttvs_running})"
    fi
    info "ro.build.display.id: ${TV_BUILD}"
    fetch_packages "Enabled packages" -e --user 0 || exit 2
    enabled_count=$(count_matches '^package:' <<< "$ADB_OUTPUT") || { fail "Could not count enabled packages during check."; exit 2; }
    info "Enabled package count (user 0): ${enabled_count}"
    log "  Summary: ${drift_count} ENABLED drift; ${ok_count} disabled/uninstalled; ${absent_count} not present."
    if [ "$drift_count" -gt 0 ]; then
        fail "Enabled packages requiring remediation:"
        for pkg in "${drift[@]}"; do
            info "$pkg"
        done
        info "Fix: ./tcl_tv_remediate.sh ${tv_ip}"
        exit 1
    fi
    success "No ENABLED package drift."
    exit 0
}

# =============================================================================
# Usage and entry point
# =============================================================================

usage() {
    printf '\n  TCL Smart TV Telemetry Remediation Script\n\n'
    printf '  Usage: %s [TV_IP_ADDRESS] [MODE] [OPTIONS]\n\n' "$0"
    printf '    No arguments                 Discover, pick a TV, then remediate\n'
    printf '    <ip>                         Remediate the specified TCL TV\n'
    printf '    [<ip>] --rollback|rollback   Restore packages (TCL only)\n'
    printf '    [<ip>] --check|check         Read-only package/process audit\n'
    printf '    --scan                       Discover and print TVs; no ADB needed or called\n'
    printf '    --force-non-tcl              Override manufacturer guard for remediation only\n'
    printf '    -h|--help                    Show this help\n\n'
    printf '  IP and options may appear in any order; only one IP and one mode are allowed.\n'
    printf '  Without an IP, remediation/rollback/check requires an interactive numbered selection.\n'
    printf '  Even one candidate requires selection; q cancels with exit 0.\n'
    printf '  Discovery: local subnet, parallel mDNS, bounded TCP 5555 probes.\n'
    printf '  Manual IP: TV Settings > Network & Internet.\n'
    printf '  Prerequisites: ADB (except scan), Developer Options and USB debugging, same LAN.\n'
    printf '  Check exits: 0 = no drift; 1 = ENABLED drift; 2 = connection/auth/query failure or non-TCL.\n'
    printf '  Connection/auth failure exits 2 in all device modes.\n\n'
}

main() {
    local tv_ip="" mode=remediate mode_seen=false help_requested=false arg
    local octets=()
    for arg in "$@"; do
        case "$arg" in
            -h|--help) help_requested=true ;;
            --force-non-tcl) FORCE_NON_TCL=true ;;
            --rollback|rollback|--check|check|--scan)
                if [ "$mode_seen" = true ]; then
                    fail "Only one mode is allowed; extra mode: ${arg}"
                    usage
                    exit 1
                fi
                mode=${arg#--}
                mode_seen=true
                ;;
            *)
                if ! validate_ipv4 "$arg"; then
                    fail "Unknown argument or invalid IPv4 address: '${arg}'"
                    usage
                    exit 1
                fi
                if [ -n "$tv_ip" ]; then
                    fail "Only one TV IP is allowed; extra IP: ${arg}"
                    usage
                    exit 1
                fi
                # Normalize decimal octets so leading zeros cannot imply octal IPs.
                IFS=. read -r -a octets <<< "$arg"
                printf -v tv_ip '%d.%d.%d.%d' "$((10#${octets[0]}))" "$((10#${octets[1]}))" "$((10#${octets[2]}))" "$((10#${octets[3]}))"
                ;;
        esac
    done
    if [ "$help_requested" = true ]; then
        usage
        exit 0
    fi
    if [ "$FORCE_NON_TCL" = true ] && [ "$mode" != remediate ]; then
        fail "--force-non-tcl is only valid in remediate mode."
        usage
        exit 1
    fi
    if [ "$mode" = scan ]; then
        header "LAN TV DISCOVERY — NO ADB"
        log "  Date:   $(date)"
        log "  Log:    ${LOGFILE}"
        discover_tvs || exit 1
        print_tv_table
        [ "${#TV_IPS[@]}" -gt 0 ] || info "No TVs found. Supply the IP from TV Settings > Network & Internet."
        exit 0
    fi
    if [ -z "$tv_ip" ]; then
        discover_tvs || exit 1
        select_tv
        tv_ip="$SELECTED_IP"
    fi
    case "$mode" in
        remediate) do_remediate "$tv_ip" ;;
        rollback) do_rollback "$tv_ip" ;;
        check) do_check "$tv_ip" ;;
        *) fail "Unsupported mode: ${mode}"; exit 1 ;;
    esac
}

main "$@"
