# Month 1, Week 4 — EKS production patterns

> The week your EKS cluster goes from "demo-shaped" to "ship-able." Karpenter
> for autoscaling, AWS Load Balancer Controller for Ingress, EBS CSI for
> PVCs, and a stateful workload end-to-end.

## Goal for the week

By Saturday, you can:
- Replace managed node groups with Karpenter; explain why a real shop would
- Deploy AWS Load Balancer Controller and provision an ALB via Ingress object
- Mount EBS volumes via PVC with the EBS CSI driver
- Run a stateful workload (Postgres) end-to-end with persistent storage
- Defend "why these 4 add-ons" in an interview

## Time breakdown

- Theory: ~2 hours
- Lab: ~10 hours
- Buffer: ~3 hours

---

## Part 1 — Theory

### 1.1 Karpenter — why it replaced cluster-autoscaler

Cluster Autoscaler (CA) works by tweaking ASG desired count. Limitations:
- Slow (60-120 sec to add a node)
- Bound to ASG instance type (one size at a time)
- Can't pick the cheapest instance type per pod
- No bin packing

Karpenter:
- Watches pending pods directly
- Provisions raw EC2 (no ASG layer)
- Picks the best-fit instance type per pending pod batch
- Cold-start ~30 sec
- Bin packs pods, consolidates underutilized nodes
- Supports Spot instances cleanly

By 2026 Karpenter is the default at most EKS-running shops. Knowing it
cold is worth ~5 LPA at interview time.

**Karpenter's data model:**

```
NodePool             — "what KIND of nodes can I provision?"
├── instance types: families, sizes, CPU/mem ranges
├── arch: amd64/arm64
├── capacity type: on-demand, spot, or both
├── zones: which AZs
├── limits: max CPU / memory in this pool
└── disruption: when to consolidate / replace nodes

EC2NodeClass         — "what does the AWS-side of a node look like?"
├── AMI family
├── instance profile (IAM role)
├── subnets (tag selectors)
├── security groups (tag selectors)
├── user-data
└── volume config (root EBS size, IOPS)
```

A pod hits "unschedulable"; Karpenter looks at the pod's requirements
(cpu/mem/nodeselector/affinity), finds a matching NodePool, picks a cheap
EC2 instance type that fits, launches it directly via the EC2 API. ~30 sec
later the pod schedules.

### 1.2 AWS Load Balancer Controller (ALB Ingress)

In Week 3 you used Service type=LoadBalancer with the legacy in-tree NLB
controller. That works but limits you to L4 NLBs.

AWS Load Balancer Controller (LBC) is the modern way:
- Watches Ingress objects → provisions ALBs
- Watches Service type=LoadBalancer with `nlb` class → provisions NLBs
- Supports TargetGroupBinding CRD for advanced cases

**Two target modes:**

| Mode | How it works | When to use |
|---|---|---|
| **instance mode** | ALB targets are EC2 instance IDs, traffic goes via NodePort | Older, simpler, default if not specified |
| **ip mode** | ALB targets are pod IPs directly | Newer, faster, no NodePort hop, fewer iptables rules. **Use this.** |

ip mode requires VPC-CNI (which gives pods VPC-routable IPs). It's why
EKS specifically benefits — Cilium-based clusters in Calico-or-Flannel mode
can't do ip mode the same way.

**Why this matters at interview time:**
- "How do you expose a service to the internet in EKS?" → Ingress object,
  ALB Ingress class, LBC provisions ALB. Be able to draw it.
- "What's the difference between in-tree LB and LBC?" → know it cold.

### 1.3 EBS CSI driver

EBS volumes are AWS's "block storage attached to one instance." For
K8s PVCs, the EBS CSI driver:
- Watches PVCs with the `gp3` storage class
- Provisions EBS volumes
- Attaches them to the node running the pod
- Mounts them inside the pod

Key knobs (StorageClass parameters):
- `type`: `gp3` (general purpose, default), `io1`/`io2` (high IOPS), `st1` (throughput optimized)
- `iops`: gp3 lets you set IOPS independently of size (3000 baseline, up to 16000)
- `throughput`: gp3 lets you set throughput (125 MB/s baseline, up to 1000)
- `encrypted: "true"`: always set this. Costs $0 extra.

