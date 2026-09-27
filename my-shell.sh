#!/bin/sh
# =============================================================================
#  my-shell -- portable developer workstation setup
# =============================================================================
#  The body of this file is bash. Minimal distributions (Alpine, debootstrap
#  images, distroless CI images) do not ship bash at all, so the kernel cannot
#  even exec this file. This preamble is deliberately POSIX so that it always
#  runs; it makes sure a bash exists and then hands over to it.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        _ms_root=""
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            _ms_root="sudo"
        fi
        _ms_ok=0
        for _ms_mgr in apk dnf yum apt-get zypper pacman xbps-install emerge; do
            command -v "$_ms_mgr" >/dev/null 2>&1 || continue
            # shellcheck disable=SC2086
            case "$_ms_mgr" in
                apk)          $_ms_root apk add --no-cache bash >/dev/null 2>&1 ;;
                dnf)          $_ms_root dnf install -y bash >/dev/null 2>&1 ;;
                yum)          $_ms_root yum install -y bash >/dev/null 2>&1 ;;
                apt-get)      $_ms_root apt-get install -y bash >/dev/null 2>&1 ;;
                zypper)       $_ms_root zypper --non-interactive install bash >/dev/null 2>&1 ;;
                pacman)       $_ms_root pacman -S --needed --noconfirm bash >/dev/null 2>&1 ;;
                xbps-install) $_ms_root xbps-install -y bash >/dev/null 2>&1 ;;
                emerge)       emerge bash >/dev/null 2>&1 ;;
            esac
            if command -v bash >/dev/null 2>&1; then _ms_ok=1; break; fi
        done
        if [ "$_ms_ok" -ne 1 ]; then
            echo "my-shell: bash is required and could not be installed automatically." >&2
            echo "          install it by hand (apt install bash / apk add bash / ...)" >&2
            echo "          and re-run this script." >&2
            exit 1
        fi
    fi
    # Hand over to bash. This branch is skipped when bash is already running
    # the file; an unconditional exec here would re-exec the script forever.
    exec bash "$0" "$@"
fi

# =============================================================================
#  Everything below this line is bash (>= 4.0).
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="my-shell"
readonly SCRIPT_VERSION="2.1.0"

# Resolve paths relative to the script, never to $PWD: the original version used
# `./config_files/...` and silently failed when started from another directory.
SCRIPT_PATH="${BASH_SOURCE[0]}"
REPO_ROOT="$(cd -- "$(dirname -- "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
readonly REPO_ROOT
readonly CONFIG_DIR="$REPO_ROOT/config_files"

# -----------------------------------------------------------------------------
# Managed-block markers. Every change this script makes to a dotfile lives
# between these two lines, so re-running never duplicates anything.
# -----------------------------------------------------------------------------
readonly MB_BEGIN="# >>> ${SCRIPT_NAME} managed block >>>"
readonly MB_END="# <<< ${SCRIPT_NAME} managed block <<<"

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
NO_COLOR_FLAG=0
UPGRADE_SYSTEM=0
SET_DEFAULT_SHELL=0
# Steps that failed without stopping the run: a download that would not
# complete, a block that could not be written. The run always goes to the end,
# but the exit status has to tell the caller that something did not happen.
RUN_FAILURES=0
# Problems per section, filled in by run_sections.
declare -A SECTION_FAILURES=()
REPLACE_P10K=0
INSTALL_KUBE_PS1=0
PROMPT_ENGINE="powerlevel10k"
FONT_SET="both"
TARGET_SHELL=""
FONT_INSTALL_DIR="/usr/local/share/fonts"
BACKUP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/my-shell/backups"
NERD_FONT_VERSION=""
KUBECTL_VERSION=""
KUBECTX_VERSION=""
STERN_VERSION=""

EXTRA_PACKAGES=()
WANTED_SECTIONS=()
SKIP_SECTIONS=()
_argv_list=()

# Tool manifest: the declarative list of what a machine should end up with.
TOOL_MANIFEST="$CONFIG_DIR/tools.conf"
TOOL_SELECTION=()
SKIP_TOOLS=()
EXTRAS_PROFILES=()
USE_AUR=0
AUR_HELPER=""

OS_ID=""
OS_ID_LIKE=""
OS_NAME=""
OS_VERSION=""
PKG_MANAGER=""
PKG_OVERRIDE=""
PKG_REFRESHED=0
GOOS=""
GOARCH=""
TARGET_ARCH=""
SUDO=()
TMPDIR_ME=""

ZSH_RC=""
OMZ_DIR=""

declare -A SECTION_ON=()
readonly ALL_SECTIONS=(deps fonts zsh plugins theme k8s vim git extras shell)
readonly OPTIONAL_SECTIONS=(git extras shell)

# Colour globals, filled in by setup_colors().
C_RED="" C_GRN="" C_YEL="" C_BLU="" C_MAG="" C_DIM="" C_BLD="" C_OFF=""

# =============================================================================
#  Logging
# =============================================================================
setup_colors() {
    local enable=0
    if (( NO_COLOR_FLAG == 0 )) && [[ -t 1 ]] && [[ ${TERM:-dumb} != "dumb" ]]; then
        enable=1
    fi
    if (( enable )); then
        C_RED=$'\033[0;31m'
        C_GRN=$'\033[0;32m'
        C_YEL=$'\033[0;33m'
        C_BLU=$'\033[0;34m'
        C_MAG=$'\033[0;35m'
        C_DIM=$'\033[0;90m'
        C_BLD=$'\033[1m'
        C_OFF=$'\033[0m'
    fi
}

log_info() { printf '%s[ info]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
log_ok()   { printf '%s[  ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
log_warn() { printf '%s[ warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
log_err()  { printf '%s[ fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; RUN_FAILURES=$(( RUN_FAILURES + 1 )); }
log_skip() { printf '%s[ skip]%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
log_dry()  { printf '%s[dry  ]%s %s\n' "$C_MAG" "$C_OFF" "$*"; }
# log_done: "this has been done". During a dry run nothing was done, so the
# message must not claim success.
log_done() {
    if (( DRY_RUN )); then
        log_dry "$*"
    else
        log_ok "$*"
    fi
}
log_step() { printf '\n%s==>%s %s%s%s\n' "$C_BLD" "$C_OFF" "$C_BLD" "$*" "$C_OFF"; }
log_debug() {
    if (( VERBOSE )); then
        printf '%s[debug]%s %s\n' "$C_DIM" "$C_OFF" "$*"
    fi
}

die() {
    log_err "$*"
    exit 1
}

banner() {
    local zsh_state="absent"
    if [[ -f $ZSH_RC ]]; then
        if zsh_rc_is_distro_managed; then
            zsh_state="managed by the distribution"
        elif zsh_rc_sources_omz; then
            zsh_state="Oh My Zsh"
        else
            zsh_state="custom"
        fi
    fi

    printf '%s%s %s%s  (portable dev setup)\n' "$C_BLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$C_OFF"
    printf '  distribution : %s  [id=%s version=%s]\n' "${OS_NAME:-unknown}" "${OS_ID:-?}" "${OS_VERSION:-?}"
    printf '  package mgr  : %s\n' "${PKG_MANAGER:-none}"
    printf '  platform     : %s/%s (download arch: %s)\n' "$GOOS" "$TARGET_ARCH" "$GOARCH"
    printf '  zsh rc       : %s [%s]\n' "$ZSH_RC" "$zsh_state"
    printf '  prompt       : %s\n' "$PROMPT_ENGINE"
    if (( DRY_RUN )); then
        printf '  %s*** DRY RUN - nothing on this machine will be modified ***%s\n' "$C_YEL" "$C_OFF"
    fi
}

# =============================================================================
#  Traps
# =============================================================================
on_error() {
    local exit_code=$?
    local line=${1:-?}
    trap - ERR
    printf '%s[ fail]%s aborted in step "%s" at line %s (exit %s)\n' \
        "$C_RED" "$C_OFF" "$CURRENT_STEP" "$line" "$exit_code" >&2
    exit "$exit_code"
}

on_interrupt() {
    trap - INT TERM
    printf '\n%s[abort]%s interrupted, cleaning up\n' "$C_YEL" "$C_OFF" >&2
    cleanup
    exit 130
}

cleanup() {
    if [[ -n ${TMPDIR_ME:-} && -d ${TMPDIR_ME:-} ]]; then
        rm -rf -- "$TMPDIR_ME"
    fi
    return 0
}

require_tmpdir() {
    if [[ -z ${TMPDIR_ME:-} ]]; then
        TMPDIR_ME="$(mktemp -d "${TMPDIR:-/tmp}/my-shell.XXXXXXXX")"
        log_debug "scratch dir: $TMPDIR_ME"
    fi
}

# =============================================================================
#  Command execution
# =============================================================================
have() { command -v "$1" >/dev/null 2>&1; }

quote_cmd() {
    printf '%q ' "$@"
}

# run: execute for real, or just log when --dry-run. Non-zero exit aborts.
run() {
    if (( DRY_RUN )); then
        log_dry "$(quote_cmd "$@")"
        return 0
    fi
    "$@"
}

# try: like run, but a failure is reported and ignored (optional components).
try() {
    if (( DRY_RUN )); then
        log_dry "$(quote_cmd "$@")"
        return 0
    fi
    if "$@"; then
        return 0
    fi
    log_warn "ignoring failure of: $(quote_cmd "$@")"
    # Propagate the failure so callers can count or branch on it. Nothing
    # aborts the run: the warning is the notification.
    return 1
}

# try_privileged <command>...
# Run something that needs root, where a failure is inconvenient but must not
# kill the run: fonts and the default login shell are cosmetic compared to the
# rest of the setup, and a missing sudo password (CI, containers, a machine
# where the account has no sudo at all) would otherwise abort the script after
# everything else already succeeded.
#
# Returns the command's own status, so callers can tell what really happened.
# Always call it in a condition: that is what stops a non-zero status from
# reaching `set -e` and the ERR trap, which would abort the whole run.
try_privileged() {
    if (( DRY_RUN )); then
        log_dry "$(quote_cmd "$@")"
        return 0
    fi
    if as_root "$@"; then
        return 0
    fi
    log_warn "needs root, skipped: $(quote_cmd "$@")"
    log_warn "      run it yourself with: sudo $(quote_cmd "$@")"
    return 1
}

# as_root: run a command with root privileges (sudo / doas / already root).
as_root() {
    if ((${#SUDO[@]} > 0)); then
        "${SUDO[@]}" "$@"
    else
        "$@"
    fi
}

ensure_dir() {  # ensure_dir <dir>: create it, escalating only when necessary
    local d="$1"
    if [[ -d $d ]]; then
        return 0
    fi
    if (( DRY_RUN )); then
        log_dry "mkdir -p -- $d"
        return 0
    fi
    # Try without root first: ~/.local/bin usually does not exist yet but is ours.
    if mkdir -p -- "$d" 2>/dev/null; then
        return 0
    fi
    run as_root mkdir -p -- "$d"
}

install_file() {  # install_file <src> <dst> [mode]
    local src="$1" dst="$2" mode="${3:-0644}" dir
    dir=$(dirname -- "$dst")
    if [[ ! -d $dir ]]; then
        run mkdir -p -- "$dir"
    fi
    run install -m "$mode" -- "$src" "$dst"
}

install_binary() {  # install_binary <src> <dst-path>
    local src="$1" dst="$2" dir
    dir=$(dirname -- "$dst")
    ensure_dir "$dir"

    # A user-writable destination must not be chown'ed to root.
    if dir_writable "$dir"; then
        run install -m 0755 -- "$src" "$dst"
        return 0
    fi

    if [[ $GOOS == "darwin" ]]; then
        # BSD install has no -o/-g and macOS has no 'root' group.
        run as_root install -m 0755 -- "$src" "$dst"
    else
        run as_root install -o root -g root -m 0755 -- "$src" "$dst"
    fi
}

# =============================================================================
#  Privilege escalation
# =============================================================================
setup_sudo() {
    SUDO=()
    if (( EUID == 0 )); then
        log_debug "running as root, no privilege escalation needed"
        return 0
    fi
    local -a candidate=()
    if have sudo; then
        candidate=(sudo)
    elif have doas; then
        candidate=(doas)
    else
        die "root privileges are required but neither sudo nor doas is installed"
    fi

    # Prefer a non-interactive form when the credential is already cached, so a
    # long install does not re-prompt for every single command.
    if [[ ${candidate[0]} == "sudo" ]] && sudo -n true 2>/dev/null; then
        SUDO=(sudo -n)
    elif [[ ${candidate[0]} == "doas" ]] && doas -n true 2>/dev/null; then
        SUDO=(doas -n)
    else
        SUDO=("${candidate[@]}")
        if [[ -t 0 ]]; then
            log_info "you may be asked for your password during this run"
        fi
    fi
    log_debug "privilege escalation: ${SUDO[*]}"
}

# =============================================================================
#  Distribution / package manager detection
# =============================================================================
os_release_value() {  # os_release_value <file> <key>
    local file="$1" key="$2" line
    line=$(grep -m1 -E "^${key}=" -- "$file" 2>/dev/null) || return 0
    line=${line#*=}
    line=${line#\"}
    line=${line%\"}
    line=${line#\'}
    line=${line%\'}
    printf '%s' "$line"
}

load_os_release() {
    local f
    for f in /etc/os-release /usr/lib/os-release; do
        if [[ -r $f ]]; then
            OS_ID=$(os_release_value "$f" ID)
            OS_ID_LIKE=$(os_release_value "$f" ID_LIKE)
            OS_NAME=$(os_release_value "$f" PRETTY_NAME)
            OS_VERSION=$(os_release_value "$f" VERSION_ID)
            if [[ -z $OS_VERSION ]]; then
                # Rolling distros (Arch family) ship BUILD_ID but no VERSION_ID.
                OS_VERSION=$(os_release_value "$f" BUILD_ID)
            fi
            if [[ -z $OS_VERSION ]]; then
                OS_VERSION=$(os_release_value "$f" VERSION)
            fi
            return 0
        fi
    done
    return 1
}

pkg_manager_for_id() {  # pkg_manager_for_id <id> -> prints manager or nothing
    case "$1" in
        debian|ubuntu|linuxmint|pop|elementary|kali|raspbian|devuan|parrot|antix|mx|deepin|neon|zorin|trisquel|pureos|raspberrypi*|kali-rolling)
            printf 'apt' ;;
        fedora|rhel|redhat|centos|rocky|almalinux|ol|oracle|amzn|scientific|centos-stream|rhel-for-x86)
            printf 'dnf' ;;
        opensuse|opensuse-tumbleweed|opensuse-leap|opensuse-microos|sles|sled|suse|suse-linux|opensuse-ostree)
            printf 'zypper' ;;
        arch|archarm|manjaro|endeavouros|garuda|cachyos|artix|arcolinux|manjaro-arm|blendos|frogging-lounge)
            printf 'pacman' ;;
        alpine)
            printf 'apk' ;;
        gentoo|funtoo|calculate)
            printf 'emerge' ;;
        void)
            printf 'xbps' ;;
        nixos)
            printf 'nix' ;;
        solus)
            printf 'eopkg' ;;
        darwin|macos)
            printf 'brew' ;;
        *)
            return 1 ;;
    esac
}

detect_distro() {
    if ! load_os_release; then
        log_warn "no /etc/os-release found, falling back to legacy release files"
    fi

    local -a chain=()
    if [[ -n $OS_ID ]]; then
        chain+=("$OS_ID")
    fi
    if [[ -n $OS_ID_LIKE ]]; then
        local w
        # shellcheck disable=SC2086
        for w in $OS_ID_LIKE; do
            chain+=("$w")
        done
    fi
    if ((${#chain[@]} == 0)); then
        if [[ -f /etc/debian_version ]]; then
            chain+=(debian)
        elif [[ -f /etc/redhat-release ]]; then
            chain+=(rhel)
        elif [[ -f /etc/arch-release ]]; then
            chain+=(arch)
        elif [[ -f /etc/alpine-release ]]; then
            chain+=(alpine)
        elif [[ -f /etc/gentoo-release ]]; then
            chain+=(gentoo)
        fi
    fi

    local id
    for id in "${chain[@]}"; do
        if PKG_MANAGER=$(pkg_manager_for_id "$id"); then
            log_debug "matched id '$id' -> $PKG_MANAGER (chain: ${chain[*]})"
            break
        fi
        PKG_MANAGER=""
    done

    if [[ -n $PKG_OVERRIDE ]]; then
        PKG_MANAGER="$PKG_OVERRIDE"
        log_warn "package manager forced by --pkg-manager: $PKG_MANAGER"
    fi

    # Degrade gracefully when the preferred tool is not installed.
    if [[ $PKG_MANAGER == "dnf" ]] && ! have dnf; then
        if have yum; then
            log_warn "dnf not found, falling back to yum"
            PKG_MANAGER="yum"
        fi
    fi

    if [[ -z $PKG_MANAGER ]]; then
        log_err "unsupported or unrecognised distribution (id chain: ${chain[*]:-none})"
        log_err "supported: debian/ubuntu/rhel/fedora/suse/arch/alpine/gentoo/void/nixos/solus/macos"
        log_err "if this system does have a package manager, force it with --pkg-manager=<name>"
        exit 1
    fi

    if ! have "$PKG_MANAGER"; then
        log_warn "'$PKG_MANAGER' was detected but the binary is not on PATH;"
        log_warn "package installation steps will fail. Install it or use --pkg-manager."
    fi

    if [[ $PKG_MANAGER == "apt" ]] && ! have dpkg-query; then
        log_warn "dpkg-query missing; package presence checks will be unreliable"
    fi
}

# =============================================================================
#  Architecture detection
# =============================================================================
detect_arch() {
    local kernel
    kernel=$(uname -s)
    local machine
    machine=$(uname -m)

    case "$machine" in
        x86_64|amd64)   GOARCH="amd64";   TARGET_ARCH="x86_64" ;;
        aarch64|arm64)  GOARCH="arm64";   TARGET_ARCH="aarch64" ;;
        armv8l)         GOARCH="arm64";   TARGET_ARCH="aarch64" ;;
        armv7l|armv7)   GOARCH="arm";     TARGET_ARCH="armv7l" ;;
        armv7hl)        GOARCH="arm";     TARGET_ARCH="armv7l" ;;
        armv6l)         GOARCH="arm";     TARGET_ARCH="armv6l" ;;
        i386|i486|i586|i686) GOARCH="386"; TARGET_ARCH="i686" ;;
        s390x)          GOARCH="s390x";   TARGET_ARCH="s390x" ;;
        ppc64le)        GOARCH="ppc64le"; TARGET_ARCH="ppc64le" ;;
        riscv64)        GOARCH="riscv64"; TARGET_ARCH="riscv64" ;;
        loongarch64|loong64) GOARCH="loong64"; TARGET_ARCH="loongarch64" ;;
        *)              GOARCH="$machine"; TARGET_ARCH="$machine"
                        log_warn "unrecognised machine type '$machine', using it verbatim" ;;
    esac

    case "$kernel" in
        Linux)  GOOS="linux" ;;
        Darwin) GOOS="darwin" ;;
        *)      GOOS=$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]') ;;
    esac

    # Rosetta: `uname -m` reports x86_64 but the real hardware is arm64.
    if [[ $GOOS == "darwin" ]] && have sysctl; then
        if [[ $(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0') == "1" ]]; then
            GOARCH="arm64"
            TARGET_ARCH="aarch64"
            log_debug "running under Rosetta, using arm64 downloads"
        fi
    fi
}

# =============================================================================
#  Package manager interface
# =============================================================================
pkg_installed() {  # pkg_installed <name>
    local p="$1"
    case "$PKG_MANAGER" in
        apt)    dpkg-query -W -f='${db:Status-Status}' -- "$p" 2>/dev/null | grep -qx "installed" ;;
        dnf|yum|zypper) rpm -q -- "$p" >/dev/null 2>&1 ;;
        pacman) pacman -Qi -- "$p" >/dev/null 2>&1 ;;
        apk)    apk -e info -- "$p" >/dev/null 2>&1 ;;
        xbps)   xbps-query -Rs -- "$p" >/dev/null 2>&1 ;;
        eopkg)  eopkg list-installed 2>/dev/null | grep -qw -- "$p" ;;
        emerge) qlist -I "^${p}\$" >/dev/null 2>&1 ;;
        brew)   brew list --formula -- "$p" >/dev/null 2>&1 ;;
        nix)    return 1 ;;
        *)      return 1 ;;
    esac
}

