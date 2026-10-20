#!/bin/bash
# Shared helpers for the KallioInnovations workstation scripts.
# Sourced, never executed. Callers source ki.conf first and set:
#   KI_LIB_SRC     directory holding luks-slots.py
#   KI_ESCROW_PUB  path of escrow.pub
#
# Note for maintainers: scripts run with "set -o pipefail", so never write
# "cmd | grep -q": grep exits early, cmd gets SIGPIPE and the pipeline fails.
# Capture output first and use ki_match instead.

# ---------- output ----------
ki_step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
ki_ok()   { printf '   \033[32mOK\033[0m    %s\n' "$*"; }
ki_warn() { printf '   \033[33mWARN\033[0m  %s\n' "$*" >&2; }
ki_die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ki_match <extended regex> <text>
ki_match() { grep -Eq -- "$1" <<<"$2"; }

ki_require_root() { [ "$(id -u)" -eq 0 ] || ki_die "Run this as root (sudo)."; }

# ---------- network ----------
# Exit 0 if GitHub answers over HTTPS (DNS, routing and TLS all working).
ki_online() { curl -fsS --max-time 8 -o /dev/null https://github.com 2>/dev/null; }

# Waits for an internet connection, helping the person at the keyboard join
# Wi-Fi. Gives up after about 15 minutes. Interactive scripts only.
ki_require_network() {
  local tries=0
  ki_online && { ki_ok "Internet connection"; return 0; }
  ki_warn "No internet connection. Wi-Fi is fine; it does not need a cable."
  until ki_online; do
    tries=$((tries + 1))
    [ "$tries" -le 45 ] || ki_die "Still no internet connection after 15 minutes."
    if [ -r /dev/tty ] && command -v nmtui >/dev/null; then
      printf '   Connect from the network menu at the top right of the screen, or press Enter here to pick a Wi-Fi network.\n'
      if read -r -t 20 _ < /dev/tty; then
        nmtui connect < /dev/tty > /dev/tty 2>&1 || true
      fi
    else
      sleep 20
    fi
  done
  ki_ok "Internet connection"
}

# Makes every saved Wi-Fi connection available to all users, so the network
# kiadmin joined during setup also works at the employee's login screen.
ki_share_wifi() {
  local uuid type name flags
  command -v nmcli >/dev/null || return 0
  while IFS=: read -r uuid type; do
    [ "$type" = "802-11-wireless" ] || continue
    name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null || true)
    nmcli connection modify "$uuid" connection.permissions "" >/dev/null 2>&1 \
      || { ki_warn "Could not share Wi-Fi network: $name"; continue; }
    flags=$(nmcli -g 802-11-wireless-security.psk-flags connection show "$uuid" 2>/dev/null || true)
    case "$flags" in
      ""|0*) ki_ok "Wi-Fi network shared with all users: $name" ;;
      *) ki_warn "Wi-Fi $name: password saved for one user only; the employee types it once." ;;
    esac
  done < <(nmcli -g UUID,TYPE connection show 2>/dev/null || true)
}

# ---------- primary user ----------
# Roles: developer = admin rights (sudo), asked for their password at most once
# an hour; standard = no admin rights. Recorded in $KI_STATE_DIR/primary-user,
# which ki-check reads.
ki_valid_username() { ki_match '^[a-z][a-z0-9]{1,30}$' "$1"; }

