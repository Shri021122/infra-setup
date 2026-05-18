# Cluster Template

Copy this folder to `clusters/<your-cluster-name>/` and edit the three tfvars
files. Or run the wizard:

```bash
./scripts/new-cluster.sh <your-cluster-name>
```

After editing, deploy:

```bash
./scripts/deploy.sh <your-cluster-name>
```

## Files in this folder

| File | What it controls | Tracked in Git? |
|------|------------------|:---:|
| `proxmox.tfvars` | VM provisioning: IPs, sizing, count, Proxmox connection | ✅ |
| `observability.tfvars` | Prometheus + Alertmanager + central Mimir/Loki URLs | ✅ |
| `argocd.tfvars` | ArgoCD installation + Ingress + LB IP pool + cert | ✅ |
| `tfstate/*.tfstate` | Terraform state (one per module) | ❌ gitignored |
| `kubeconfig.yaml` | Admin kubeconfig | ❌ gitignored |
| `rbac-kubeconfigs/*.yaml` | Role kubeconfigs (senior-devops, junior-devops, etc.) | ❌ gitignored |
| `handoff.md` | Auto-generated post-deploy summary for the DevOps team | ❌ gitignored |

## What MUST stay in lockstep

The string `<cluster-name>` (the folder name) must match `cluster_name` inside
every tfvars file AND the various `*_hostname` and `loki_tenant_id` defaults.
The wizard handles this for you; if editing by hand, `grep -n CHANGE_ME .`
and replace everywhere.