pkg_refresh_once() {
    if (( PKG_REFRESHED )); then
        return 0
    fi
    PKG_REFRESHED=1
    pkg_refresh
}

pkg_refresh() {
    log_info "refreshing package index ($PKG_MANAGER)"
    case "$PKG_MANAGER" in
        apt)
            run as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
            ;;
        dnf)
            run as_root dnf -y makecache --refresh
            ;;
        yum)
            run as_root yum -y makecache
            ;;
        zypper)
            run as_root zypper --non-interactive refresh
            ;;
        pacman)
            if (( UPGRADE_SYSTEM )); then
                run as_root pacman -Syu --noconfirm
            else
                log_skip "pacman: not refreshing the sync database."
                log_skip "        a partial upgrade (-Sy then -S) breaks Arch, so this is opt-in."
                log_skip "        pass --upgrade for a full 'pacman -Syu'."
            fi
            ;;
        apk)
            run as_root apk update -q
            ;;
        emerge)
            run emerge --sync --quiet
            ;;
        xbps)
            # -S = sync repo indexes, -y = assume yes
            run as_root xbps-install -S -y
            ;;
        eopkg)
            run as_root eopkg update -y
            ;;
        nix)
            log_skip "nix: package index is immutable, nothing to refresh"
            ;;
        brew)
            run brew update
            ;;
        *)
            log_warn "pkg_refresh: nothing to do for '$PKG_MANAGER'"
            ;;
    esac
}

pkg_install() {  # pkg_install <pkg>...
    local -a missing=()
    local p
    for p in "$@"; do
        if pkg_installed "$p"; then
            log_skip "$p (already installed)"
        else
            missing+=("$p")
        fi
    done
    if ((${#missing[@]} == 0)); then
        return 0
    fi

    log_info "installing: ${missing[*]}"
    pkg_refresh_once
    case "$PKG_MANAGER" in
        apt)
            run as_root env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "${missing[@]}"
            ;;
        dnf)
            run as_root dnf install -y "${missing[@]}"
            ;;
        yum)
            run as_root yum install -y "${missing[@]}"
            ;;
        zypper)
            run as_root zypper --non-interactive install -y "${missing[@]}"
            ;;
        pacman)
            run as_root pacman -S --needed --noconfirm "${missing[@]}"
            ;;
        apk)
            run as_root apk add --no-progress "${missing[@]}"
            ;;
        emerge)
            # emerge asks for confirmation and refuses to overwrite by default.
            run as_root sh -c "yes | emerge --noreplace --quiet $(printf '%q ' "${missing[@]}")"
            ;;
        xbps)
            run as_root xbps-install -y "${missing[@]}"
            ;;
        eopkg)
            run as_root eopkg install -y "${missing[@]}"
            ;;
        nix)
            local n
            for n in "${missing[@]}"; do
                run nix profile install "nixpkgs#$n"
            done
            ;;
        brew)
            run brew install "${missing[@]}"
            ;;
        *)
            die "pkg_install: unsupported package manager '$PKG_MANAGER'"
            ;;
    esac
}

# try_dl <command>...
# Like try, but does not short-circuit on a dry run: the command is still run so
# it can print what it would fetch. Use it for installers that log their own
# preview, so a dry run shows the version and the URL instead of a function name.
# Always returns 0, for the same reason try does: a download that cannot be
# completed is a warning, not a reason to abandon the rest of the setup.
try_dl() {
    if "$@"; then
        return 0
    fi
    log_warn "ignoring failure of: $(quote_cmd "$@")"
    return 0
}

# =============================================================================
#  Tool manifest (config_files/tools.conf)
# =============================================================================
#  The list of tools a machine should end up with is data, not code: it lives in
#  config_files/tools.conf so a new workstation can be provisioned by editing a
#  table instead of a script. Everything here is read-only lookups plus a
#  resolver that turns a tool id into something installable on this distro.
# -----------------------------------------------------------------------------

# manifest_data: the manifest with comments and blank lines removed.
# Comments must be stripped *before* splitting on '|', otherwise the column
# header line looks like a tool called "group" and a profile called " group ".
manifest_data() {
    [[ -f $TOOL_MANIFEST ]] || return 0
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' -- "$TOOL_MANIFEST"
}

# tool_field <id> <field: id|group|method|arg|mapping|note|probe>
# Prints the requested field, or nothing when the id is unknown.
tool_field() {
    local id="$1" field="$2" line
    [[ -f $TOOL_MANIFEST ]] || return 1
    line=$(manifest_data | grep -E "^${id}\|" | head -1) || true
    [[ -n $line ]] || return 1
    case "$field" in
        id)      printf '%s' "$id" ;;
        group)   printf '%s' "$(cut -d'|' -f2 <<< "$line")" ;;
        method)  printf '%s' "$(cut -d'|' -f3 <<< "$line")" ;;
        arg)     printf '%s' "$(cut -d'|' -f4 <<< "$line")" ;;
        mapping) printf '%s' "$(cut -d'|' -f5 <<< "$line")" ;;
        note)    printf '%s' "$(cut -d'|' -f6 <<< "$line")" ;;
        probe)   printf '%s' "$(cut -d'|' -f7 <<< "$line")" ;;
        *)       return 1 ;;
    esac
}

# tool_present <id>
# True when the tool's executable is on PATH. That executable is not always the
# manifest id: Debian calls it fdfind, btop, codium and yq-of-a-different-kind.
# The manifest carries a probe list so the check works on every distribution;
# without it the script would reinstall the same tool on every run on exactly
# the distributions where the name differs.
tool_present() {  # tool_present <id>
    local id="$1" probes c
    probes=$(tool_field "$id" probe) || probes=""
    if [[ -z $probes || $probes == "-" ]]; then
        # The k8s section owns these five and may have put them in
        # ~/.local/bin, which is not on PATH until the user adds it. Only they
        # get that extra lookup: for any other tool a same-named file in the k8s
        # bin dir would be a false positive.
        case "$id" in
            kubectl|oc|kubectx|kubens|stern) have_installed "$id"; return ;;
        esac
        have "$id"
        return
    fi
    for c in ${probes//,/ }; do
        if have "$c"; then
            log_debug "$id: present as '$c'"
            return 0
        fi
    done
    return 1
}

# tool_in_group <group> -> prints every id in that group, in manifest order
tool_in_group() {
    local group="$1" id g
    while IFS='|' read -r id g _rest; do
        [[ -n $id ]] || continue
        if [[ $g == "$group" ]]; then
            printf '%s\n' "$id"
        fi
    done < <(manifest_data)
    # Explicit success: a trailing false test would make this function return 1,
    # and with `set -E` the ERR trap fires inside the process substitution.
    return 0
}

# all_manifest_groups -> every group name present in the manifest
# Trim with sed, not `tr -d '[:space:]'`: that would also delete the newlines,
# collapsing every group into a single unsortable line.
all_manifest_groups() {
    manifest_data \
        | cut -d'|' -f2 \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort -u
}

# manifest_ids -> every tool id, sorted
manifest_ids() {
    manifest_data | cut -d'|' -f1 | sort
}

