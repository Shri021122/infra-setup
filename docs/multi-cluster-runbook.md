# Multi-Cluster Operations Runbook

Operator-facing runbook for the multi-cluster RKE2-on-Proxmox flow. Follow it
top-to-bottom on a fresh workstation, or jump to the section you need.

The repo layout: one directory per cluster under `clusters/`, shared Terraform
code under `terraform/`. Each cluster's tfvars live in Git; its state and
kubeconfigs stay local (gitignored). API-token-only — no SSH from Terraform
to Proxmox.

---

## 1. One-time Proxmox admin setup

Done **once per Proxmox host**, by someone with root SSH to Proxmox. After
this, the infra engineer needs only the API token — no SSH-to-Proxmox.

### 1.1 Create the API user + role + token

```bash
ssh root@<PROXMOX_HOST>

pveum user add terraform@pve

pveum role add TerraformRole -privs \
  "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU \
   VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType \
   VM.Config.Memory VM.Config.Network VM.Config.Options \
   VM.Monitor VM.Audit VM.PowerMgmt \
   Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate \
   Datastore.Audit SDN.Use Sys.Audit"

pveum aclmod / -user terraform@pve -role TerraformRole

pveum user token add terraform@pve terraform --expire 0 --privsep=0
# OUTPUT shown ONCE — combine: terraform@pve!terraform=<UUID>
# This whole string is what the infra engineer exports as TF_VAR_proxmox_api_token.
```

### 1.2 Create the Ubuntu cloud-init template

```bash
TEMPLATE_ID=9200    # whatever ID you pick; this repo defaults to 9200

wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img \
  -O /tmp/ubuntu-2204.img

qm create $TEMPLATE_ID --memory 2048 --cores 2 \
  --name ubuntu-rke2-base --net0 virtio,bridge=vmbr0

qm importdisk $TEMPLATE_ID /tmp/ubuntu-2204.img local-lvm
qm set $TEMPLATE_ID \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:vm-${TEMPLATE_ID}-disk-0,discard=on \
  --ide2 local-lvm:cloudinit \
  --boot c --bootdisk scsi0 \
  --serial0 socket --vga serial0 \
  --agent enabled=1 --ostype l26

qm template $TEMPLATE_ID
```

### 1.3 Upload the shared cloud-init snippet (once per Proxmox host)

The Terraform code references this file by ID via the REST API — no SSH from
Terraform.

**Web UI path** (recommended):
- Datacenter → Storage → `local` → Snippets tab → Upload
- Upload `terraform/proxmox/snippets/k8s-common.yaml` from this repo
- Confirm it appears as `local:snippets/k8s-common.yaml`

**Or one-time scp** (admin shell):
```bash
scp terraform/proxmox/snippets/k8s-common.yaml \
    root@<PROXMOX_HOST>:/var/lib/vz/snippets/k8s-common.yaml
```

### 1.4 Verify the token works

From the infra engineer's workstation:

```bash
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'

curl -sk \
  -H "Authorization: PVEAPIToken=${TF_VAR_proxmox_api_token}" \
  "https://<PROXMOX_HOST>:8006/api2/json/nodes/<NODE>/storage/local/content?content=snippets" \
  | head -c 200 ; echo
# Should return JSON listing your snippet, NOT 401/403.
```

If you get `permission check failed`, the role is missing privileges — re-run
`pveum role modify TerraformRole -privs "..."` with the full list from 1.1.

---

## 2. Workstation pre-flight (once per machine)

```bash
# Tools
terraform version       # >= 1.6
kubectl version --client # >= 1.29
helm version            # >= 3.14
jq --version
ssh -V
openssl version

# SSH key for VM access (NOT for Proxmox — Terraform doesn't SSH to Proxmox)
ls -l ~/.ssh/rke2_cluster_id ~/.ssh/rke2_cluster_id.pub
# Missing? Generate (one-time):
#   ssh-keygen -t ed25519 -f ~/.ssh/rke2_cluster_id -N '' -C 'rke2-cluster-deploy'

# Clone + checkout the multi-cluster branch
git clone <your-gitlab-url>/infra-setup.git
cd infra-setup
git switch feat/multi-cluster
git pull
```

---

## 3. Deploy a NEW cluster

### 3.1 Export secrets (every fresh shell)

```bash
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'
export TF_VAR_central_mimir_password='...'   # '' if your central stack has no auth
export TF_VAR_central_loki_password='...'
export TF_VAR_alertmanager_slack_webhook=''  # optional
```

