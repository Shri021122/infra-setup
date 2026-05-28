# Data-at-rest encryption — design, operations, and residual risk

Status: implemented for **fxview-test** (2026-05-27). Gated behind `enable_disk_encryption`
so other clusters (e.g. the `9200`-based prod cluster) are unaffected until they opt in.

This is the authoritative reference. The host-side template build is in
[`disk-encryption-template-build.md`](./disk-encryption-template-build.md); the build tool is
[`scripts/build-encrypted-template.sh`](../scripts/build-encrypted-template.sh).

---

## Two layers (and what was actually needed)

| Layer | Mechanism | Status |
|-------|-----------|--------|
| **K8s Secrets at rest in etcd** | RKE2 **enables this by default** (AES-CBC, `--encryption-provider-config`) | ✅ already on — verified `rke2 secrets-encrypt status` = Enabled |
| **Full-disk (root + data)** | Guest-level **LUKS2**, auto-unlocked by a **per-VM virtual TPM** via **Clevis** | ✅ implemented for fxview-test |

> RKE2 secrets encryption was **already enabled** out of the box — no change required. The work here
> is the full-disk layer.

## Architecture

```
Proxmox clones the encrypted template (9011/9020) per node:
  scsi0 (root)  → ESP + /boot (plaintext) + LUKS2 → LVM (ubuntu-vg/ubuntu-lv, ext4)
                   └─ unlocked at boot by CLEVIS from this VM's vTPM (clevis-initramfs)
  scsi1 (data)  → LUKS2 → ext4 (masters: etcd) / xfs (workers: /var/lib/rancher)
                   └─ unlocked by a keyfile that lives ON the (already-encrypted) root,
                      referenced from /etc/crypttab → opens automatically after root is up
  vTPM (tpmstate) → added per-VM by Terraform; sealed clevis key (no PCR policy: unlocks
                    whenever THIS vTPM is present)
  recovery        → the install-time LUKS passphrase is KEPT (in /root/luks-template/tempkey
                    on the build host) so a TPM problem can never brick a node
```

**Why Clevis, not `systemd-cryptenroll --tpm2-device`:** Ubuntu 22.04's initramfs uses the *classic*
`cryptsetup-initramfs`, which **ignores** the `tpm2-device=` crypttab option (that's a
`systemd-cryptsetup` feature). Clevis (`clevis-initramfs` + `clevis-tpm2`) is what actually performs
TPM-based LUKS unlock in this initramfs. An earlier `systemd-cryptenroll` attempt booted to a passphrase
prompt — Clevis is the correct mechanism here.

**Root auto-grow:** because the root is LUKS+LVM, plain cloud-init `growpart` can't expand it. The
Terraform provisioner runs the full chain (`growpart → cryptsetup resize → pvresize → lvextend →
resize2fs`) so the root fills whatever `*_disk_size_gb` is set to.

## How it's wired

- **Template:** `9011` (or `9020` after the no-reboot patch) — UEFI/OVMF, LUKS2 encrypted root, clevis +
  tpm2 tooling, generalized for cloning. Built by `scripts/build-encrypted-template.sh`.
- **Terraform:** `enable_disk_encryption` (default `false`) in `terraform/proxmox/variables.tf`, passed to
  both modules. When true: `bios = ovmf`, `efi_disk` + `tpm_state` blocks, and the `scsi1` provisioner
  does LUKS + keyfile-crypttab + root auto-grow. When false: seabios + plain `mkfs` (unchanged).
- **Per cluster:** set in `clusters/<name>/proxmox.tfvars`:
  ```hcl
  vm_template_id         = 9011    # encrypted template
  enable_disk_encryption = true
  ```

## Threat model — what it does and doesn't protect