# Resolve the package name for a tool on the detected package manager.
# Prints nothing and returns 1 when the manifest has no entry for it, which the
# caller reports as "unavailable" instead of aborting the run.
tool_package_for_manager() {  # tool_package_for_manager <id>
    local id="$1" mapping pair mgr pkg
    mapping=$(tool_field "$id" mapping) || return 1
    for pair in ${mapping//,/ }; do
        mgr="${pair%%=*}"
        pkg="${pair#*=}"
        if [[ $mgr == "$PKG_MANAGER" && $pkg != "-" && -n $pkg ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done
    return 1
}

# AUR helpers execute arbitrary code from PKGBUILDs. That is a real security
# decision, so it is never implicit: no helper is used unless --aur is given.
detect_aur_helper() {
    local h
    for h in paru yay pikaur trizen; do
        if have "$h"; then
            AUR_HELPER="$h"
            log_debug "aur helper: $h"
            return 0
        fi
    done
    return 1
}

# aur_install <pkg>... -- only reached when USE_AUR is 1 and a helper exists.
aur_install() {
    if (( USE_AUR == 0 )); then
        return 1
    fi
    if [[ -z $AUR_HELPER ]]; then
        log_warn "no AUR helper found (paru, yay, pikaur, trizen)"
        log_warn "install one, or install the package by hand; nothing was changed"
        return 1
    fi
    log_info "$AUR_HELPER: installing from the AUR: $*"
    if (( DRY_RUN )); then
        log_dry "$AUR_HELPER -S --needed $*"
        return 0
    fi
    case "$AUR_HELPER" in
        paru)  "$AUR_HELPER" -S --needed --noconfirm "$@" ;;
        yay)   "$AUR_HELPER" -S --needed --noconfirm "$@" ;;
        pikaur) "$AUR_HELPER" -S --confirm "$@" ;;
        trizen) "$AUR_HELPER" -S --yes "$@" ;;
    esac
}

# =============================================================================
#  Alternative install backends
# =============================================================================
#  Plenty of developer tools are not packaged by any distribution, or only by
#  one. These backends cover the rest so the script does not simply give up.

backend_available() {  # backend_available <method> <arg>
    case "$1" in
        npm)     have npm ;;
        uv)      have uv || have pipx ;;
        cargo)   have cargo ;;
        official) have curl ;;
        *)       return 1 ;;
    esac
}

backend_install() {  # backend_install <method> <arg>
    local method="$1" arg="$2"

    if ! backend_available "$method" "$arg"; then
        log_warn "method '$method' is not available on this machine (missing: $(
            case "$method" in
                npm) printf 'npm' ;;
                uv)  printf 'uv or pipx' ;;
                cargo) printf 'cargo' ;;
                *)   printf 'curl' ;;
            esac
        ))"
        return 1
    fi

    if (( DRY_RUN )); then
        log_dry "install via $method: $arg"
        return 0
    fi

    case "$method" in
        npm)
            # A global npm install writes into npm's global prefix, which on most
            # distributions is a root-owned directory. Running it anyway would
            # either fail or stop the whole run on a password prompt the user
            # never asked for, so check first and hand them the exact command.
            local npm_prefix
            npm_prefix=$(npm prefix -g 2>/dev/null) || npm_prefix=""
            if [[ -n $npm_prefix && ! -w $npm_prefix ]]; then
                log_warn "npm's global prefix is not writable: $npm_prefix"
                log_warn "      set a user-level prefix, then re-run:"
                log_warn "        npm config set prefix \"\$HOME/.local\""
                log_warn "        npm install -g --no-fund --no-audit $arg"
                return 1
            fi
            # --no-fund/--no-audit keep the output short and avoid telemetry.
            log_info "npm install -g $arg"
            npm install -g --no-fund --no-audit "$arg"
            ;;
        uv)
            if have uv; then
                log_info "uv tool install $arg"
                uv tool install "$arg"
            else
                log_info "pipx install $arg"
                pipx install "$arg"
            fi
            ;;
        cargo)
            log_info "cargo install $arg"
            cargo install "$arg"
            ;;
        official)
            # These are third-party install scripts. Print the command so it is
            # visible in a log what was actually piped into a shell.
            log_warn "running third-party installer: $arg"
            log_warn "review it first if you care about what it executes"
            curl -fsSL --connect-timeout 20 -- "$arg" | sh
            ;;
        *)
            log_warn "unknown install method '$method'"
            return 1
            ;;
    esac
}

# dir_writable <dir>
# True when a file could be created inside <dir>. A directory that does not exist
# yet counts as writable when its nearest existing ancestor is, which is what
# ensure_dir is about to create. Testing `-w` on a missing directory is always
# false, so a dry run would otherwise predict a root escalation that the real run
# would never perform.
dir_writable() {  # dir_writable <dir>
    local d="$1"
    while [[ ! -e $d ]]; do
        local parent
        parent=$(dirname -- "$d")
        if [[ $parent == "$d" ]]; then
            return 1
        fi
        d="$parent"
    done
    [[ -d $d && -w $d ]]
}

# =============================================================================
#  Download / verify helpers
# =============================================================================
fetch_file() {  # fetch_file <url> <dest>
    # The download is wrapped in a condition on purpose. Called bare, a
    # transient network error would reach the ERR trap and abort a run that has
    # otherwise succeeded, so the failure is reported here and the caller
    # decides whether it matters.
    local url="$1" dest="$2"
    if (( DRY_RUN )); then
        log_dry "download $url -> $dest"
        return 0
    fi
    local rc=0
    if have curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest" -- "$url" || rc=$?
    elif have wget; then
        wget -q -T 20 -t 3 -O "$dest" -- "$url" || rc=$?
    else
        die "neither curl nor wget is available; cannot download $url"
    fi
    if (( rc != 0 )); then
        rm -f -- "$dest"
        log_err "download failed (exit $rc): $url"
        return 1
    fi
    # A server that closes the connection early can still exit 0 and leave a
    # partial body behind. Callers unpack what they get, so catch it here.
    if [[ ! -s $dest ]]; then
        log_err "download produced an empty file: $url"
        return 1
    fi
    return 0
}

fetch_stdout() {  # fetch_stdout <url>
    if have curl; then
        curl -fsSL --retry 3 --connect-timeout 20 -- "$1"
    elif have wget; then
        wget -q -O- -- "$1"
    else
        die "neither curl nor wget is available; cannot download $1"
    fi
}

sha256_of() {  # sha256_of <file>
    local f="$1"
    if have sha256sum; then
        sha256sum -- "$f" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 -- "$f" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 -- "$f" | awk '{print $NF}'
    else
        printf ''
    fi
}

verify_sha256() {  # verify_sha256 <file> <sha-url> [name-as-listed-in-the-checksum-file]
    # Every variable is initialised: `local expected` alone leaves it *unset*,
    # and under `set -u` reading an unset variable aborts the run.
    local f="$1" sha_url="$2" want="${3:-}" body="" expected="" actual=""
    body=$(fetch_stdout "$sha_url" 2>/dev/null) || body=""

    if [[ -n $want ]]; then
        # Multi-entry checksum file: pick the line for this exact artifact.
        # The second field may be prefixed with '*' in binary mode.
        expected=$(printf '%s\n' "$body" \
            | awk -v n="$want" '$2 == n || $2 == "*" n {print $1; exit}')
    fi
    if [[ -z $expected ]]; then
        # Single-hash file (kubectl ships this format).
        expected=$(printf '%s\n' "$body" | awk 'NF {print $1; exit}')
    fi
    expected=${expected//[[:space:]]/}
    actual=$(sha256_of "$f")

    if [[ -z $expected ]]; then
        log_warn "could not read a checksum from $sha_url; relying on TLS"
        return 0
    fi
    if [[ -z $actual ]]; then
        log_warn "no sha256 tool available: cannot verify $(basename -- "$f")"
        return 0
    fi
    if [[ $expected != "$actual" ]]; then
        rm -f -- "$f"
        log_err "sha256 mismatch for $(basename -- "$f")"
        log_err "  expected $expected"
        log_err "  got      $actual"
        return 1
    fi
    log_ok "sha256 verified: $(basename -- "$f")"
}

# download_verified <url> <dest> [sha-url] [name-in-checksum-file]
# Returns non-zero on failure so that callers can decide whether a component is
# optional. A checksum mismatch must never be fatal for the whole run.
download_verified() {
    local url="$1" dest="$2" sha_url="${3:-}" name="${4:-}"
    if ! fetch_file "$url" "$dest"; then
        log_err "download failed: $url"
        return 1
    fi
    if [[ -n $sha_url ]] && (( DRY_RUN == 0 )); then
        verify_sha256 "$dest" "$sha_url" "$name" || return 1
    fi
    return 0
}

github_latest_tag() {  # github_latest_tag <owner/repo>
    # Read the whole body first: piping curl straight into grep/head makes curl
    # die with "Failure writing output to destination" (exit 23) every time.
    local body
    body=$(fetch_stdout "https://api.github.com/repos/$1/releases/latest" 2>/dev/null) || return 1
    printf '%s' "$body" \
        | grep -m1 -oE '"tag_name":[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/'
}

ensure_git_repo() {  # ensure_git_repo <url> <dest> [branch]
    local url="$1" dest="$2" branch="${3:-}"
    if [[ -d $dest/.git ]]; then
        log_ok "already cloned: $dest"
        if [[ -n $branch ]] && (( DRY_RUN == 0 )); then
            local current
            current=$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')
            if [[ $current != "$branch" ]]; then
                log_info "switching $dest: $current -> $branch"
                try git -C "$dest" fetch --depth=1 origin "$branch"
                try git -C "$dest" checkout -q "$branch"
            fi
        fi
        return 0
    fi
    if [[ -e $dest ]]; then
        log_warn "$dest exists but is not a git clone; leaving it alone"
        return 1
    fi
    log_info "cloning $url -> $dest"
    local -a args=(--depth=1)
    if [[ -n $branch ]]; then
        args+=(--branch "$branch")
    fi
    run git clone "${args[@]}" -- "$url" "$dest"
}

# =============================================================================
#  Prompts
# =============================================================================
confirm() {  # confirm <question> [y|n]
    local question="$1" default="${2:-y}" reply
    if (( ASSUME_YES )); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_warn "no TTY, assuming '$default' for: $question"
        if [[ $default == "y" ]]; then return 0; fi
        return 1
    fi
    while true; do
        reply=""
        read -r -p "$question [$(tr '[:lower:]' '[:upper:]' <<< "$default")] " reply || reply=""
        if [[ -z $reply ]]; then
            reply="$default"
        fi
        case "${reply,,}" in
            y|yes|s|si|ja) return 0 ;;
            n|no)            return 1 ;;
            *) printf 'Please answer yes or no.\n' ;;
        esac
    done
}

# ask_action <path> -> prints one of: keep | backup | merge | cancel
ask_action() {
    local path="$1" reply
    if (( ASSUME_YES )); then
        printf 'merge\n'
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_warn "no TTY, defaulting to 'merge' (additive, nothing overwritten) for $path"
        printf 'merge\n'
        return 0
    fi
    while true; do
        cat >&2 <<EOF

  $C_YEL$path already exists.$C_OFF
    [K]eep      leave the file exactly as it is
    [B]ackup    copy it into the backup dir, then overwrite it
    [M]erge     keep it and append a managed block (safest, re-runnable)
    [C]ancel    skip this file

EOF
        reply=""
        read -r -p "  choice [M]: " reply || reply=""
        if [[ -z $reply ]]; then
            reply="M"
        fi
        case "${reply^^}" in
            K) printf 'keep\n';   return 0 ;;
            B) printf 'backup\n'; return 0 ;;
            M) printf 'merge\n';  return 0 ;;
            C) printf 'cancel\n'; return 0 ;;
            *) printf '  Please answer K, B, M or C.\n' >&2 ;;
        esac
    done
}

# =============================================================================
#  Dotfile handling
# =============================================================================
file_owned_by_package() {  # file_owned_by_package <path>
    local f="$1"
    case "$PKG_MANAGER" in
        apt)           dpkg -S "$f" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -qf "$f" >/dev/null 2>&1 ;;
        pacman)        pacman -Qo -- "$f" >/dev/null 2>&1 ;;
        brew)          brew list --formula >/dev/null 2>&1 ;;
        *)             return 1 ;;
    esac
}

backup_file() {  # backup_file <path>
    local f="$1" dest
    [[ -e $f ]] || return 0
    dest="$BACKUP_DIR/$(basename -- "$f").$(date +%Y%m%d-%H%M%S).bak"
    if (( DRY_RUN )); then
        log_dry "backup $f -> $dest"
        return 0
    fi
    mkdir -p -- "$BACKUP_DIR"
    cp -a -- "$f" "$dest"
    log_ok "backup saved: $dest"
}

# strip_managed_block <file>: print the file without the my-shell block.
strip_managed_block() {  # strip_managed_block <file>
    local f="$1"
    if ! grep -qF -- "$MB_BEGIN" "$f"; then
        cat -- "$f"
        return 0
    fi
    # Blank lines are buffered and only emitted when a real line follows, so
    # repeated runs cannot accumulate empty lines at the end of the file.
    awk -v b="$MB_BEGIN" -v e="$MB_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip    { next }
        {
            if ($0 ~ /^[[:space:]]*$/) { pending++; next }
            while (pending > 0) { print ""; pending-- }
            print
        }
    ' "$f"
}

# file_mentions_outside_block <file> <extended-regex>
# Ignores what this script itself added, so our own additions can never make a
# user-owned file look like a distribution-provided one. The match is done with
# the bash regex engine rather than grep: a `producer | grep -q` pipeline can
# die of SIGPIPE under `set -o pipefail` and silently report "not found".
file_mentions_outside_block() {  # file_mentions_outside_block <file> <regex>
    local f="$1" re="$2" content
    [[ -f $f ]] || return 1
    content=$(strip_managed_block "$f") || return 1
    [[ $content =~ $re ]]
}

