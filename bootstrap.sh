#!/bin/bash
# KallioInnovations workstation bootstrap - run once, on the first boot after
# the automated install, logged in as kiadmin:
#
#   git clone https://github.com/KallioInnovations-Oy/workstation-bootstrap.git
#   sudo bash workstation-bootstrap/bootstrap.sh <username>
#
# <username> is the employee's account (first name + last initial, e.g. villem).
#
# Takes 20-40 minutes. It asks for input once, near the end: confirm that the
# sealed escrow file has been stored. After that the disk unlocks with the TPM,
# the install passphrase and install kiadmin password stop working, and the
# only way back in for IT is the escrow file.
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config/ki.conf
source "$REPO_DIR/config/ki.conf"
KI_LIB_SRC="$REPO_DIR/lib"
KI_ESCROW_PUB="$REPO_DIR/escrow.pub"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

STEP="preflight"
SECRETS=""
cleanup() {
  if [ -n "$SECRETS" ] && [ -d "$SECRETS" ]; then
    find "$SECRETS" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$SECRETS"
  fi
}
trap cleanup EXIT
trap 'printf "\n\033[1;31mBOOTSTRAP FAILED\033[0m during: %s (line %s)\nNothing after this step ran. Fix the cause and run the script again.\n" "$STEP" "$LINENO" >&2' ERR

USERNAME=${1:-}
LOG=/var/log/ki-bootstrap.log

# =====================================================================
ki_step "0/12 Preflight checks"
# =====================================================================
ki_require_root
[ -n "$USERNAME" ] || ki_die "Usage: sudo bash bootstrap.sh <username>   (e.g. villem)"
ki_match '^[a-z][a-z0-9]{1,30}$' "$USERNAME" || ki_die "Username must be lowercase letters and digits, e.g. villem."
[ "$USERNAME" != "$KI_ADMIN_USER" ] || ki_die "The employee account cannot be $KI_ADMIN_USER."

# shellcheck source=/dev/null
. /etc/os-release
[ "${VERSION_ID:-}" = "$KI_OS_VERSION" ] || ki_die "This is Ubuntu ${VERSION_ID:-unknown}; the standard is $KI_OS_VERSION."
ki_ok "Ubuntu $VERSION_ID"

ki_check_escrow_pub
ki_ok "Escrow public key present"

SB=$(mokutil --sb-state 2>&1 || true)
ki_match 'SecureBoot enabled' "$SB" || ki_die "Secure Boot is off. Turn it on in the BIOS (section 2 of the procedure)."
ki_ok "Secure Boot enabled"

[ -e /dev/tpmrm0 ] || ki_die "No TPM 2.0 found. Enable the Security Chip in the BIOS."
ki_ok "TPM 2.0 present"

DEV=$(ki_luks_device)
LUKS_VERSION=$(cryptsetup luksDump "$DEV" | awk '/^Version:/ {print $2}')
[ "$LUKS_VERSION" = "2" ] || ki_die "$DEV is LUKS$LUKS_VERSION; TPM unlock needs LUKS2. Reinstall with autoinstall.yaml."
UUID=$(cryptsetup luksUUID "$DEV")
ki_ok "Encrypted disk $DEV (LUKS2, $UUID)"

SECRETS=$(mktemp -d /run/ki-bootstrap.XXXXXX)
chmod 0700 "$SECRETS"
printf '%s' "$KI_INSTALL_LUKS_PASSPHRASE" > "$SECRETS/install.key"
ki_keyfile_unlocks "$DEV" "$SECRETS/install.key" \
  || ki_die "The install passphrase does not unlock $DEV. Either this machine is already bootstrapped (use ki-rotate) or it was not installed with autoinstall.yaml."
ki_ok "Install passphrase still active (expected before bootstrap)"

command -v dracut >/dev/null && command -v lsinitrd >/dev/null \
  || ki_die "dracut is not installed; Ubuntu $KI_OS_VERSION should build its initramfs with dracut."
MODULES=$(lsinitrd -m "/boot/initrd.img-$(uname -r)" 2>/dev/null || true)
ki_match '^systemd$' "$MODULES" || ki_die "The current initramfs is not a dracut/systemd image; TPM unlock would not work."
ki_ok "initramfs built by dracut with systemd"

AC=$(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo 0)
[ "$AC" = "1" ] || ki_warn "Not on mains power. Plug in the charger; firmware updates need it."

