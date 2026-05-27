# Encrypted-root golden template build (host-side, one-time)

**Audience:** whoever has **root on the Proxmox host `pve-4`** (the person who built template `9200`).
**Goal:** build a UEFI template (e.g. **`9011`**) with a **LUKS2-encrypted root** that each clone
auto-unlocks from its **own virtual TPM** via **Clevis**, plus a kept recovery passphrase.

This is the only step that needs host access. Once the template exists, everything else (clone settings,
data-disk encryption, redeploy) runs through the normal VM/API workflow — see
[`disk-encryption.md`](./disk-encryption.md) for the full design, operations, and residual risk.

---

## Quick start — use the script

`scripts/build-encrypted-template.sh` does the whole build (ISO fetch + checksum, autoinstall with
encrypted-LVM root, clevis + TPM tooling, generalization, templating, and a smoke test). Copy it to
`pve-4` and run as root:

```bash
# from your workstation:
scp scripts/build-encrypted-template.sh root@10.10.16.249:/root/

# on pve-4 (verify you have the current copy — must print a number, not 0):
grep -c clevis /root/build-encrypted-template.sh

# build (give it a free IP for the install-time package download; gateway/DNS default to the tfvars):
./build-encrypted-template.sh all --ip 10.10.16.79/24
#   default mode pauses for ONE console action (web UI -> VM -> Console -> at GRUB press 'e',
#   add 'autoinstall', Ctrl-x). Add --headless to skip that (needs: apt-get install -y xorriso).
```

It powers off, converts to a template, then clones a smoke-test VM with a vTPM for validation.

## What the script produces

- **UEFI/OVMF**, LUKS2-encrypted root (subiquity guided encrypted-LVM: `ubuntu-vg/ubuntu-lv`).
- **Clevis** (`clevis-initramfs` + `clevis-tpm2`) bound to the per-VM TPM on first boot, so root unlocks
  with no passphrase. (Clevis — *not* `systemd-cryptenroll` — because Ubuntu 22.04's classic initramfs
  ignores `tpm2-device=`. See `disk-encryption.md`.)
- **Recovery passphrase kept** (the install-time key, in `/root/luks-template/tempkey`) so a TPM problem
  can never brick a node. Back this up out-of-band; rotate post-deploy if policy requires.
- **Generalized** for cloning: no baked IP/netplan, blank machine-id, no SSH host keys, cloud-init
  datasource pinned to NoCloud — so each clone gets its own IP/identity from Proxmox cloud-init.

## Validate before trusting it (the smoke test does this)

1. The clone boots **straight to a login prompt — no passphrase** (clevis enrolled on first boot).
2. **Reboot it** and confirm it still reaches login with no passphrase → TPM unlock is live.
3. **Pull the TPM** (`qm set <id> --delete tpmstate0 && qm start <id>`) → it **must block** on
   `Please unlock disk` → proof the disk is genuinely encrypted and TPM-bound.

## Before a fresh cluster deploy — remove the first-boot reboot

Templates built before the latest script reboot the node once during clevis enrollment, which races the
Terraform provisioner during `deploy.sh`. The current script no longer does this. To patch an existing
template in place (clone → strip the reboot → re-template):

```bash
qm clone 9011 9020 --full && qm set 9020 --vga std && qm start 9020 && sleep 90
qm guest exec 9020 -- bash -c "sed -i '/systemctl reboot/d' /usr/local/sbin/tpm-enroll.sh; grep -c 'systemctl reboot' /usr/local/sbin/tpm-enroll.sh"  # must print 0
qm guest exec 9020 -- bash -c 'truncate --size=0 /etc/machine-id; rm -f /etc/ssh/ssh_host_* /etc/netplan/*.yaml /etc/cloud/cloud.cfg.d/90-installer-network.cfg; rm -rf /var/lib/cloud/*'
qm shutdown 9020   # wait: qm status 9020 -> stopped
qm destroy 9011 && qm template 9020
# then set vm_template_id = 9020 in the cluster's proxmox.tfvars
```

## Manual build (fallback, if you can't run the script)

The script is authoritative; if you must build by hand, mirror what it does: Ubuntu 22.04 live-server
**autoinstall** with `storage: layout: {name: lvm, password: <key>}` (encrypted LVM root), install
`clevis clevis-luks clevis-initramfs clevis-tpm2 cryptsetup-initramfs tpm2-tools qemu-guest-agent`, embed
a temporary keyfile in the initramfs for the first unattended boot, and a `tpm-enroll.service` oneshot
that runs `clevis luks bind -d <cryptdev> -k <keyfile> tpm2 '{}'`, rewrites `/etc/crypttab` to
`dm_crypt-0 UUID=<uuid> none luks,discard`, removes the embedded keyfile, and rebuilds the initramfs
(keeping the recovery passphrase slot). Then generalize and `qm template`. Read the script for the exact,
tested commands.

---

See **[`disk-encryption.md`](./disk-encryption.md)** for the threat model and the **residual
vTPM-on-unencrypted-host risk** (host-level LUKS on `pve-4` is the follow-up for the stricter prod rollout).