managed_block_remove() {  # managed_block_remove <file>
    local f="$1" tmp
    [[ -f $f ]] || return 0
    grep -qF -- "$MB_BEGIN" "$f" || return 0
    if (( DRY_RUN )); then
        log_debug "dry run: would strip the existing managed block from $f"
        return 0
    fi
    require_tmpdir
    tmp="$TMPDIR_ME/mblk.$$"
    strip_managed_block "$f" > "$tmp"
    cat -- "$tmp" > "$f"
    rm -f -- "$tmp"
    log_debug "removed previous managed block from $f"
}

# write_managed_block <file> <content-file> [header]
write_managed_block() {
    local f="$1" content="$2" header="${3:-}" dir
    dir=$(dirname -- "$f")
    if (( DRY_RUN )); then
        log_dry "replace the managed block in $f (content: $(basename -- "$content"))"
        return 0
    fi
    if [[ ! -d $dir ]]; then
        mkdir -p -- "$dir" || { log_err "cannot create $dir"; return 1; }
    fi
    if [[ -f $f ]]; then
        managed_block_remove "$f"
    fi
    if ! {
        printf '\n%s\n' "$MB_BEGIN"
        if [[ -n $header ]]; then
            printf '# %s\n' "$header"
        fi
        cat -- "$content"
        printf '%s\n' "$MB_END"
    } >> "$f"; then
        log_err "cannot write the managed block to $f"
        return 1
    fi
    log_ok "managed block written to $f"
}

# install_dotfile <src> <dst> <description>
install_dotfile() {
    local src="$1" dst="$2" desc="$3" action
    if [[ ! -f $src ]]; then
        log_warn "template not found: $src"
        return 1
    fi

    if [[ ! -e $dst ]]; then
        log_step "$desc: creating $dst"
        install_file "$src" "$dst"
        return 0
    fi

    if file_owned_by_package "$dst"; then
        log_warn "$dst belongs to a package; leaving it untouched"
        return 0
    fi

    action=$(ask_action "$dst")
    case "$action" in
        keep)
            log_skip "$desc: $dst kept as is"
            return 0
            ;;
        cancel)
            log_warn "$desc: cancelled"
            return 1
            ;;
        backup)
            backup_file "$dst"
            install_file "$src" "$dst"
            return 0
            ;;
        merge)
            log_info "$desc: appending a managed block to $dst"
            write_managed_block "$dst" "$src" "merged from $desc"
            return 0
            ;;
        *)
            die "internal error: unexpected action '$action'"
            ;;
    esac
}

# =============================================================================
#  zsh introspection
# =============================================================================
# Print the "configuration surfaces" of the target zsh: the user's .zshrc
# without our managed block, plus any file it pulls in.
#
# This matters on distributions such as CachyOS, Arch or Ubuntu, where ~/.zshrc
# is a single line sourcing a large config from /usr/share, and every setting
# that matters (Oh My Zsh, Powerlevel10k, the plugins) lives in that file
# instead. Looking at ~/.zshrc alone would make us duplicate all of it.
zsh_config_surfaces() {
    [[ -f $ZSH_RC ]] || return 0
    strip_managed_block "$ZSH_RC"

    local p seen=0
    while IFS= read -r p; do
        seen=$(( seen + 1 ))
        if (( seen > 32 )); then
            break
        fi
        if [[ -f $p && -r $p && $p != "$ZSH_RC" ]]; then
            printf '\n# ---- %s ----\n' "$p"
            cat -- "$p"
        fi
    done < <(grep -oE '/[A-Za-z0-9._/+-]+' -- "$ZSH_RC" 2>/dev/null)
}

zshrc_mentions() {  # zshrc_mentions <extended-regex>
    local re="$1" content
    content=$(zsh_config_surfaces) || return 1
    [[ $content =~ $re ]]
}

# A .zshrc that pulls in files from /usr/share is shipped (or curated) by the
# distribution. Installing Oh My Zsh on top of it duplicates ~1 GB and breaks
# the distro prompt, so we adopt it instead.
zsh_rc_is_distro_managed() {
    zshrc_mentions '/usr/share/(zsh|cachyos|oh-my-zsh|bash-it|zsh-defaults|powerlevel10k)'
}

zsh_rc_sources_omz() {
    zshrc_mentions 'oh-my-zsh\.sh'
}

zsh_rc_has_p10k() {
    zshrc_mentions 'powerlevel10k'
}

detect_omz() {
    OMZ_DIR=""
    local c
    for c in "$HOME/.oh-my-zsh" /usr/share/oh-my-zsh /usr/share/oh-my-zsh-git; do
        if [[ -f $c/oh-my-zsh.sh ]]; then
            OMZ_DIR="$c"
            return 0
        fi
    done
    return 1
}

# Where this script installs plugins it has to fetch itself. Deliberately a
# user-owned directory: no sudo, no clash with distribution packages.
user_plugin_dir() {
    printf '%s/my-shell/zsh-plugins' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# Directories that may already contain a zsh plugin, most specific first.
plugin_search_paths() {
    printf '%s\n' \
        "${ZSH_CUSTOM:-}" \
        "$(user_plugin_dir)" \
        /usr/share/zsh/plugins \
        /usr/share/oh-my-zsh/custom/plugins \
        "$HOME/.oh-my-zsh/custom/plugins"
}

find_plugin() {  # find_plugin <name> -> prints the plugin directory
    local name="$1" p
    while IFS= read -r p; do
        if [[ -n $p && -d "$p/$name" ]]; then
            printf '%s' "$p/$name"
            return 0
        fi
    done < <(plugin_search_paths)
    return 1
}

plugin_entry_file() {  # plugin_entry_file <dir> <name>
    local dir="$1" name="$2"
    if [[ -f "$dir/$name.plugin.zsh" ]]; then
        printf '%s' "$dir/$name.plugin.zsh"
        return 0
    fi
    if [[ -f "$dir/$name.zsh" ]]; then
        printf '%s' "$dir/$name.zsh"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
#  Managed block accumulator
#  Several sections contribute snippets and the block is written once, at the
#  end, so a later section can never overwrite an earlier one's work. The
#  accumulator is keyed by shell because completions may target a different
#  shell than the one the zsh section configures.
# -----------------------------------------------------------------------------
declare -A BLOCK_PARTS=()

# block_add <shell> <comment>   (body read from stdin)
block_add() {
    local shell_name="$1" comment="$2" body
    body=$(cat)
    if [[ -z ${BLOCK_PARTS[$shell_name]+x} ]]; then
        BLOCK_PARTS[$shell_name]=""
    fi
    # The comment is emitted as a real comment: '#' works in zsh, bash and fish.
    BLOCK_PARTS[$shell_name]+="# ${comment}"$'\n'"${body}"$'\n'
}

# flush_one_block <shell>
flush_one_block() {
    local sh="$1" rc content

    if [[ -z ${BLOCK_PARTS[$sh]+x} || ${BLOCK_PARTS[$sh]} =~ ^[[:space:]]*$ ]]; then
        return 0
    fi

    rc=$(shell_rc_path "$sh") || return 0
    if [[ -z $rc ]]; then
        return 0
    fi

    # For zsh, only ever add to an existing file: a bare block without the Oh
    # My Zsh bootstrap above it would be a broken configuration.
    if [[ $sh == "zsh" && ! -f $rc ]]; then
        log_warn "$rc does not exist; run the 'zsh' section first (nothing written)"
        return 0
    fi
    # Never invent a ~/.bashrc from nothing; just tell the user what to add.
    if [[ $sh == "bash" && ! -f $rc ]]; then
        log_warn "no ~/.bashrc found; add this manually:"
        printf '%s' "${BLOCK_PARTS[$sh]}" | sed 's/^/    /'
        return 0
    fi

    require_tmpdir
    content="$TMPDIR_ME/shell_block.$sh"
    printf '%s\n' "${BLOCK_PARTS[$sh]}" > "$content"
    if (( DRY_RUN )); then
        log_dry "write the managed block for $sh into $rc"
        return 0
    fi
    write_managed_block "$rc" "$content" "added by $SCRIPT_NAME $SCRIPT_VERSION - safe to delete"
}

flush_blocks() {
    local sh
    if ((${#BLOCK_PARTS[@]} == 0)); then
        log_skip "nothing to add to any shell configuration"
        return 0
    fi
    for sh in "${!BLOCK_PARTS[@]}"; do
        flush_one_block "$sh"
    done
    BLOCK_PARTS=()
}

# =============================================================================
#  Section: base dependencies
# =============================================================================
section_deps() {
    CURRENT_STEP="deps"
    log_step "Base dependencies"

    local -a pkgs=(git curl wget unzip tar gzip)
    if [[ $FONT_SET != "none" ]]; then
        pkgs+=(fontconfig)
    fi
    if [[ $TARGET_SHELL == "bash" ]]; then
        pkgs+=(bash)
    fi

    if (( DRY_RUN )); then
        log_dry "would install: ${pkgs[*]}"
        return 0
    fi
    pkg_install "${pkgs[@]}"

    for tool in git curl tar unzip; do
        if ! have "$tool"; then
            log_warn "$tool is still missing after the install step"
        fi
    done
}

# =============================================================================
#  Section: Nerd Fonts
# =============================================================================
# font_family_present <extended-regex>
# A family counts as installed when fontconfig already reports it, or when a
# matching font file is already sitting in the target directory. The second
# check matters because fontconfig does not necessarily index a custom
# --font-dir, and re-downloading 30+ MB on every run would be wasteful.
# No pipes are used here on purpose: `producer | grep -q` can be killed by
# SIGPIPE under `set -o pipefail` and silently look like "not found".
font_family_present() {  # font_family_present <regex>
    local re="$1" out=""
    if have fc-list; then
        out=$(fc-list 2>/dev/null) || out=""
        if [[ $out =~ $re ]]; then
            return 0
        fi
    fi
    if [[ -d ${FONT_INSTALL_DIR:-} ]]; then
        out=$(find "$FONT_INSTALL_DIR" -maxdepth 1 -type f \
            \( -name '*.ttf' -o -name '*.otf' \) 2>/dev/null) || out=""
        if [[ $out =~ $re ]]; then
            return 0
        fi
    fi
    return 1
}

install_nerd_font() {  # install_nerd_font <asset-zip> <probe-regex> <label>
    local asset="$1" probe="$2" label="$3" version zip stage

    if font_family_present "$probe"; then
        log_skip "$label already installed"
        return 0
    fi

    version="${NERD_FONT_VERSION}"
    if [[ -z $version ]]; then
        version=$(github_latest_tag ryanoasis/nerd-fonts || true)
    fi
    if [[ -z $version ]]; then
        version="v3.5.1"
        log_warn "could not query the latest nerd-fonts release, falling back to $version"
    fi
    if [[ $version != v* ]]; then
        version="v$version"
    fi
    log_info "$label: installing from nerd-fonts $version"

    require_tmpdir
    zip="$TMPDIR_ME/$asset"
    stage="$TMPDIR_ME/fonts-$label"

    if ! fetch_file "https://github.com/ryanoasis/nerd-fonts/releases/download/${version}/${asset}" "$zip"; then
        log_warn "$label: could not download $asset, skipping this font"
        return 1
    fi
    if (( DRY_RUN )); then
        log_dry "unzip $zip -> $FONT_INSTALL_DIR (flattened)"
        return 0
    fi

    rm -rf -- "$stage"
    mkdir -p -- "$stage"
    # -j flattens any directory structure inside the archive, -o overwrites.
    unzip -o -j -q -- "$zip" '*.ttf' -d "$stage"

    local count
    count=$(find "$stage" -maxdepth 1 -name '*.ttf' | wc -l)
    if [[ $count -eq 0 ]]; then
        # A truncated or error-page download yields no font files. Only the
        # prompt icons are affected, so this is a warning, never a reason to
        # abandon the rest of the setup.
        log_warn "$label: $asset yielded no .ttf files ($(( $(wc -c < "$zip") )) bytes downloaded)"
        log_warn "      retry later, or install it by hand from"
        log_warn "      https://github.com/ryanoasis/nerd-fonts/releases"
        return 1
    fi
    log_ok "unpacked $count font files for $label"

    ensure_dir "$FONT_INSTALL_DIR"
    local copied=0
    if cp -a -- "$stage/." "$FONT_INSTALL_DIR/" 2>/dev/null; then
        copied=1
    else
        # Not fatal: the glyphs only affect icon rendering in the prompt.
        if try_privileged cp -a -- "$stage/." "$FONT_INSTALL_DIR/"; then
            copied=1
        fi
    fi
    rm -rf -- "$stage"
    if (( copied )); then
        log_done "$label installed into $FONT_INSTALL_DIR"
    else
        log_warn "$label unpacked but not copied into $FONT_INSTALL_DIR"
    fi
}

section_fonts() {
    CURRENT_STEP="fonts"
    log_step "Nerd Fonts"

    if ! have fc-cache; then
        log_warn "fc-cache is missing; install fontconfig first (or keep the 'deps' section enabled)"
    fi

    # try_dl rather than a bare call: install_nerd_font returns 1 when a
    # download comes back unusable, and a bare non-zero status would abort the
    # whole run over a font. It also logs its own dry-run preview.
    case "$FONT_SET" in
        none) log_skip "FONT_SET=none"; return 0 ;;
        meslo) try_dl install_nerd_font "Meslo.zip" "MesloLGS.*Nerd" "MesloLGS NF" ;;
        hack)  try_dl install_nerd_font "Hack.zip"  "HackNerdFont|Hack Nerd Font" "Hack Nerd Font" ;;
        both)
            try_dl install_nerd_font "Meslo.zip" "MesloLGS.*Nerd" "MesloLGS NF"
            try_dl install_nerd_font "Hack.zip"  "HackNerdFont|Hack Nerd Font" "Hack Nerd Font"
            ;;
        *) die "invalid --fonts value '$FONT_SET' (expected: meslo, hack, both, none)" ;;
    esac

    if ! have fc-cache; then
        log_warn "fc-cache not found: fonts are copied but the cache is not refreshed"
        return 0
    fi
    if (( DRY_RUN )); then
        log_dry "fc-cache -f"
        return 0
    fi
    # fontconfig also indexes the system directories, so a user-owned target
    # still produces permission warnings for those; only escalate when we
    # actually had to write into a root-owned directory.
    if dir_writable "$FONT_INSTALL_DIR"; then
        fc-cache -f >/dev/null 2>&1 || log_warn "fc-cache reported problems; run 'fc-cache -fv' to inspect"
    else
        as_root fc-cache -f >/dev/null || log_warn "fc-cache reported problems; run 'sudo fc-cache -fv' to inspect"
    fi
    log_done "font cache rebuilt"
}

