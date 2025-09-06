#!/usr/bin/env zsh
# Secure shutdown for archcrypt USB (zsh)
# Flow:
#   1) Show a nice info panel (fastfetch if available) + relevant system details
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

# If fastfetch is present, show it first (quiet on errors)
if command -v fastfetch &>/dev/null; then
  # minimal width-aware; no colors forced so it respects your theme
  fastfetch 2>/dev/null || true
  line
fi

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

info "Mounted under /mnt, /media, /run/media (likely your exFAT share etc.):"
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
  (podman ps -q | xargs -r podman stop --time 10) || warn "podman stop issues"
fi
if command -v docker &>/dev/null; then
  info "Stopping docker containers…"
  (docker ps -q | xargs -r docker stop --time 10) || warn "docker stop issues"
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
  ip -o link show 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2}' | while read -r ifc; do
    ip link set "$ifc" down 2>/dev/null || true
  done
fi

# Unmount user/ephemeral mounts (never touches / or /home)
unmount_tree() {
  local base="$1"
  local -a targets
  mapfile -t targets < <(mount | awk -v b="^$base" '$3 ~ b {print $3}' | sort -r)
  if (( ${#targets[@]} )); then
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
  mapfile -t maps < <(ls /dev/mapper 2>/dev/null | grep -vE '^(control|crypt|arch-vg-.*)$' || true)
  for m in "${maps[@]:-}"; do
    if lsblk "/dev/mapper/$m" &>/dev/null; then
      info "Closing LUKS map: $m"
      umount -R "/dev/mapper/$m" 2>/dev/null || true
      cryptsetup close "$m" 2>/dev/null || warn "could not close $m"
    fi
  done
fi

# zram/swap handling (you said zram only; this covers both)
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  info "Disabling swap…"
  swapon --show | sed 's/^/    /' || true
  swapoff -a || warn "swapoff returned non-zero"
fi
if command -v zramctl &>/dev/null; then
  if zramctl --output NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
    info "Resetting zram devices…"
    swapon --show=NAME --noheadings 2>/dev/null | grep -E '^/dev/zram' | xargs -r -n1 swapoff || true
    zramctl --output NAME --noheadings 2>/dev/null | xargs -r -n1 zramctl --reset || warn "zram reset incomplete"
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