touch "$LOG"; chmod 0600 "$LOG"   # holds the first-login password
exec > >(tee -a "$LOG") 2>&1
quiet() { "$@" >> "$LOG" 2>&1; }   # detail goes to the log only
echo "Bootstrap started $(date -Iseconds) for user $USERNAME" >> "$LOG"

# =====================================================================
STEP="hostname"; ki_step "1/12 Hostname from serial number"
# =====================================================================
SERIAL=$(ki_serial)
HOST=$(ki_expected_hostname)
hostnamectl set-hostname "$HOST"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOST}/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$HOST" >> /etc/hosts
fi
ki_ok "$HOST"

# =====================================================================
STEP="updates and packages"; ki_step "2/12 Updates and packages (the slow part)"
# =====================================================================
export DEBIAN_FRONTEND=noninteractive
quiet apt-get update -q
quiet apt-get full-upgrade -y -q
quiet apt-get install -y -q ufw auditd apparmor-utils tpm2-tools systemd-cryptsetup age git curl fwupd file
ki_ok "System up to date, security tools installed"
ki_apply_apps "$REPO_DIR/config"

# =====================================================================
STEP="hardening"; ki_step "3/12 Hardening"
# =====================================================================
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Keep our edited /etc/grub.d/10_linux on GRUB updates instead of skipping them.
cat > /etc/apt/apt.conf.d/52ki-keep-config << 'EOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1
ki_ok "Automatic security updates"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
ki_ok "Firewall: deny incoming"

cat > /etc/audit/rules.d/50-ki.rules << 'EOF'
# KallioInnovations audit rules
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/pam.d/ -p wa -k pam
-w /etc/crypttab -p wa -k disk_encryption
-w /usr/bin/sudo -p x -k priv_esc
-w /usr/bin/su -p x -k priv_esc
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_cmd
EOF
augenrules --load >/dev/null 2>&1 || true
systemctl enable --now auditd >/dev/null 2>&1
ki_ok "Audit logging"

cat > /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
EOF
cat > /usr/share/pam-configs/faillock << 'EOF'
Name: Lock account after repeated failed logins
Default: no
Priority: 0
Auth-Type: Primary
Auth:
	[default=die] pam_faillock.so authfail
EOF
cat > /usr/share/pam-configs/faillock_notify << 'EOF'
Name: Check failed-login counter and reset on success
Default: no
Priority: 1024
Auth-Type: Primary
Auth:
	requisite pam_faillock.so preauth
Account-Type: Primary
Account:
	required pam_faillock.so
EOF
pam-auth-update --package --enable faillock faillock_notify
ki_ok "Lock account for 15 min after 5 failed logins"

ki_dconf_profile
cat > /etc/dconf/db/local.d/00-ki-security << 'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0

[org/gnome/desktop/notifications]
show-in-lock-screen=false

[org/gnome/desktop/media-handling]
autorun-never=true
EOF
cat > /etc/dconf/db/local.d/locks/00-ki-security << 'EOF'
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/notifications/show-in-lock-screen
/org/gnome/desktop/media-handling/autorun-never
EOF
dconf update
ki_ok "Screen locks after 5 minutes (users cannot change it)"

AA=$(aa-enabled 2>&1 || true)
[ "$AA" = "Yes" ] && ki_ok "AppArmor enabled" || ki_warn "AppArmor reports: $AA"

# =====================================================================
STEP="branding and hosts"; ki_step "4/12 Wallpaper and internal hostnames"
# =====================================================================
ki_apply_branding "$REPO_DIR/branding"
ki_ok "KallioInnovations wallpaper"
ki_apply_hosts "$REPO_DIR/config/hosts"
ki_ok "Staging hostnames in /etc/hosts"

# =====================================================================
STEP="TPM unlock"; ki_step "5/12 Disk unlock with the TPM"
# =====================================================================
DRACUT_MODS=$(dracut --list-modules 2>/dev/null || true)
ki_match '^tpm2-tss$' "$DRACUT_MODS" || ki_die "dracut has no tpm2-tss module."
{
  echo '# KallioInnovations: unlock the root disk with the TPM'
  echo 'add_dracutmodules+=" tpm2-tss "'
  ki_match '^systemd-cryptsetup$' "$DRACUT_MODS" && echo 'add_dracutmodules+=" systemd-cryptsetup "'
  echo 'install_items+=" /etc/crypttab "'
} > /etc/dracut.conf.d/90-ki-tpm2.conf