# ki_apply_user_role <user> <developer|standard>
ki_apply_user_role() {
  local user=$1 role=$2 grp drop tmp line ok=0
  id "$user" >/dev/null 2>&1 || ki_die "No account named $user."
  [ "$user" != "$KI_ADMIN_USER" ] || ki_die "The employee account cannot be $KI_ADMIN_USER."
  drop="/etc/sudoers.d/60-ki-$user"
  case "$role" in
    developer)
      usermod -aG sudo "$user"
      # Ubuntu ships sudo-rs, which may reject options classic sudo accepts:
      # use the first line that validates.
      tmp=$(mktemp)
      for line in \
        "Defaults:$user timestamp_timeout=60, timestamp_type=global" \
        "Defaults:$user timestamp_timeout=60"; do
        printf '# KallioInnovations: developer %s, sudo password at most once an hour\n%s\n' "$user" "$line" > "$tmp"
        if visudo -cqf "$tmp" >/dev/null 2>&1; then ok=1; break; fi
      done
      if [ "$ok" -eq 1 ]; then
        install -m 0440 -o root -g root "$tmp" "$drop"
      else
        rm -f "$drop"
        ki_warn "sudo password caching not changed (no option validated); sudo still works"
      fi
      rm -f "$tmp"
      ki_ok "$user is a developer: admin rights via sudo with their own password"
      ;;
    standard)
      for grp in sudo adm; do
        if ki_match "^${grp}\$" "$(id -nG "$user" | tr ' ' '\n')"; then
          gpasswd -d "$user" "$grp" >/dev/null
          ki_warn "Removed $user from $grp"
        fi
      done
      rm -f "$drop"
      ki_ok "$user is a standard user: no admin rights"
      ;;
    *) ki_die "Role must be developer or standard, not: $role" ;;
  esac
  install -d -m 0755 "$KI_STATE_DIR"
  printf 'user=%s\nrole=%s\n' "$user" "$role" > "$KI_STATE_DIR/primary-user"
  chmod 0644 "$KI_STATE_DIR/primary-user"
}

# ki_primary_user_field <user|role> - prints the recorded value, or nothing.
ki_primary_user_field() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$KI_STATE_DIR/primary-user" 2>/dev/null || true
}

# ---------- Tailscale ----------
# Prints the user allowed to run "tailscale up/down" without sudo, or nothing.
ki_tailscale_operator_now() {
  local prefs
  prefs=$(tailscale debug prefs 2>/dev/null) || return 0
  python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("OperatorUser") or "")' <<<"$prefs" 2>/dev/null || true
}

# ki_tailscale_operator <user> - waits for tailscaled (it is slow to start right
# after install), sets the operator and verifies it. Exit 1 if it did not stick.
ki_tailscale_operator() {
  local user=$1
  for _ in $(seq 1 30); do
    [ -S /var/run/tailscale/tailscaled.sock ] && tailscale set --operator="$user" >/dev/null 2>&1 && break
    sleep 1
  done
  [ "$(ki_tailscale_operator_now)" = "$user" ]
}

# ---------- machine identity ----------
ki_serial() {
  local s
  s=$(tr -cd '[:alnum:]' < /sys/class/dmi/id/product_serial | tr '[:upper:]' '[:lower:]')
  [ -n "$s" ] || ki_die "Could not read the serial number from /sys/class/dmi/id/product_serial."
  printf '%s' "$s"
}

ki_expected_hostname() { printf '%s%s' "$KI_HOST_PREFIX" "$(ki_serial)"; }

# ---------- disk encryption ----------
# Prints the single LUKS partition, or dies.
ki_luks_device() {
  local devs count
  devs=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null || true)
  count=$(grep -c . <<<"$devs" || true)
  [ "$count" -eq 1 ] || ki_die "Expected exactly one LUKS partition, found ${count}: ${devs:-none}"
  printf '%s' "$devs"
}

# Prints "tpm2 <slot> <pcrs>" / "other <slot>" lines for a LUKS2 device.
ki_luks_slots() {
  cryptsetup luksDump --dump-json-metadata "$1" | python3 -I "$KI_LIB_SRC/luks-slots.py"
}

# Exit 0 if the TPM token unlocks the device right now (without activating it).
ki_tpm_unlocks() {
  cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 "$1" >/dev/null 2>&1
}

# Exit 0 if the key file itself unlocks the device. Token plugins are disabled:
# otherwise cryptsetup tries the TPM token first and reports success whatever
# the key file holds.
ki_keyfile_unlocks() {
  cryptsetup open --test-passphrase --disable-external-tokens --key-file "$2" "$1" >/dev/null 2>&1
}

# ---------- secrets ----------
# ki_random <alphabet> <length>
ki_random() {
  local out
  out=$(head -c 8192 /dev/urandom | LC_ALL=C tr -dc "$1" | cut -c1-"$2")
  [ "${#out}" -eq "$2" ] || ki_die "Random secret generation failed."
  printf '%s' "$out"
}