> Single-quote the token — bash treats `!` as history-expansion inside `"..."`.

### 3.2 Run the wizard

```bash
./scripts/new-cluster.sh <cluster-name>
```

DNS-safe name (lowercase, hyphens OK): `acme-prod`, `customer-a-staging`, etc.

The wizard prompts for everything — hit Enter to accept the `[default]`:

```
── Identity ──
  Environment [production]:                              ← Enter

── Network ──
  Subnet CIDR (e.g. 10.20.0.0/24) [10.20.0.0/24]: 10.30.0.0/24
  Proxmox network bridge [vmbrk8s]:                       ← Enter
  Network gateway [10.30.0.1]:                            ← Enter (auto-derived)
  DNS servers (comma) [10.30.0.1, 8.8.8.8]:               ← Enter
  Internal domain [cluster.internal]:                     ← Enter
  Control-plane VIP (free IP) [10.30.0.100]:              ← Enter
  Ingress LB pool CIDR (/32 = one IP) [10.30.0.200/32]:   ← Enter

── Proxmox connection ──
  Proxmox API URL [https://10.10.16.249:8006/api2/json]:  ← Enter
  Proxmox node name [pve-4]:                              ← Enter
  Cloud-init template VM ID [9200]:                       ← Enter
  Disk storage pool [pve-4-storage]:                      ← Enter
  Shared cloud-init snippet [local:snippets/k8s-common.yaml]: ← Enter

── Masters ──
  Number of masters (odd: 1, 3, 5) [3]:                   ← Enter
  Master IPs (comma) [10.30.0.101,...]:                   ← Enter (auto-derived)
  Proxmox VM ID for first master [401]: 421               ← bump if 401-403 are taken
  Master CPU cores [2]:                                   ← Enter
  Master RAM (MB) [8192]:                                 ← Enter
  Master OS disk (GB) [50]:                               ← Enter
  Master etcd disk (GB) [20]:                             ← Enter

── Workers ──
  Number of workers [3]:                                  ← Enter
  Worker IPs (comma) [10.30.0.111,...]:                   ← Enter
  Proxmox VM ID for first worker [430]:                   ← Enter (master_start + 9)
  Worker CPU cores [8]:                                   ← Enter
  Worker RAM (MB) [16384]:                                ← Enter
  Worker OS disk (GB) [100]:                              ← Enter
  Worker data disk (GB) [200]:                            ← Enter

── SSH key (for VM access) ──
  SSH private key path [~/.ssh/rke2_cluster_id]:          ← Enter
  Linux user inside VMs [ubuntu]:                         ← Enter

── Central observability ──
  Mimir push URL [http://mimir.stackflow.org/api/v1/push]: ← Enter or set your own
  Loki push URL [http://loki.stackflow.org]:               ← Enter

── ArgoCD ──
  Deploy ArgoCD for this cluster? (y/n) [y]:              ← y
  ArgoCD hostname [argocd.<name>.internal]:               ← Enter
```

Result: `clusters/<cluster-name>/{proxmox,observability,argocd}.tfvars` written.

### 3.3 Commit + push the cluster definition

```bash
git add clusters/<cluster-name>
git commit -m "feat(clusters): bootstrap <cluster-name>"
git push                       # to feat/multi-cluster, or open an MR
```

### 3.4 Pre-deploy sanity check (REQUIRED before every deploy or redeploy)

Before pressing the deploy button — especially on production — run the
read-only checker. It catches the common foot-guns (wrong cluster_name,
IP collision with another cluster, ForceNew terraform plan, syntax errors).

```bash
./scripts/check-cluster.sh <cluster-name>
```

What it does (all read-only, no infra changes):

| # | Check | What it catches |
|---|---|---|
| 1 | Cluster directory + required tfvars exist | Forgot to run `new-cluster.sh`, or wrong cluster name |
| 2 | `cluster_name` is consistent across all three tfvars | Typo in one file that would mis-label telemetry |
| 3 | No IP / VM-ID collisions with OTHER clusters in `clusters/` | Two clusters fighting over the same address |
| 4 | Each IP's reachability on the network (ping) | IP in use by something else; or expected to respond but doesn't |
| 5 | `terraform validate` per module (HCL + var types) | Typo, missing variable, wrong type |
| 6 | `terraform plan` per module — summary only | Anything `forces replacement` (would destroy + recreate VMs) |

**Exit codes:**
- `0` + green "ALL GREEN" → safe to deploy
- `0` + yellow warnings → review, then deploy if expected
- `1` + red fails → fix before deploying