# =============================================================================
#  Section: zsh + Oh My Zsh
# =============================================================================
section_zsh() {
    CURRENT_STEP="zsh"
    log_step "zsh"

    pkg_install zsh
    if ! have zsh; then
        log_warn "zsh is not available; the zsh, theme and completion steps will be limited"
        return 0
    fi

    if zsh_rc_is_distro_managed; then
        log_ok "$ZSH_RC is provided by the distribution - adopting it, not replacing it"
        if detect_omz; then
            log_info "Oh My Zsh found at $OMZ_DIR"
        else
            log_info "no Oh My Zsh detected (a plain zsh config is perfectly fine)"
        fi
        return 0
    fi

    if zsh_rc_sources_omz && detect_omz; then
        log_ok "$ZSH_RC already loads Oh My Zsh"
        return 0
    fi

    if detect_omz; then
        log_ok "Oh My Zsh already installed at $OMZ_DIR"
    else
        log_info "installing Oh My Zsh into $HOME/.oh-my-zsh"
        ensure_git_repo "https://github.com/ohmyzsh/ohmyzsh.git" "$HOME/.oh-my-zsh"
        detect_omz || die "Oh My Zsh installation failed"
        log_ok "Oh My Zsh installed at $OMZ_DIR"
    fi

    if [[ -f $ZSH_RC ]]; then
        # Existing custom .zshrc without Oh My Zsh: prepend a bootstrap block.
        log_warn "$ZSH_RC exists but does not load Oh My Zsh"
        if confirm "prepend an Oh My Zsh bootstrap block to $ZSH_RC?" "n"; then
            backup_file "$ZSH_RC"
            require_tmpdir
            local boot="$TMPDIR_ME/omz_bootstrap.zsh"
            cat > "$boot" <<EOF
export ZSH="\${ZSH:-$HOME/.oh-my-zsh}"
ZSH_THEME=""
plugins=(git)
source "\$ZSH/oh-my-zsh.sh"
EOF
            if (( DRY_RUN )); then
                log_dry "prepend Oh My Zsh bootstrap to $ZSH_RC"
            else
                local staged="$TMPDIR_ME/zshrc.new"
                cat -- "$boot" "$ZSH_RC" > "$staged"
                cat -- "$staged" > "$ZSH_RC"
                log_done "Oh My Zsh bootstrap added to $ZSH_RC"
            fi
        else
            log_skip "leaving $ZSH_RC alone"
        fi
        return 0
    fi

    # No .zshrc at all: install the template this repo ships.
    install_dotfile "$CONFIG_DIR/zshrc-omz" "$ZSH_RC" "zsh configuration"
    return 0
}

# =============================================================================
#  Section: zsh plugins
# =============================================================================
ZSH_PLUGINS=(
    zsh-autosuggestions
    zsh-history-substring-search
    zsh-syntax-highlighting
)

# zsh-syntax-highlighting must be sourced last of the trio or it breaks the
# syntax colouring of the other two: ZSH_PLUGINS is already in load order.

install_plugin_from_github() {  # install_plugin_from_github <name> <url>
    local name="$1" url="$2" dest
    dest="$(user_plugin_dir)/$name"
    require_tmpdir
    mkdir -p -- "$(user_plugin_dir)"
    ensure_git_repo "$url" "$dest"
}

section_plugins() {
    CURRENT_STEP="plugins"
    log_step "zsh plugins"

    if ! have zsh; then
        log_warn "zsh is not installed, skipping plugin setup"
        return 0
    fi
    if ! have git; then
        log_warn "git is not installed, cannot fetch plugins"
        return 0
    fi

    local -a wanted=("${ZSH_PLUGINS[@]}")
    if (( INSTALL_KUBE_PS1 )); then
        wanted+=(kube-ps1)
    fi

    local name dir entry repo body="" body_added=0
    for name in "${wanted[@]}"; do
        case "$name" in
            zsh-autosuggestions)          repo="https://github.com/zsh-users/zsh-autosuggestions.git" ;;
            zsh-history-substring-search) repo="https://github.com/zsh-users/zsh-history-substring-search.git" ;;
            zsh-syntax-highlighting)       repo="https://github.com/zsh-users/zsh-syntax-highlighting.git" ;;
            kube-ps1)                     repo="https://github.com/ahmetb/kube-ps1.git" ;;
            *) die "unknown plugin '$name'" ;;
        esac

        if dir=$(find_plugin "$name") && entry=$(plugin_entry_file "$dir" "$name"); then
            log_ok "$name -> $entry (already present)"
        else
            log_info "fetching $name"
            if (( DRY_RUN )); then
                dir="$(user_plugin_dir)/$name"
                entry="$(user_plugin_dir)/$name/$name.zsh"
            else
                install_plugin_from_github "$name" "$repo"
                dir=$(find_plugin "$name") || dir="$(user_plugin_dir)/$name"
                entry=$(plugin_entry_file "$dir" "$name") \
                    || entry="$dir/$name.zsh"
            fi
            log_done "$name -> $entry"
        fi

        # A distribution config (or a previous manual setup) usually already
        # loads these plugins. Sourcing them twice is at best redundant and at
        # worst breaks zsh-syntax-highlighting, so only add what is missing.
        if zshrc_mentions "$name"; then
            log_skip "$name is already loaded by the current zsh configuration"
            continue
        fi

        body+="[[ -r '${entry}' ]] && source '${entry}'"$'\n'
        body_added=1
    done

    if (( body_added )); then
        block_add zsh "zsh plugins (loaded in the order zsh-syntax-highlighting requires)" <<< "$body"
        log_done "plugin sourcing added to the managed block"
    fi

    if (( INSTALL_KUBE_PS1 )); then
        if zsh_rc_has_p10k; then
            log_warn "Powerlevel10k is active: it renders the kubernetes context natively."
            log_warn "kube-ps1 also rewrites \$PROMPT, so the two can fight. This is why"
            log_warn "kube-ps1 is opt-in (--kube-ps1) rather than installed by default."
        fi
    else
        if zsh_rc_has_p10k; then
            log_info "kubernetes context is already shown by the p10k 'kubecontext' segment"
        fi
    fi
}

# =============================================================================
#  Section: prompt theme
# =============================================================================
# p10k_theme_file: prints the path of an existing Powerlevel10k theme file.
# It prints nothing and returns 1 when the theme is not installed yet, so it is
# safe to call in an `if` condition (an earlier version printed unconditionally,
# which leaked the path into the output).
p10k_theme_file() {
    local c
    for c in \
        "/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme" \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme" \
        "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" \
        "/usr/share/oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
    do
        if [[ -f $c ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

install_p10k_config() {
    local src="$CONFIG_DIR/p10k.zsh" dst="$HOME/.p10k.zsh"
    if [[ ! -f $src ]]; then
        log_warn "p10k config template not found: $src"
        return 0
    fi
    if [[ -f $dst ]]; then
        if (( REPLACE_P10K )); then
            backup_file "$dst"
            install_file "$src" "$dst"
            log_done "$dst replaced (previous version backed up)"
        else
            log_skip "$dst already exists; regenerate it with 'p10k configure'"
            log_skip "or pass --replace-p10k to overwrite it with the repo version"
        fi
        return 0
    fi
    install_file "$src" "$dst"
    log_done "$dst installed"
}

theme_powerlevel10k() {
    local theme_file

    if theme_file=$(p10k_theme_file); then
        log_ok "Powerlevel10k available at $theme_file"
    else
        log_info "installing Powerlevel10k"
        if (( DRY_RUN )); then
            theme_file="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme"
        else
            ensure_git_repo "https://github.com/romkatv/powerlevel10k.git" \
                "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" "master"
            theme_file="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme"
        fi
    fi

    install_p10k_config

    if zsh_rc_has_p10k; then
        log_skip "$ZSH_RC already loads Powerlevel10k"
        if ! zshrc_mentions 'p10k\.zsh'; then
            block_add zsh "Powerlevel10k configuration" <<EOF
[[ -r \$HOME/.p10k.zsh ]] && source "\$HOME/.p10k.zsh"
EOF
        fi
        return 0
    fi

    block_add zsh "Powerlevel10k theme" <<EOF
if [[ -r '${theme_file}' ]]; then
  source '${theme_file}'
fi
[[ -r \$HOME/.p10k.zsh ]] && source "\$HOME/.p10k.zsh"
EOF
    log_done "Powerlevel10k added to the managed block"
}

theme_starship() {
    pkg_install starship
    if ! have starship; then
        log_warn "starship is not available, keeping the current prompt"
        return 0
    fi
    if zshrc_mentions 'starship\.init'; then
        log_skip "$ZSH_RC already initialises starship"
        return 0
    fi
    block_add zsh "starship prompt" <<'EOF'
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
EOF
    log_done "starship added to the managed block"
}

section_theme() {
    CURRENT_STEP="theme"
    log_step "Prompt theme (${PROMPT_ENGINE})"

    case "$PROMPT_ENGINE" in
        none) log_skip "PROMPT_ENGINE=none"; return 0 ;;
        powerlevel10k) theme_powerlevel10k ;;
        starship) theme_starship ;;
        *) die "invalid --prompt value '$PROMPT_ENGINE' (expected: powerlevel10k, starship, none)" ;;
    esac
}

# =============================================================================
#  Section: Kubernetes tooling
# =============================================================================
KUBECTL_BIN_DIR=""

