#!/usr/bin/env bash
###############################################################################
# build-encrypted-template.sh
#
# Builds an encrypted-root Proxmox VM template (UEFI/OVMF + LUKS2 root) that
# each cloned cluster node can auto-unlock from its own virtual TPM at first
# boot. Companion to docs/disk-encryption-template-build.md.
#
# RUN THIS AS ROOT **ON THE PROXMOX HOST pve-4**. It is the one step that needs
# host access; everything afterwards is normal Terraform/API work.
#
# SAFETY
#   * Purely ADDITIVE. It only CREATES the template + an optional smoke-test VM.
#   * It REFUSES to run if the target VM IDs already exist (no clobbering).
#   * The ONLY thing it ever destroys is its own smoke-test VM, and only after
#     you type 'yes'. It never touches any other VM, disk, or your prod cluster.
#
# TWO BOOT MODES (how autoinstall gets triggered)
#   default (reliable): attaches the installer + a cidata seed, then asks you to
#     do ONE ~10s action at the GRUB console (add 'autoinstall' to the boot line)
#     while the script waits. Recommended on a production host.
#   --headless: repacks the ISO so the install needs no console interaction.
#     Fully unattended, but the ISO-repack step is the least-tested part — use it
#     only if you're comfortable, and watch the first run.
#
# USAGE (run on pve-4 as root; e.g. in an interactive SSH session)
#   ./build-encrypted-template.sh all          # build + finalize + smoke test
#   ./build-encrypted-template.sh build         # seed + builder VM + run install
#   ./build-encrypted-template.sh finalize      # detach media + convert to template
#   ./build-encrypted-template.sh smoke         # clone, vTPM, verify, (offer to) destroy
#   ./build-encrypted-template.sh clean         # remove work dir + aborted builder VM
#
#   Flags:
#     --template-id N   template VM ID    (default 9201)
#     --smoke-id N      smoke-test VM ID  (default 9009)
#     --storage NAME    Proxmox storage   (default pve-4-storage)
#     --bridge NAME     network bridge    (default vmbr0)
#     --headless        repack the ISO for a no-console-interaction install
#     --yes             skip the confirmation prompt on smoke-VM destroy
###############################################################################
set -euo pipefail

# ----------------------------- configuration --------------------------------
TEMPLATE_ID=9201
SMOKE_ID=9009
STORAGE="pve-4-storage"
BRIDGE="vmbr0"
HEADLESS=0          # 0 = reliable manual-trigger (default); 1 = repack ISO
ASSUME_YES=0

# Network for the BUILDER during install (needs internet to fetch packages).
# Leave NET_IP empty for DHCP; set it (CIDR) for a static address on a no-DHCP net.
NET_IP=""                  # e.g. 10.10.16.60/24
NET_GW="10.10.16.1"
NET_DNS="8.8.8.8"

ISO_URL="https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
ISO_DIR="/var/lib/vz/template/iso"
BASE_ISO="${ISO_DIR}/ubuntu-22.04.5-live-server-amd64.iso"
AUTO_ISO="${ISO_DIR}/ubuntu-2204-luks-autoinstall.iso"
SEED_ISO="${ISO_DIR}/luks-seed.iso"
WORK="/root/luks-template"
EXTRACT="${WORK}/iso-extract"

# ------------------------------- helpers ------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans; read -r -p "$1 [type 'yes' to proceed] " ans
  [ "$ans" = "yes" ]
}

vm_exists() { qm status "$1" >/dev/null 2>&1; }

# --------------------------- argument parsing -------------------------------
SUBCMD="${1:-all}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --template-id) TEMPLATE_ID="$2"; shift 2;;
    --smoke-id)    SMOKE_ID="$2";    shift 2;;
    --storage)     STORAGE="$2";     shift 2;;
    --bridge)      BRIDGE="$2";      shift 2;;
    --headless)    HEADLESS=1;       shift;;
    --ip)          NET_IP="$2";      shift 2;;
    --gateway)     NET_GW="$2";      shift 2;;
    --dns)         NET_DNS="$2";     shift 2;;
    --yes)         ASSUME_YES=1;     shift;;
    *) die "unknown flag: $1";;
  esac
done