**Options:**
```bash
./scripts/check-cluster.sh <cluster-name>              # full check (slowest: ~30-60s)
./scripts/check-cluster.sh <cluster-name> --skip-plan  # quick check (~2s, skips step 6)
```

For routine re-deploys with small tfvars edits, the full check is the most
valuable — `terraform plan` is what catches "you accidentally bumped
`master_vm_id_start` from 421 to 422 and now it wants to destroy all your
masters".

**Interpreting step 6's plan summary:**

| Plan output | Meaning |
|---|---|
| `No changes. Your infrastructure matches the configuration.` | ✅ State and config agree. Re-running deploy is a true no-op. |
| `Plan: N to add, 0 to change, 0 to destroy` | ✅ Adding new resources only (e.g. added a worker). |
| `Plan: 0 to add, N to change, 0 to destroy` | ✅ In-place updates (e.g. tag change, RAM bump). |
| `Plan: N to add, M to change, K to destroy` | ⚠️ Mixed. Read the destroy list before applying. |
| Output contains `forces replacement` | 🛑 ForceNew field changed. Terraform will destroy + re-create. Investigate before applying. |

If step 6 prints `Error: Unable to create Proxmox VE API credentials`, you
forgot to export `TF_VAR_proxmox_api_token` — re-export and re-run the check.

### 3.5 Deploy

```bash
./scripts/deploy.sh <cluster-name>
```

Phases run automatically:

| Phase | What | ~Time |
|---|---|---|
| 2 | Terraform → VMs on Proxmox | 8–12 min |
| 3 | RKE2 + Alloy on each VM | 12–18 min |
| 4 | RBAC + cert-manager + ESO + kubeconfigs | 5 min |
| 5 | Prometheus + Alertmanager → central Mimir | 5–8 min |
| 6 | Cilium IngressController verify | 2 min |
| 7 | ArgoCD + Ingress + LB IP pool + cert | 3–5 min |
| **Total** | | **35–55 min** |

Tail the log in a second terminal:
```bash
tail -f .logs/deploy-<cluster-name>-*.log
```

### 3.6 Verify success

```bash
export KUBECONFIG=$PWD/clusters/<cluster-name>/kubeconfig.yaml

kubectl get nodes -o wide                              # 3 masters + N workers, all Ready
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
                                                        # should print "No resources found"
kubectl -n kube-system get svc cilium-ingress           # EXTERNAL-IP from your LB pool
kubectl -n argocd get ingress,certificate               # READY=True
```

Quick alloy spot-check on every node (uses your VM SSH key):
```bash
for ip in $(grep -oE '"10\.[0-9.]+"' clusters/<cluster-name>/proxmox.tfvars | tr -d '"' | head -6); do
  echo "$ip → $(ssh -i ~/.ssh/rke2_cluster_id ubuntu@$ip 'systemctl is-active alloy' 2>&1 | tail -1)"
done
```
Every line should end in `active`.

---

## 4. Two modes of running the wizard + deploy

You have a choice based on whether GitOps review matters for this deploy:

### Mode A — Separate (recommended for production)

```bash
./scripts/new-cluster.sh <name>     # writes tfvars; doesn't touch infra
git add clusters/<name>
git commit -m "feat: bootstrap <name>"
git push                            # open MR, get review, merge
./scripts/deploy.sh <name>          # only after merge
```

**Why:** every cluster definition goes through Git review. You commit the
"cluster planned, not yet deployed" state so colleagues can see the IPs,
sizing, and counts before any infra exists. Audit trail in Git.

### Mode B — Combined (for dev / one-off)

```bash
./scripts/deploy.sh <name>          # detects clusters/<name>/ doesn't exist
                                    # and offers to run the wizard inline
```

**Why:** faster for solo work or throwaway clusters. The wizard runs first,
then deploy.sh continues into Phase 2 once you confirm.

For production / customer clusters, **always use Mode A** so the cluster
definition is reviewed and committed before any VMs are created. For your
own lab, Mode B is fine.

---

## 5. Resume / re-run a partial deploy

If `deploy.sh` exited halfway:

```bash
# Pick up from the phase that failed:
./scripts/deploy.sh <cluster-name> --from phase3

# Re-run ONE phase only:
./scripts/deploy.sh <cluster-name> --only phase7

# Validate inputs without applying:
./scripts/deploy.sh <cluster-name> --dry-run
```

All install scripts are idempotent — they skip nodes that already have RKE2
active, and Alloy install skips if the service is already active.