resolve_bin_dir() {
    if [[ $GOOS == "darwin" ]]; then
        KUBECTL_BIN_DIR="/usr/local/bin"
        return 0
    fi
    if [[ -w /usr/local/bin ]] || [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        KUBECTL_BIN_DIR="/usr/local/bin"
    else
        KUBECTL_BIN_DIR="$HOME/.local/bin"
        log_info "using user-writable bin dir: $KUBECTL_BIN_DIR"
    fi
}

# Warn when a package-managed binary of the same name would be shadowed.
warn_if_shadowed() {  # warn_if_shadowed <command> <target-path>
    local cmd="$1" target="$2" current
    have "$cmd" || return 0
    current=$(command -v "$cmd" 2>/dev/null || printf '')
    if [[ -n $current && $current != "$target" ]]; then
        if file_owned_by_package "$current"; then
            log_warn "$cmd is currently $current and is owned by a package;"
            log_warn "the new copy at $target will take precedence (PATH order)."
        else
            log_warn "$cmd resolves to $current, not $target; check your PATH."
        fi
    fi
}

# tool_path <cmd> -> prints the full path, or nothing
# The k8s binaries can live in ~/.local/bin, which is not on PATH until the
# user adds it. Looking them up with `command -v` alone would therefore make the
# script blind to its own previous run and reinstall the same binaries forever.
tool_path() {
    local found
    if found=$(command -v "$1" 2>/dev/null) && [[ -x $found ]]; then
        printf '%s' "$found"
        return 0
    fi
    if [[ -n ${KUBECTL_BIN_DIR:-} && -x ${KUBECTL_BIN_DIR}/$1 ]]; then
        printf '%s' "${KUBECTL_BIN_DIR}/$1"
        return 0
    fi
    return 1
}

# have_installed <cmd>: like have, but also looks in the k8s install directory
have_installed() { tool_path "$1" >/dev/null; }

installed_binary_version() {  # installed_binary_version <cmd> <version-args> [grep-pattern]
    local cmd="$1" vargs="$2" pattern="${3:-}" path out
    path=$(tool_path "$cmd") || return 1
    # vargs is deliberately unquoted: it is a small argument string.
    # shellcheck disable=SC2086
    out=$("$path" $vargs 2>/dev/null) || return 1
    out=$(printf '%s\n' "$out" | head -5)
    if [[ -n $pattern ]]; then
        printf '%s' "$out" | grep -oE -- "$pattern" | head -1
    else
        printf '%s' "$out" | awk -F': *' 'NF > 1 {print $NF; exit}' | tr -d '[:space:]'
    fi
}

install_kubectl() {
    local ver="$KUBECTL_VERSION" base url sha
    if [[ -z $ver ]]; then
        ver=$(fetch_stdout "https://dl.k8s.io/release/stable.txt" | tr -d '[:space:]' || true)
    fi
    if [[ -z $ver ]]; then
        log_err "cannot determine the latest kubectl version, skipping"
        return 0
    fi

    local current=""
    if current=$(installed_binary_version kubectl "version --client -o json" '"gitVersion"[[:space:]]*:[[:space:]]*"[^"]+"'); then
        current=${current##*\"}
    fi
    [[ -n $current ]] || current=$(installed_binary_version kubectl "version --client" 'v?[0-9]+\.[0-9]+\.[0-9]+[-+a-z0-9.]*' || true)
    if [[ $current == "$ver" ]]; then
        log_skip "kubectl $ver already installed ($(tool_path kubectl))"
        return 0
    fi
    if [[ -n $current ]]; then
        log_info "kubectl $current -> $ver"
    fi

    require_tmpdir
    base="https://dl.k8s.io/release/${ver}/bin/${GOOS}/${GOARCH}"
    url="${base}/kubectl"
    sha="${base}/kubectl.sha256"
    if ! download_verified "$url" "$TMPDIR_ME/kubectl" "$sha"; then
        log_warn "skipping kubectl: download or checksum verification failed"
        return 1
    fi
    install_binary "$TMPDIR_ME/kubectl" "$KUBECTL_BIN_DIR/kubectl"
    warn_if_shadowed kubectl "$KUBECTL_BIN_DIR/kubectl"
    log_done "kubectl $ver -> $KUBECTL_BIN_DIR/kubectl"
}

install_oc() {
    if ! have tar; then
        log_warn "tar is required to unpack the oc client, skipping"
        return 0
    fi
    # Note: never compare GOARCH inside (( )). Bash re-parses the *value* of
    # the variable as an arithmetic expression, so GOARCH=amd64 would be read as
    # the identifier "amd64" and, with set -u, abort the script.
    if [[ $GOARCH == "arm" || $GOARCH == "386" ]]; then
        log_warn "the OpenShift mirror has no ${GOOS}/${GOARCH} build, skipping oc"
        return 0
    fi

    # The OpenShift mirror publishes one rolling "latest" tarball, with no
    # version index and no checksum. There is no way to tell whether the
    # installed oc is still the current one, and re-downloading ~100MB on every
    # run would make this section never converge. Skip when present and say how
    # to force a refresh.
    local current="" existing=""
    existing=$(tool_path oc || printf '')
    if [[ -n $existing ]] && current=$(installed_binary_version oc "version --client" 'v?[0-9]+\.[0-9]+\.[0-9]+[-+a-z0-9.]*'); then
        log_skip "oc $current already present ($existing)"
        log_info "      the mirror has no version index, so it is not refreshed"
        log_info "      automatically; to update it: rm -f '$existing' and re-run"
        return 0
    fi
    if [[ -z $existing ]]; then
        log_info "oc not installed; downloading the latest release"
    fi

    require_tmpdir
    local url="https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz"
    log_info "downloading oc (latest) for ${GOOS}/${GOARCH}"
    if ! fetch_file "$url" "$TMPDIR_ME/oc.tar.gz"; then
        log_warn "skipping oc: download failed"
        return 1
    fi
    if (( DRY_RUN )); then
        log_dry "tar xzf $TMPDIR_ME/oc.tar.gz -> install oc"
        return 0
    fi
    log_warn "the OpenShift mirror publishes no checksum for oc; relying on HTTPS"
    if ! tar -xzf "$TMPDIR_ME/oc.tar.gz" -C "$TMPDIR_ME"; then
        log_warn "could not unpack the oc archive"
        return 1
    fi
    if [[ ! -f $TMPDIR_ME/oc ]]; then
        log_warn "oc binary not found inside the archive, skipping"
        return 1
    fi
    install_binary "$TMPDIR_ME/oc" "$KUBECTL_BIN_DIR/oc"
    warn_if_shadowed oc "$KUBECTL_BIN_DIR/oc"
    log_done "oc -> $KUBECTL_BIN_DIR/oc"
}

kubectx_release_arch() {
    case "$GOARCH" in
        amd64)   printf 'x86_64' ;;
        arm64)   printf 'arm64' ;;
        arm)     printf 'armv7' ;;
        386)     printf 'i386' ;;
        ppc64le) printf 'ppc64le' ;;
        s390x)   printf 's390x' ;;
        riscv64) printf 'riscv64' ;;
        *)       return 1 ;;
    esac
}

install_kubectx() {
    local ver arch base
    ver="$KUBECTX_VERSION"
    if [[ -z $ver ]]; then
        ver=$(github_latest_tag ahmetb/kubectx || true)
    fi
    if [[ -z $ver ]]; then
        log_err "cannot determine the latest kubectx release, skipping"
        return 1
    fi
    if ! arch=$(kubectx_release_arch); then
        log_warn "kubectx has no build for ${GOOS}/${GOARCH}, skipping"
        return 1
    fi

    if have_installed kubectx && have_installed kubens; then
        log_skip "kubectx/kubens already installed ($(tool_path kubectx))"
        return 0
    fi

    require_tmpdir
    base="https://github.com/ahmetb/kubectx/releases/download/${ver}"

    # kubectx and kubens ship as two separate archives, each also containing a
    # LICENSE that has no business in a bin directory. Extract selectively.
    local tool tarball
    for tool in kubectx kubens; do
        tarball="${tool}_${ver}_${GOOS}_${arch}.tar.gz"
        if ! download_verified "${base}/${tarball}" "$TMPDIR_ME/$tarball" \
            "${base}/checksums.txt" "$tarball"; then
            log_warn "skipping $tool: download or checksum verification failed"
            return 1
        fi
        if (( DRY_RUN )); then
            log_dry "extract only '$tool' from $tarball (LICENSE left behind)"
            continue
        fi
        if ! tar -xzf "$TMPDIR_ME/$tarball" -C "$TMPDIR_ME" "$tool"; then
            log_warn "could not extract $tool from the archive"
            return 1
        fi
        install_binary "$TMPDIR_ME/$tool" "$KUBECTL_BIN_DIR/$tool"
        log_done "$tool ${ver} -> $KUBECTL_BIN_DIR/$tool"
    done
}

install_stern() {
    local ver
    ver="$STERN_VERSION"
    if [[ -z $ver ]]; then
        ver=$(github_latest_tag stern/stern || true)
    fi
    if [[ -z $ver ]]; then
        log_err "cannot determine the latest stern release, skipping"
        return 0
    fi
    if have_installed stern; then
        log_skip "stern already installed ($(tool_path stern))"
        return 0
    fi
    require_tmpdir
    local bare="${ver#v}"
    local tgz="stern_${bare}_${GOOS}_${GOARCH}.tar.gz"
    local base="https://github.com/stern/stern/releases/download/${ver}"
    # Note: stern names its checksum file plain "checksums.txt", unlike kubectx.
    if ! download_verified "${base}/${tgz}" "$TMPDIR_ME/$tgz" \
        "${base}/checksums.txt" "$tgz"; then
        log_warn "skipping stern: download or checksum verification failed"
        return 1
    fi
    if (( DRY_RUN )); then
        log_dry "extract stern from $tgz"
        return 0
    fi
    if ! tar -xzf "$TMPDIR_ME/$tgz" -C "$TMPDIR_ME" stern; then
        log_warn "could not extract stern from the archive"
        return 1
    fi
    install_binary "$TMPDIR_ME/stern" "$KUBECTL_BIN_DIR/stern"
    log_done "stern ${ver} -> $KUBECTL_BIN_DIR/stern"
}

# completions_for <shell> -> snippet on stdout
# kubectl and oc expose a `completion` subcommand; kubectx and stern expose
# their own. Every snippet is guarded so a missing binary cannot break startup.
completions_for() {  # completions_for <shell>
    local sh="$1" c
    for c in kubectl oc kubectx stern; do
        have "$c" || (( DRY_RUN )) || continue
        case "$sh" in
            zsh|bash)
                printf 'if command -v %s >/dev/null 2>&1; then\n' "$c"
                printf '  source <(%s completion %s 2>/dev/null)\n' "$c" "$sh"
                printf 'fi\n'
                ;;
            fish)
                printf 'if type -q %s\n' "$c"
                printf '  %s completion fish | source\n' "$c"
                printf 'end\n'
                ;;
            *)
                return 0
                ;;
        esac
    done
}

aliases_for() {  # aliases_for <shell>
    local sh="$1"
    case "$sh" in
        zsh|bash)
            cat <<'EOF'
alias k=kubectl
alias kns=kubens
alias kx=kubectx
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
EOF
            ;;
        fish)
            cat <<'EOF'
alias k kubectl
alias kns kubens
alias kx kubectx
alias kgp 'kubectl get pods'
alias kgs 'kubectl get svc'
EOF
            ;;
        *) return 0 ;;
    esac
}

history_for() {  # history_for <shell>
    case "$1" in
        zsh)
            cat <<'EOF'
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS HIST_SAVE_NO_DUPS
setopt COMPLETION_WAITING_DOTS
EOF
            ;;
        bash)
            cat <<'EOF'
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth
shopt -s histappend
EOF
            ;;
        *) return 0 ;;
    esac
}

# Where the managed block for a given shell has to be written.
shell_rc_path() {  # shell_rc_path <shell>
    case "$1" in
        zsh)  printf '%s' "$ZSH_RC" ;;
        bash) printf '%s' "$HOME/.bashrc" ;;
        fish) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/my-shell.fish" ;;
        *)    return 1 ;;
    esac
}

# add_shell_block <comment> <content-on-stdin> [shell]
# Defaults to the resolved target shell. The snippet is accumulated, never
# written directly, so several sections can contribute to the same block.
add_shell_block() {
    local comment="$1" body sh="${3:-$TARGET_SHELL}"
    body=$(cat)
    if [[ -z $body || -z $sh ]]; then
        return 0
    fi
    block_add "$sh" "$comment" <<< "$body"
}

section_k8s() {
    CURRENT_STEP="k8s"
    log_step "Kubernetes & OpenShift tooling"

    resolve_bin_dir
    log_info "installing binaries into $KUBECTL_BIN_DIR"

    if have git; then
        # Called directly rather than through try: try short-circuits on a dry
        # run and would only print the function name, hiding the version, the
        # download URL and the checksum. These functions log a preview of
        # themselves instead, and a failure to download is not fatal.
        # --skip-tools reaches them too, so the one selection mechanism covers
        # manifest tools and the binaries this section downloads.
        if tool_skipped kubectl; then
            log_skip "kubectl (excluded by --skip-tools)"
        else
            try_dl install_kubectl
        fi
        if tool_skipped oc; then
            log_skip "oc (excluded by --skip-tools)"
        else
            try_dl install_oc
        fi
        if tool_skipped kubectx || tool_skipped kubens; then
            log_skip "kubectx, kubens (excluded by --skip-tools)"
        else
            try_dl install_kubectx
        fi
        if tool_skipped stern; then
            log_skip "stern (excluded by --skip-tools)"
        else
            try_dl install_stern
        fi
    else
        log_warn "git is required to download the release archives, skipping"
    fi

    if [[ $KUBECTL_BIN_DIR != "/usr/local/bin" && -d $KUBECTL_BIN_DIR ]]; then
        case ":${PATH}:" in
            *":${KUBECTL_BIN_DIR}:"*) : ;;
            *) log_warn "$KUBECTL_BIN_DIR is not on your PATH; add it to use kubectl/oc/kubectx" ;;
        esac
    fi

    local comp rc
    comp=$(completions_for "$TARGET_SHELL")
    if [[ -n $comp ]]; then
        rc=$(shell_rc_path "$TARGET_SHELL" || printf '')
        if [[ -n $rc ]] && file_mentions_outside_block "$rc" 'kubectl completion'; then
            log_skip "completions already configured in $rc"
        else
            add_shell_block "shell completion for the kubernetes tooling" <<< "$comp"
            log_done "completions wired into $TARGET_SHELL"
        fi
    else
        log_skip "no completion generators available yet"
    fi

    add_shell_block "kubernetes aliases" <<< "$(aliases_for "$TARGET_SHELL")"
    add_shell_block "shell history tuning" <<< "$(history_for "$TARGET_SHELL")"
}

# =============================================================================
#  Section: vim
# =============================================================================
section_vim() {
    CURRENT_STEP="vim"
    log_step "vim"
    pkg_install vim
    install_dotfile "$CONFIG_DIR/vimrc" "$HOME/.vimrc" "vim configuration"
}

# =============================================================================
#  Section: git defaults (opt-in, never overrides an existing value)
# =============================================================================
git_default() {  # git_default <key> <value>
    local key="$1" value="$2"
    if have git && git config --global --get "$key" >/dev/null 2>&1; then
        log_skip "git $key already set to $(git config --global --get "$key")"
        return 0
    fi
    if ! have git; then
        log_warn "git not installed, skipping git defaults"
        return 0
    fi
    log_info "git $key = $value"
    run git config --global -- "$key" "$value"
}

section_git() {
    CURRENT_STEP="git"
    log_step "git defaults"
    pkg_install git
    git_default init.defaultBranch main
    git_default core.pager 'less -FRX'
    git_default color.ui auto
    git_default color.diffMoved zebra
    git_default fetch.prune true
    git_default fetch.pruneTags true
    git_default push.autoSetupRemote true
    git_default pull.ff only
    git_default credential.helper 'cache --timeout=28800'
    log_info "review with: git config --global --list --show-origin"
}

# =============================================================================
#  Section: optional extras
# =============================================================================
#  Resolves the tools requested on the command line against the manifest and
#  installs each one by whichever method is available here. A tool that cannot
#  be installed is reported and the run continues: a missing nicety must never
#  abort provisioning a machine.
# -----------------------------------------------------------------------------