# ------------------------------ preflight -----------------------------------
preflight() {
  log "Preflight checks"
  [ "$(id -u)" = "0" ] || die "must run as root on the Proxmox host"
  command -v qm    >/dev/null || die "qm not found — are you on the Proxmox host?"
  command -v pvesm >/dev/null || die "pvesm not found — are you on the Proxmox host?"
  command -v wget  >/dev/null || die "wget not found (apt-get install -y wget)"
  command -v openssl >/dev/null || die "openssl not found (apt-get install -y openssl)"

  pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
    || die "storage '$STORAGE' not found (check 'pvesm status')"

  if [ "$HEADLESS" = "1" ]; then
    command -v xorriso >/dev/null \
      || die "xorriso not found — needed for --headless ISO repack (apt-get install -y xorriso), or drop --headless"
  fi
  command -v genisoimage >/dev/null \
    || die "genisoimage not found (apt-get install -y genisoimage)"

  vm_exists "$TEMPLATE_ID" && die "VM/template ID $TEMPLATE_ID already exists — pick another with --template-id, or remove it yourself first"
  ok "Preflight OK (template=$TEMPLATE_ID smoke=$SMOKE_ID storage=$STORAGE bridge=$BRIDGE headless=$HEADLESS)"
}

# ---------------------- generate the throwaway temp key ---------------------
# Unlocks root ONLY during a clone's first boot, before its TPM is enrolled.
# tpm-enroll.service wipes it per-clone. Regenerated each build.
gen_temp_key() {
  mkdir -p "$WORK"
  [ -f "${WORK}/tempkey" ] || { head -c 32 /dev/urandom | base64 | tr -d '\n' > "${WORK}/tempkey"; chmod 600 "${WORK}/tempkey"; }
  TEMPKEY="$(cat "${WORK}/tempkey")"
}