---

## 6. Modify an existing cluster

The standard knobs are in `clusters/<cluster-name>/proxmox.tfvars`. Edit,
commit, re-apply.

```bash
# Example: add a worker, bump RAM, resize a disk
$EDITOR clusters/<cluster-name>/proxmox.tfvars
#   worker_count = 4
#   worker_ip_addresses = [..., "10.30.0.114"]   # add the new IP
#   worker_memory_mb = 32768                     # was 16384

git add clusters/<cluster-name>/proxmox.tfvars
git commit -m "<cluster-name>: scale workers to 4"
git push

./scripts/deploy.sh <cluster-name>           # only the diff is applied
```

> **Don't change `master_vm_id_start` / `worker_vm_id_start` after deploy** —
> those identify already-created VMs in state. Changing them would force-replace VMs.

---

## 7. Uninstall a cluster

**Scope**: destroys ONE cluster only. Other clusters in the repo are untouched.

```bash
# Interactive — prompts at each phase
./scripts/uninstall.sh <cluster-name>

# Skip all prompts (CI / scripted)
./scripts/uninstall.sh <cluster-name> --yes

# Preview without doing anything
./scripts/uninstall.sh <cluster-name> --dry-run

# Only tear down one phase (e.g. wipe RKE2 from nodes, keep VMs alive)
./scripts/uninstall.sh <cluster-name> --only phase3
```

What gets destroyed (in reverse of deploy):

| Phase | Removes |
|---|---|
| 7 | ArgoCD Helm release, Ingress, Certificate, LB IP pool, L2 policy, `argocd` namespace |
| 5 | Prometheus + Alertmanager, `monitoring` namespace + PVCs |
| 4 | cert-manager, ESO, RBAC, NetworkPolicies, related namespaces |
| 3 | `rke2-uninstall.sh` on every node + Alloy purge |
| 2 | `terraform destroy` → all VMs for this cluster |
| Cleanup | `clusters/<cluster-name>/{tfstate/,kubeconfig.yaml,rbac-kubeconfigs/,handoff.md}` |

**Kept after uninstall** (so you can redeploy):
- `clusters/<cluster-name>/*.tfvars` (the cluster definition)
- All source code in Git
- Other `clusters/*/` folders

To remove the cluster definition entirely after a destroy:
```bash
rm -r clusters/<cluster-name>
git add -A
git commit -m "chore: remove <cluster-name>"
git push
```

---

## 8. Hand off to DevOps

After a successful deploy, the artifacts you give the DevOps team:

```
clusters/<cluster-name>/
├── kubeconfig.yaml             ← admin kubeconfig (send via secure channel)
├── rbac-kubeconfigs/
│   ├── senior-devops.yaml      ← cluster-admin-equivalent
│   ├── junior-devops.yaml      ← namespaced
│   ├── developer.yaml          ← dev/staging namespaces
│   └── auditor.yaml            ← read-only
└── handoff.md                  ← (auto-generated) cluster endpoint URLs + retrieval cmds
```