[ -f /etc/crypttab.ki-orig ] || cp -a /etc/crypttab /etc/crypttab.ki-orig
awk -v uuid="$UUID" 'BEGIN { OFS = "\t" }
  $1 !~ /^#/ && index($0, uuid) {
    found = 1
    if (NF < 3) $3 = "none"
    if (NF < 4) $4 = "luks"
    if ($4 !~ /tpm2-device=/) $4 = $4 ",tpm2-device=auto"
  }
  { print }
  END { if (!found) exit 3 }' /etc/crypttab.ki-orig > /etc/crypttab.ki-new \
  || ki_die "/etc/crypttab has no entry for $UUID."
mv /etc/crypttab.ki-new /etc/crypttab
CRYPT_OPTS=$(awk -v uuid="$UUID" '$1 !~ /^#/ && index($0, uuid) {print $4}' /etc/crypttab)
ki_ok "crypttab: $CRYPT_OPTS"

quiet systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 \
  --unlock-key-file="$SECRETS/install.key" "$DEV"
ki_tpm_unlocks "$DEV" || ki_die "The TPM was enrolled but cannot unlock the disk."
ki_ok "TPM enrolled (bound to Secure Boot state, PCR 7) and tested"

ki_rebuild_initramfs
for img in /boot/initrd.img-*; do
  ki_initramfs_has_tpm "$img" || ki_die "$img lacks TPM unlock support."
done
ki_ok "initramfs rebuilt with TPM support"

# =====================================================================
STEP="recovery key"; ki_step "6/12 Recovery key"
# =====================================================================
RECOVERY=$(ki_recovery_key)
printf '%s' "$RECOVERY" > "$SECRETS/recovery.key"
if ki_match '^other 7$' "$(ki_luks_slots "$DEV")"; then
  cryptsetup luksKillSlot --key-file "$SECRETS/install.key" "$DEV" 7
fi
cryptsetup luksAddKey --key-file "$SECRETS/install.key" --key-slot 7 "$DEV" "$SECRETS/recovery.key"
ki_keyfile_unlocks "$DEV" "$SECRETS/recovery.key" || ki_die "The new recovery key does not unlock the disk."
ki_ok "Recovery key in slot 7, tested"

# =====================================================================
STEP="GRUB lock"; ki_step "7/12 Boot menu lock"
# =====================================================================
GRUB_PW=$(ki_password 20)
ki_apply_grub_lock "$(ki_grub_hash "$GRUB_PW")" "$UUID" "$CRYPT_OPTS"
ki_ok "Boot entries start without a password; editing them needs the GRUB password"

# =====================================================================
STEP="user account"; ki_step "8/12 Employee account"
# =====================================================================
USER_PW=""
if id "$USERNAME" >/dev/null 2>&1; then
  ki_warn "$USERNAME already exists; password left unchanged"
else
  useradd -m -s /bin/bash "$USERNAME"
  USER_PW=$(ki_random 'abcdefghjkmnpqrstuvwxyz23456789' 12)
  printf '%s:%s\n' "$USERNAME" "$USER_PW" | chpasswd
  chage -d 0 "$USERNAME"   # must choose a new password at first login
  ki_ok "$USERNAME created (no admin rights). First-login password: $USER_PW"
fi
for grp in sudo adm; do
  if ki_match "^${grp}\$" "$(id -nG "$USERNAME" | tr ' ' '\n')"; then
    gpasswd -d "$USERNAME" "$grp" >/dev/null
    ki_warn "Removed $USERNAME from $grp"
  fi
done

# =====================================================================
STEP="Tailscale"; ki_step "9/12 Tailscale"
# =====================================================================
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh -o "$SECRETS/tailscale-install.sh"
  quiet sh "$SECRETS/tailscale-install.sh"
fi
systemctl enable --now tailscaled >/dev/null 2>&1
if tailscale set --operator="$USERNAME" --hostname="$HOST" 2>/dev/null; then
  ki_ok "Installed; $USERNAME signs in with: tailscale up"
else
  ki_warn "Could not pre-set the Tailscale operator. After handover IT runs: sudo tailscale up --operator=$USERNAME"
fi

# =====================================================================
STEP="KI tools"; ki_step "10/12 KI maintenance tools"
# =====================================================================
install -d -m 0755 "$KI_LIB_DIR" "$KI_STATE_DIR" "$KI_ESCROW_DIR"
install -m 0644 "$REPO_DIR/config/ki.conf" "$KI_LIB_DIR/ki.conf"
install -m 0644 "$REPO_DIR/lib/common.sh" "$KI_LIB_DIR/common.sh"
install -m 0755 "$REPO_DIR/lib/luks-slots.py" "$KI_LIB_DIR/luks-slots.py"
install -m 0644 "$REPO_DIR/escrow.pub" "$KI_LIB_DIR/escrow.pub"
for tool in "$REPO_DIR"/sbin/ki-*; do
  install -m 0755 "$tool" "/usr/local/sbin/$(basename "$tool")"