# --------------------------- write seed files -------------------------------
write_seed() {
  log "Writing autoinstall config + TPM enrollment unit to $WORK"
  mkdir -p "$WORK"

  # First-boot enrollment script (runs once per clone). Temp key baked in so the
  # clone can authorize the TPM enrollment, then wipe the passphrase slots.
  cat > "${WORK}/tpm-enroll.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
MARKER=/var/lib/tpm-enroll.done
[ -f "\$MARKER" ] && exit 0
CRYPTDEV=\$(blkid -t TYPE=crypto_LUKS -o device | head -1)
# Wait for this VM's vTPM (Proxmox tpm_state). Retry next boot if absent.
[ -e /dev/tpmrm0 ] || { echo "tpm-enroll: no TPM yet, retry next boot"; exit 0; }
# Bind a Clevis TPM2 slot, authorized by the embedded keyfile. Clevis (NOT
# systemd-cryptenroll) is what Ubuntu's classic initramfs can actually use to
# auto-unlock LUKS at boot. '{}' seals to the TPM with no PCR policy → unlocks
# whenever THIS vTPM is present (matches the disk-theft threat model; avoids
# PCR-change lockouts).
clevis luks bind -y -d "\$CRYPTDEV" -k /etc/cryptsetup-keys.d/root.key tpm2 '{}'
# Normal crypttab — clevis-initramfs answers the unlock prompt from the TPM.
UUID=\$(blkid -s UUID -o value "\$CRYPTDEV")
echo "dm_crypt-0 UUID=\$UUID none luks,discard" > /etc/crypttab
# Stop shipping the temp keyfile in initramfs; rebuild with the clevis hook.
sed -i '/KEYFILE_PATTERN/d' /etc/cryptsetup-initramfs/conf-hook || true
rm -f /etc/cryptsetup-keys.d/root.key
update-initramfs -u
# IMPORTANT: the install-time passphrase slot is KEPT as a recovery key (it's in
# /root/luks-template/tempkey on the build host). This guarantees a TPM problem
# can NEVER brick a node — you can always unlock manually. Rotate/remove later
# per policy. (This is why we no longer wipe the passphrase slot.)
touch "\$MARKER"
systemctl disable tpm-enroll.service || true
# No immediate reboot: the keyfile is already removed and the initramfs rebuilt
# with the clevis hook, so TPM unlock takes effect on the next natural reboot.
# Root stays mounted for the rest of this boot — this avoids disrupting the
# Terraform SSH provisioner during a cluster deploy.
EOF

  cat > "${WORK}/tpm-enroll.service" <<'EOF'
[Unit]
Description=First-boot LUKS TPM2 enrollment
After=cloud-init.service network-online.target
ConditionPathExists=!/var/lib/tpm-enroll.done
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tpm-enroll.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  # Embed both files as base64 so they're delivered regardless of where the
  # install media is mounted (fixes the /cdrom path difference between modes).
  local B64_SH B64_SVC
  B64_SH="$(base64 -w0 "${WORK}/tpm-enroll.sh")"
  B64_SVC="$(base64 -w0 "${WORK}/tpm-enroll.service")"
  # base64 too, because its 'datasource_list: [...]' would break YAML as a plain late-command (the ': ').
  local B64_DSL; B64_DSL="$(printf 'datasource_list: [ NoCloud, ConfigDrive, None ]\n' | base64 -w0)"

  # Network block for the installer. Static IP if --ip given (no-DHCP nets),
  # else DHCP. Without working internet the 'packages:' download fails (exit 100).
  local NETWORK_BLOCK
  if [ -n "$NET_IP" ]; then
    NETWORK_BLOCK=$(cat <<NETEOF
  network:
    version: 2
    ethernets:
      zz-all:
        match: {name: "e*"}
        dhcp4: false
        addresses: [${NET_IP}]
        routes:
          - to: default
            via: ${NET_GW}
        nameservers:
          addresses: [${NET_DNS}]
NETEOF
)
    log "Builder network: static ${NET_IP} gw ${NET_GW} dns ${NET_DNS}"
  else
    NETWORK_BLOCK=$(cat <<'NETEOF'
  network:
    version: 2
    ethernets:
      zz-all:
        match: {name: "e*"}
        dhcp4: true
NETEOF
)
    warn "Builder network: DHCP (no --ip given). If your net has no DHCP, the package download will fail — re-run with --ip."
  fi

  # 'storage: layout: {name: lvm, password: ...}' = subiquity's guided encrypted
  # LVM (ESP + /boot + LUKS2 pv -> vg -> root), UEFI-aware. We add the keyfile +
  # TPM tooling in late-commands.
  cat > "${WORK}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: us}
${NETWORK_BLOCK}
  identity:
    hostname: ubuntu-2204-luks
    username: ubuntu
    password: "$(openssl passwd -6 "$TEMPKEY")"
  ssh:
    install-server: true
  storage:
    layout:
      name: lvm
      password: "${TEMPKEY}"
  packages:
    - qemu-guest-agent
    - cloud-init
    - cryptsetup
    - cryptsetup-initramfs
    - tpm2-tools
    # Clevis is what Ubuntu's initramfs uses to auto-unlock LUKS from the TPM.
    # (systemd-cryptenroll's tpm2-device=auto is IGNORED by classic cryptsetup-initramfs.)
    - clevis
    - clevis-luks
    - clevis-initramfs
    - clevis-tpm2
    - chrony
  shutdown: poweroff
  late-commands:
    - curtin in-target -- bash -c 'mkdir -p /etc/cryptsetup-keys.d && printf "%s" "${TEMPKEY}" > /etc/cryptsetup-keys.d/root.key && chmod 0400 /etc/cryptsetup-keys.d/root.key'
    - curtin in-target -- bash -c 'CD=\$(blkid -t TYPE=crypto_LUKS -o device | head -1); printf "%s" "${TEMPKEY}" | cryptsetup luksAddKey "\$CD" /etc/cryptsetup-keys.d/root.key -'
    - curtin in-target -- bash -c 'echo "KEYFILE_PATTERN=/etc/cryptsetup-keys.d/*.key" >> /etc/cryptsetup-initramfs/conf-hook'
    - curtin in-target -- bash -c 'echo "UMASK=0077" >> /etc/initramfs-tools/initramfs.conf'
    - curtin in-target -- bash -c 'CD=\$(blkid -t TYPE=crypto_LUKS -o device | head -1); echo "dm_crypt-0 UUID=\$(blkid -s UUID -o value \$CD) /etc/cryptsetup-keys.d/root.key luks,discard" > /etc/crypttab'
    - curtin in-target -- bash -c 'echo ${B64_SH} | base64 -d > /usr/local/sbin/tpm-enroll.sh && chmod 0755 /usr/local/sbin/tpm-enroll.sh'
    - curtin in-target -- bash -c 'echo ${B64_SVC} | base64 -d > /etc/systemd/system/tpm-enroll.service'
    - curtin in-target -- systemctl enable tpm-enroll.service qemu-guest-agent
    - curtin in-target -- update-initramfs -u
    # ---- GENERALIZE: make this a reusable cloud template so each CLONE gets a
    #      unique identity and its OWN IP from Proxmox cloud-init (not the build IP) ----
    # Drop ALL installer netplan (that's the build-time --ip; clones must not inherit it). cloud-init regenerates per clone.
    - curtin in-target -- bash -c 'rm -f /etc/netplan/*.yaml'
    # subiquity DISABLES cloud-init networking — re-enable it so the Proxmox cloud-init drive drives the per-VM IP.
    - curtin in-target -- bash -c 'rm -f /etc/cloud/cloud.cfg.d/*installer*.cfg /etc/cloud/cloud.cfg.d/subiquity-*.cfg /etc/cloud/cloud-init.disabled'
    # Pin cloud-init to Proxmox's datasource (NoCloud/ConfigDrive) so it never wastes minutes probing EC2/OVF.
    - curtin in-target -- bash -c 'echo ${B64_DSL} | base64 -d > /etc/cloud/cloud.cfg.d/99-pve.cfg'
    # Reset cloud-init so it re-runs against the clone's datasource on first boot.
    - curtin in-target -- bash -c 'rm -rf /var/lib/cloud/*'
    # Unique-per-clone identity: blank machine-id + remove SSH host keys (regenerated on first boot).
    - curtin in-target -- bash -c 'truncate -s 0 /etc/machine-id'
    - curtin in-target -- bash -c 'rm -f /etc/ssh/ssh_host_*'
EOF

  printf 'instance-id: ubuntu-2204-luks-template\n' > "${WORK}/meta-data"
  ok "Seed files written (throwaway key in ${WORK}/tempkey — shred it after templating)"
}

