#!/usr/bin/env zsh
# Secure shutdown for archcrypt USB (zsh)
# Flow:
#   1) Show a nice info panel + relevant system details
#   2) Bottom line: "Goodbye yuriy! ( 'ω' )/  — Press ENTER to power off…"
#   3) On ENTER: run a safe, clean teardown and poweroff

set -Eeuo pipefail
IFS=$'\n\t'

### ---------- UI helpers ----------
autoload -Uz colors && colors || true
: ${TERM:="xterm-256color"}

ok()    { print -P "%F{green}[✓]%f $*"; }
warn()  { print -P "%F{yellow}[!]%f $*"; }
err()   { print -P "%F{red}[✗]%f $*" >&2; }
info()  { print -P "%F{cyan}[*]%f $*"; }

spinner() {  # spinner "message" & pid
  local msg="$1" pid="$2" s='|/-\' i=0
  print -n -- " $msg "
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r %s %s" "${msg}" "${s:i++%${#s}:1}"
    sleep 0.1
  done
  printf "\r"
}

line() { print -P "%F{magenta}-----------------------------------------------------%f"; }
banner() {
  local h="$(hostname -s 2>/dev/null || echo archcrypt)"
  local d="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  print -P "%F{magenta}=====================================================%f"
  print -P "%F{magenta} Secure Shutdown — ${h} — ${d}%f"
  print -P "%F{magenta}=====================================================%f"
}

### ---------- safety nets ----------
trap 'err "Unexpected error; aborting."; exit 1' ERR
trap 'warn "Interrupted by user."; exit 130' INT
stty -echoctl 2>/dev/null || true  # hide ^C caret

# Require root; re-exec with same env. Will prompt for sudo if needed.
if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

### ---------- 1) INFO PANEL ----------
clear
banner

# Targeted info that matters for your stack
info "Kernel: $(uname -r)   Uptime: $(uptime -p)"
info "TTY: $(tty 2>/dev/null || echo n/a)   User: ${SUDO_USER:-$USER}"
info "Root source: $(findmnt -no SOURCE /)"

if command -v cryptsetup >/dev/null 2>&1; then
  if cryptsetup status crypt &>/dev/null; then
    info "LUKS mapping 'crypt' is active:"
    cryptsetup status crypt | sed 's/^/    /'
  else
    warn "LUKS mapping 'crypt' not detected"
  fi
fi

info "Block devices:"
lsblk -o NAME,RM,SIZE,RO,TYPE,MOUNTPOINTS | sed 's/^/    /'

info "Mounted under /mnt, /media, /run/media -"
{ mount | grep -E ' on (/(mnt|media)(/| )|/run/media/)'; true; } | sed 's/^/    /' || true

line
print
print -P "%F{green}[✓]%f Ready."
print
print -P "%F{cyan}[→]%f Goodbye yuriy! ( 'ω' )/  — %F{magenta}Press ENTER to power off…%f"
print

# Wait for ENTER only (ignore other keys)
read -r

### ---------- 2) SECURE SHUTDOWN SEQUENCE ----------
banner
info "Starting secure shutdown…"

# Gracefully stop containers/VM daemons (best-effort)
stop_if_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    info "Stopping $unit…"
    systemctl stop "$unit" || warn "Failed to stop $unit"
  fi
}
if command -v podman &>/dev/null; then
  info "Stopping podman containers…"
  local pods
  pods=("${(@f)$(podman ps -q 2>/dev/null)}")
  if (( ${#pods} )); then
    podman stop --time 10 "${pods[@]}" || warn "podman stop issues"
  fi
fi
if command -v docker &>/dev/null; then
  info "Stopping docker containers…"
  local dcts
  dcts=("${(@f)$(docker ps -q 2>/dev/null)}")
  if (( ${#dcts} )); then
    docker stop --time 10 "${dcts[@]}" || warn "docker stop issues"
  fi
fi
stop_if_active "libvirtd.service"
stop_if_active "virtqemud.service"

# SSH agent cleanup (no lingering keys)
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  info "Clearing ssh-agent keys…"
  ssh-add -D 2>/dev/null || true
fi

# Networking down (tidy; non-fatal)
if command -v nmcli &>/dev/null; then
  info "Disabling networking (nmcli)…"
  nmcli radio all off || true
  nmcli networking off || true
else
  info "Bringing non-loopback interfaces down…"
  local ifaces
  ifaces=("${(@f)$(ip -o link show 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2}')}") || true
  for ifc in "${ifaces[@]}"; do
    ip link set "$ifc" down 2>/dev/null || true
  done
fi

# Unmount user/ephemeral mounts (never touches / or /home)
unmount_tree() {
  local base="$1"
  local -a targets
  targets=("${(@f)$(mount | awk -v b="^$base" '$3 ~ b {print $3}' | sort -r)}")
  if (( ${#targets} )); then
    info "Unmounting under ${base}…"
    for m in "${targets[@]}"; do
      umount -R "$m" 2>/dev/null || umount "$m" 2>/dev/null || warn "could not umount $m"
    done
  fi
}
unmount_tree "/mnt"
unmount_tree "/media"
unmount_tree "/run/media"

# Close non-root LUKS maps (skip your root + LVM)
if command -v cryptsetup &>/dev/null; then
  local -a maps
  maps=("${(@f)$(ls /dev/mapper 2>/dev/null | grep -vE '^(control|crypt|arch-vg-.*)$' || true)}")
  for m in "${maps[@]}"; do
    if lsblk "/dev/mapper/$m" &>/dev/null; then
      info "Closing LUKS map: $m"
      umount -R "/dev/mapper/$m" 2>/dev/null || true
      cryptsetup close "$m" 2>/dev/null || warn "could not close $m"
    fi
  done
fi

# zram/swap handling
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  info "Disabling swap…"
  swapon --show | sed 's/^/    /' || true
  swapoff -a || warn "swapoff returned non-zero"
fi
if command -v zramctl &>/dev/null; then
  local -a zdevs
  zdevs=("${(@f)$(zramctl --output NAME --noheadings 2>/dev/null | grep '^/dev/zram' || true)}")
  if (( ${#zdevs} )); then
    info "Resetting zram devices…"
    # ensure swap is off on those, then reset each
    local -a zswaps
    zswaps=("${(@f)$(swapon --show=NAME --noheadings 2>/dev/null | grep '^/dev/zram' || true)}")
    for d in "${zswaps[@]}"; do swapoff "$d" 2>/dev/null || true; done
    for d in "${zdevs[@]}";  do zramctl --reset "$d" 2>/dev/null || warn "zram reset incomplete on $d"; done
  fi
fi

# Writeback + cache drop
info "Syncing filesystems…"
(sync; sync; sync) &; spinner "Flushing buffers…" $!
info "Dropping pagecache/dentries/inodes…"
echo 3 > /proc/sys/vm/drop_caches || warn "could not drop caches"

# Final state report
ok "Teardown complete. Extra mounts are clean; stray LUKS closed."
info "Powering off now…"
exec systemctl poweroff -i