# 8 groups of 4 characters, no look-alike letters: easy to read out and type at boot.
ki_recovery_key() {
  ki_random 'abcdefghjkmnpqrstuvwxyz23456789' 32 | sed 's/.\{4\}/&-/g; s/-$//'
}

ki_password() { ki_random 'A-Za-z0-9' "${1:-24}"; }

# ki_seal <output file>  - encrypts stdin to the company escrow public key.
# Callers set KI_ESCROW_PUB to the escrow.pub file to use.
ki_check_escrow_pub() {
  [ -f "$KI_ESCROW_PUB" ] && ki_match '^age1[0-9a-z]{58}$' "$(head -n1 "$KI_ESCROW_PUB")" \
    || ki_die "escrow.pub does not contain the company age public key (age1...). See README."
}
ki_seal() {
  ki_check_escrow_pub
  install -d -m 0755 "$KI_ESCROW_DIR"
  age -a -R "$KI_ESCROW_PUB" -o "$1"
  chmod 0644 "$1"   # encrypted; readable so it can be copied off without root
}

# ---------- initramfs ----------
# Rebuild the initramfs of every installed kernel with dracut.
ki_rebuild_initramfs() {
  local vmlinuz ver
  for vmlinuz in /boot/vmlinuz-*; do
    ver=${vmlinuz#/boot/vmlinuz-}
    [ -d "/lib/modules/$ver" ] || continue
    dracut --force --quiet "/boot/initrd.img-$ver" "$ver"
  done
}

# Exit 0 if the initramfs can unlock the root disk with the TPM.
ki_initramfs_has_tpm() {
  local img=$1 listing crypttab
  [ -f "$img" ] || return 1
  listing=$(lsinitrd "$img" 2>/dev/null) || return 1
  crypttab=$(lsinitrd -f etc/crypttab "$img" 2>/dev/null) || return 1
  ki_match 'libtss2-esys' "$listing" && ki_match 'tpm2-device=auto' "$crypttab"
}

# ---------- GRUB ----------
# ki_apply_grub_lock <pbkdf2 hash> <luks uuid> <crypttab options>
# Booting the default entries needs no password; editing the kernel command
# line, the boot menu's advanced/recovery entries and the GRUB shell do.
ki_apply_grub_lock() {
  local hash=$1 uuid=$2 opts=$3 cfg
  cat > /etc/grub.d/01_ki_password << EOF
#!/bin/sh
# KallioInnovations: GRUB superuser. Password is in device escrow.
cat << 'GRUBEOF'
set superusers="${KI_ADMIN_USER}"
password_pbkdf2 ${KI_ADMIN_USER} ${hash}
GRUBEOF
EOF
  chmod 0700 /etc/grub.d/01_ki_password

  if ! grep -q -- '--class os --unrestricted"' /etc/grub.d/10_linux; then
    sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"$/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
    grep -q -- '--class os --unrestricted"' /etc/grub.d/10_linux \
      || ki_die "Could not mark Ubuntu boot entries unrestricted in /etc/grub.d/10_linux."
  fi

  install -d /etc/default/grub.d
  cat > /etc/default/grub.d/90-ki.cfg << EOF
# KallioInnovations: no recovery entries (they give a root shell), no initramfs
# shell, and TPM unlock options for the root disk.
GRUB_DISABLE_RECOVERY="true"
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX} rd.luks.options=${uuid}=${opts} rd.shell=0"
EOF

  update-grub >/dev/null 2>&1 || ki_die "update-grub failed."
  cfg=$(cat /boot/grub/grub.cfg)
  ki_match "password_pbkdf2 ${KI_ADMIN_USER} grub\.pbkdf2" "$cfg" || ki_die "GRUB password missing from grub.cfg."
  ki_match '--unrestricted' "$cfg" || ki_die "Unrestricted boot entries missing from grub.cfg."
  ki_match "rd\.luks\.options=${uuid}" "$cfg" || ki_die "TPM unlock options missing from the kernel command line."
}