# ------------------------------- get base ISO -------------------------------
fetch_iso() {
  # Official checksum — used to detect a truncated/corrupt download (the usual
  # cause of "a DVD entry shows in OVMF but won't boot").
  local want; want="$(wget -qO- https://releases.ubuntu.com/22.04/SHA256SUMS 2>/dev/null | awk '/live-server-amd64.iso/{print $1}')"

  if [ -f "$BASE_ISO" ]; then
    if [ -n "$want" ]; then
      if [ "$(sha256sum "$BASE_ISO" | awk '{print $1}')" = "$want" ]; then
        ok "Base ISO present, checksum verified"; return
      fi
      warn "Base ISO is corrupt/incomplete (checksum mismatch) — re-downloading"
      rm -f "$BASE_ISO"
    else
      warn "Base ISO present but couldn't fetch SHA256SUMS to verify — assuming OK"
      ok "Using $BASE_ISO"; return
    fi
  fi

  log "Downloading Ubuntu 22.04 live-server ISO (~2 GB)"
  wget -q --show-progress -O "$BASE_ISO" "$ISO_URL" || die "ISO download failed"
  if [ -n "$want" ]; then
    [ "$(sha256sum "$BASE_ISO" | awk '{print $1}')" = "$want" ] \
      || die "downloaded ISO failed checksum — bad/interrupted download, re-run to retry"
    ok "ISO downloaded and checksum verified"
  else
    ok "Downloaded $BASE_ISO (checksum unverified — couldn't reach SHA256SUMS)"
  fi
}

# ----------------------- seed ISO (always built) ----------------------------
build_seed_iso() {
  log "Building cidata seed ISO"
  rm -f "$SEED_ISO"
  ( cd "$WORK" && genisoimage -quiet -output "$SEED_ISO" -volid cidata -joliet -rock user-data meta-data )
  ok "Built $SEED_ISO"
}