Cluster endpoints they'll need:
- **API server**: `https://<control_plane_vip>:6443` (from `proxmox.tfvars` → `control_plane_vip`)
- **ArgoCD UI**: `https://<argocd_hostname>` resolved to the LB IP (from `argocd.tfvars`)
- **Initial ArgoCD admin password**:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
  ```
  Rotate immediately + delete the secret after first login.
- **Telemetry**: central Grafana filter `cluster="<cluster-name>"`

Distribute the kubeconfigs via your team's secure-channel of choice
(encrypted attachment, age, password manager). Never paste them into
Slack/email.

---

## 9. Multi-cluster gotchas

- **Deploy clusters sequentially**, not in parallel from the same workstation.
  Files under `.secrets/` and `rke2/configs/inventory.ini` are shared
  per-deploy and get overwritten.
- **VM ID ranges must not overlap** across clusters on the same Proxmox host.
  The wizard prompts for these — give different ranges (the wizard defaults
  workers to `master_start + 9`).
- **LB IP pools must not overlap**. Same goes for control-plane VIPs and node
  IPs.
- **Cilium L2 announcements** require the ingress LB IP to be in the same
  broadcast domain as the workers. If your subnet and LB pool are on
  different L2 segments, that won't work.
- **`apply-cilium-config.sh` and `generate-kubeconfigs.sh`** target whichever
  cluster was last deployed on this workstation (they read
  `rke2/configs/inventory.ini`). Run them immediately after
  `deploy.sh <cluster-name>`, not days later when you may have deployed
  something else.

---

## 10. Common failure patterns and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `clusters/<name>/ does not exist` at startup | Cluster directory not created | `./scripts/new-cluster.sh <name>` |
| Phase 2 hangs on "Waiting for SSH on <ip>" | Cloud-init still installing packages | Wait (5-min timeout). If it actually fails, check the VM via Proxmox console. |
| Phase 2 plan shows `5 to add, 5 to destroy` | Someone set `shared_cloud_init_snippet_file_id` on an already-deployed cluster | `user_data_file_id` is ForceNew. Leave it empty if VMs already exist; only set on fresh clusters. (We use `vendor_data_file_id` now — this shouldn't happen.) |
| `install-worker.sh` exits "Command failed" right after `=== Installing Grafana Alloy ===` | `clusters/<name>/observability.tfvars` not found | Make sure the wizard wrote it and it's at the per-cluster path. |
| `terraform plan` errors with "Unable to create Proxmox VE API credentials" | `TF_VAR_proxmox_api_token` not exported | Re-export in this shell. Single-quote the value. |
| `permission check failed` from Proxmox API | Token missing privileges | Run §1.1's `pveum role modify` with the full priv list. |
| `cilium-ingress` EXTERNAL-IP stays `<pending>` | Phase 7 hasn't run, or `argocd_ingress_enabled = false` | `./scripts/deploy.sh <name> --only phase7` |
| Alloy `failed` on a node | Stale config attribute (we hit `extra_metrics_relabel_rules` and `batch_size` as int) | Check `journalctl -u alloy` for the parse error; update `rke2/configs/alloy-config.alloy.tpl`; re-run `--only phase3`. |
| `SSH host key mismatch` (`REMOTE HOST IDENTIFICATION HAS CHANGED`) blocking the probe | Previous cluster used these IPs | `ssh-keygen -f ~/.ssh/known_hosts -R <ip>` for each stale IP. deploy.sh's probe uses `UserKnownHostsFile=/dev/null` so it should not be affected. |

---

## 11. Manual verification commands (when the helper isn't enough)

`check-cluster.sh` wraps the commands below — if you want to inspect things
yourself, run any of these directly. All are read-only.

### 11.1 Eyeball the cluster definition

```bash
cat clusters/<name>/proxmox.tfvars            # full proxmox config
cat clusters/<name>/observability.tfvars      # Mimir/Loki + Prometheus sizing
cat clusters/<name>/argocd.tfvars             # ArgoCD chart + Ingress

# Or in one go
less clusters/<name>/*.tfvars
```

### 11.2 Check IPs are free / in-use on the network

```bash
for ip in 10.30.0.100 10.30.0.101 10.30.0.102 10.30.0.103 \
          10.30.0.111 10.30.0.112 10.30.0.113 10.30.0.200; do
  ping -c1 -W1 $ip >/dev/null 2>&1 && echo "$ip in use" || echo "$ip free"
done
```
- **Fresh deploy** → every IP should be `free`.
- **Redeploy** → master/worker/VIP IPs should be `in use` (your VMs).

### 11.3 Check for IP / VM-ID collisions across clusters

```bash
# IPs claimed by every cluster in the repo
grep -hE '"10\.[0-9.]+"' clusters/*/proxmox.tfvars | sort | uniq -c | sort -rn | head
# Any count > 1 = collision