| Scenario | Protected? |
|----------|:--:|
| Someone steals a powered-off VM's virtual disk image (or a disk-only backup) | ✅ |
| Stolen etcd snapshot / backup (Secrets stay encrypted by RKE2's at-rest key) | ✅ |
| Live node compromised (disks already unlocked) | ❌ (at-rest control only) |
| **Theft of the entire `pve-4` host** (attacker gets the vTPM state file *and* the disks) | ❌ **residual risk** |

### Residual risk you are explicitly accepting

The per-VM vTPM is a **state file Proxmox stores on `pve-4`, which is not itself encrypted** (the cluster
team has VM/API access only, no host root). So TPM auto-unlock protects a stolen *disk in isolation*, but
**not** whole-host theft — an attacker with the entire host storage gets vTPM + disk and can replay the
unlock.

**To close it (recommended for the stricter prod rollout):**
- **Host-level LUKS on `pve-4`** (full-disk encryption of the host's own storage) — needs host root, and
  a boot-unlock strategy (TPM2 on the physical host, or a Tang server). This is the real "data at rest"
  control for the host-theft case.
- Or add **Tang** as a second factor to the clevis binding (`sss` with tpm2 + tang) so a node only unlocks
  on the trusted LAN.

## Operations

- **Recovery passphrase:** the install-time LUKS passphrase is kept on every node. It's stored at
  `/root/luks-template/tempkey` on the build host. **Back it up securely and out-of-band.** If clevis/TPM
  ever fails to unlock, enter it at the `Please unlock disk` prompt. Consider rotating it post-deploy
  (`cryptsetup luksChangeKey`) so it isn't the shared build key.
- **etcd-snapshot backups must include the RKE2 encryption key** (`/var/lib/rancher/rke2/server/cred/`).
  A snapshot restored without it cannot decrypt its Secrets. Verify your external backup job covers it.
- **Verify a node:** `clevis luks list -d <dev>` shows the tpm2 binding; `lsblk` shows LUKS on root +
  data; a reboot returns to login with no passphrase; pulling the vTPM makes it block (the proof).
- **Resize a disk:** change `*_disk_size_gb` in tfvars and re-apply — the provisioner auto-grows the
  encrypted root; the data disk is `mkfs`'d at full size.

## `TF_VAR_luks_passphrase` — what it is and where it flows

This environment variable lets you supply the LUKS recovery passphrase to the deploy so the encrypted
root **auto-grows** to whatever `*_disk_size_gb` you've set. **Its value is the build tempkey** stored
at `/root/luks-template/tempkey` on the host that built the template — they're the same string. Set it
at deploy time:

```bash
export TF_VAR_luks_passphrase="$(ssh root@<pve> cat /root/luks-template/tempkey)"
./scripts/deploy.sh <cluster-name>
unset TF_VAR_luks_passphrase    # cleanup
```

End-to-end path through the code:

```
TF_VAR_luks_passphrase  (env)
        ↓
terraform/proxmox/variables.tf    →  variable "luks_passphrase" { sensitive = true }
        ↓  (passed through terraform/proxmox/main.tf)
modules/{master,worker}_node/variables.tf  →  variable "luks_passphrase" (also sensitive)
        ↓
modules/{master,worker}_node/main.tf  locals.grow_root_steps:
   "printf '%s' '${var.luks_passphrase}' | sudo cryptsetup resize dm_crypt-0 || echo WARN..."
        ↓
SSH provisioner runs that one line on each VM. `cryptsetup resize` reads the
passphrase from stdin (no prompt), authorizes the LUKS volume key, then the
chain pvresize → lvextend → resize2fs grows the root.
```

It is used **only inside the provisioner inline** and is **never persisted** — not written to tfvars,
not stored in Terraform state, not echoed in apply output (Terraform suppresses the provisioner output
because the variable is `sensitive`). If you leave it unset, root stays at the template's size
(~18 GB) and the deploy still succeeds — data lives on `scsi1`, so that's usually fine.

## Backup checklist — what to keep safe for the cluster's lifetime

Lose these and you may not be able to recover. Back them up **out-of-band** (password manager,
encrypted vault, multiple offline copies):

| # | Item | Where it lives | Why it matters |
|---|------|----------------|----------------|
| **1** | **LUKS recovery passphrase** (the build tempkey — same value as `TF_VAR_luks_passphrase`) | `/root/luks-template/tempkey` on the Proxmox host that built the template | **The master key.** If a TPM ever fails, you type this at the LUKS prompt to unlock a node manually. |
| **2** | **Cluster SSH private key** | `~/.ssh/rke2_cluster_id` (per `vm_ssh_private_key_path` in tfvars) on whoever runs the deploy | Terraform/deploy/install scripts use it; also your ongoing SSH access. Lose it → can't SSH in. |
| **3** | **RKE2 secrets-encryption key** | `/var/lib/rancher/rke2/server/cred/` on every master (especially the init master) | Encrypts K8s Secrets in etcd. **Required to restore an etcd snapshot** — without it, restored Secrets are unreadable. |
| **4** | **etcd snapshots + the cred dir, paired** | `/var/lib/rancher/rke2/server/db/snapshots/` + the cred dir above | One is useless without the other. Your external backup job MUST cover both. |
| **5** | **Cluster kubeconfig** | `clusters/<name>/kubeconfig.yaml` (gitignored) | Full cluster-admin credential. |
| **6** | **Proxmox API credentials** | `TF_VAR_proxmox_password` / `TF_VAR_proxmox_api_token` env | Required for any Terraform re-apply. |
| **7** | **Terraform state** | `clusters/<name>/tfstate/` (gitignored) | Knows which resources exist. Back up for recovery. |
| **8** | **Per-VM vTPM state files** | Proxmox host storage: the per-VM `tpmstate` volume | If you back up VMs, include vTPM state (vzdump does). Without it the node's clevis binding is dead — falls back to the recovery passphrase. |

**Items #1 and #3 are the two irreplaceable ones** — they can't be regenerated. Everything else can be
rotated or rebuilt from infrastructure-as-code.

### Practical steps
- Put **`tempkey`** (#1) and the contents of **`cred/`** (#3) into your secure vault now, for *every*
  cluster you build.
- Make sure your etcd-snapshot job copies the **cred dir alongside the snapshot file** (#4) — they need
  to land together in the backup target.
- Label each backed-up `tempkey` with the **template ID + Proxmox host that built it**, so future-you
  knows which key matches which environment. Rebuild the template **per environment** so different
  environments don't share a recovery key (smaller blast radius if one leaks).
- Treat the **encrypted template image itself** as sensitive too — it carries the temp key in its LUKS
  header. Don't publish it; restrict access on the Proxmox host.

## Recommended sizing (per node role)

| Disk | Holds | Recommend |
|------|-------|-----------|
| OS root (`scsi0`) | OS, RKE2, logs (incl. audit on masters) | 50 GB |
| etcd (`scsi1`, masters) | etcd DB + 10 local snapshots | 30 GB |
| data (`scsi1`, workers) | container images + volumes (`/var/lib/rancher`) | 100 GB+ |
