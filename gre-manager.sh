#!/usr/bin/env bash
# =============================================================================
#  gre-manager — GRE tunnel manager for Iran <-> Kharej servers
#
#  * Several tunnels per server (one Iran server -> many Kharej servers)
#  * Persistent tunnels through a systemd template unit (gre-manager@<name>)
#  * Port forwarding (DNAT) through the tunnel, MSS clamping, optional NAT-out
#  * Health monitor that restarts dead tunnels, connectivity and MTU tests
#  * Backup / restore, kernel tuning (BBR), interactive menu and a full CLI
#
#  Run without arguments for the interactive menu, or "gre-manager help".
# =============================================================================

set -Eeuo pipefail
shopt -s nullglob

readonly VERSION="2.2.0"
readonly APP="gre-manager"
readonly INSTALL_PATH="/usr/local/bin/${APP}"
readonly CONF_DIR="/etc/${APP}"
readonly TUN_DIR="${CONF_DIR}/tunnels"
readonly GLOBAL_CONF="${CONF_DIR}/${APP}.conf"
readonly STATE_DIR="/run/${APP}"
readonly LOCK_FILE="/run/${APP}.lock"
readonly LOG_FILE="/var/log/${APP}.log"
readonly BACKUP_DIR="/root/${APP}-backups"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly UNIT_TEMPLATE="${SYSTEMD_DIR}/${APP}@.service"
readonly MONITOR_SERVICE="${SYSTEMD_DIR}/${APP}-monitor.service"
readonly MONITOR_TIMER="${SYSTEMD_DIR}/${APP}-monitor.timer"
readonly SYSCTL_FILE="/etc/sysctl.d/99-${APP}.conf"
readonly SCRIPT_URL="https://raw.githubusercontent.com/xmohammad1/GRE-Tunnel/main/gre-manager.sh"
readonly ABUSE_CHAIN="GREM-ABUSE"
readonly GUARD_METRIC=4242

# Artifacts of the old single-tunnel script (gre2manager.sh).
readonly LEGACY_SERVICE="gre-tun2"
readonly LEGACY_DEV="tun2"
readonly LEGACY_SCRIPT="/usr/local/bin/${LEGACY_SERVICE}.sh"

# Keys allowed in a tunnel config file; anything else is ignored on load.
readonly TUNNEL_KEYS=(NAME ROLE ID LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP
    PREFIX IPV6 LOCAL_TUN_IP6 REMOTE_TUN_IP6 MTU TTL GRE_KEY FORWARDS
    MSS_CLAMP NAT_OUT FW_ALLOW MONITOR COMMENT CREATED)

# ---- Defaults, overridable in /etc/gre-manager/gre-manager.conf -------------
SUBNET_BASE="10.100"        # tunnel ID N  ->  ${SUBNET_BASE}.N.0/30
SUBNET6_BASE="fd10:100"     # tunnel ID N  ->  ${SUBNET6_BASE}:N::/64
DEFAULT_MTU=1476
DEFAULT_TTL=255
MONITOR_INTERVAL="1min"
MONITOR_FAILS=3
MONITOR_PING_COUNT=3
ABUSE_GUARD="no"            # drop private/reserved ranges leaving the public interface
ABUSE_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 198.18.0.0/15 192.0.0.0/24 192.0.2.0/24 198.51.100.0/24 203.0.113.0/24 240.0.0.0/4"

# The tunnel currently loaded by tunnel_load().
declare -A T=()
# Tunnel excluded from uniqueness checks while it is being edited.
EXCEPT_NAME=""
# Set by install_self() when the installed binary changed.
SELF_UPDATED=0

# =============================================================================
#  Output & logging
# =============================================================================

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    readonly C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m'
    readonly C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

log() {
    local level=$1
    shift
    printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$level" "$*" 2>/dev/null >>"$LOG_FILE" || true
}

info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; log INFO "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log OK "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log WARN "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log ERROR "$*"; }
die()  { err "$*"; exit 1; }