# VM ID ranges
grep -E "_vm_id_start|_count" clusters/*/proxmox.tfvars
# Cross-check: master_start..(master_start+master_count-1) shouldn't overlap
#              worker_start..(worker_start+worker_count-1) of any other cluster
```

### 11.4 terraform validate per module (HCL syntax + variable types)

```bash
terraform -chdir=terraform/proxmox       validate
terraform -chdir=terraform/observability validate
terraform -chdir=terraform/argocd        validate
# Each should print "Success! The configuration is valid."
```

If validate fails because providers aren't downloaded, run `terraform -chdir=terraform/<mod> init` first.

### 11.5 terraform plan per module (the real "what would happen")

```bash
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'
CLUSTER=<cluster-name>

# Proxmox (VMs) — most important
terraform -chdir=terraform/proxmox plan \
  -var-file=../../clusters/${CLUSTER}/proxmox.tfvars \
  -state=../../clusters/${CLUSTER}/tfstate/proxmox.tfstate

# Observability (Prometheus + Alertmanager)
terraform -chdir=terraform/observability plan \
  -var-file=../../clusters/${CLUSTER}/observability.tfvars \
  -state=../../clusters/${CLUSTER}/tfstate/observability.tfstate

# ArgoCD
terraform -chdir=terraform/argocd plan \
  -var-file=../../clusters/${CLUSTER}/argocd.tfvars \
  -state=../../clusters/${CLUSTER}/tfstate/argocd.tfstate
```

Look at the LAST few lines of each:

| Plan output (last line) | Meaning |
|---|---|
| `No changes. Your infrastructure matches the configuration.` | ✅ Re-running deploy is a no-op |
| `Plan: N to add, 0 to change, 0 to destroy` | ✅ Adding (e.g. new worker) |
| `Plan: 0 to add, N to change, 0 to destroy` | ✅ In-place updates (RAM bump, tag change) |
| `Plan: N to add, M to change, K to destroy` | ⚠️ Mixed — read the destroy list |
| Output contains `forces replacement` | 🛑 ForceNew field changed — terraform will destroy + re-create |

### 11.6 Inspect existing terraform state (what's deployed right now?)

```bash
CLUSTER=<cluster-name>

# List all resources terraform thinks it owns
terraform -chdir=terraform/proxmox state list \
  -state=../../clusters/${CLUSTER}/tfstate/proxmox.tfstate

# Look at one resource in detail
terraform -chdir=terraform/proxmox state show \
  -state=../../clusters/${CLUSTER}/tfstate/proxmox.tfstate \
  'module.master_nodes[0].proxmox_virtual_environment_vm.master'

# Get outputs (init master IP, VIP, all node IPs)
terraform -chdir=terraform/proxmox output \
  -state=../../clusters/${CLUSTER}/tfstate/proxmox.tfstate
```

### 11.7 Once-deployed: cluster health from kubectl

```bash
export KUBECONFIG=$PWD/clusters/<name>/kubeconfig.yaml

kubectl get nodes -o wide                                       # all Ready
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl -n kube-system get svc cilium-ingress                   # EXTERNAL-IP allocated
kubectl get ciliumloadbalancerippools.cilium.io                 # pool exists, CONFLICTING=False
kubectl -n argocd get ingress,certificate                       # READY=True
```

---

## 12. Quick reference card

```bash
# Pre-flight (every fresh shell)
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'
export TF_VAR_central_mimir_password='...'
export TF_VAR_central_loki_password='...'

# Lifecycle
./scripts/new-cluster.sh   <name>          # interactive wizard, writes tfvars
./scripts/check-cluster.sh <name>          # pre-deploy sanity check (read-only)
./scripts/check-cluster.sh <name> --skip-plan  # fast version (no terraform plan)
./scripts/deploy.sh        <name>          # Phases 2–7
./scripts/deploy.sh        <name> --from phaseN
./scripts/deploy.sh        <name> --only phaseN
./scripts/uninstall.sh     <name>          # interactive teardown
./scripts/uninstall.sh     <name> --yes    # non-interactive

# Use the cluster
export KUBECONFIG=$PWD/clusters/<name>/kubeconfig.yaml
kubectl get nodes

# Push a Cilium config change to a live cluster (live-edit case)
./rke2/scripts/apply-cilium-config.sh      # uses the active cluster's inventory.ini

# Re-generate role kubeconfigs for a cluster
./rbac/scripts/generate-kubeconfigs.sh <name>
```

---

## 13. What's in Git, what isn't

| Path | In Git? | Why |
|---|---|---|
| `terraform/**` | ✅ | Shared infrastructure code |
| `clusters/<name>/*.tfvars` | ✅ | The cluster definition (no secrets — values go via env vars) |
| `clusters/_template/` | ✅ | Starting point for new clusters |
| `scripts/`, `rke2/`, `rbac/`, `security/`, `docs/` | ✅ | Source |
| `clusters/<name>/tfstate/` | ❌ | Local state — back up via cron rsync |
| `clusters/<name>/kubeconfig.yaml` | ❌ | Admin credential |
| `clusters/<name>/rbac-kubeconfigs/` | ❌ | Role credentials |
| `clusters/<name>/handoff.md` | ❌ | Generated per deploy |
| `.secrets/` | ❌ | rke2-cluster-token + certs |
| `.logs/` | ❌ | Deploy logs |

If you need disaster-recovery for terraform state, set up `clusters/` to
rsync to a backup host on a cron:
```cron
0 */6 * * *  rsync -a /home/<user>/infra-setup/clusters/ <backup-host>:/backups/infra-clusters/
```