# ki_grub_hash <password>
ki_grub_hash() {
  local out
  out=$(printf '%s\n%s\n' "$1" "$1" | grub-mkpasswd-pbkdf2 2>/dev/null)
  out=$(grep -Eo 'grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F.]+' <<<"$out" || true)
  [ -n "$out" ] || ki_die "grub-mkpasswd-pbkdf2 failed."
  printf '%s' "$out"
}

# ---------- managed data (shared by bootstrap.sh and ki-sync) ----------
# Prints the entries of a list file: comments and blank lines removed.
ki_list_entries() {
  [ -f "$1" ] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

# ki_apply_apps <config dir>
ki_apply_apps() {
  local dir=$1 line name opt pkgs=()
  while IFS= read -r line; do
    if ki_match '^[a-z0-9][a-z0-9+.-]+$' "$line"; then pkgs+=("$line")
    else ki_warn "Ignoring invalid package name: $line"; fi
  done < <(ki_list_entries "$dir/apt-packages.txt")
  if [ "${#pkgs[@]}" -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" >/dev/null \
      && ki_ok "Packages: ${pkgs[*]}" \
      || ki_warn "Some packages failed to install: ${pkgs[*]}"
  fi

  command -v snap >/dev/null || return 0
  while IFS= read -r line; do
    read -r name opt <<<"$line"
    if ! ki_match '^[a-z0-9][a-z0-9-]*$' "$name" || { [ -n "${opt:-}" ] && [ "$opt" != "--classic" ]; }; then
      ki_warn "Ignoring invalid snap entry: $line"; continue
    fi
    snap list "$name" >/dev/null 2>&1 && continue
    # shellcheck disable=SC2086
    snap install "$name" ${opt:-} >/dev/null && ki_ok "Snap: $name" || ki_warn "Snap failed: $name"
  done < <(ki_list_entries "$dir/snaps.txt")
}

# ki_apply_hosts <hosts file>
ki_apply_hosts() {
  local line block="" tmp
  while IFS= read -r line; do
    if ki_match '^([0-9]{1,3}\.){3}[0-9]{1,3}([[:space:]]+[a-z0-9][a-z0-9.-]*)+$' "$line"; then
      block+="$line"$'\n'
    else
      ki_warn "Ignoring invalid hosts entry: $line"
    fi
  done < <(ki_list_entries "$1")
  tmp=$(mktemp)
  awk '/^# BEGIN KI managed/{skip=1; next} /^# END KI managed/{skip=0; next} !skip' /etc/hosts > "$tmp"
  {
    printf '# BEGIN KI managed (edit config/hosts in workstation-bootstrap, not here)\n'
    printf '%s' "$block"
    printf '# END KI managed\n'
  } >> "$tmp"
  cat "$tmp" > /etc/hosts   # keep the file's owner and permissions
  rm -f "$tmp"
}

ki_dconf_profile() {
  install -d /etc/dconf/profile /etc/dconf/db/local.d/locks
  printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
}

# ki_apply_branding <branding dir>
ki_apply_branding() {
  local dir=$1 f bg="$KI_BACKGROUND_DIR"
  install -d -m 0755 "$bg"
  for f in ki-wallpaper-dark.png ki-wallpaper-light.png; do
    [ -f "$dir/$f" ] || continue
    [ "$(file -b --mime-type "$dir/$f")" = "image/png" ] || { ki_warn "Not a PNG, skipped: $f"; continue; }
    install -m 0644 "$dir/$f" "$bg/$f"
  done
  ki_dconf_profile
  cat > /etc/dconf/db/local.d/01-ki-branding << EOF
# KallioInnovations default wallpaper (users may change it)
[org/gnome/desktop/background]
picture-uri='file://${bg}/ki-wallpaper-light.png'
picture-uri-dark='file://${bg}/ki-wallpaper-dark.png'
picture-options='zoom'
primary-color='#1A1A1A'

[org/gnome/desktop/screensaver]
picture-uri='file://${bg}/ki-wallpaper-dark.png'
picture-options='zoom'
primary-color='#1A1A1A'
EOF
  dconf update
}