**Gotcha:** EBS volumes are zonal — they live in a single AZ. A pod with
an EBS PVC can only schedule onto a node in the same AZ as the volume.
Use `volumeBindingMode: WaitForFirstConsumer` in your StorageClass so the
volume is created in the same AZ as the pod's node, after the pod is
scheduled.

### 1.4 What else does a production EKS cluster have?

Beyond what we cover this week, a typical prod EKS shop also runs:

| Add-on | What | When you need it |
|---|---|---|
| **External DNS** | Watches Ingress, creates Route53 records | When you want `app.yourdomain.com → ALB` automatically |
| **cert-manager** | TLS certs from Let's Encrypt | If not using ACM (e.g., for internal certs) |
| **Cluster Autoscaler OR Karpenter** | Node autoscaling | Always |
| **Metrics Server** | CPU/mem metrics for HPA | Always |
| **AWS LBC** | ALB Ingress | Always |
| **EBS CSI** | PVCs | When you have stateful workloads |
| **EFS CSI** | Shared filesystem PVCs | Rare; when ReadWriteMany needed |
| **Secrets Manager / SSM CSI driver** | Mount AWS Secrets as files | Common; alternative to external-secrets |
| **Velero** | Backups | Always |
| **kube-prometheus-stack or AMP+AMG** | Observability | Always |

We'll cover several of these implicitly in Month 2 (when you map your
dealing knowledge onto EKS).

---

## Part 2 — Lab

### Lab 1 — Recreate the cluster (~30 min)

Apply your Week 3 Terraform. EKS cluster + 2 t3.medium nodes.

### Lab 2 — Install AWS Load Balancer Controller (~2 hours)

LBC needs IRSA. There's a circular feel — you'll use IRSA-protected
permissions to install the controller that provisions ALBs.

```hcl
data "http" "lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.lbc_policy.response_body
}

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "eks-lab-lbc"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
```

Then install via Helm:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-lab \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw lbc_role_arn)

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

Verify:
```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=20
# look for: "starting load balancer controller", no errors
```

### Lab 3 — Deploy nginx with ALB Ingress (~1 hour)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: { app: web }
  ports: [{ port: 80, targetPort: 80 }]
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-south-1:XXX:certificate/...
spec:
  rules:
  - host: web.yourdomain.click
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
```

Apply. Watch:
```bash
kubectl get ingress web -w
# Wait until ADDRESS shows an ALB DNS name
```

Add a Route53 alias record pointing `web.yourdomain.click` → ALB DNS name
(either by hand in console, or via Terraform).

`curl https://web.yourdomain.click/` — should serve nginx.

**Now inspect what happened in AWS:**
```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-`)]'
aws elbv2 describe-target-groups
aws elbv2 describe-target-health --target-group-arn ...
```

The ALB, target group, listeners, and rules — all provisioned by LBC reading
your Ingress object. The targets registered are pod IPs (ip mode).

### Lab 4 — Install Karpenter (~3 hours)

This is the longest lab — but mastering Karpenter is the single highest-ROI
EKS skill.

Karpenter needs:
- Its own IRSA role (controller pods)
- A node instance profile (the EC2 instances it provisions)
- Subnets and SGs tagged for Karpenter discovery

Easiest path: follow [Karpenter's official "Getting Started with Karpenter"
docs](https://karpenter.sh/docs/getting-started/) — use the Terraform
variant, NOT the eksctl variant.

After install:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
# Should be 2 Karpenter pods Running
```

