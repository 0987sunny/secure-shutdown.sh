#!/usr/bin/env zsh
# v 1.3 yuriy edition 
# Secure shutdown for archcrypt USB (zsh)
# Flow: 
#   1) Show a nice info panel + relevant system details
#   2) Bottom line: "Goodbye yuriy! ヽ( ⌒ω⌒)ﾉ  — Press ENTER to begin power off…"
#   3) On first ENTER: run a safe, clean teardown
#   4) On second ENTER: poweroff

set -Eeuo pipefail
IFS=$'\n\t'

### ---------- UI helpers ----------
autoload -Uz colors && colors || true
: ${TERM:="xterm-256color"}

ok()    { print -P "%F{green}[✓]%f $*"; }
warn()  { print -P "%F{yellow}[!]%f $*"; }
err()   { print -P "%F{red}[✗]%f $*" >&2; }
info()  { print -P "%F{cyan}[*]%f $*"; }

line() { print -P "%F{magenta}------------------------------------------------------------------------%f"; }
banner() {
  local h="$(hostname -s 2>/dev/null || echo archcrypt)"
  local d="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  print -P "%F{magenta}=======================================================================%f"
  print -P "%F{yellow}         Secure Shutdown — ${h} — ${d}%F      "
  print -P "%F{magenta}=======================================================================%f"
}

### ---------- safety nets (restore net on abort) ----------
_restore_net() {
  [[ -f /run/secure-shutdown.netoff ]] || return 0
  if command -v nmcli &>/dev/null; then
    nmcli radio all on || true
    nmcli networking on || true
    systemctl restart NetworkManager || true
  else
    local ifc
    for ifc in ${(f)"$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2}')"}; do
      ip link set "$ifc" up 2>/dev/null || true
    done
  fi
  rm -f /run/secure-shutdown.netoff 2>/dev/null || true
}

trap 'err "Unexpected error; restoring networking and aborting."; _restore_net; exit 1' ERR
trap 'warn "Interrupted by user; restoring networking."; _restore_net; exit 130' INT
stty -echoctl 2>/dev/null || true  # hide ^C caret

# Require root; re-exec with same env. Will prompt for sudo if needed.
if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

### ---------- 1) INFO PANEL ----------
clear
banner

print -P "%F{green}[i] archcrypt System Details -%f"
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
print

info "Mounted user/removable partitions:"
mount | grep -E ' on (/(mnt|media)(/| )|/run/media/)' | \
  awk '{printf "    %-20s %-20s %s\n", $1, $3, $5}' || print "    (none)"

print
print -P "%F{green}[✓] Ready to initialize secure power off sequence...%f"
print -P "%F{green}[→] Goodbye yuriy.  ( 'ω' )/%f"
line
print -P "%F{yellow}                   - press ENTER to begin power off -%f              "
line

# Wait for first ENTER to begin teardown
read -r
clear
banner
info "Starting secure shutdown…"