# ------------------- headless: repack ISO with autoinstall ------------------
repack_iso() {
  log "Repacking ISO for unattended autoinstall (headless)"
  rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
  xorriso -osirrox on -indev "$BASE_ISO" -extract / "$EXTRACT" >/dev/null 2>&1
  chmod -R u+w "$EXTRACT"
  cp "${WORK}/user-data" "${WORK}/meta-data" "$EXTRACT/"

  local GRUB="$EXTRACT/boot/grub/grub.cfg"
  [ -f "$GRUB" ] || die "grub.cfg not found ($GRUB) — drop --headless and use the console trigger"
  # Append autoinstall args to each kernel line; escape ';' so GRUB passes it through.
  sed -i -E 's@(linux[[:space:]]+/casper/vmlinuz.*)@\1 autoinstall ds=nocloud\\;s=/cdrom/@' "$GRUB"
  sed -i -E 's@^set timeout=.*@set timeout=1@' "$GRUB"

  # Replay the original El Torito boot setup so the new ISO stays UEFI-bootable.
  local OPTS; OPTS="$(xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null | grep -vE '^-(V|o)\b' || true)"
  [ -n "$OPTS" ] || die "could not read El Torito layout — drop --headless and use the console trigger"
  rm -f "$AUTO_ISO"
  # shellcheck disable=SC2086
  xorriso -as mkisofs -r -V UBUNTU_LUKS_AUTO -o "$AUTO_ISO" $OPTS "$EXTRACT" >/dev/null 2>&1 \
    || die "ISO repack failed — drop --headless and use the console trigger"
  [ -s "$AUTO_ISO" ] || die "repacked ISO is empty — drop --headless"
  ok "Built unattended ISO: $AUTO_ISO"
}

# ----------------------------- create builder VM ---------------------------
create_builder() {
  log "Creating builder VM $TEMPLATE_ID (UEFI/OVMF)"
  # NOTE: VGA display (--vga std), NOT serial. The Ubuntu installer ISO's GRUB
  # renders to VGA, so the GRUB menu is only visible via the Proxmox web UI
  # (noVNC) console. A serial-only display shows a black screen at GRUB. We keep
  # a serial device attached for the installed OS, but the display must be VGA.
  qm create "$TEMPLATE_ID" --name ubuntu-2204-luks --memory 2048 --cores 2 \
    --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci --machine q35 \
    --bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
    --scsi0 "${STORAGE}:20" --serial0 socket --vga std --agent enabled=1

  if [ "$HEADLESS" = "1" ]; then
    qm set "$TEMPLATE_ID" --ide2 "${AUTO_ISO},media=cdrom" --boot order='ide2;scsi0'
  else
    qm set "$TEMPLATE_ID" --ide2 "${BASE_ISO},media=cdrom" \
                          --ide3 "${SEED_ISO},media=cdrom" --boot order='ide2;scsi0'
  fi
  ok "Builder VM $TEMPLATE_ID created"
}

# ------------------------------- run install --------------------------------
run_install() {
  log "Starting builder VM $TEMPLATE_ID"
  qm start "$TEMPLATE_ID"

  if [ "$HEADLESS" = "0" ]; then
    cat <<EOF

  ┌─ ONE-TIME CONSOLE STEP (~10s) ────────────────────────────────────────────┐
  │  Open the Proxmox WEB UI -> pve-4 -> VM $TEMPLATE_ID -> Console (noVNC).     │
  │  (Use the web UI, NOT 'qm terminal' — the installer's GRUB is on VGA, so a   │
  │   serial console shows only a black screen.)                                 │
  │  At the GRUB menu press 'e', append to the 'linux .../casper/vmlinuz' line:  │
  │      autoinstall                                                             │
  │  (the cidata seed is auto-detected) then press Ctrl-x to boot.               │
  │  This script keeps waiting for the install to finish.                        │
  └────────────────────────────────────────────────────────────────────────────┘
EOF
  fi

  log "Waiting for autoinstall to finish (VM powers off when done; up to 30 min)"
  local i=0
  while [ "$i" -lt 180 ]; do
    sleep 10; i=$((i+1))
    qm status "$TEMPLATE_ID" | grep -q running || { ok "Install complete — builder powered off"; return 0; }
    [ $((i % 6)) -eq 0 ] && log "  ...still installing ($((i/6)) min)"
  done
  die "timed out. Check 'qm terminal $TEMPLATE_ID'. If it's at a login prompt the install finished but didn't power off — run: qm stop $TEMPLATE_ID && $0 finalize"
}