# install_manifest_tool <id>
# One tool, whatever its method. Prints nothing; the return value says whether
# it is now installed.
install_manifest_tool() {  # install_manifest_tool <id>
    local id="$1" method arg pkg note

    if ! method=$(tool_field "$id" method); then
        log_warn "unknown tool '$id'; see $TOOL_MANIFEST for the available ids"
        return 1
    fi
    arg=$(tool_field "$id" arg) || arg=""
    note=$(tool_field "$id" note) || note=""

    if tool_present "$id"; then
        log_skip "$id (already installed)"
        return 0
    fi

    case "$method" in
        pkg)
            if ! pkg=$(tool_package_for_manager "$id"); then
                if (( USE_AUR )); then
                    log_info "$id: no $PKG_MANAGER package, trying the AUR"
                    if aur_install "$id"; then
                        return 0
                    fi
                fi
                log_warn "$id: no package for $PKG_MANAGER on ${OS_ID:-this system}"
                if [[ -n $note ]]; then
                    log_warn "      $note"
                fi
                return 1
            fi
            log_info "$id -> package '$pkg'"
            if (( DRY_RUN )); then
                log_dry "install package $pkg (for $id)"
                return 0
            fi
            if ! pkg_install "$pkg"; then
                log_warn "$id: '$pkg' could not be installed via $PKG_MANAGER"
                return 1
            fi
            log_ok "$id ($pkg)"
            ;;
        npm|uv|cargo|official)
            log_info "$id via $method${arg:+ ($arg)}"
            if ! backend_install "$method" "$arg"; then
                log_warn "$id: install method '$method' failed or is unavailable"
                return 1
            fi
            log_done "$id"
            ;;
        none)
            # Listed in the manifest so the inventory is complete and
            # --skip-tools reaches it, but it is not a package: a dedicated
            # section downloads it and verifies its checksum.
            log_skip "$id: not a package, provided by its own section"
            return 0
            ;;
        *)
            log_warn "$id: unsupported manifest method '$method'"
            return 1
            ;;
    esac
}

# tool_skipped <id> -> true when --skip-tools named this tool
tool_skipped() {
    local s
    for s in "${SKIP_TOOLS[@]}"; do
        if [[ $s == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

section_extras() {
    CURRENT_STEP="extras"
    log_step "Developer tools"

    local -a wanted=()

    # --extras=<profiles>: pull in whole groups by name. A missing manifest only
    # disables the manifest-driven half of this section; --extra still works,
    # because it takes package names and never consults the manifest.
    if [[ -f $TOOL_MANIFEST ]]; then
        local prof
        for prof in "${EXTRAS_PROFILES[@]}"; do
            local -a gids=()
            mapfile -t gids < <(tool_in_group "$prof") || true
            if ((${#gids[@]} == 0)); then
                log_warn "profile '$prof' matches no group in the manifest"
                log_warn "  available: $(all_manifest_groups | tr '\n' ' ')"
                continue
            fi
            log_debug "profile $prof -> ${gids[*]}"
            wanted+=("${gids[@]}")
        done
    elif ((${#EXTRAS_PROFILES[@]} > 0 || ${#TOOL_SELECTION[@]} > 0)); then
        log_skip "no tool manifest, so no manifest tools can be selected"
    fi

    # --tools=<ids>: explicit single tools.
    local t
    for t in "${TOOL_SELECTION[@]}"; do
        wanted+=("$t")
    done

    # --extra=<pkgs>: raw package names, the escape hatch for anything that is
    # not in the manifest at all.
    if ((${#EXTRA_PACKAGES[@]} > 0)); then
        log_debug "raw extra packages: ${EXTRA_PACKAGES[*]}"
    fi

    if ((${#wanted[@]} == 0 && ${#EXTRA_PACKAGES[@]} == 0)); then
        log_skip "no tools requested"
        log_skip "  use --extras=<profile>   e.g. --extras=daily,k8s"
        log_skip "  or  --tools=<id>          e.g. --tools=zoxide,lazygit"
        if [[ -f $TOOL_MANIFEST ]]; then
            log_skip "  profiles: $(all_manifest_groups | tr '\n' ' ')"
        fi
        return 0
    fi

    # De-duplicate while preserving order, so a tool named in two profiles is
    # only considered once. Note the explicit `if`s: a `(( x )) && continue`
    # evaluates to false when x is 0 and would trip errexit.
    local -a seen=() uniq=() id
    for id in "${wanted[@]}"; do
        local dup=0 s
        for s in "${seen[@]}"; do
            if [[ $s == "$id" ]]; then
                dup=1
                break
            fi
        done
        if (( dup )); then
            continue
        fi
        seen+=("$id")
        uniq+=("$id")
    done

    # --skip-tools=<ids>: drop the ones already handled elsewhere.
    if ((${#SKIP_TOOLS[@]} > 0)); then
        local -a kept=()
        for id in "${uniq[@]}"; do
            local drop=0 s
            for s in "${SKIP_TOOLS[@]}"; do
                if [[ $s == "$id" ]]; then
                    drop=1
                    break
                fi
            done
            if (( drop == 0 )); then
                kept+=("$id")
            fi
        done
        uniq=("${kept[@]}")
    fi

    # Only bail out when there is genuinely nothing left to do. An empty list
    # here can also mean the manifest was missing, and --extra may still have
    # packages queued below.
    if ((${#uniq[@]} == 0)); then
        if ((${#SKIP_TOOLS[@]} > 0)); then
            log_skip "every requested tool was excluded by --skip-tools"
        else
            log_skip "no manifest tools to install"
        fi
    fi

    if (( USE_AUR )); then
        log_info "AUR is enabled: helper '$AUR_HELPER' may run PKGBUILD code"
    fi

    # Sort so the output order is stable across runs and machines. Guarded
    # because `printf '%s\n' "${empty[@]}"` still prints one empty line, which
    # would otherwise become a bogus empty tool id.
    if ((${#uniq[@]} > 0)); then
        mapfile -t uniq < <(printf '%s\n' "${uniq[@]}" | sort)
    fi

    local installed=0 failed=0 deferred=0 id method
    for id in "${uniq[@]}"; do
        # Called directly rather than through try: try short-circuits on dry-run,
        # and a dry run is exactly when you want to see how each tool resolves.
        # install_manifest_tool already logs its own warnings.
        if tool_field "$id" method >/dev/null 2>&1 && [[ $(tool_field "$id" method) == "none" ]]; then
            # Listed for completeness only. Counting it as installed would make
            # the totals claim something this section did not do.
            if install_manifest_tool "$id"; then
                deferred=$(( deferred + 1 ))
            fi
            continue
        fi
        if install_manifest_tool "$id"; then
            installed=$(( installed + 1 ))
        else
            failed=$(( failed + 1 ))
        fi
    done

    # --extra=<pkg>: raw package names, for anything not in the manifest. Passed
    # as a single transaction so the index is refreshed at most once.
    if ((${#EXTRA_PACKAGES[@]} > 0)); then
        log_step "Extra packages: ${EXTRA_PACKAGES[*]}"
        local -a raw_pkgs=()
        for id in "${EXTRA_PACKAGES[@]}"; do
            if pkg_installed "$id"; then
                log_skip "$id (already installed)"
            else
                raw_pkgs+=("$id")
            fi
        done
        if ((${#raw_pkgs[@]} > 0)); then
            if (( DRY_RUN )); then
                log_dry "install packages: ${raw_pkgs[*]}"
            elif pkg_install "${raw_pkgs[@]}"; then
                log_ok "installed: ${raw_pkgs[*]}"
                installed=$(( installed + ${#raw_pkgs[@]} ))
            else
                log_warn "could not install: ${raw_pkgs[*]}"
                failed=$(( failed + ${#raw_pkgs[@]} ))
            fi
        fi
    fi

    local deferred_note=""
    if (( deferred > 0 )); then
        deferred_note=", $deferred handled by another section"
    fi
    if (( DRY_RUN )); then
        log_info "tools: $installed would be installed, $failed unavailable here${deferred_note}"
    else
        log_info "tools: $installed ready, $failed unavailable on this system${deferred_note}"
    fi
    if (( failed > 0 )); then
        log_info "  the manifest records why; edit $TOOL_MANIFEST to adjust"
    fi
}

# =============================================================================
#  Section: default login shell (opt-in)
# =============================================================================
current_login_shell() {
    local u="${USER:-${LOGNAME:-}}"
    if [[ -n $u ]] && have getent; then
        getent passwd "$u" 2>/dev/null | cut -d: -f7 && return 0
    fi
    printf '%s' "${SHELL:-unknown}"
}

section_shell() {
    CURRENT_STEP="shell"
    log_step "Default login shell"

    local target current
    target=$(command -v "$TARGET_SHELL" 2>/dev/null || printf '')
    if [[ -z $target ]]; then
        log_skip "$TARGET_SHELL is not installed, nothing to do"
        return 0
    fi
    current=$(current_login_shell)
    if [[ $current == "$target" ]]; then
        log_ok "default shell is already $TARGET_SHELL"
        return 0
    fi
    log_info "default shell: $current -> $target"
    if ! confirm "change the default login shell to $TARGET_SHELL?" "n"; then
        log_skip "left unchanged (run 'chsh' yourself when ready)"
        return 0
    fi

    if [[ $GOOS == "darwin" ]]; then
        # dscl does not need root, but it fails on a machine where the user
        # record is managed by something else. That is not worth aborting for.
        if run dscl . -change "/Users/${USER}" UserShell "$target"; then
            log_done "default shell set to $target (log out and back in to see it)"
        else
            log_warn "dscl could not change the shell; run it by hand:"
            log_warn "      sudo dscl . -change \"/Users/${USER}\" UserShell $target"
        fi
        return 0
    fi

    if [[ -f /etc/passwd ]]; then
        backup_file /etc/passwd
    fi
    if try_privileged chsh -s "$target" "${USER:-$(id -un)}"; then
        log_done "default shell set to $target (log out and back in to see it)"
    else
        log_info "everything else is done; the login shell is the only step left"
    fi
}

# =============================================================================
#  Orchestration
# =============================================================================
preflight() {
    if (( BASH_VERSINFO[0] < 4 )); then
        die "bash >= 4.0 is required (found ${BASH_VERSION:-unknown})"
    fi

    local tool
    local absent=0
    for tool in sed awk grep uname date mktemp cp mkdir id chmod; do
        if ! have "$tool"; then
            log_err "required tool not found: $tool"
            absent=1
        fi
    done
    if (( absent == 1 )); then
        die "coreutils are missing; this system is not supported"
    fi

    if [[ ! -r $CONFIG_DIR ]]; then
        log_warn "config_files/ not readable at $CONFIG_DIR; template-driven steps will be skipped"
    fi

    if [[ ! -t 0 ]] && (( ASSUME_YES == 0 )); then
        log_warn "stdin is not a TTY: running fully non-interactively"
        log_warn "existing files will be merged (never overwritten). Use --yes to silence this."
        ASSUME_YES=1
    fi
}

resolve_target_shell() {
    if [[ -n $TARGET_SHELL ]]; then
        return 0
    fi
    # The zsh section being enabled is the strongest signal...
    if (( SECTION_ON[zsh] )); then
        TARGET_SHELL="zsh"
        return 0
    fi
    # ...then an existing .zshrc, even when the section was skipped: the user
    # clearly works in zsh and only asked for, say, the k8s part.
    if [[ -f $ZSH_RC ]]; then
        TARGET_SHELL="zsh"
        return 0
    fi
    local cur
    cur=$(basename -- "$(current_login_shell 2>/dev/null || printf 'bash')")
    TARGET_SHELL="$cur"
    log_debug "target shell defaulted to $TARGET_SHELL"
}

resolve_sections() {
    local s
    for s in "${ALL_SECTIONS[@]}"; do
        SECTION_ON[$s]=1
    done
    for s in "${OPTIONAL_SECTIONS[@]}"; do
        SECTION_ON[$s]=0
    done
    if ((${#WANTED_SECTIONS[@]} > 0)); then
        for s in "${ALL_SECTIONS[@]}"; do
            SECTION_ON[$s]=0
        done
        for s in "${WANTED_SECTIONS[@]}"; do
            if [[ -z ${SECTION_ON[$s]+x} ]]; then
                die "unknown section '$s' (valid: ${ALL_SECTIONS[*]})"
            fi
            SECTION_ON[$s]=1
        done
    fi
    for s in "${SKIP_SECTIONS[@]}"; do
        if [[ -z ${SECTION_ON[$s]+x} ]]; then
            die "unknown section '$s' (valid: ${ALL_SECTIONS[*]})"
        fi
        SECTION_ON[$s]=0
    done
}

validate_sections() {
    local requested="${WANTED_SECTIONS[*]} ${SKIP_SECTIONS[*]}"

    # A missing manifest is not a usage error, so warn once here and let the
    # extras section report what it cannot do. Validating the profile names in
    # this case would abort the run with a misleading "unknown profile" message.
    if [[ ! -f $TOOL_MANIFEST ]]; then
        if ((${#EXTRAS_PROFILES[@]} > 0 || ${#TOOL_SELECTION[@]} > 0)); then
            log_warn "tool manifest not found at $TOOL_MANIFEST"
            log_warn "tools cannot be resolved; fetch config_files/tools.conf"
            log_warn "or use --extra=<package> to install something by name"
        fi
    else
        # Catch a typo in --extras early: it would otherwise silently select
        # nothing. No pipes here: `producer | head -1` can be killed by SIGPIPE
        # under `set -o pipefail` and would make a valid profile look unknown.
        local prof known
        if ((${#EXTRAS_PROFILES[@]} > 0)); then
            known=$(all_manifest_groups | tr '\n' ' ')
            for prof in "${EXTRAS_PROFILES[@]}"; do
                if [[ -z $(tool_in_group "$prof") ]]; then
                    die "unknown extras profile '$prof' (available: $known)"
                fi
            done
        fi

        # Same for --tools: an unknown id would be reported per-tool and ignored.
        if ((${#TOOL_SELECTION[@]} > 0)); then
            local t
            for t in "${TOOL_SELECTION[@]}"; do
                if ! tool_field "$t" method >/dev/null 2>&1; then
                    log_warn "tool '$t' is not in $TOOL_MANIFEST; it will be skipped"
                fi
            done
        fi
    fi

    # Plugins, theme and completions need a zsh rc to write into.
    if (( SECTION_ON[plugins] || SECTION_ON[theme] )) \
        && (( SECTION_ON[zsh] == 0 )) && [[ ! -f $ZSH_RC ]]; then
        if [[ $requested == *"zsh"* ]]; then
            log_warn "the 'zsh' section was skipped and $ZSH_RC does not exist;"
            log_warn "plugin/theme lines cannot be written anywhere"
        else
            log_warn "plugin/theme setup needs a zsh rc; add 'zsh' to --only or --skip"
        fi
    fi
}

run_sections() {
    local s before after
    for s in "${ALL_SECTIONS[@]}"; do
        if (( SECTION_ON[$s] )); then
            # Snapshot the failure counter around each section so the summary
            # can say which ones actually completed. A section that could not
            # install something still runs to the end, so "done" on its own
            # would be a claim the log does not support.
            before=$RUN_FAILURES
            "section_${s}"
            after=$RUN_FAILURES
            SECTION_FAILURES[$s]=$(( after - before ))
        else
            log_step "Section: ${s}"
            log_skip "disabled"
        fi
    done
    flush_blocks
}

summary() {
    log_step "Summary"
    local s
    for s in "${ALL_SECTIONS[@]}"; do
        if (( SECTION_ON[$s] )); then
            if (( ${SECTION_FAILURES[$s]:-0} > 0 )); then
                printf '  %s%-10s%s finished with %d problem(s)\n' \
                    "$C_YEL" "$s" "$C_OFF" "${SECTION_FAILURES[$s]}"
            else
                printf '  %s%-10s%s done\n' "$C_GRN" "$s" "$C_OFF"
            fi
        fi
    done

    if (( DRY_RUN )); then
        log_info "dry run: no changes were made"
        return 0
    fi

    if (( RUN_FAILURES > 0 )); then
        log_err "$RUN_FAILURES step(s) did not complete; the run finished anyway"
        log_err "the [ fail] lines above say which ones"
    fi

    local -a next=()
    local rc=""
    rc=$(shell_rc_path "$TARGET_SHELL" || printf '')
    if (( SECTION_ON[zsh] || SECTION_ON[theme] )) && [[ -f $ZSH_RC ]]; then
        next+=("open a new login shell: exec ${TARGET_SHELL} -l")
    fi
    if [[ -n $KUBECTL_BIN_DIR && -d $KUBECTL_BIN_DIR ]]; then
        case ":${PATH}:" in
            *":${KUBECTL_BIN_DIR}:"*) : ;;
            *) next+=("add ${KUBECTL_BIN_DIR} to your PATH to use kubectl/oc/kubectx") ;;
        esac
    fi
    if [[ -n $rc && -f $rc ]] && grep -qF -- "$MB_BEGIN" "$rc" 2>/dev/null; then
        next+=("review what was added: sed -n '/${SCRIPT_NAME}/,\$p' $rc")
    fi
    if [[ -f $HOME/.p10k.zsh ]] && [[ $PROMPT_ENGINE != "none" ]]; then
        next+=("regenerate the prompt config any time with: p10k configure")
    fi
    if [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]]; then
        next+=("backups (if any) are in $BACKUP_DIR")
    fi

    local n
    for n in "${next[@]}"; do
        printf '  %s->%s %s\n' "$C_BLD" "$C_OFF" "$n"
    done
}

usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} - portable developer workstation setup

USAGE
  ./my-shell.sh [options]

SECTIONS
  deps      git, curl, wget, unzip, tar, fontconfig
  fonts     MesloLGS NF and/or Hack Nerd Font + font cache
  zsh       zsh, Oh My Zsh, a starter .zshrc
  plugins   zsh-autosuggestions, -history-substring-search, -syntax-highlighting
  theme     Powerlevel10k (or starship) + ~/.p10k.zsh
  k8s       kubectl, oc, kubectx, kubens, stern, completions, aliases
  vim       vim + ~/.vimrc
  git       safe global git defaults            (opt-in)
  extras    tools from config_files/tools.conf   (opt-in)
  shell     chsh to the target shell            (opt-in)

  Run with --only=<list> or --skip=<list> to choose. --all enables everything.

SAFETY
  - Nothing is downloaded and installed before you answer, and existing files
    are never overwritten silently: you get keep / backup / merge / cancel.
  - Everything written to a dotfile lives between
      ${MB_BEGIN}
      ${MB_END}
    so re-running is safe and removing the block restores the original.
  - Files owned by a package manager are never touched.
  - No full system upgrade unless you ask for --upgrade.

COMMON OPTIONS
  -n, --dry-run          print what would happen, change nothing
  -y, --yes              non-interactive, assume "merge" for existing files
  -v, --verbose          extra diagnostics
      --no-color         disable ANSI colours
  -h, --help             this text

SELECTION
      --only=a,b         run exactly these sections
      --skip=a,b         skip these sections
      --all              enable every section, including git/extras/shell

CUSTOMISATION
      --prompt=ENGINE    powerlevel10k (default) | starship | none
      --fonts=SET        both (default) | meslo | hack | none
      --font-dir=DIR     font target dir (default /usr/local/share/fonts)
      --font-version=V   pin the nerd-fonts release, e.g. v3.4.0
      --shell=NAME       shell to target for completions/chsh (default zsh)
      --kube-ps1         also install kube-ps1 (off by default: p10k
                         already renders the kubernetes context natively)
      --replace-p10k     overwrite ~/.p10k.zsh with the repo version
      --git              enable the git defaults section
      --aur              allow installing from the AUR with paru/yay/pikaur/
                         trizen. These run PKGBUILD code, so it is opt-in
      --extras[=LIST]    enable the extras section, optionally limited to
                         whole groups from config_files/tools.conf
                         (default group: daily)
      --tools=LIST       specific manifest tools, e.g. zoxide,lazygit,sops
      --skip-tools=LIST  drop tools from whatever was selected
      --extra=LIST       raw package names, installed with the package manager
                         (escape hatch for anything not in the manifest)
      --upgrade          allow a full system upgrade (pacman -Syu, dnf upgrade)
      --set-default-shell  change the login shell without asking
      --pkg-manager=NAME force a package manager (apt, dnf, yum, zypper,
                         pacman, apk, emerge, xbps, eopkg, nix, brew)
      --kubectl-version=V   pin kubectl, e.g. v1.31.4
      --kubectx-version=V   pin kubectx/kubens
      --stern-version=V      pin stern
      --backup-dir=DIR   where dotfile backups are stored

EXAMPLES
  ./my-shell.sh --dry-run
  ./my-shell.sh --only=fonts,theme,k8s
  ./my-shell.sh --prompt=starship --extras
  ./my-shell.sh --all --set-default-shell

  # a new workstation, from the manifest
  ./my-shell.sh --extras=daily,k8s,terminal,secrets --aur
  ./my-shell.sh --tools=zoxide,sops,lazygit --extras
  ./my-shell.sh --extras=daily --skip-tools=bat,eza

SUPPORTED
  Debian/Ubuntu/Mint/Pop/Kali, Fedora/RHEL/CentOS/Rocky/Alma/Oracle/Amazon,
  openSUSE/SLES, Arch/Manjaro/EndeavourOS/CachyOS/Garuda, Alpine, Gentoo,
  Void, NixOS, Solus, macOS (Homebrew). Use --pkg-manager elsewhere.
EOF
}

parse_args() {
    local a
    need_arg() {
        # need_arg <flag> <count-remaining>
        if (($2 < 2)); then
            die "option '$1' requires a value"
        fi
    }
    while (($# > 0)); do
        a="$1"
        case "$a" in
            -h|--help)          usage; exit 0 ;;
            --version)          printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            -n|--dry-run)       DRY_RUN=1 ;;
            -y|--yes|--non-interactive) ASSUME_YES=1 ;;
            -v|--verbose)       VERBOSE=1 ;;
            --no-color)         NO_COLOR_FLAG=1 ;;
            --all)              WANTED_SECTIONS=("${ALL_SECTIONS[@]}") ;;
            --only)             need_arg "$a" $#; shift; IFS=',' read -r -a WANTED_SECTIONS <<< "$1" ;;
            --only=*)           IFS=',' read -r -a WANTED_SECTIONS <<< "${a#*=}" ;;
            --skip)             need_arg "$a" $#; shift; IFS=',' read -r -a SKIP_SECTIONS <<< "$1" ;;
            --skip=*)           IFS=',' read -r -a SKIP_SECTIONS <<< "${a#*=}" ;;
            --prompt)           need_arg "$a" $#; shift; PROMPT_ENGINE="$1" ;;
            --prompt=*)         PROMPT_ENGINE="${a#*=}" ;;
            --fonts)            need_arg "$a" $#; shift; FONT_SET="$1" ;;
            --fonts=*)          FONT_SET="${a#*=}" ;;
            --font-dir)         need_arg "$a" $#; shift; FONT_INSTALL_DIR="$1" ;;
            --font-dir=*)       FONT_INSTALL_DIR="${a#*=}" ;;
            --font-version)     need_arg "$a" $#; shift; NERD_FONT_VERSION="$1" ;;
            --font-version=*)   NERD_FONT_VERSION="${a#*=}" ;;
            --shell)            need_arg "$a" $#; shift; TARGET_SHELL="$1" ;;
            --shell=*)          TARGET_SHELL="${a#*=}" ;;
            --kube-ps1)         INSTALL_KUBE_PS1=1 ;;
            --replace-p10k)     REPLACE_P10K=1 ;;
            --git)              WANTED_SECTIONS+=("git") ;;
            --extras)           EXTRAS_PROFILES=("daily") ;;
            --extras=*)         IFS=',' read -r -a _argv_list <<< "${a#*=}"; EXTRAS_PROFILES+=("${_argv_list[@]}") ;;
            --tools)            need_arg "$a" $#; shift; IFS=',' read -r -a _argv_list <<< "$1"; TOOL_SELECTION+=("${_argv_list[@]}") ;;
            --tools=*)          IFS=',' read -r -a _argv_list <<< "${a#*=}"; TOOL_SELECTION+=("${_argv_list[@]}") ;;
            --skip-tools)       need_arg "$a" $#; shift; IFS=',' read -r -a _argv_list <<< "$1"; SKIP_TOOLS+=("${_argv_list[@]}") ;;
            --skip-tools=*)     IFS=',' read -r -a _argv_list <<< "${a#*=}"; SKIP_TOOLS+=("${_argv_list[@]}") ;;
            --aur)              USE_AUR=1 ;;
            --extra)            need_arg "$a" $#; shift; IFS=',' read -r -a _argv_list <<< "$1"; EXTRA_PACKAGES+=("${_argv_list[@]}") ;;
            --extra=*)          IFS=',' read -r -a _argv_list <<< "${a#*=}"; EXTRA_PACKAGES+=("${_argv_list[@]}") ;;
            --upgrade)          UPGRADE_SYSTEM=1 ;;
            --set-default-shell) SET_DEFAULT_SHELL=1 ;;
            --pkg-manager)      need_arg "$a" $#; shift; PKG_OVERRIDE="$1" ;;
            --pkg-manager=*)    PKG_OVERRIDE="${a#*=}" ;;
            --kubectl-version)  need_arg "$a" $#; shift; KUBECTL_VERSION="$1" ;;
            --kubectl-version=*) KUBECTL_VERSION="${a#*=}" ;;
            --kubectx-version)  need_arg "$a" $#; shift; KUBECTX_VERSION="$1" ;;
            --kubectx-version=*) KUBECTX_VERSION="${a#*=}" ;;
            --stern-version)    need_arg "$a" $#; shift; STERN_VERSION="$1" ;;
            --stern-version=*)  STERN_VERSION="${a#*=}" ;;
            --backup-dir)       need_arg "$a" $#; shift; BACKUP_DIR="$1" ;;
            --backup-dir=*)     BACKUP_DIR="${a#*=}" ;;
            --)                 shift; break ;;
            -*)                 die "unknown option: $a (try --help)" ;;
            *)                  die "unexpected argument: $a" ;;
        esac
        shift
    done
    if (($# > 0)); then
        die "unexpected argument: $1"
    fi

    case "$PROMPT_ENGINE" in
        powerlevel10k|starship|none) ;;
        *) die "invalid --prompt value '$PROMPT_ENGINE'" ;;
    esac
    case "$FONT_SET" in
        both|meslo|hack|none) ;;
        *) die "invalid --fonts value '$FONT_SET'" ;;
    esac
    if (( SET_DEFAULT_SHELL )); then
        WANTED_SECTIONS+=("shell")
    fi
}