### ---------- 2) SECURE SHUTDOWN SEQUENCE ----------
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
  local -a pods; pods=("${(@f)$(podman ps -q 2>/dev/null)}")
  (( ${#pods} )) && podman stop --time 10 "${pods[@]}" || true
fi
if command -v docker &>/dev/null; then
  info "Stopping docker containers…"
  local -a dcts; dcts=("${(@f)$(docker ps -q 2>/dev/null)}")
  (( ${#dcts} )) && docker stop --time 10 "${dcts[@]}" || true
fi
stop_if_active "libvirtd.service"
stop_if_active "virtqemud.service"

# SSH agent cleanup (no lingering keys)
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  info "Clearing ssh-agent keys…"
  ssh-add -D 2>/dev/null || true
fi

# Networking down (mark so traps can restore on abort)
if command -v nmcli &>/dev/null; then
  info "Disabling networking (nmcli)…"
  : > /run/secure-shutdown.netoff
  nmcli radio all off || true
  nmcli networking off || true
else
  info "Bringing non-loopback interfaces down…"
  : > /run/secure-shutdown.netoff
  local -a ifaces; ifaces=("${(@f)$(ip -o link show 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2}')}")
  for ifc in "${ifaces[@]}"; do ip link set "$ifc" down 2>/dev/null || true; done
fi

# Unmount user/ephemeral mounts (never touches / or /home)
unmount_tree() {
  local base="$1"
  local -a targets
  targets=("${(@f)$(mount | awk -v b="^$base" '$3 ~ b {print $3}' | sort -r)}")
  if (( ${#targets} )); then
    info "Unmounting under ${base}…"
    local m
    for m in "${targets[@]}"; do
      umount -R "$m" 2>/dev/null || umount "$m" 2>/dev/null || warn "could not umount $m"
    done
  fi
}
unmount_tree "/mnt"
unmount_tree "/media"
unmount_tree "/run/media"

# This is the new part for your specific USB exFAT partition
# I'm unmounting it with the others since it's a shared partition
# and isn't critical to the system's operation.
unmount_tree "/mnt/usb"

# Close non-root LUKS maps only (TYPE=crypt), never close 'crypt' (root)
if command -v cryptsetup &>/dev/null; then
  local -a mappers; mappers=("${(@f)$(ls /dev/mapper 2>/dev/null | grep -v '^control$' || true)}")
  local m t
  for m in "${mappers[@]}"; do
    [[ "$m" == "crypt" ]] && continue   # root mapping
    t="$(lsblk -no TYPE "/dev/mapper/$m" 2>/dev/null || echo "")"
    [[ "$t" != "crypt" ]] && continue    # skip LVM and others
    info "Closing LUKS map: $m"
    umount -R "/dev/mapper/$m" 2>/dev/null || true
    cryptsetup close "$m" 2>/dev/null || warn "could not close $m"
  done
fi

# zram/swap handling
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  info "Disabling swap…"
  swapon --show | sed 's/^/    /' || true
  swapoff -a || warn "swapoff returned non-zero"
fi
if command -v zramctl &>/dev/null; then
  local -a zdevs; zdevs=("${(@f)$(zramctl --output NAME --noheadings 2>/dev/null | grep '^/dev/zram' || true)}")
  if (( ${#zdevs} )); then
    info "Resetting zram devices…"
    local -a zswaps; zswaps=("${(@f)$(swapon --show=NAME --noheadings 2>/dev/null | grep '^/dev/zram' || true)}")
    local d
    for d in "${zswaps[@]}"; do swapoff "$d" 2>/dev/null || true; done
    for d in "${zdevs[@]}";  do zramctl --reset "$d" 2>/dev/null || warn "zram reset incomplete on $d"; done
  fi
fi

# Writeback + cache drop
info "Syncing filesystems…"
( sync; sync; sync ) &>/dev/null
info "Dropping pagecache/dentries/inodes…"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || warn "could not drop caches"

### ---------- FINAL-STATE SANITY PRINT ----------
info "Final state check (pre-poweroff):"

info "Remaining TYPE=crypt device-mapper entries:"
lsblk -rno NAME,TYPE,MOUNTPOINTS /dev/mapper 2>/dev/null | awk '$2=="crypt"{print "    "$0}' || true

info "Active mounts under /mnt, /media, /run/media:"
mount | grep -E ' on (/(mnt|media)(/| )|/run/media/)' | \
  awk '{printf "    %-20s %-20s %s\n", $1, $3, $5}' || print "    (none)"

info "NetworkManager state (if present):"
line
if command -v nmcli &>/dev/null; then
  nmcli general status 2>/dev/null | sed 's/^/    /' || true
else
  print "    nmcli not installed"
fi

ok "Teardown complete."
rm -f /run/secure-shutdown.netoff 2>/dev/null || true
print -P "%F{green}[→] Goodbye yuriy.  ヽ( ⌒ω⌒)ﾉ%f"
print
line
print -P "%F{yellow}                     - press ENTER to power off -%f              "
line

# Wait for second ENTER to power off
read -r
info "Powering off now…"
exec systemctl poweroff -i
