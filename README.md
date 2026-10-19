# workstation-bootstrap

Builds a KallioInnovations laptop (Ubuntu Desktop 26.04 LTS, reference model
Lenovo ThinkPad T14 Gen 1) from a blank disk to a hardened, handed-over machine,
with about 15 minutes of hands-on work.

The result boots straight to the login screen: the disk is LUKS2-encrypted and
unlocked by the TPM, the boot menu is locked, and every machine-specific secret
is sealed to the company escrow key.

**This repo is public on purpose.** Laptops fetch it without credentials. It
contains no secrets: the two install values in `autoinstall.yaml` and
`config/ki.conf` are replaced by `bootstrap.sh` on every machine, and
`ki-check` fails if either still works.

## One-time setup (IT)

1. Create the escrow key pair on a trusted machine (Windows: `winget install FiloSottile.age`):
   ```
   age-keygen -o ki-escrow.key
   ```
   - Put `ki-escrow.key` in the company password vault and print a copy for the safe, then delete the local file.
   - Put the printed `age1...` public key in `escrow.pub` (replacing the placeholder) and commit.
2. Create the private repo `KallioInnovations-Oy/device-escrow` (see its README).
3. Optional: a short URL for the installer, e.g. `https://kallioinnovations.fi/ws`
   redirecting to the raw `autoinstall.yaml` URL, so nobody has to type the long one.

## Install day, per laptop

| Step | Hands-on | What to do |
| --- | --- | --- |
| 1. BIOS | 10 min | Supervisor password, Secure Boot on, Security Chip (TPM) on, Intel AMT off. **No power-on password.** See the procedure doc. |
| 2. Install | 2 min | Boot the Ubuntu 26.04.1 Desktop USB, choose **Automated installation**, give the URL below. Wipes the disk, no questions. |
| 3. Bootstrap | 5 min | Log in as `kiadmin` (password `ki-install-temporary`), open a terminal and run the two commands below. |
| 4. Escrow | 2 min | When asked, store the sealed file in `device-escrow`, type `SAVED`. |
| 5. Handover | 5 min | Reboot (no disk passphrase prompt). The employee logs in, sets a password, runs `tailscale up`, enrolls a fingerprint. |

Autoinstall URL:
```
https://raw.githubusercontent.com/KallioInnovations-Oy/workstation-bootstrap/main/autoinstall.yaml
```

Bootstrap (replace `villem` with the employee's username):
```
git clone https://github.com/KallioInnovations-Oy/workstation-bootstrap.git
sudo bash workstation-bootstrap/bootstrap.sh villem
```

The bootstrap stops at the first error, says which step failed, and can be run
again after fixing the cause. Its full log is `/var/log/ki-bootstrap.log`.

## What bootstrap.sh does

1. Checks: Ubuntu 26.04, Secure Boot on, TPM present, one LUKS2 disk, escrow key set.
2. Hostname `ki-ws-<serial>`.
3. Updates; installs the tools and the apps in `config/`.
4. Hardening: auto security updates, firewall (deny incoming), audit rules, lockout after 5 failed logins, enforced 5-minute screen lock.
5. Wallpaper and internal hostnames.
6. TPM unlock bound to Secure Boot state (PCR 7); initramfs rebuilt and checked.
7. Recovery key in LUKS slot 7, tested.
8. Boot menu lock: entries boot without a password, editing them needs the GRUB password; recovery entries and the initramfs shell are disabled.
9. Employee account, no admin rights, password must be changed at first login.
10. Tailscale installed; the employee signs in so the device belongs to them.
11. Installs the maintenance tools below and their timers.
12. Firmware updates.
13. Seals recovery key + new random `kiadmin` password + GRUB password into one escrow file, waits for `SAVED`, then removes the install passphrase and install password.

## Maintenance tools on every laptop

| Command | When |
| --- | --- |
| `cat /var/log/ki-check.txt` | Anyone: latest compliance result (runs at boot and daily). |
| `sudo ki-check` | Run the check now. |
| `sudo ki-firmware-update` | BIOS/firmware updates without a recovery prompt afterwards. |
| `sudo ki-rotate "reason"` | After a recovery, after IT used the kiadmin password, when reissuing the laptop. |
| `ki-sync` (daily timer) | Pulls this repo and applies `config/apt-packages.txt`, `config/snaps.txt`, `config/hosts` and `branding/`. |

`sudo` needs the kiadmin password from the machine's escrow file.

## Changing apps, hostnames or the wallpaper

Edit the files in `config/` or `branding/` and commit to `main`. Every laptop
picks the change up within a day. `ki-sync` only reads data: it never runs code
from this repo, it validates every package name, snap name, hosts line and image,
and removing a line never uninstalls anything. Changes to scripts reach existing
laptops only through IT (Phase 2: Ansible).

## Recovering a laptop

1. Find the newest file for its serial in `device-escrow`.
2. Decrypt on a trusted machine with the escrow key from the vault:
   `age -d -i ki-escrow.key <file>.age`
3. Disk won't unlock: type `recovery_key` at the passphrase prompt.
   Admin access: log in as `kiadmin` with `kiadmin_password`.
4. Afterwards, on the laptop: `sudo ki-rotate "recovery after ..."` and store the new file.

## Not yet tested on hardware

The scripts have been linted and their disk-slot, crypttab, hosts and escrow
logic tested against a LUKS2 image, but not booted on a ThinkPad. The first real
install is the test; if a step fails, the error names it.