main() {
    parse_args "$@"
    setup_colors

    CURRENT_STEP="startup"
    trap 'on_error $LINENO' ERR
    trap 'on_interrupt' INT TERM
    trap 'cleanup' EXIT

    ZSH_RC="${ZDOTDIR:-$HOME}/.zshrc"

    preflight
    detect_distro
    detect_arch
    resolve_sections
    resolve_target_shell
    setup_sudo
    if (( USE_AUR )); then
        if detect_aur_helper; then
            log_info "AUR enabled, helper: $AUR_HELPER"
        else
            log_warn "--aur was given but no helper is installed (paru, yay, pikaur, trizen)"
            log_warn "AUR packages build code from PKGBUILDs; install a helper first, or"
            log_warn "pass --extra=<package> for anything your package manager has"
        fi
    fi
    if (( UPGRADE_SYSTEM )) && (( DRY_RUN )); then
        log_warn "--upgrade ignored in dry-run mode"
        UPGRADE_SYSTEM=0
    fi
    if (( DRY_RUN )); then
        sudo -v 2>/dev/null || true
        SUDO=()
        log_debug "dry run: privilege escalation disabled"
    fi
    validate_sections
    banner

    run_sections
    summary

    # The setup always runs to the end, so a zero status cannot be inferred
    # from "it did not crash". A caller in a provisioning pipeline needs to know
    # whether everything it asked for actually happened.
    if (( RUN_FAILURES > 0 )); then
        return 1
    fi
    return 0
}

main "$@"