# --------------------------- convert to template ----------------------------
make_template() {
  vm_exists "$TEMPLATE_ID" || die "VM $TEMPLATE_ID does not exist — run '$0 build' first"
  qm status "$TEMPLATE_ID" | grep -q running && { warn "stopping $TEMPLATE_ID"; qm stop "$TEMPLATE_ID"; }
  log "Detaching install media and converting $TEMPLATE_ID to a template"
  qm set "$TEMPLATE_ID" --delete ide2 >/dev/null 2>&1 || true
  qm set "$TEMPLATE_ID" --delete ide3 >/dev/null 2>&1 || true
  qm set "$TEMPLATE_ID" --boot order='scsi0'
  qm template "$TEMPLATE_ID"
  ok "Template $TEMPLATE_ID (ubuntu-2204-luks) ready"
  warn "Shred the throwaway key now:  shred -u ${WORK}/tempkey"
}

# ------------------------------- smoke test ---------------------------------
smoke_test() {
  vm_exists "$SMOKE_ID" && die "smoke-test ID $SMOKE_ID already exists — pick another with --smoke-id"
  log "Smoke test: cloning $TEMPLATE_ID -> $SMOKE_ID with a fresh vTPM"
  qm clone "$TEMPLATE_ID" "$SMOKE_ID" --name luks-smoketest --full
  qm set "$SMOKE_ID" --tpmstate0 "${STORAGE}:1,version=v2.0"
  qm start "$SMOKE_ID"
  log "Waiting for first-boot TPM enrollment + reboot cycle (~3-5 min)"
  sleep 120
  cat <<EOF

  Watch the boot in the Proxmox WEB UI -> VM $SMOKE_ID -> Console (noVNC).
  EXPECTED (no login needed): it boots straight to a login prompt (keyfile-unlock +
  clevis enrollment; NO auto-reboot).

  VERIFY clevis now owns the unlock — reboot and confirm NO passphrase prompt:
    qm reboot $SMOKE_ID
    -> comes back to the login prompt with NO "Please enter passphrase" = TPM unlock works.

  HARD PROOF (no login needed): pull the TPM, confirm it stays LOCKED:
    qm stop $SMOKE_ID && qm set $SMOKE_ID --delete tpmstate0 && qm start $SMOKE_ID
    -> boot must BLOCK on a "Please enter passphrase" prompt. That is the proof.
    Re-add the TPM: qm set $SMOKE_ID --tpmstate0 ${STORAGE}:1,version=v2.0

  DEEPER CHECK (optional): log in as 'ubuntu' (password = contents of ${WORK}/tempkey), then:
    lsblk; sudo cryptsetup status dm_crypt-0
    sudo clevis luks list -d \$(blkid -t TYPE=crypto_LUKS -o device|head -1)  # shows a tpm2 binding
    cat /etc/crypttab                                                         # dm_crypt-0 ... none luks,discard
EOF
  if confirm "Destroy the smoke-test VM $SMOKE_ID now?"; then
    qm stop "$SMOKE_ID" >/dev/null 2>&1 || true; qm destroy "$SMOKE_ID"; ok "Smoke-test VM $SMOKE_ID destroyed"
  else
    warn "Leaving $SMOKE_ID up — remember 'qm destroy $SMOKE_ID' when done"
  fi
}

# --------------------------------- clean ------------------------------------
clean() {
  if vm_exists "$TEMPLATE_ID" && ! qm config "$TEMPLATE_ID" | grep -q '^template:'; then
    warn "Builder VM $TEMPLATE_ID exists and is NOT a template (aborted build?)"
    confirm "Destroy leftover builder VM $TEMPLATE_ID?" && { qm stop "$TEMPLATE_ID" 2>/dev/null || true; qm destroy "$TEMPLATE_ID"; }
  fi
  rm -rf "$EXTRACT"
  ok "Cleaned work artifacts (kept ISOs + tempkey in $WORK if present)"
}

# --------------------------------- driver -----------------------------------
case "$SUBCMD" in
  build)
    preflight; gen_temp_key; write_seed; fetch_iso; build_seed_iso
    [ "$HEADLESS" = "1" ] && repack_iso
    create_builder; run_install
    ok "Build done. Next: $0 finalize" ;;
  finalize) make_template ;;
  smoke)    smoke_test ;;
  clean)    clean ;;
  all)
    preflight; gen_temp_key; write_seed; fetch_iso; build_seed_iso
    [ "$HEADLESS" = "1" ] && repack_iso
    create_builder; run_install; make_template; smoke_test
    ok "ALL DONE. Set vm_template_id = $TEMPLATE_ID in your cluster's proxmox.tfvars." ;;
  *) die "unknown subcommand '$SUBCMD' (use: all | build | finalize | smoke | clean)";;
esac