section() { printf '\n%s%s━━ %s ━━%s\n\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"; }
kv()      { printf '  %-20s %s\n' "$1" "$2"; }

on_error() {
    local code=$? line=$1 cmd=$2
    err "Unexpected failure (exit ${code}) at line ${line}: ${cmd}"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# =============================================================================
#  Generic helpers
# =============================================================================

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This command must be run as root (try: sudo ${0##*/})"
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

strip_quotes() {
    local s=$1
    s=${s#\"}
    printf '%s' "${s%\"}"
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.2f %s"), b, u[i]
    }'
}

# ask VAR "Prompt" [default] [validator]
# Re-prompts until the validator (a function taking the value) succeeds.
ask() {
    local __var=$1 __prompt=$2 __default=${3:-} __validator=${4:-} __reply
    while true; do
        if [[ -n $__default ]]; then
            read -r -p "${C_CYAN}?${C_RESET} ${__prompt} [${C_DIM}${__default}${C_RESET}]: " __reply || return 1
        else
            read -r -p "${C_CYAN}?${C_RESET} ${__prompt}: " __reply || return 1
        fi
        __reply=$(trim "${__reply:-$__default}")
        if [[ -z $__validator ]] || "$__validator" "$__reply"; then
            printf -v "$__var" '%s' "$__reply"
            return 0
        fi
        warn "Invalid value: '${__reply}'"
    done
}

# confirm "Question" [y|n]  — returns 0 on yes.
confirm() {
    local reply default=${2:-n} hint='y/N'
    [[ $default == y ]] && hint='Y/n'
    read -r -p "${C_YELLOW}?${C_RESET} $1 [${hint}]: " reply || return 1
    reply=${reply:-$default}
    [[ ${reply,,} == y || ${reply,,} == yes ]]
}

pause() {
    [[ -t 0 ]] || return 0
    read -r -s -n1 -p "${C_DIM}Press any key to continue...${C_RESET}" || true
    echo
}

# =============================================================================
#  Validators (each takes one value, returns 0 when valid)
# =============================================================================

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

is_ipv4() {
    local IFS=. octet
    local -a octets
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -r -a octets <<<"$1"
    for octet in "${octets[@]}"; do
        [[ $((10#$octet)) -le 255 ]] || return 1
    done
}

is_private_ipv4() {
    [[ $1 =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

# ipv4_network IP PREFIX  ->  network/prefix, e.g. 10.100.1.1 30 -> 10.100.1.0/30
ipv4_network() {
    local n
    n=$(($(ipv4_to_int "$1") & ((0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF)))
    printf '%d.%d.%d.%d/%d' $((n >> 24 & 255)) $((n >> 16 & 255)) $((n >> 8 & 255)) $((n & 255)) "$2"
}

is_port()      { is_uint "$1" && [[ $((10#$1)) -ge 1 && $((10#$1)) -le 65535 ]]; }
is_mtu()       { is_uint "$1" && [[ $((10#$1)) -ge 576 && $((10#$1)) -le 9000 ]]; }
is_tunnel_id() { is_uint "$1" && [[ $((10#$1)) -ge 1 && $((10#$1)) -le 254 ]]; }
is_gre_key()   { is_uint "$1" && [[ ${#1} -le 10 && $((10#$1)) -ge 1 && $((10#$1)) -le 4294967295 ]]; }
is_gre_key_opt() { [[ $1 == none ]] || is_gre_key "$1"; }
is_role_choice() { [[ $1 == 1 || $1 == 2 ]]; }

# Tunnel names become part of the device name (gre-<name>, max 15 chars).
is_valid_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,10}$ ]]; }

# =============================================================================
#  System setup
# =============================================================================

load_global_conf() {
    [[ -r $GLOBAL_CONF ]] || return 0
    local line key
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        case $key in
            SUBNET_BASE | SUBNET6_BASE | DEFAULT_MTU | DEFAULT_TTL | MONITOR_INTERVAL | MONITOR_FAILS | \
                MONITOR_PING_COUNT | ABUSE_GUARD | ABUSE_RANGES)
                printf -v "$key" '%s' "$(strip_quotes "$(trim "${BASH_REMATCH[2]}")")"
                ;;
        esac
    done <"$GLOBAL_CONF"
}

write_default_global_conf() {
    [[ -f $GLOBAL_CONF ]] && return 0
    cat >"$GLOBAL_CONF" <<EOF
# ${APP} global settings. Changes apply to tunnels created afterwards.

# Inner IPv4 subnet of tunnel ID N is \${SUBNET_BASE}.N.0/30
SUBNET_BASE="${SUBNET_BASE}"
# Inner IPv6 subnet of tunnel ID N is \${SUBNET6_BASE}:N::/64
SUBNET6_BASE="${SUBNET6_BASE}"
DEFAULT_MTU="${DEFAULT_MTU}"
DEFAULT_TTL="${DEFAULT_TTL}"

# Health monitor: restart a tunnel after MONITOR_FAILS failed checks in a row.
MONITOR_INTERVAL="${MONITOR_INTERVAL}"
MONITOR_FAILS="${MONITOR_FAILS}"
MONITOR_PING_COUNT="${MONITOR_PING_COUNT}"

# Abuse guard: drop packets to these ranges when they leave the public interface.
ABUSE_GUARD="${ABUSE_GUARD}"
ABUSE_RANGES="${ABUSE_RANGES}"
EOF
    chmod 600 "$GLOBAL_CONF"
}

set_global_conf() {
    local key=$1 value=$2
    write_default_global_conf
    if grep -q "^${key}=" "$GLOBAL_CONF"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$GLOBAL_CONF"
    else
        printf '%s="%s"\n' "$key" "$value" >>"$GLOBAL_CONF"
    fi
    printf -v "$key" '%s' "$value"
}

pkg_install() {
    info "Installing packages: $*"
    if has_cmd apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
    elif has_cmd dnf; then
        dnf install -y -q "$@"
    elif has_cmd yum; then
        yum install -y -q "$@"
    else
        die "No supported package manager found. Install manually: $*"
    fi
}

ensure_deps() {
    local -a missing=()
    has_cmd ip || missing+=(iproute2)
    has_cmd iptables || missing+=(iptables)
    has_cmd ping || missing+=(iputils-ping)
    has_cmd flock || missing+=(util-linux)
    has_cmd curl || missing+=(curl)
    if ((${#missing[@]} > 0)); then
        if ! has_cmd apt-get; then
            missing=("${missing[@]/iproute2/iproute}")
            missing=("${missing[@]/iputils-ping/iputils}")
        fi
        pkg_install "${missing[@]}"
    fi
    modprobe ip_gre 2>/dev/null || warn "Could not load the ip_gre kernel module (containers such as OpenVZ/LXC usually lack GRE support)."
}

# Prints the IPv4 address GRE should use as its local endpoint.
detect_public_ip() {
    local ip url
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }') || true
    if is_ipv4 "${ip:-}" && ! is_private_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -4 -fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if is_ipv4 "${ip:-}"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

script_version() {
    sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n1
}

version_lt() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]
}

# Fetches the script from GitHub and installs it when it differs from
# INSTALL_PATH. Returns 1 (with an error message) when the download fails.
download_self() {
    local tmp new_ver cur_ver
    has_cmd curl || pkg_install curl
    tmp=$(mktemp)
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        err "Could not download ${SCRIPT_URL}"
        return 1
    fi
    if [[ $(head -n1 "$tmp") != '#!/usr/bin/env bash' ]] || ! grep -q "^readonly APP=\"${APP}\"$" "$tmp" ||
        ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "The downloaded file is not a valid ${APP} script."
        return 1
    fi
    if cmp -s "$tmp" "$INSTALL_PATH" 2>/dev/null; then
        rm -f "$tmp"
        return 0
    fi
    new_ver=$(script_version "$tmp")
    cur_ver=$(script_version "$INSTALL_PATH")
    if [[ -n $cur_ver ]] && version_lt "$new_ver" "$cur_ver"; then
        rm -f "$tmp"
        warn "GitHub has ${APP} ${new_ver}, older than the installed ${cur_ver}; keeping the installed version."
        return 0
    fi
    install -m 0755 "$tmp" "$INSTALL_PATH"
    rm -f "$tmp"
    SELF_UPDATED=1
    ok "Installed ${APP} $(script_version "$INSTALL_PATH") to ${INSTALL_PATH}"
}

# Puts this script at INSTALL_PATH, which the systemd units execute.
install_self() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    [[ $src == "$INSTALL_PATH" ]] && return 0
    if [[ -f $src ]]; then
        if ! has_cmd cmp || ! cmp -s "$src" "$INSTALL_PATH" 2>/dev/null; then
            install -m 0755 "$src" "$INSTALL_PATH"
            SELF_UPDATED=1
            ok "Installed ${APP} ${VERSION} to ${INSTALL_PATH}"
        fi
    else
        # Started as "bash <(curl ...)": there is no file to copy, so fetch one.
        info "Fetching the latest ${APP} from GitHub ..."
        download_self || [[ -x $INSTALL_PATH ]] ||
            die "Install manually: curl -fsSL ${SCRIPT_URL} -o ${INSTALL_PATH} && chmod +x ${INSTALL_PATH}"
    fi
}

cmd_update() {
    local before
    before=$(script_version "$INSTALL_PATH")
    SELF_UPDATED=0
    download_self || return 1
    if [[ $SELF_UPDATED -eq 1 ]]; then
        write_units
        ok "Updated ${APP} ${before:-?} -> $(script_version "$INSTALL_PATH")."
    else
        ok "${APP} is already up to date (${before})."
    fi
}

write_units() {
    cat >"$UNIT_TEMPLATE" <<EOF
[Unit]
Description=GRE tunnel %i (${APP})
Documentation=file://${INSTALL_PATH}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} up %i
ExecStop=${INSTALL_PATH} down %i
ExecReload=${INSTALL_PATH} apply %i
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

    cat >"$MONITOR_SERVICE" <<EOF
[Unit]
Description=${APP} tunnel health monitor
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} monitor
EOF

    cat >"$MONITOR_TIMER" <<EOF
[Unit]
Description=Run ${APP} health monitor every ${MONITOR_INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${MONITOR_INTERVAL}
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

# One-time preparation for every management command.
bootstrap() {
    has_cmd systemctl || die "systemd is required."
    mkdir -p "$TUN_DIR" "$STATE_DIR"
    chmod 700 "$CONF_DIR"
    ensure_deps
    install_self
    write_default_global_conf
    if [[ ! -f $UNIT_TEMPLATE || $SELF_UPDATED -eq 1 ]]; then
        write_units
        systemctl enable --now "${APP}-monitor.timer" >/dev/null 2>&1 || warn "Could not enable the health monitor timer."
    fi
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another ${APP} instance is running."
}

ensure_forwarding() {
    if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) != 1 ]]; then
        sysctl -qw net.ipv4.ip_forward=1
    fi
    if ! grep -qs '^net.ipv4.ip_forward' "$SYSCTL_FILE"; then
        printf '# Managed by %s\nnet.ipv4.ip_forward = 1\n' "$APP" >>"$SYSCTL_FILE"
    fi
}

ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }') || true
    echo "${port:-22}"
}

# =============================================================================
#  Tunnel configuration model
# =============================================================================

dev_name()  { printf 'gre-%s' "$1"; }
unit_name() { printf '%s@%s.service' "$APP" "$1"; }
conf_file() { printf '%s/%s.conf' "$TUN_DIR" "$1"; }
tunnel_exists() { [[ -f $(conf_file "$1") ]]; }

tunnel_names() {
    local f
    for f in "$TUN_DIR"/*.conf; do
        f=${f##*/}
        printf '%s\n' "${f%.conf}"
    done
}

is_tunnel_key() {
    local key
    for key in "${TUNNEL_KEYS[@]}"; do
        [[ $key == "$1" ]] && return 0
    done
    return 1
}

# Reads one key of a tunnel config without touching T.
conf_get() {
    local line
    line=$(grep -m1 "^$2=" "$(conf_file "$1")" 2>/dev/null) || return 0
    strip_quotes "${line#*=}"
}

tunnel_load() {
    local name=$1 file line key
    file=$(conf_file "$name")
    [[ -r $file ]] || die "Tunnel '${name}' does not exist."
    T=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        is_tunnel_key "$key" || continue
        T[$key]=$(strip_quotes "${BASH_REMATCH[2]}")
    done <"$file"
    tunnel_defaults
    T[NAME]=$name
}

# Fills every key so that ${T[KEY]} is always safe under "set -u".
tunnel_defaults() {
    local key
    for key in "${TUNNEL_KEYS[@]}"; do
        T[$key]=${T[$key]:-}
    done
    T[PREFIX]=${T[PREFIX]:-30}
    T[MTU]=${T[MTU]:-$DEFAULT_MTU}
    T[TTL]=${T[TTL]:-$DEFAULT_TTL}
    T[IPV6]=${T[IPV6]:-no}
    T[MSS_CLAMP]=${T[MSS_CLAMP]:-yes}
    T[NAT_OUT]=${T[NAT_OUT]:-no}
    T[FW_ALLOW]=${T[FW_ALLOW]:-yes}
    T[MONITOR]=${T[MONITOR]:-yes}
}

tunnel_save() {
    local file tmp key
    file=$(conf_file "${T[NAME]}")
    tmp=$(mktemp "${file}.XXXXXX")
    {
        printf '# %s tunnel config, written %s\n' "$APP" "$(date '+%F %T')"
        for key in "${TUNNEL_KEYS[@]}"; do
            printf '%s="%s"\n' "$key" "${T[$key]:-}"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

# Derives inner addresses from the tunnel ID (Iran = .1, Kharej = .2).
tunnel_compute_addresses() {
    local id=$((10#${T[ID]})) self=2 peer=1
    if [[ ${T[ROLE]} == iran ]]; then
        self=1 peer=2
    fi
    T[LOCAL_TUN_IP]="${SUBNET_BASE}.${id}.${self}"
    T[REMOTE_TUN_IP]="${SUBNET_BASE}.${id}.${peer}"
    T[PREFIX]=30
    T[LOCAL_TUN_IP6]="${SUBNET6_BASE}:${id}::${self}"
    T[REMOTE_TUN_IP6]="${SUBNET6_BASE}:${id}::${peer}"
}

# Prints the name of the tunnel (other than EXCEPT_NAME) that uses this ID.
tunnel_with_id() {
    local name
    for name in $(tunnel_names); do
        [[ $name == "$EXCEPT_NAME" ]] && continue
        if [[ $(conf_get "$name" ID) == "$((10#$1))" ]]; then
            echo "$name"
            return 0
        fi
    done
}

# The kernel refuses two GRE tunnels with the same local/remote/key.
tunnel_with_endpoints() {
    local name
    for name in $(tunnel_names); do
        [[ $name == "$EXCEPT_NAME" ]] && continue
        if [[ $(conf_get "$name" LOCAL_IP) == "$1" && $(conf_get "$name" REMOTE_IP) == "$2" &&
            $(conf_get "$name" GRE_KEY) == "$3" ]]; then
            echo "$name"
            return 0
        fi
    done
}

next_free_id() {
    local id
    for ((id = 1; id <= 254; id++)); do
        if [[ -z $(tunnel_with_id "$id") ]]; then
            echo "$id"
            return 0
        fi
    done
    return 1
}

is_free_tunnel_id() {
    is_tunnel_id "$1" || return 1
    local owner
    owner=$(tunnel_with_id "$1")
    [[ -z $owner ]] && return 0
    warn "Tunnel ID $1 is already used by '${owner}'."
    return 1
}

# default_name BASE N  ->  first unused BASE<N>, BASE<N+1>, ...
default_name() {
    local n=$((10#$2))
    while tunnel_exists "${1}${n}"; do
        n=$((n + 1))
    done
    echo "${1}${n}"
}

is_new_tunnel_name() {
    is_valid_name "$1" || return 1
    if tunnel_exists "$1"; then
        warn "A tunnel named '$1' already exists."
        return 1
    fi
}

# =============================================================================
#  Port-forward rules
#
#  Spec:  proto:port[-port][>target_port]     proto = tcp | udp | both
#  e.g.   tcp:443   udp:51820   both:8443   tcp:2000-2100   tcp:2222>22
# =============================================================================

readonly FORWARD_RE='^(tcp|udp|both):([0-9]{1,5})(-([0-9]{1,5}))?(>([0-9]{1,5}))?$'

# Sets FW_PROTO, FW_LO, FW_HI and FW_DPORT (empty = same port).
parse_forward() {
    [[ $1 =~ $FORWARD_RE ]] || return 1
    FW_PROTO=${BASH_REMATCH[1]}
    FW_LO=$((10#${BASH_REMATCH[2]}))
    FW_HI=$((10#${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}))
    FW_DPORT=${BASH_REMATCH[6]:+$((10#${BASH_REMATCH[6]}))}
}

is_forward_spec() {
    parse_forward "$1" || return 1
    is_port "$FW_LO" && is_port "$FW_HI" || return 1
    [[ $FW_HI -ge $FW_LO ]] || return 1
    if [[ -n $FW_DPORT ]]; then
        is_port "$FW_DPORT" && [[ $FW_HI -eq $FW_LO ]] || return 1
    fi
}

forward_describe() {
    parse_forward "$1"
    local ports=$FW_LO target
    [[ $FW_HI -ne $FW_LO ]] && ports="${FW_LO}-${FW_HI}"
    target=${FW_DPORT:-$ports}
    printf '%-5s %-12s -> %s:%s' "$FW_PROTO" "$ports" "$2" "$target"
}

# Prints "tunnel:rule" of an existing rule overlapping SPEC, if any.
# Rules of tunnel SELF are taken from the in-memory list SELF_RULES.
forward_conflict() {
    local spec=$1 self=$2 self_rules=$3 name rule pair proto lo hi
    local -a rules pairs=()
    for name in $(tunnel_names); do
        [[ $name == "$self" ]] && continue
        read -r -a rules <<<"$(conf_get "$name" FORWARDS)"
        for rule in "${rules[@]}"; do
            pairs+=("${name}:${rule}")
        done
    done
    read -r -a rules <<<"$self_rules"
    for rule in "${rules[@]}"; do
        pairs+=("${self}:${rule}")
    done

    parse_forward "$spec"
    proto=$FW_PROTO lo=$FW_LO hi=$FW_HI
    for pair in "${pairs[@]}"; do
        parse_forward "${pair#*:}" || continue
        [[ $proto == both || $FW_PROTO == both || $proto == "$FW_PROTO" ]] || continue
        if [[ $lo -le $FW_HI && $FW_LO -le $hi ]]; then
            echo "$pair"
            return 0
        fi
    done
}

# Validates SPEC and appends it to T[FORWARDS]; asks before touching SSH.
# Returns 1 (with an error message) instead of exiting, so menus can retry.
forward_add() {
    local spec=$1 conflict ssh
    if ! is_forward_spec "$spec"; then
        err "Invalid forward rule '${spec}'. Examples: tcp:443  both:8443  tcp:2000-2100  tcp:2222>22"
        return 1
    fi
    conflict=$(forward_conflict "$spec" "${T[NAME]}" "${T[FORWARDS]}")
    if [[ -n $conflict ]]; then
        err "Rule '${spec}' overlaps existing rule ${conflict}."
        return 1
    fi
    ssh=$(ssh_port)
    parse_forward "$spec"
    if [[ $FW_PROTO != udp && $FW_LO -le $ssh && $ssh -le $FW_HI ]]; then
        if [[ ! -t 0 ]] || ! confirm "Rule covers SSH port ${ssh}; you would lose SSH access to this server. Continue?"; then
            err "Refusing to forward the SSH port ${ssh}."
            return 1
        fi
    fi
    T[FORWARDS]=$(trim "${T[FORWARDS]} ${spec}")
}

forward_del() {
    local spec=$1 rule kept=""
    local -a rules
    read -r -a rules <<<"${T[FORWARDS]}"
    for rule in "${rules[@]}"; do
        [[ $rule == "$spec" ]] || kept+=" ${rule}"
    done
    kept=$(trim "$kept")
    if [[ $kept == "${T[FORWARDS]}" ]]; then
        err "No rule '${spec}' on tunnel '${T[NAME]}'."
        return 1
    fi
    T[FORWARDS]=$kept
}

# =============================================================================
#  Firewall (iptables). Every tunnel owns chains GREM-<name>-{IN,OUT,FWD,MSS,PRE,POST}
#  whose jumps sit at the top of the built-in chains, so tunnel traffic is
#  accepted before ufw or rules that block private ranges can drop it.
# =============================================================================

# Runs ip6tables instead when the caller declares "local IPT=ip6tables".
ipt() { "${IPT:-iptables}" -w 5 "$@"; }
fw_chain() { printf 'GREM-%s-%s' "$1" "$2"; }

fw_attach() {
    local table=$1 parent=$2 chain=$3
    ipt -t "$table" -N "$chain" 2>/dev/null || ipt -t "$table" -F "$chain"
    ipt -t "$table" -C "$parent" -j "$chain" 2>/dev/null || ipt -t "$table" -I "$parent" -j "$chain"
}

fw_detach() {
    local table=$1 parent=$2 chain=$3
    while ipt -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
    ipt -t "$table" -F "$chain" 2>/dev/null || true
    ipt -t "$table" -X "$chain" 2>/dev/null || true
}

# Deletes every jump from PARENT to CHAIN, whatever its matches, then CHAIN.
fw_detach_all() {
    local table=$1 parent=$2 chain=$3 rules rule
    local -a args
    rules=$(ipt -t "$table" -S "$parent" 2>/dev/null | grep -E -- "-j ${chain}( |$)" || true)
    while IFS= read -r rule; do
        [[ -n $rule ]] || continue
        read -r -a args <<<"${rule/#-A /-D }"
        ipt -t "$table" "${args[@]}" 2>/dev/null || true
    done <<<"$rules"
    ipt -t "$table" -F "$chain" 2>/dev/null || true
    ipt -t "$table" -X "$chain" 2>/dev/null || true
}

# True when PARENT jumps to CHAIN before any rule that may drop the packet.
fw_jump_first() {
    local rules
    rules=$(ipt -t "$1" -S "$2" 2>/dev/null) || return 1
    awk -v jump=" -j $3" '
        substr($0, length($0) - length(jump) + 1) == jump { found = 1; exit }
        / -j (DROP|REJECT|ufw-)/ { exit }
        END { exit !found }' <<<"$rules"
}

fw_clear() {
    local name=$1
    if has_cmd iptables; then
        fw_detach filter INPUT "$(fw_chain "$name" IN)"
        fw_detach filter OUTPUT "$(fw_chain "$name" OUT)"
        fw_detach filter FORWARD "$(fw_chain "$name" FWD)"
        fw_detach mangle FORWARD "$(fw_chain "$name" MSS)"
        fw_detach nat PREROUTING "$(fw_chain "$name" PRE)"
        fw_detach nat POSTROUTING "$(fw_chain "$name" POST)"
    fi
    if has_cmd ip6tables; then
        local IPT=ip6tables
        fw_detach filter INPUT "$(fw_chain "$name" IN)"
        fw_detach filter OUTPUT "$(fw_chain "$name" OUT)"
        fw_detach filter FORWARD "$(fw_chain "$name" FWD)"
    fi
}

# Accepts routed tunnel traffic even when the FORWARD policy is DROP (ufw, docker).
fw_allow_forward() {
    local fwd
    fwd=$(fw_chain "$1" FWD)
    fw_attach filter FORWARD "$fwd"
    ipt -A "$fwd" -i "$2" -j ACCEPT
    ipt -A "$fwd" -o "$2" -j ACCEPT
}

# Accepts GRE from/to the peer and all traffic on the tunnel interface, ahead
# of ufw's default deny and of rules that block private ranges (anti-abuse).
fw_allow_io() {
    local in out
    in=$(fw_chain "$1" IN)
    out=$(fw_chain "$1" OUT)
    fw_attach filter INPUT "$in"
    fw_attach filter OUTPUT "$out"
    if [[ ${IPT:-iptables} == iptables ]]; then
        ipt -A "$in" -p 47 -s "${T[REMOTE_IP]}" -j ACCEPT
        ipt -A "$out" -p 47 -d "${T[REMOTE_IP]}" -j ACCEPT
    fi
    ipt -A "$in" -i "$2" -j ACCEPT
    ipt -A "$out" -o "$2" -j ACCEPT
}

fw_apply6() {
    local IPT=ip6tables
    fw_allow_forward "$1" "$2" || return 1
    if [[ ${T[FW_ALLOW]} == yes ]]; then
        fw_allow_io "$1" "$2" || return 1
    fi
}

# False when a firewall reload (ufw, iptables-restore, ...) removed the rules
# of the loaded tunnel or put blocking rules in front of them.
fw_intact() {
    local name=${T[NAME]}
    has_cmd iptables || return 0
    fw_jump_first filter FORWARD "$(fw_chain "$name" FWD)" || return 1
    if [[ ${T[FW_ALLOW]} == yes ]]; then
        fw_jump_first filter INPUT "$(fw_chain "$name" IN)" || return 1
        fw_jump_first filter OUTPUT "$(fw_chain "$name" OUT)" || return 1
    fi
    if [[ -n ${T[FORWARDS]} ]]; then
        ipt -t nat -C PREROUTING -j "$(fw_chain "$name" PRE)" 2>/dev/null || return 1
    fi
}

fw_apply() {
    local name=${T[NAME]} dev mss pre post rule proto dport to
    local -a protos
    dev=$(dev_name "$name")
    fw_clear "$name"
    if ! has_cmd iptables; then
        warn "iptables not found; firewall rules skipped."
        return 0
    fi

    fw_allow_forward "$name" "$dev"
    if [[ ${T[FW_ALLOW]} == yes ]]; then
        fw_allow_io "$name" "$dev"
    fi
    if [[ ${T[IPV6]} == yes ]] && has_cmd ip6tables; then
        fw_apply6 "$name" "$dev" 2>/dev/null || warn "Could not add ip6tables rules for ${dev}."
    fi

    if [[ ${T[MSS_CLAMP]} == yes ]]; then
        mss=$(fw_chain "$name" MSS)
        fw_attach mangle FORWARD "$mss"
        ipt -t mangle -A "$mss" -o "$dev" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        ipt -t mangle -A "$mss" -i "$dev" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    fi

    [[ -n ${T[FORWARDS]} || ${T[NAT_OUT]} == yes ]] || return 0
    pre=$(fw_chain "$name" PRE)
    post=$(fw_chain "$name" POST)
    fw_attach nat PREROUTING "$pre"
    fw_attach nat POSTROUTING "$post"

    for rule in ${T[FORWARDS]}; do
        parse_forward "$rule" || continue
        dport=$FW_LO
        [[ $FW_HI -ne $FW_LO ]] && dport="${FW_LO}:${FW_HI}"
        to=${T[REMOTE_TUN_IP]}
        [[ -n $FW_DPORT ]] && to+=":${FW_DPORT}"
        protos=("$FW_PROTO")
        [[ $FW_PROTO == both ]] && protos=(tcp udp)
        for proto in "${protos[@]}"; do
            ipt -t nat -A "$pre" ! -i "$dev" -m addrtype --dst-type LOCAL \
                -p "$proto" --dport "$dport" -j DNAT --to-destination "$to"
        done
    done
    if [[ -n ${T[FORWARDS]} ]]; then
        # Replies must come back through the tunnel, so source-NAT to our inner IP.
        ipt -t nat -A "$post" -o "$dev" -j SNAT --to-source "${T[LOCAL_TUN_IP]}"
    fi
    if [[ ${T[NAT_OUT]} == yes ]]; then
        # Let the peer use this server as its internet gateway.
        ipt -t nat -A "$post" -s "${T[REMOTE_TUN_IP]}" ! -o "$dev" -j MASQUERADE
    fi
}

# =============================================================================
#  Abuse protection
#
#  Providers such as Hetzner report servers whose public interface sends packets
#  to private or reserved addresses ("netscan" abuse).
#  * Leak guard (always on): a high-metric blackhole route per tunnel network,
#    so traffic for the peer's inner IP is dropped locally while the tunnel is
#    down instead of leaving through the default route.
#  * Abuse guard (optional): drops packets to private/reserved ranges that leave
#    the public interface. Tunnel traffic uses gre-* interfaces and is unaffected.
# =============================================================================

# leak_guard add|del — for the loaded tunnel.
leak_guard() {
    local op=replace net
    [[ $1 == del ]] && op=del
    net=$(ipv4_network "${T[LOCAL_TUN_IP]}" "${T[PREFIX]}")
    if ! ip route "$op" blackhole "$net" metric "$GUARD_METRIC" 2>/dev/null && [[ $op != del ]]; then
        warn "Could not add the leak-guard route for ${net}."
    fi
    if [[ ${T[IPV6]} == yes ]]; then
        ip -6 route "$op" blackhole "${T[LOCAL_TUN_IP6]%::*}::/64" metric "$GUARD_METRIC" 2>/dev/null || true
    fi
}

# Prints "<interface> <gateway>" of the IPv4 default route.
wan_info() {
    ip -4 route show default 2>/dev/null | awk '{
        for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "via") g = $(i + 1) }
        print d, g; exit
    }'
}

# IPv4 resolvers in use; they must stay reachable even when private.
dns_servers() {
    local f
    for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
        [[ -r $f ]] || continue
        awk '$1 == "nameserver" && $2 ~ /^[0-9]+(\.[0-9]+){3}$/ { print $2 }' "$f"
    done | sort -u
}

abuse_guard_clear() {
    has_cmd iptables || return 0
    fw_detach_all mangle POSTROUTING "$ABUSE_CHAIN"
}

abuse_guard_apply() {
    local wan gw addr ip range
    local -a addrs dns ranges
    abuse_guard_clear
    [[ $ABUSE_GUARD == yes ]] || return 0
    if ! has_cmd iptables; then
        warn "iptables not found; abuse guard skipped."
        return 0
    fi
    read -r wan gw <<<"$(wan_info)"
    if [[ -z $wan ]]; then
        warn "No IPv4 default route; abuse guard skipped."
        return 0
    fi
    mapfile -t addrs < <(ip -4 -o addr show dev "$wan" 2>/dev/null | awk '{ print $4 }')
    mapfile -t dns < <(dns_servers)
    read -r -a ranges <<<"$ABUSE_RANGES"

    # mangle/POSTROUTING sees both local and forwarded traffic after routing, so
    # ACCEPT rules in the filter table cannot bypass the guard.
    ipt -t mangle -N "$ABUSE_CHAIN" 2>/dev/null || ipt -t mangle -F "$ABUSE_CHAIN"
    # Never block the interface's own networks, the gateway or the resolvers.
    for addr in "${addrs[@]}"; do
        ipt -t mangle -A "$ABUSE_CHAIN" -d "$(ipv4_network "${addr%/*}" "${addr#*/}")" -j RETURN
    done
    if [[ -n $gw ]]; then
        ipt -t mangle -A "$ABUSE_CHAIN" -d "$gw" -j RETURN
    fi
    for ip in "${dns[@]}"; do
        ipt -t mangle -A "$ABUSE_CHAIN" -d "$ip" -j RETURN
    done
    for range in "${ranges[@]}"; do
        ipt -t mangle -A "$ABUSE_CHAIN" -d "$range" -j DROP
    done
    ipt -t mangle -I POSTROUTING -o "$wan" -j "$ABUSE_CHAIN"
}

abuse_guard_intact() {
    local wan
    read -r wan _ <<<"$(wan_info)"
    [[ -z $wan ]] || ipt -t mangle -C POSTROUTING -o "$wan" -j "$ABUSE_CHAIN" 2>/dev/null
}

abuse_guard_drops() {
    ipt -t mangle -L "$ABUSE_CHAIN" -v -n -x 2>/dev/null | awk '$3 == "DROP" { s += $1 } END { print s + 0 }'
}

# abuse_guard_set yes|no [force]
abuse_guard_set() {
    local wan addr
    if [[ $1 == yes && ${2:-} != force ]]; then
        read -r wan _ <<<"$(wan_info)"
        addr=$(ip -4 -o addr show dev "${wan:-lo}" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
        if is_private_ipv4 "${addr:-}"; then
            err "Public interface ${wan} has the private address ${addr} (cloud NAT such as AWS, GCP or Oracle)."
            err "The abuse guard could cut this server off from its provider's network; use '${APP} abuse-guard on --force' to enable it anyway."
            return 1
        fi
    fi
    set_global_conf ABUSE_GUARD "$1"
    abuse_guard_apply
    if [[ $1 == yes ]]; then
        ok "Abuse guard enabled."
    else
        ok "Abuse guard disabled."
    fi
}

abuse_guard_status() {
    local wan gw state=$ABUSE_GUARD
    local -a ranges
    read -r wan gw <<<"$(wan_info)"
    if [[ $state == yes ]] && ! abuse_guard_intact; then
        state="yes (rules missing; the health monitor re-applies them)"
    fi
    kv "Abuse guard" "$state"
    kv "Public interface" "${wan:-none} (gateway ${gw:-none})"
    if [[ $ABUSE_GUARD == yes ]]; then
        kv "Dropped packets" "$(abuse_guard_drops)"
    fi
    kv "Blocked ranges" "(ABUSE_RANGES in ${GLOBAL_CONF})"
    read -r -a ranges <<<"$ABUSE_RANGES"
    printf '      %-17s %-17s %-17s\n' "${ranges[@]}"
}

# =============================================================================
#  Tunnel lifecycle (called by systemd through "up", "down" and "apply")
# =============================================================================

tunnel_up() {
    local name=$1 dev
    local -a args
    tunnel_load "$name"
    dev=$(dev_name "$name")
    modprobe ip_gre 2>/dev/null || true

    if ip link show "$dev" &>/dev/null; then
        ip link set "$dev" down 2>/dev/null || true
        ip tunnel del "$dev" 2>/dev/null || true
    fi

    args=(mode gre local "${T[LOCAL_IP]}" remote "${T[REMOTE_IP]}" ttl "${T[TTL]}")
    if [[ -n ${T[GRE_KEY]} ]]; then
        args+=(key "${T[GRE_KEY]}")
    fi
    ip tunnel add "$dev" "${args[@]}"
    ip link set "$dev" mtu "${T[MTU]}"
    ip addr add "${T[LOCAL_TUN_IP]}/${T[PREFIX]}" dev "$dev"
    if [[ ${T[IPV6]} == yes ]]; then
        ip -6 addr add "${T[LOCAL_TUN_IP6]}/64" dev "$dev" nodad 2>/dev/null ||
            warn "Could not add IPv6 address to ${dev} (is IPv6 disabled on this host?)"
    fi
    ip link set "$dev" up
    leak_guard add

    if [[ -n ${T[FORWARDS]} || ${T[NAT_OUT]} == yes ]]; then
        ensure_forwarding
    fi
    fw_apply
    if [[ $ABUSE_GUARD == yes ]] && ! abuse_guard_intact; then
        abuse_guard_apply
    fi
    rm -f "${STATE_DIR}/${name}.fails"
    ok "Tunnel ${name} up: ${dev} ${T[LOCAL_TUN_IP]} -> ${T[REMOTE_TUN_IP]} via ${T[REMOTE_IP]}"
}

tunnel_down() {
    local name=$1 dev
    dev=$(dev_name "$name")
    fw_clear "$name"
    if ip link show "$dev" &>/dev/null; then
        ip link set "$dev" down 2>/dev/null || true
        ip tunnel del "$dev" 2>/dev/null || ip link del "$dev" 2>/dev/null || true
    fi
    rm -f "${STATE_DIR}/${name}.fails"
    ok "Tunnel ${name} down"
}

# Re-applies firewall rules without recreating the interface.
tunnel_apply() {
    tunnel_load "$1"
    if [[ $(tunnel_state "$1") != up ]]; then
        info "Tunnel $1 is not up; rules will be applied when it starts."
        return 0
    fi
    if [[ -n ${T[FORWARDS]} || ${T[NAT_OUT]} == yes ]]; then
        ensure_forwarding
    fi
    fw_apply
    ok "Firewall rules of tunnel $1 applied."
}

svc_restart() {
    local unit
    unit=$(unit_name "$1")
    systemctl enable "$unit" >/dev/null 2>&1 || true
    if ! systemctl restart "$unit"; then
        err "Failed to start ${unit}. Recent log:"
        journalctl -u "$unit" -n 15 --no-pager >&2 || true
        return 1
    fi
}

# Stops a tunnel for good: unlike "down", this also drops its leak guard.
svc_remove() {
    systemctl disable --now "$(unit_name "$1")" >/dev/null 2>&1 || true
    tunnel_down "$1" >/dev/null
    if tunnel_exists "$1"; then
        (tunnel_load "$1" && leak_guard del) || true
    fi
}

# Prints up | down | missing.
tunnel_state() {
    local dev flags re='[<,]UP[,>]'
    dev=$(dev_name "$1")
    flags=$(ip link show "$dev" 2>/dev/null | head -n1) || true
    if [[ -z $flags ]]; then
        echo missing
    elif [[ $flags =~ $re ]]; then
        echo up
    else
        echo down
    fi
}

# ping_ms IP [count] — prints the average RTT or "-".
ping_ms() {
    local out
    out=$(ping -c "${2:-1}" -W 1 -q "$1" 2>/dev/null) || {
        echo "-"
        return 0
    }
    awk -F'/' '/^(rtt|round-trip)/ { printf "%.1f ms\n", $5 }' <<<"$out"
}

# =============================================================================
#  Commands shared by the CLI and the menu
# =============================================================================

# Validates the tunnel described in T, saves it and starts its unit.
tunnel_create() {
    local name=${T[NAME]} other rule
    local -a rules
    tunnel_defaults
    is_valid_name "$name" || die "Invalid name '${name}' (1-11 chars: letters, digits, '_' or '-')."
    ! tunnel_exists "$name" || die "Tunnel '${name}' already exists."
    [[ ${T[ROLE]} == iran || ${T[ROLE]} == kharej ]] || die "Role must be 'iran' or 'kharej'."
    is_tunnel_id "${T[ID]}" || die "Tunnel ID must be 1-254."
    T[ID]=$((10#${T[ID]}))
    other=$(tunnel_with_id "${T[ID]}")
    [[ -z $other ]] || die "Tunnel ID ${T[ID]} is already used by '${other}'."
    is_ipv4 "${T[LOCAL_IP]}" || die "Invalid local IP '${T[LOCAL_IP]}'."
    is_ipv4 "${T[REMOTE_IP]}" || die "Invalid remote IP '${T[REMOTE_IP]}'."
    [[ ${T[LOCAL_IP]} != "${T[REMOTE_IP]}" ]] || die "Local and remote IP must differ."
    is_mtu "${T[MTU]}" || die "MTU must be 576-9000."
    [[ -z ${T[GRE_KEY]} ]] || is_gre_key "${T[GRE_KEY]}" || die "GRE key must be 1-4294967295."
    other=$(tunnel_with_endpoints "${T[LOCAL_IP]}" "${T[REMOTE_IP]}" "${T[GRE_KEY]}")
    [[ -z $other ]] || die "Tunnel '${other}' already uses ${T[LOCAL_IP]} -> ${T[REMOTE_IP]} with the same GRE key. Set a distinct --key."

    if [[ -z ${T[LOCAL_TUN_IP]} ]]; then
        tunnel_compute_addresses
    fi
    { is_ipv4 "${T[LOCAL_TUN_IP]}" && is_ipv4 "${T[REMOTE_TUN_IP]}"; } ||
        die "Invalid inner addresses; check SUBNET_BASE in ${GLOBAL_CONF}."

    read -r -a rules <<<"${T[FORWARDS]}"
    T[FORWARDS]=""
    for rule in "${rules[@]}"; do
        forward_add "$rule" || exit 1
    done

    T[COMMENT]=${T[COMMENT]//[\"\\]/}
    T[CREATED]=$(date '+%F %T')
    tunnel_save
    ok "Tunnel '${name}' saved."
    svc_restart "$name" || warn "Tunnel saved but did not start; see '${APP} status ${name}'."
}

peer_command() {
    local peer_role=kharej peer_name
    [[ ${T[ROLE]} == kharej ]] && peer_role=iran
    peer_name="${T[ROLE]}${T[ID]}"
    printf '%s add --role %s --id %s --name %s --local %s --remote %s --mtu %s' \
        "$APP" "$peer_role" "${T[ID]}" "$peer_name" "${T[REMOTE_IP]}" "${T[LOCAL_IP]}" "${T[MTU]}"
    if [[ -n ${T[GRE_KEY]} ]]; then
        printf ' --key %s' "${T[GRE_KEY]}"
    fi
    if [[ ${T[IPV6]} == yes ]]; then
        printf ' --ipv6'
    fi
    if [[ ${T[LOCAL_TUN_IP]} != "${SUBNET_BASE}."* ]]; then
        printf ' --local-tun %s --remote-tun %s' "${T[REMOTE_TUN_IP]}" "${T[LOCAL_TUN_IP]}"
    fi
    echo
}

cmd_list() {
    local name state color latency
    local -a names fwd
    mapfile -t names < <(tunnel_names)
    if ((${#names[@]} == 0)); then
        info "No tunnels configured yet."
        return 0
    fi
    printf '\n  %s%-12s %-7s %-4s %-16s %-17s %-8s %-10s %s%s\n' "$C_BOLD" \
        NAME ROLE ID REMOTE_IP INNER_PEER STATE LATENCY FWD "$C_RESET"
    for name in "${names[@]}"; do
        tunnel_load "$name"
        state=$(tunnel_state "$name")
        latency="-"
        case $state in
            up) color=$C_GREEN latency=$(ping_ms "${T[REMOTE_TUN_IP]}") ;;
            down) color=$C_YELLOW ;;
            *) color=$C_RED ;;
        esac
        [[ $latency == "-" && $state == up ]] && color=$C_YELLOW state=no-ping
        read -r -a fwd <<<"${T[FORWARDS]}"
        printf '  %-12s %-7s %-4s %-16s %-17s %s%-8s%s %-10s %s\n' "$name" "${T[ROLE]}" "${T[ID]}" \
            "${T[REMOTE_IP]}" "${T[REMOTE_TUN_IP]}" "$color" "$state" "$C_RESET" "$latency" "${#fwd[@]}"
    done
    echo
}

cmd_status() {
    local name=$1 dev unit stats_dir rule
    local -a rules
    tunnel_load "$name"
    dev=$(dev_name "$name")
    unit=$(unit_name "$name")
    stats_dir="/sys/class/net/${dev}/statistics"

    section "Tunnel: ${name}"
    kv "Role" "${T[ROLE]}"
    kv "Tunnel ID" "${T[ID]}"
    kv "Device" "${dev} ($(tunnel_state "$name"))"
    kv "Underlay" "${T[LOCAL_IP]} -> ${T[REMOTE_IP]}"
    kv "Inner IPv4" "${T[LOCAL_TUN_IP]}/${T[PREFIX]} -> ${T[REMOTE_TUN_IP]}"
    if [[ ${T[IPV6]} == yes ]]; then
        kv "Inner IPv6" "${T[LOCAL_TUN_IP6]}/64 -> ${T[REMOTE_TUN_IP6]}"
    fi
    kv "MTU / TTL" "${T[MTU]} / ${T[TTL]}"
    kv "GRE key" "${T[GRE_KEY]:-none}"
    kv "MSS clamp" "${T[MSS_CLAMP]}"
    kv "NAT-out (gateway)" "${T[NAT_OUT]}"
    kv "Health monitor" "${T[MONITOR]}"
    kv "Firewall allow" "${T[FW_ALLOW]}"
    if [[ $(tunnel_state "$name") == up ]]; then
        if fw_intact; then
            kv "Firewall rules" "in place"
        else
            kv "Firewall rules" "missing or outranked (the health monitor re-applies them)"
        fi
    fi
    kv "Service" "$(systemctl is-active "$unit" 2>/dev/null || true) / $(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [[ -r ${stats_dir}/rx_bytes ]]; then
        kv "Traffic" "RX $(human_bytes "$(<"${stats_dir}/rx_bytes")")  TX $(human_bytes "$(<"${stats_dir}/tx_bytes")")"
    fi
    kv "Latency" "$(ping_ms "${T[REMOTE_TUN_IP]}" 3)"
    [[ -n ${T[COMMENT]} ]] && kv "Comment" "${T[COMMENT]}"
    kv "Created" "${T[CREATED]:-unknown}"

    read -r -a rules <<<"${T[FORWARDS]}"
    if ((${#rules[@]} > 0)); then
        printf '\n  %sPort forwards%s\n' "$C_BOLD" "$C_RESET"
        for rule in "${rules[@]}"; do
            printf '    %s\n' "$(forward_describe "$rule" "${T[REMOTE_TUN_IP]}")"
        done
    fi
    echo
}

# Largest ICMP payload that reaches IP without fragmentation, or empty.
find_pmtu_payload() {
    local ip=$1 lo=$2 hi=$3 mid best=""
    while ((lo <= hi)); do
        mid=$(((lo + hi) / 2))
        if ping -c1 -W1 -M "do" -s "$mid" "$ip" &>/dev/null; then
            best=$mid
            lo=$((mid + 1))
        else
            hi=$((mid - 1))
        fi
    done
    echo "$best"
}

cmd_test() {
    local name=$1 payload loss mtu
    tunnel_load "$name"
    section "Connectivity test: ${name}"

    info "Underlay ping ${T[REMOTE_IP]} ..."
    kv "Public RTT" "$(ping_ms "${T[REMOTE_IP]}" 4)"

    info "Tunnel ping ${T[REMOTE_TUN_IP]} ..."
    loss=$(ping -c 10 -i 0.2 -W 1 -q "${T[REMOTE_TUN_IP]}" 2>/dev/null | grep -oE '[0-9.]+% packet loss' || true)
    kv "Tunnel RTT" "$(ping_ms "${T[REMOTE_TUN_IP]}" 4)"
    kv "Tunnel loss" "${loss:-100% packet loss}"
    if [[ ${T[IPV6]} == yes ]]; then
        kv "Tunnel IPv6 RTT" "$(ping_ms "${T[REMOTE_TUN_IP6]}" 3)"
    fi

    info "Discovering path MTU (this takes a few seconds) ..."
    payload=$(find_pmtu_payload "${T[REMOTE_IP]}" 1200 1472)
    if [[ -n $payload ]]; then
        kv "Underlay PMTU" "$((payload + 28))  ->  recommended tunnel MTU $((payload + 28 - 24))"
    else
        kv "Underlay PMTU" "unknown (ICMP blocked?)"
    fi
    mtu=${T[MTU]}
    payload=$(find_pmtu_payload "${T[REMOTE_TUN_IP]}" 548 $((mtu - 28)))
    if [[ -n $payload ]]; then
        kv "Tunnel PMTU" "$((payload + 28)) (configured MTU ${mtu})"
        if ((payload + 28 < mtu)); then
            warn "Packets of the configured MTU do not pass; consider MTU $((payload + 28))."
        fi
    else
        kv "Tunnel PMTU" "no reply through the tunnel"
    fi
    echo
}

# Health check run by gre-manager-monitor.timer.
cmd_monitor() {
    local name fails fail_file
    mkdir -p "$STATE_DIR"
    for name in $(tunnel_names); do
        tunnel_load "$name"
        systemctl is-enabled --quiet "$(unit_name "$name")" 2>/dev/null || continue
        leak_guard add
        # "ufw reload", iptables-restore or anti-abuse scripts may wipe or outrank our rules.
        if [[ $(tunnel_state "$name") == up ]] && ! fw_intact; then
            log WARN "monitor: firewall rules of ${name} were removed or outranked; re-applying"
            fw_apply || log ERROR "monitor: re-applying firewall rules of ${name} failed"
        fi
        [[ ${T[MONITOR]} == yes ]] || continue
        fail_file="${STATE_DIR}/${name}.fails"
        if ping -c "$MONITOR_PING_COUNT" -W 2 -q "${T[REMOTE_TUN_IP]}" &>/dev/null; then
            rm -f "$fail_file"
            continue
        fi
        fails=$(($(cat "$fail_file" 2>/dev/null || echo 0) + 1))
        echo "$fails" >"$fail_file"
        log WARN "monitor: ${name} unreachable (${fails}/${MONITOR_FAILS})"
        if ((fails >= MONITOR_FAILS)); then
            log WARN "monitor: restarting ${name}"
            systemctl restart "$(unit_name "$name")" || log ERROR "monitor: restart of ${name} failed"
            rm -f "$fail_file"
        fi
    done
    if [[ $ABUSE_GUARD == yes ]] && ! abuse_guard_intact; then
        log WARN "monitor: abuse guard rules were missing; re-applying"
        abuse_guard_apply >/dev/null 2>&1 || log ERROR "monitor: re-applying the abuse guard failed"
    fi
}

monitor_enabled() { systemctl is-enabled --quiet "${APP}-monitor.timer" 2>/dev/null; }

monitor_set() {
    if [[ $1 == on ]]; then
        systemctl enable --now "${APP}-monitor.timer" >/dev/null
        ok "Health monitor enabled (every ${MONITOR_INTERVAL})."
    else
        systemctl disable --now "${APP}-monitor.timer" >/dev/null 2>&1 || true
        ok "Health monitor disabled."
    fi
}

cmd_optimize() {
    cat >"$SYSCTL_FILE" <<EOF
# Managed by ${APP}
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr module unavailable; BBR may not be active."
    sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "Some kernel settings could not be applied."
    ok "Kernel tuned: $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc), forwarding on, loose rp_filter."
}

backup_create() {
    local file
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    file="${BACKUP_DIR}/${APP}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$file" -C / "${CONF_DIR#/}"
    chmod 600 "$file"
    ok "Backup saved: ${file}"
}

backup_restore() {
    local file=$1 listing name
    [[ -f $file ]] || die "Backup file '${file}' not found."
    listing=$(tar -tzf "$file") || die "'${file}' is not a valid backup archive."
    if grep -Evq "^${CONF_DIR#/}(/|$)" <<<"$listing"; then
        die "Archive contains paths outside ${CONF_DIR}; refusing to restore."
    fi
    info "Saving the current configuration first ..."
    backup_create
    for name in $(tunnel_names); do
        svc_remove "$name"
    done
    rm -rf "$TUN_DIR"
    tar -xzf "$file" -C /
    load_global_conf
    for name in $(tunnel_names); do
        svc_restart "$name" || true
    done
    ok "Restored $(tunnel_names | wc -l) tunnel(s) from ${file}."
}

legacy_present() {
    [[ -f "${SYSTEMD_DIR}/${LEGACY_SERVICE}.service" ]] || ip link show "$LEGACY_DEV" &>/dev/null
}

legacy_remove() {
    systemctl disable --now "$LEGACY_SERVICE" >/dev/null 2>&1 || true
    ip tunnel del "$LEGACY_DEV" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${LEGACY_SERVICE}.service" "$LEGACY_SCRIPT"
    systemctl daemon-reload
    ok "Legacy tunnel ${LEGACY_DEV} removed."
}

# Converts the old gre2manager tunnel into a managed tunnel named "legacy",
# keeping its 20.0.0.x addresses so the other side keeps working unchanged.
legacy_import() {
    local local_ip remote_ip tun_ip
    [[ -r $LEGACY_SCRIPT ]] || die "Legacy script ${LEGACY_SCRIPT} not found; nothing to import."
    local_ip=$(strip_quotes "$(sed -n 's/^LOCAL_IP=//p' "$LEGACY_SCRIPT")")
    remote_ip=$(strip_quotes "$(sed -n 's/^REMOTE_IP=//p' "$LEGACY_SCRIPT")")
    tun_ip=$(strip_quotes "$(sed -n 's/^TUN_IP=//p' "$LEGACY_SCRIPT")")
    { is_ipv4 "$local_ip" && is_ipv4 "$remote_ip" && is_ipv4 "${tun_ip%/*}"; } ||
        die "Could not parse the legacy configuration."
    legacy_remove

    T=()
    T[NAME]=legacy
    T[ID]=$(next_free_id)
    T[LOCAL_IP]=$local_ip
    T[REMOTE_IP]=$remote_ip
    T[LOCAL_TUN_IP]=${tun_ip%/*}
    if [[ ${tun_ip%/*} == *.1 ]]; then
        T[ROLE]=iran T[REMOTE_TUN_IP]=${tun_ip%.1/*}.2
    else
        T[ROLE]=kharej T[REMOTE_TUN_IP]=${tun_ip%.2/*}.1
    fi
    T[COMMENT]="Imported from gre2manager"
    tunnel_create
}

uninstall_all() {
    local name purge=${1:-no}
    for name in $(tunnel_names); do
        svc_remove "$name"
    done
    systemctl disable --now "${APP}-monitor.timer" >/dev/null 2>&1 || true
    abuse_guard_clear
    rm -f "$UNIT_TEMPLATE" "$MONITOR_SERVICE" "$MONITOR_TIMER" "$SYSCTL_FILE" "$INSTALL_PATH"
    systemctl daemon-reload
    if [[ $purge == yes ]]; then
        rm -rf "$CONF_DIR" "$BACKUP_DIR"
        ok "${APP} and all of its data removed."
        rm -f "$LOG_FILE"
    else
        ok "${APP} removed. Configuration kept in ${CONF_DIR} (reinstall to restore tunnels)."
    fi
}

# =============================================================================
#  Interactive menu
# =============================================================================

# Runs a menu action in a subshell so that a failure returns to the menu.
run_action() {
    local rc
    set +e
    (
        set -e
        "$@"
    )
    rc=$?
    set -e
    ((rc == 0)) || warn "Action finished with errors (exit ${rc})."
    pause
}

# select_tunnel VAR [allow_all]  — VAR receives a name, or '*' for all.
select_tunnel() {
    local __var=$1 __allow_all=${2:-} __choice __i
    local -a __names
    mapfile -t __names < <(tunnel_names)
    if ((${#__names[@]} == 0)); then
        warn "No tunnels configured yet."
        return 1
    fi
    echo
    for __i in "${!__names[@]}"; do
        printf '   %2d) %-12s %-7s -> %s\n' $((__i + 1)) "${__names[__i]}" \
            "$(conf_get "${__names[__i]}" ROLE)" "$(conf_get "${__names[__i]}" REMOTE_IP)"
    done
    [[ -n $__allow_all ]] && printf '    a) All tunnels\n'
    printf '    0) Back\n'
    read -r -p "  Select tunnel: " __choice || return 1
    if [[ -n $__allow_all && $__choice == a ]]; then
        printf -v "$__var" '%s' '*'
    elif tunnel_exists "$__choice"; then
        printf -v "$__var" '%s' "$__choice"
    elif [[ $__choice =~ ^[0-9]+$ ]] && ((__choice >= 1 && __choice <= ${#__names[@]})); then
        printf -v "$__var" '%s' "${__names[__choice - 1]}"
    else
        return 1
    fi
}

print_banner() {
    local total=0 up=0 name monitor=off
    for name in $(tunnel_names); do
        total=$((total + 1))
        [[ $(tunnel_state "$name") == up ]] && up=$((up + 1))
    done
    monitor_enabled && monitor=on
    clear 2>/dev/null || true
    printf '%s' "$C_CYAN$C_BOLD"
    printf '  ╔══════════════════════════════════════════════╗\n'
    printf '  ║          GRE Tunnel Manager  v%-15s║\n' "$VERSION"
    printf '  ║      Iran  ⇄  Kharej  ·  one-to-many         ║\n'
    printf '  ╚══════════════════════════════════════════════╝\n'
    printf '%s' "$C_RESET"
    printf '  Host: %s%s%s   Tunnels: %s%d up%s / %d   Monitor: %s   Abuse guard: %s\n\n' \
        "$C_BOLD" "$(hostname 2>/dev/null || echo '?')" "$C_RESET" "$C_GREEN" "$up" "$C_RESET" "$total" \
        "$monitor" "$ABUSE_GUARD"
}

ui_add() {
    local role peer_role name id local_ip remote_ip mtu key def_ip spec
    section "Add GRE tunnel"
    printf '   1) Iran    (entry server; can connect to many Kharej servers)\n'
    printf '   2) Kharej  (exit server)\n\n'
    ask role "Role of THIS server" 1 is_role_choice
    if [[ $role == 1 ]]; then
        role=iran peer_role=kharej
    else
        role=kharej peer_role=iran
    fi

    info "The tunnel ID selects subnet ${SUBNET_BASE}.<ID>.0/30 and must be the SAME on both servers."
    ask id "Tunnel ID (1-254)" "$(next_free_id || true)" is_free_tunnel_id
    id=$((10#$id))
    ask name "Tunnel name (usually the peer's name)" "$(default_name "$peer_role" "$id")" is_new_tunnel_name

    info "Detecting this server's public IPv4 ..."
    def_ip=$(detect_public_ip || true)
    ask local_ip "This server's public IPv4" "$def_ip" is_ipv4
    ask remote_ip "${peer_role^} server's public IPv4" "" is_ipv4
    [[ $remote_ip != "$local_ip" ]] || die "Peer IP must differ from this server's IP."
    ask mtu "MTU" "$DEFAULT_MTU" is_mtu
    ask key "GRE key (number, or 'none'; needed for several tunnels between the same two servers)" none is_gre_key_opt
    [[ $key == none ]] && key=""

    T=()
    T[NAME]=$name T[ROLE]=$role T[ID]=$id T[LOCAL_IP]=$local_ip T[REMOTE_IP]=$remote_ip
    T[MTU]=$mtu T[GRE_KEY]=$key
    tunnel_defaults
    confirm "Enable IPv6 inside the tunnel (${SUBNET6_BASE}:${id}::/64)?" n && T[IPV6]=yes
    confirm "Enable TCP MSS clamping (recommended)?" y || T[MSS_CLAMP]=no
    if [[ $role == iran ]]; then
        info "Port forwarding sends traffic arriving on this server's ports to the Kharej server."
        info "Format: proto:port[-port][>target]  e.g. tcp:443  both:8443  tcp:2000-2100  tcp:2222>22"
        while true; do
            ask spec "Port to forward (empty to finish)" "" ""
            [[ -n $spec ]] || break
            forward_add "$spec" || true
        done
    else
        confirm "Let the Iran side use this server as its internet gateway (NAT-out)?" n && T[NAT_OUT]=yes
    fi

    echo
    tunnel_create
    printf '\n%sNext step — run on the peer server:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$(peer_command)"
}

ui_details() {
    local name
    select_tunnel name || return 0
    cmd_status "$name"
    printf '  %sRecent service log%s\n' "$C_BOLD" "$C_RESET"
    journalctl -u "$(unit_name "$name")" -n 8 --no-pager -o short 2>/dev/null | sed 's/^/    /' || true
}

toggle() {
    if [[ ${T[$1]} == yes ]]; then T[$1]=no; else T[$1]=yes; fi
}

ui_edit() {
    local name choice value other
    select_tunnel name || return 0
    tunnel_load "$name"
    EXCEPT_NAME=$name
    while true; do
        section "Edit tunnel: ${name}"
        printf '   1) Peer public IP ....... %s\n' "${T[REMOTE_IP]}"
        printf '   2) Local public IP ...... %s\n' "${T[LOCAL_IP]}"
        printf '   3) Tunnel ID ............ %s  (%s -> %s)\n' "${T[ID]}" "${T[LOCAL_TUN_IP]}" "${T[REMOTE_TUN_IP]}"
        printf '   4) MTU .................. %s\n' "${T[MTU]}"
        printf '   5) GRE key .............. %s\n' "${T[GRE_KEY]:-none}"
        printf '   6) IPv6 in tunnel ....... %s\n' "${T[IPV6]}"
        printf '   7) MSS clamping ......... %s\n' "${T[MSS_CLAMP]}"
        printf '   8) NAT-out (gateway) .... %s\n' "${T[NAT_OUT]}"
        printf '   9) Health monitor ....... %s\n' "${T[MONITOR]}"
        printf '  10) Firewall allow rules . %s\n' "${T[FW_ALLOW]}"
        printf '  11) Comment .............. %s\n' "${T[COMMENT]:--}"
        printf '\n   s) Save & apply    0) Cancel\n'
        read -r -p "  Select: " choice || return 0
        case $choice in
            1) ask value "Peer public IP" "${T[REMOTE_IP]}" is_ipv4 && T[REMOTE_IP]=$value ;;
            2) ask value "Local public IP" "${T[LOCAL_IP]}" is_ipv4 && T[LOCAL_IP]=$value ;;
            3)
                warn "Changing the ID changes the inner addresses; update the peer too."
                ask value "Tunnel ID" "${T[ID]}" is_free_tunnel_id
                T[ID]=$((10#$value))
                tunnel_compute_addresses
                ;;
            4) ask value "MTU" "${T[MTU]}" is_mtu && T[MTU]=$value ;;
            5)
                ask value "GRE key (number or 'none')" "${T[GRE_KEY]:-none}" is_gre_key_opt
                [[ $value == none ]] && value=""
                T[GRE_KEY]=$value
                ;;
            6) toggle IPV6 ;;
            7) toggle MSS_CLAMP ;;
            8) toggle NAT_OUT ;;
            9) toggle MONITOR ;;
            10) toggle FW_ALLOW ;;
            11)
                ask value "Comment" "${T[COMMENT]}" ""
                T[COMMENT]=${value//[\"\\]/}
                ;;
            s | S)
                other=$(tunnel_with_endpoints "${T[LOCAL_IP]}" "${T[REMOTE_IP]}" "${T[GRE_KEY]}")
                [[ -z $other ]] || die "Tunnel '${other}' already uses the same endpoints and GRE key."
                # Drop the leak guard of the saved config; the new one is added on start.
                (tunnel_load "$name" && leak_guard del) || true
                tunnel_save
                svc_restart "$name"
                ok "Tunnel '${name}' updated."
                if [[ -t 1 ]]; then
                    printf '  If you changed shared settings, update the peer to match:\n  %s\n' "$(peer_command)"
                fi
                return 0
                ;;
            0) info "Changes discarded." && return 0 ;;
            *) warn "Invalid option" ;;
        esac
    done
}

ui_remove() {
    local name target
    select_tunnel target all || return 0
    if [[ $target == '*' ]]; then
        confirm "Remove ALL tunnels?" n || return 0
        for name in $(tunnel_names); do
            svc_remove "$name"
            rm -f "$(conf_file "$name")"
        done
        ok "All tunnels removed."
    else
        confirm "Remove tunnel '${target}'?" n || return 0
        svc_remove "$target"
        rm -f "$(conf_file "$target")"
        ok "Tunnel '${target}' removed."
    fi
}

ui_restart() {
    local name target
    select_tunnel target all || return 0
    if [[ $target == '*' ]]; then
        for name in $(tunnel_names); do
            svc_restart "$name" && ok "Restarted ${name}" || true
        done
    else
        svc_restart "$target"
        ok "Restarted ${target}"
    fi
}

ui_forwards() {
    local name choice spec rule i
    local -a rules
    select_tunnel name || return 0
    tunnel_load "$name"
    while true; do
        section "Port forwarding: ${name}  (to ${T[REMOTE_TUN_IP]})"
        read -r -a rules <<<"${T[FORWARDS]}"
        if ((${#rules[@]} == 0)); then
            printf '   (no rules)\n'
        fi
        for i in "${!rules[@]}"; do
            printf '   %2d) %s\n' $((i + 1)) "$(forward_describe "${rules[i]}" "${T[REMOTE_TUN_IP]}")"
        done
        printf '\n   a) Add rule   d) Delete rule   c) Clear all   s) Save & apply   0) Cancel\n'
        read -r -p "  Select: " choice || return 0
        case $choice in
            a | A)
                printf '   Format: proto:port[-port][>target]  e.g. tcp:443  both:8443  tcp:2000-2100  tcp:2222>22\n'
                ask spec "Rule" "" is_forward_spec
                forward_add "$spec" || true
                ;;
            d | D)
                ask i "Rule number to delete" "" is_uint
                if ((i >= 1 && i <= ${#rules[@]})); then
                    forward_del "${rules[i - 1]}" || true
                else
                    warn "No rule #${i}"
                fi
                ;;
            c | C) confirm "Delete all rules of '${name}'?" n && T[FORWARDS]="" ;;
            s | S)
                tunnel_save
                systemctl reload "$(unit_name "$name")" 2>/dev/null || tunnel_apply "$name"
                ok "Port forwarding of '${name}' saved and applied."
                return 0
                ;;
            0) info "Changes discarded." && return 0 ;;
            *) warn "Invalid option" ;;
        esac
    done
}

ui_test() {
    local name
    select_tunnel name || return 0
    cmd_test "$name"
}

ui_monitor() {
    local choice
    section "Health monitor"
    kv "Timer" "$(monitor_enabled && echo enabled || echo disabled), every ${MONITOR_INTERVAL}"
    kv "Restart after" "${MONITOR_FAILS} failed checks"
    printf '\n  %sRecent events%s\n' "$C_BOLD" "$C_RESET"
    grep -h 'monitor:' "$LOG_FILE" 2>/dev/null | tail -n 8 | sed 's/^/    /' || true
    printf '\n   1) Enable   2) Disable   3) Run a check now   0) Back\n'
    read -r -p "  Select: " choice || return 0
    case $choice in
        1) monitor_set on ;;
        2) monitor_set off ;;
        3) cmd_monitor && ok "Check finished; see events above next time." ;;
        *) return 0 ;;
    esac
}

ui_optimize() {
    section "Kernel optimization"
    kv "Congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    kv "Queue discipline" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    kv "IPv4 forwarding" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
    echo
    confirm "Apply BBR + fq, IP forwarding, loose rp_filter and larger TCP buffers?" y || return 0
    cmd_optimize
}

ui_backup() {
    local choice file i
    local -a files
    section "Backup / Restore"
    printf '   1) Create backup   2) Restore backup   0) Back\n'
    read -r -p "  Select: " choice || return 0
    case $choice in
        1) backup_create ;;
        2)
            files=("${BACKUP_DIR}"/*.tar.gz)
            if ((${#files[@]} == 0)); then
                warn "No backups in ${BACKUP_DIR}."
                ask file "Path to a backup archive" "" ""
                [[ -n $file ]] || return 0
            else
                for i in "${!files[@]}"; do
                    printf '   %2d) %s\n' $((i + 1)) "${files[i]##*/}"
                done
                ask i "Backup number" "${#files[@]}" is_uint
                ((i >= 1 && i <= ${#files[@]})) || die "No backup #${i}"
                file=${files[i - 1]}
            fi
            confirm "Replace all current tunnels with '${file##*/}'?" n || return 0
            backup_restore "$file"
            ;;
    esac
}

ui_abuse_guard() {
    local choice
    section "Abuse guard"
    printf '  Drops packets to private/reserved ranges that would leave the public\n'
    printf '  interface; providers such as Hetzner report them as "netscan" abuse.\n'
    printf '  Tunnel traffic is not affected.\n\n'
    abuse_guard_status
    printf '\n   1) Enable   2) Disable   0) Back\n'
    read -r -p "  Select: " choice || return 0
    case $choice in
        1) abuse_guard_set yes || { confirm "Enable it anyway?" n && abuse_guard_set yes force; } ;;
        2) abuse_guard_set no ;;
    esac
}

ui_logs() {
    section "Log: ${LOG_FILE}"
    tail -n 30 "$LOG_FILE" 2>/dev/null || info "Log is empty."
    section "systemd journal"
    journalctl -u "${APP}@*" -u "${APP}-monitor.service" -n 20 --no-pager 2>/dev/null || true
}

ui_update() {
    section "Update ${APP}"
    if cmd_update && [[ $SELF_UPDATED -eq 1 ]]; then
        info "Restarting the menu with the new version ..."
        exec "$INSTALL_PATH" menu
    fi
    pause
}

ui_uninstall() {
    section "Uninstall ${APP}"
    confirm "Stop and remove all tunnels, services and the ${APP} command?" n || return 0
    if confirm "Also delete configuration, backups and logs?" n; then
        uninstall_all yes
    else
        uninstall_all no
    fi
    exit 0
}

check_legacy() {
    legacy_present || return 0
    warn "A tunnel created by the old gre2manager script (${LEGACY_DEV}) is active."
    printf '   1) Import it as tunnel "legacy" (keeps 20.0.0.x addresses)\n'
    printf '   2) Remove it\n'
    printf '   3) Leave it for now\n'
    local choice
    read -r -p "  Select: " choice || return 0
    case $choice in
        1) run_action legacy_import ;;
        2) run_action legacy_remove ;;
    esac
}

main_menu() {
    local choice
    check_legacy
    while true; do
        load_global_conf
        print_banner
        printf '  %sTunnels%s\n' "$C_BOLD" "$C_RESET"
        printf '    1) Add tunnel             4) Edit tunnel\n'
        printf '    2) List tunnels           5) Remove tunnel\n'
        printf '    3) Tunnel details         6) Restart tunnel(s)\n'
        printf '\n  %sTraffic%s\n' "$C_BOLD" "$C_RESET"
        printf '    7) Port forwarding        8) Connectivity & MTU test\n'
        printf '\n  %sSystem%s\n' "$C_BOLD" "$C_RESET"
        printf '    9) Health monitor        13) Logs\n'
        printf '   10) Abuse guard           14) Update %s\n' "$APP"
        printf '   11) Kernel optimization   15) Uninstall\n'
        printf '   12) Backup / Restore\n'
        printf '\n    0) Exit\n\n'
        read -r -p "  Select: " choice || exit 0
        case $choice in
            1) run_action ui_add ;;
            2) run_action cmd_list ;;
            3) run_action ui_details ;;
            4) run_action ui_edit ;;
            5) run_action ui_remove ;;
            6) run_action ui_restart ;;
            7) run_action ui_forwards ;;
            8) run_action ui_test ;;
            9) run_action ui_monitor ;;
            10) run_action ui_abuse_guard ;;
            11) run_action ui_optimize ;;
            12) run_action ui_backup ;;
            13) run_action ui_logs ;;
            14) ui_update ;;
            15) ui_uninstall ;;
            0 | q | Q) exit 0 ;;
            *) warn "Invalid option" && sleep 1 ;;
        esac
    done
}

# =============================================================================
#  Command line interface
# =============================================================================

usage() {
    cat <<EOF
${APP} ${VERSION} — GRE tunnel manager (one Iran server <-> many Kharej servers)

Usage: ${APP} [command] [arguments]
Without a command the interactive menu starts.

Tunnels
  add [options]                  Create a tunnel non-interactively (see below)
  list                           List tunnels with live state and latency
  status [name]                  Details of one tunnel (all when omitted)
  restart <name|--all>           Restart tunnel(s)
  remove <name|--all>            Delete tunnel(s)
  test <name>                    Ping, packet loss and path-MTU test

Traffic
  forward <name> list            Show port-forward rules
  forward <name> add <spec>...   Add rules, e.g. tcp:443 both:8443 tcp:2222>22
  forward <name> del <spec>...   Delete rules
  forward <name> clear           Delete all rules

System
  monitor [--enable|--disable]   Run the health check once, or toggle its timer
  abuse-guard [on|off] [--force] Drop private ranges leaving the public interface
  optimize                       Enable BBR, forwarding and TCP tuning
  backup                         Save configuration to ${BACKUP_DIR}
  restore <file>                 Restore configuration from a backup
  update                         Install the latest version from GitHub
  uninstall [--purge]            Remove everything (--purge also deletes config)
  up|down|apply <name>           Low-level actions used by systemd
  version | help

Options for "add"
  --role iran|kharej     Role of THIS server                       (required)
  --remote IP            Public IPv4 of the peer                   (required)
  --id N                 Tunnel ID 1-254, same on both servers     (default: next free)
  --name NAME            Tunnel name                               (default: <peer-role><id>)
  --local IP             Public IPv4 of this server                (default: auto-detect)
  --mtu N                Tunnel MTU                                (default: ${DEFAULT_MTU})
  --key N                GRE key (needed for several tunnels between the same servers)
  --ipv6                 Add IPv6 addresses inside the tunnel
  --no-mss-clamp         Disable TCP MSS clamping
  --nat-out              Let the peer use this server as internet gateway
  --no-monitor           Exclude this tunnel from the health monitor
  --no-fw-allow          Don't add INPUT/OUTPUT accept rules (let ufw/iptables filter the tunnel)
  --forward "SPECS"      Port forwards, e.g. "tcp:443 udp:51820"
  --local-tun IP --remote-tun IP   Custom inner addresses instead of ${SUBNET_BASE}.<id>.x/30
  --comment TEXT         Free-form note

Forward spec:  proto:port[-port][>target_port]    proto = tcp | udp | both

Example (one Iran server, two Kharej servers):
  Iran:     ${APP} add --role iran --id 1 --remote 203.0.113.10 --forward "tcp:443"
            ${APP} add --role iran --id 2 --remote 198.51.100.20 --forward "tcp:8443>443"
  Kharej 1: ${APP} add --role kharej --id 1 --remote <iran-ip>
  Kharej 2: ${APP} add --role kharej --id 2 --remote <iran-ip>
EOF
}

need_arg() {
    [[ -n ${2:-} ]] || die "Missing argument: $1. See '${APP} help'."
}

need_tunnel() {
    need_arg "tunnel name" "${1:-}"
    tunnel_exists "$1" || die "Tunnel '$1' does not exist. Existing: $(tunnel_names | xargs)"
}

cmd_add() {
    local peer_role
    T=()
    while (($# > 0)); do
        case $1 in
            --role) need_arg "$1" "${2:-}" && T[ROLE]=${2,,} && shift ;;
            --id) need_arg "$1" "${2:-}" && T[ID]=$2 && shift ;;
            --name) need_arg "$1" "${2:-}" && T[NAME]=$2 && shift ;;
            --local) need_arg "$1" "${2:-}" && T[LOCAL_IP]=$2 && shift ;;
            --remote) need_arg "$1" "${2:-}" && T[REMOTE_IP]=$2 && shift ;;
            --mtu) need_arg "$1" "${2:-}" && T[MTU]=$2 && shift ;;
            --key) need_arg "$1" "${2:-}" && T[GRE_KEY]=$2 && shift ;;
            --forward) need_arg "$1" "${2:-}" && T[FORWARDS]=$2 && shift ;;
            --local-tun) need_arg "$1" "${2:-}" && T[LOCAL_TUN_IP]=$2 && shift ;;
            --remote-tun) need_arg "$1" "${2:-}" && T[REMOTE_TUN_IP]=$2 && shift ;;
            --comment) need_arg "$1" "${2:-}" && T[COMMENT]=$2 && shift ;;
            --ipv6) T[IPV6]=yes ;;
            --no-mss-clamp) T[MSS_CLAMP]=no ;;
            --nat-out) T[NAT_OUT]=yes ;;
            --no-monitor) T[MONITOR]=no ;;
            --no-fw-allow) T[FW_ALLOW]=no ;;
            *) die "Unknown option for add: $1" ;;
        esac
        shift
    done

    [[ -n ${T[ROLE]:-} ]] || die "--role is required (iran or kharej)."
    [[ -n ${T[REMOTE_IP]:-} ]] || die "--remote is required."
    [[ -n ${T[LOCAL_TUN_IP]:-} && -z ${T[REMOTE_TUN_IP]:-} ]] && die "--local-tun needs --remote-tun."
    if [[ -z ${T[ID]:-} ]]; then
        T[ID]=$(next_free_id) || die "No free tunnel IDs left."
    fi
    peer_role=kharej
    [[ ${T[ROLE]} == kharej ]] && peer_role=iran
    if [[ -z ${T[NAME]:-} ]]; then
        T[NAME]=$(default_name "$peer_role" "${T[ID]}")
    fi
    if [[ -z ${T[LOCAL_IP]:-} ]]; then
        T[LOCAL_IP]=$(detect_public_ip) || die "Could not detect the public IP; pass --local."
    fi
    tunnel_create
    printf '\nRun on the peer server:\n  %s\n' "$(peer_command)"
}

cmd_forward() {
    local name=${1:-} action=${2:-list} spec rule
    local -a rules
    need_tunnel "$name"
    shift 2 || shift $#
    tunnel_load "$name"
    case $action in
        list)
            read -r -a rules <<<"${T[FORWARDS]}"
            ((${#rules[@]} > 0)) || info "No port-forward rules on '${name}'."
            for rule in "${rules[@]}"; do
                printf '  %-18s %s\n' "$rule" "$(forward_describe "$rule" "${T[REMOTE_TUN_IP]}")"
            done
            return 0
            ;;
        add)
            (($# > 0)) || die "Usage: ${APP} forward ${name} add <spec>..."
            for spec in "$@"; do forward_add "$spec" || exit 1; done
            ;;
        del | delete | rm)
            (($# > 0)) || die "Usage: ${APP} forward ${name} del <spec>..."
            for spec in "$@"; do forward_del "$spec" || exit 1; done
            ;;
        clear) T[FORWARDS]="" ;;
        *) die "Unknown forward action '${action}' (list, add, del, clear)." ;;
    esac
    tunnel_save
    tunnel_apply "$name"
}

cmd_for_each() {
    local fn=$1 target=${2:-} name rc=0
    if [[ $target == --all ]]; then
        for name in $(tunnel_names); do
            "$fn" "$name" || rc=1
        done
        return "$rc"
    else
        need_tunnel "$target"
        "$fn" "$target"
    fi
}

remove_tunnel() {
    svc_remove "$1"
    rm -f "$(conf_file "$1")"
    ok "Tunnel '$1' removed."
}

restart_tunnel() {
    svc_restart "$1" && ok "Restarted $1"
}

main() {
    local cmd=${1:-menu} name
    [[ $# -gt 0 ]] && shift

    case $cmd in
        -h | --help | help) usage && return 0 ;;
        -v | --version | version) echo "${APP} ${VERSION}" && return 0 ;;
    esac

    require_root
    load_global_conf
    mkdir -p "$STATE_DIR"

    # Called by systemd: keep these free of locking and package installs.
    case $cmd in
        up) need_tunnel "${1:-}" && tunnel_up "$1" && return 0 ;;
        down) need_arg "tunnel name" "${1:-}" && tunnel_down "$1" && return 0 ;;
        apply) need_tunnel "${1:-}" && tunnel_apply "$1" && return 0 ;;
        monitor)
            if [[ -z ${1:-} ]]; then
                cmd_monitor
                return 0
            fi
            ;;
    esac

    bootstrap
    acquire_lock
    case $cmd in
        menu) main_menu ;;
        add) cmd_add "$@" ;;
        list | ls) cmd_list ;;
        status)
            if [[ -n ${1:-} ]]; then
                need_tunnel "$1"
                cmd_status "$1"
            else
                for name in $(tunnel_names); do cmd_status "$name"; done
            fi
            ;;
        restart) cmd_for_each restart_tunnel "${1:-}" || exit 1 ;;
        remove | rm | delete) cmd_for_each remove_tunnel "${1:-}" || exit 1 ;;
        test) need_tunnel "${1:-}" && cmd_test "$1" ;;
        forward | fw) cmd_forward "$@" ;;
        monitor)
            case $1 in
                --enable | on) monitor_set on ;;
                --disable | off) monitor_set off ;;
                *) die "Usage: ${APP} monitor [--enable|--disable]" ;;
            esac
            ;;
        abuse-guard)
            case ${1:-status} in
                on | --enable) abuse_guard_set yes "$([[ ${2:-} == --force ]] && echo force)" || exit 1 ;;
                off | --disable) abuse_guard_set no ;;
                status) abuse_guard_status ;;
                *) die "Usage: ${APP} abuse-guard [on|off|status] [--force]" ;;
            esac
            ;;
        optimize) cmd_optimize ;;
        backup) backup_create ;;
        restore) need_arg "backup file" "${1:-}" && backup_restore "$1" ;;
        import-legacy) legacy_import ;;
        update) cmd_update || exit 1 ;;
        uninstall)
            if [[ ${1:-} == --purge ]]; then uninstall_all yes; else uninstall_all no; fi
            ;;
        *)
            usage >&2
            die "Unknown command: ${cmd}"
            ;;
    esac
}

main "$@"
