#!/usr/bin/env zsh
# Secure Shutdown for Archcrypt USB (v1.1 - yuriy edition, enhanced)

set -Eeuo pipefail
IFS=$'\n\t'

autoload -Uz colors && colors || true
: ${TERM:="xterm-256color"}

ok()    { print -P "%F{green}[✓]%f $*"; }
warn()  { print -P "%F{yellow}[!]%f $*"; }
err()   { print -P "%F{red}[✗]%f $*" >&2; }
info()  { print -P "%F{cyan}[*]%f $*"; }

line() { print -P "%F{magenta}-------------------------------------------------------------------%f"; }
banner() {
  local h="$(hostname -s 2>/dev/null || echo archcrypt)"
  local d="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  print -P "%F{magenta}=================================================================%f"
  print -P "%F{yellow}      Secure Shutdown — ${h} — ${d}%F      "
  print -P "%F{magenta}=================================================================%f"
}

spinner() { local msg="$1" pid="$2"; local -a f=('|' '/' '-' '\\'); local i=1; print -n -- " $msg "; while kill -0 "$pid" 2>/dev/null; do print -nr -- "\r $msg ${f[i]}"; (( i = (i % ${#f}) + 1 )); sleep 0.1; done; print -r -- "\r $msg "; }

_restore_net() {
  [[ -f /run/secure-shutdown.netoff ]] || return 0
  if command -v nmcli &>/dev/null; then
    nmcli radio all on || true
    nmcli networking on || true
    systemctl restart NetworkManager || true
  else
    for ifc in ${(f)"$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2}')"}; do
      ip link set "$ifc" up 2>/dev/null || true
    done
  fi
  rm -f /run/secure-shutdown.netoff 2>/dev/null || true
}

trap 'err "Unexpected error; restoring networking and aborting."; _restore_net; exit 1' ERR
trap 'warn "Interrupted by user; restoring networking."; _restore_net; exit 130' INT
stty -echoctl 2>/dev/null || true

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

### --------- [1] INFO PANEL ----------
clear
banner

print -P "%F{green}[i] archcrypt System Details -%f"
info "Kernel: $(uname -r)   Uptime: $(uptime -p)"
info "TTY: $(tty 2>/dev/null || echo n/a)   User: ${SUDO_USER:-$USER}"
info "Root source: $(findmnt -no SOURCE /)"

if command -v cryptsetup >/dev/null && cryptsetup status crypt &>/dev/null; then
  info "LUKS mapping 'crypt' is active:"
  cryptsetup status crypt | sed 's/^/    /'
else
  warn "LUKS mapping 'crypt' not detected"
fi

info "Block devices:"
lsblk -o NAME,RM,SIZE,RO,TYPE,MOUNTPOINTS | sed 's/^/    /'

info "Mounted under /mnt /media /run/media:"
{ mount | grep -E ' on (/(mnt|media)(/| )|/run/media/)'; true; } | sed 's/^/    /'

print
print -P "%F{green}[✓] Ready to initialize secure power off sequence...%f"
print -P "%F{green}[→] Goodbye yuriy.  ( 'ω' )/%f"
line
print -P "%F{yellow}                   - press ENTER to begin poweroff -%f"
line
read -r

### --------- [2] SECURE TEARDOWN ----------
banner
info "Starting secure shutdown…"

stop_if_active() {
  systemctl is-active --quiet "$1" && { info "Stopping $1…"; systemctl stop "$1" || warn "Failed to stop $1"; }
}
if command -v podman &>/dev/null; then
  info "Stopping podman containers…"
  podman ps -q | xargs -r podman stop --time 10 || true
fi
if command -v docker &>/dev/null; then
  info "Stopping docker containers…"
  docker ps -q | xargs -r docker stop --time 10 || true
fi
stop_if_active "libvirtd.service"
stop_if_active "virtqemud.service"

[[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]] && { info "Clearing ssh-agent keys…"; ssh-add -D 2>/dev/null || true; }

if command -v nmcli &>/dev/null; then
  info "Disabling networking (nmcli)…"
  : > /run/secure-shutdown.netoff
  nmcli radio all off || true
  nmcli networking off || true
else
  info "Bringing non-loopback interfaces down…"
  : > /run/secure-shutdown.netoff
  for ifc in ${(f)"$(ip -o link show 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2}')"}; do
    ip link set "$ifc" down 2>/dev/null || true
  done
fi

# Unmount targets including /mnt/usb
unmount_tree() {
  local base="$1"
  local -a targets
  targets=("${(@f)$(mount | awk -v b="^$base" '$3 ~ b {print $3}' | sort -r)}")
  (( ${#targets} )) || return
  info "Unmounting under ${base}…"
  for m in "${targets[@]}"; do
    umount -R "$m" 2>/dev/null || umount "$m" 2>/dev/null || warn "could not umount $m"
  done
}
unmount_tree "/mnt"
unmount_tree "/media"
unmount_tree "/run/media"
unmount_tree "/mnt/usb"  # Safe since it's on same device but separate from root LUKS

# Close non-root LUKS maps (skip root 'crypt')
if command -v cryptsetup &>/dev/null; then
  for m in ${(f)"$(ls /dev/mapper 2>/dev/null | grep -v '^control$')"}; do
    [[ "$m" == "crypt" ]] && continue
    [[ "$(lsblk -no TYPE "/dev/mapper/$m" 2>/dev/null)" == "crypt" ]] || continue
    info "Closing LUKS map: $m"
    umount -R "/dev/mapper/$m" 2>/dev/null || true
    cryptsetup close "$m" 2>/dev/null || warn "could not close $m"
  done
fi

# zram/swap teardown
if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
  info "Disabling swap…"
  swapon --show | sed 's/^/    /'
  swapoff -a || warn "swapoff returned non-zero"
fi
if command -v zramctl &>/dev/null; then
  for d in ${(f)"$(zramctl --output NAME --noheadings | grep '^/dev/zram')"}; do
    swapoff "$d" 2>/dev/null || true
    zramctl --reset "$d" 2>/dev/null || warn "zram reset failed on $d"
  done
fi

info "Syncing filesystems…"
( sync; sync; sync ) &> /dev/null & spinner "Flushing buffers…" $!

info "Dropping pagecache/dentries/inodes…"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || warn "could not drop caches"

### --------- [3] FINAL CHECK ----------
line
info "Final state check (pre-poweroff):"

info "Remaining TYPE=crypt entries:"
lsblk -rno NAME,TYPE,MOUNTPOINTS /dev/mapper 2>/dev/null | awk '$2=="crypt"{print "    "$0}' || true

info "Active mounts under /mnt, /media, /run/media:"
mount | grep -E ' on (/(mnt|media)(/| )|/run/media/)' | sed 's/^/    /' || print "    (none)"

info "NetworkManager state (if present):"
command -v nmcli &>/dev/null && nmcli general status 2>/dev/null | sed 's/^/    /' || print "    nmcli not installed"
line

ok "Teardown complete."
rm -f /run/secure-shutdown.netoff 2>/dev/null || true

# === NEW FINAL PROMPT BEFORE POWER OFF ===
print -P "%F{green}[✓] System ready for shutdown.%f"
print -P "%F{green}[→] Goodbye yuriy.  ( 'ω' )/%f"
line
print -P "%F{yellow}                   - press ENTER to power off -%f"
line
read -r

info "Powering off now…"
exec systemctl poweroff -i > /dev/null 2>&1