Create a NodePool + EC2NodeClass:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "m"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["small", "medium", "large"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h  # nodes auto-replaced after 30 days
  limits:
    cpu: "100"
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: KarpenterNodeRole-eks-lab
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: eks-lab
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: eks-lab
```

(You'll need to add `karpenter.sh/discovery = eks-lab` tags to your private
subnets and the cluster's SG — Terraform.)

**Test it:**

```bash
# Scale up nginx hard
kubectl scale deploy web --replicas=50

# Watch Karpenter provision new nodes
kubectl -n kube-system logs deploy/karpenter -f

# In another terminal
kubectl get nodes -w
```

Within ~30 seconds Karpenter notices pending pods and provisions a node of
the right size. Pods schedule. Done.

Then scale down:

```bash
kubectl scale deploy web --replicas=2
# Wait 30s, watch nodes get drained + deleted
```

**Replace the original managed node group:**
Edit your EKS module to set `eks_managed_node_groups = {}` (or just leave
a single tiny "system" node group for Karpenter itself to run on — Karpenter
can't run on the node it manages).

### Lab 5 — EBS CSI + stateful Postgres (~2 hours)

EBS CSI is usually an EKS add-on now:

```hcl
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"
  role_name = "eks-lab-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# Add to module "eks" cluster_addons:
cluster_addons = {
  # ...
  aws-ebs-csi-driver = {
    most_recent              = true
    service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
  }
}
```

Apply. Now create a StorageClass and deploy Postgres:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: postgres }
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
      - name: postgres
        image: postgres:16
        env:
        - name: POSTGRES_PASSWORD
          value: changeme
        ports: [{ containerPort: 5432 }]
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      resources: { requests: { storage: 10Gi } }
```

Apply. Watch:
```bash
kubectl get pvc -w
# Wait for STATUS=Bound
kubectl get pods -w postgres-0
# Wait for Running
```

In AWS console → EC2 → Volumes: a new gp3 EBS volume exists, attached to
the node running postgres-0.

Test data persists across pod restart:
```bash
kubectl exec -it postgres-0 -- psql -U postgres -c "CREATE TABLE test (id int); INSERT INTO test VALUES (1);"
kubectl delete pod postgres-0
# StatefulSet replaces it
kubectl exec -it postgres-0 -- psql -U postgres -c "SELECT * FROM test;"
# Returns id=1, proving the volume re-attached
```

### Lab 6 — Teardown (~30 min)

`terraform destroy`. Watch carefully:
- PVCs must be deleted first or EBS volumes orphan (Terraform usually handles this)
- ALBs must be deleted before SGs (LBC handles this if you delete Ingress first)

Practice: `kubectl delete ingress --all && kubectl delete pvc --all` BEFORE
`terraform destroy`.

---

## Part 3 — Saturday review checkpoint

1. **Karpenter vs Cluster Autoscaler — give me 4 concrete differences.**
2. **Why does AWS LB Controller's `ip mode` require VPC-CNI specifically?
   What changes if you use Cilium with ENI mode?**
3. **Your Postgres pod can't reschedule when its node dies. Why? How do you
   fix it?** (Hint: AZ pinning of EBS volume + `WaitForFirstConsumer`.)
4. **An Ingress sits with empty ADDRESS for 10 minutes. List 6 debug steps,
   in order.** (LBC logs, IAM policy on LBC role, subnet tags, SG, ACM cert,
   Ingress class.)
5. **A production EKS cluster running 100 nodes. Karpenter just consolidated
   and is about to drain a node with 30 pods. What can go wrong if the apps
   aren't well-configured? How do you protect critical workloads?** (Answer:
   PDBs, do-not-disrupt annotations, longer terminationGracePeriodSeconds.)

Bring: cluster status, screenshot of `kubectl get nodes` showing Karpenter-
provisioned node, `kubectl get pvc`, your full Terraform.

---

## Resources

- [Karpenter docs](https://karpenter.sh/docs/)
- [AWS Load Balancer Controller user guide](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [EKS Best Practices: Cost optimization](https://aws.github.io/aws-eks-best-practices/cost_optimization/)

---

## What's next: Month 2 — Cilium/eBPF deep dive

End of Month 1. You can stand up a production-shaped EKS cluster. Month 2
shifts gears: we use your dealing cluster as a lab to go deep into Cilium
and eBPF — the specialization that anchors your interview pitch.

Week 5 starts with Cilium internals: BPF maps, identity allocation, the
ipcache, policy maps. The stuff most "Cilium users" never see.