done
install -m 0644 "$REPO_DIR"/systemd/ki-*.service "$REPO_DIR"/systemd/ki-*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable ki-tpm-reseal.service ki-check.timer ki-sync.timer >/dev/null 2>&1

# Root-owned copy of the repo that ki-sync reads data (apps, hosts, wallpaper) from.
rm -rf "$KI_SYNC_DIR"
install -d -m 0755 "$(dirname "$KI_SYNC_DIR")"
git clone -q --depth 1 "$KI_REPO_URL" "$KI_SYNC_DIR"
ki_ok "ki-check, ki-sync, ki-firmware-update, ki-rotate installed"

# =====================================================================
STEP="firmware"; ki_step "11/12 Firmware updates"
# =====================================================================
/usr/local/sbin/ki-firmware-update --from-bootstrap || ki_warn "Firmware update did not complete; run: sudo ki-firmware-update"

# =====================================================================
STEP="escrow"; ki_step "12/12 Escrow and removal of install secrets"
# =====================================================================
ADMIN_PW=$(ki_password 24)
ESCROW_FILE="$KI_ESCROW_DIR/${SERIAL}-$(date +%Y%m%d-%H%M).age"
printf 'host=%s\nserial=%s\nuser=%s\ndevice=%s\nluks_uuid=%s\ncreated=%s\nrecovery_key=%s\nkiadmin_password=%s\ngrub_user=%s\ngrub_password=%s\n' \
  "$HOST" "$SERIAL" "$USERNAME" "$DEV" "$UUID" "$(date -Iseconds)" \
  "$RECOVERY" "$ADMIN_PW" "$KI_ADMIN_USER" "$GRUB_PW" | ki_seal "$ESCROW_FILE"
unset RECOVERY GRUB_PW

cat << EOF

  Sealed escrow file: $ESCROW_FILE
  Store it in the private device-escrow repo as:  ${SERIAL}/$(basename "$ESCROW_FILE")

  Easiest: open https://github.com/KallioInnovations-Oy/device-escrow in Firefox
  on this laptop, Add file > Upload files, pick the file above, commit, then sign
  out of GitHub. The file is encrypted, so any copy route is fine.

  Nothing changes until you type SAVED. Then the install disk passphrase and the
  install kiadmin password stop working, and this file is IT's only way back in.

$(cat "$ESCROW_FILE")

EOF
while :; do
  read -r -p "Type SAVED when the file is in device-escrow: " ANSWER < /dev/tty \
    || ki_die "No terminal to confirm on. Run bootstrap.sh from a terminal on the laptop."
  [ "$ANSWER" = "SAVED" ] && break
done

# Only now that the escrow file is stored: replace the install secrets.
printf '%s:%s\n' "$KI_ADMIN_USER" "$ADMIN_PW" | chpasswd
unset ADMIN_PW
# Remove every slot holding the install passphrase (the installer may add more than one).
for _ in 1 2 3 4 5 6 7 8; do
  ki_keyfile_unlocks "$DEV" "$SECRETS/install.key" || break
  cryptsetup luksRemoveKey --disable-external-tokens "$DEV" "$SECRETS/install.key"
done
if ki_keyfile_unlocks "$DEV" "$SECRETS/install.key"; then
  ki_die "The install passphrase still unlocks the disk."
fi
ki_ok "Install disk passphrase removed"
ki_ok "kiadmin password replaced (in escrow)"

STEP="final check"
/usr/local/sbin/ki-check --pre-reboot || true

cat << EOF

================================================================
  Bootstrap complete: $HOST
================================================================
  Next:
  1. Reboot. It must go straight to the login screen, with no
     disk passphrase prompt. (Firmware updates may add a reboot.)
  2. The employee logs in as: $USERNAME
EOF
[ -n "$USER_PW" ] && echo "     First-login password:   $USER_PW   (must be changed at login)"
cat << EOF
  3. The employee runs:  tailscale up   and signs in.
  4. Settings > System > Users > Fingerprint Login.
  5. Check the result any time:  cat /var/log/ki-check.txt
================================================================
EOF
echo "Bootstrap finished $(date -Iseconds)" >> "$LOG"
