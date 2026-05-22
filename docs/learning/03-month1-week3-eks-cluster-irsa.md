# Month 1, Week 3 — EKS cluster + IRSA

> The week K8s comes back. You provision an EKS cluster via Terraform,
> understand each piece (control plane, node groups, VPC-CNI, OIDC), and
> wire IRSA properly so pods get AWS permissions without hardcoded keys.

## Goal for the week

By Saturday, you can:
- Provision an EKS cluster via Terraform from scratch (no `eksctl`)
- Explain the difference between cluster IAM role and node IAM role
- Configure the OIDC provider and write an IRSA trust policy by hand
- Run a pod that reads from S3 using IRSA-issued credentials
- Read VPC-CNI logs and understand pod IP allocation

## Time breakdown

- Theory: ~2 hours
- Lab: ~10 hours
- Buffer: ~3 hours

---

## Part 1 — Theory

### 1.1 EKS architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│                    AWS-managed EKS Control Plane                       │
│   (3× kube-apiserver + etcd + scheduler + controller-manager,          │
│    spread across 3 AZs, behind an NLB you don't see)                   │
└───────────────────────────────────────────────────────────────────────┘
                                  ▲                ▲
                                  │ kubectl/api    │ kubelet
                                  │                │
   ┌─────────────────────────┐    │                │   ┌─────────────────────────┐
   │ Your laptop / CI         │────┘                └───│   Worker nodes (EC2)    │
   │ kubectl                  │                         │   in YOUR VPC subnets   │
   └─────────────────────────┘                         └─────────────────────────┘
```

Three things to know:
1. **Control plane is AWS-managed.** You don't SSH it. No `etcdctl` access.
   You pay $0.10/hour ($73/month) per cluster for it.
2. **Worker nodes live in your VPC.** They're EC2 instances. You pay normal
   EC2 rates for them.
3. **kubelet on the node talks to the control plane** over the
   `eks.amazonaws.com` API endpoint (private or public, your choice).

### 1.2 Cluster endpoint access modes

EKS gives you 3 modes:

| Mode | API endpoint reachable from | Use case |
|---|---|---|
| **Public** | Internet | Dev clusters, learning |
| **Public + private** | Internet AND inside VPC | Most common — kubectl from laptop works, nodes use private route |
| **Private only** | Inside VPC only | Production, paranoid security |

For this lab: public + private. Once you're in Month 5 and operating in a
real shop, you'd use private-only + VPN/SSM bastion.

### 1.3 EKS IAM — there are TWO roles, not one

A common confusion. EKS needs:

| Role | Trust policy says | Permission policy does | Notes |
|---|---|---|---|
| **Cluster IAM role** | `eks.amazonaws.com` can assume | Lets EKS service manage AWS resources on your behalf (create ENIs, ELBs, etc.) | One per cluster. Attached to the cluster itself. |
| **Node IAM role** | `ec2.amazonaws.com` can assume | Lets worker nodes pull images, talk to EKS API, manage ENIs | One per node group. Attached via instance profile. |

These are NOT the same. You'll create both in Terraform.

### 1.4 Managed node groups vs self-managed

EKS gives you two ways to run worker nodes:

| | Managed node group | Self-managed |
|---|---|---|
| Who maintains the ASG | AWS | You |
| AMI | Optimized EKS AMI (AWS-published) | Whatever you want |
| Updates | One-click | Roll your own |
| Cost | Same | Same |
| Karpenter compat | Karpenter replaces it | Karpenter replaces it |

Use managed node groups for this lab. In Week 4 we replace the node group
with Karpenter (which is a third option that uses neither MNG nor self-managed,
it provisions raw EC2 directly).

### 1.5 VPC-CNI — how pods get IPs

EKS uses Amazon's VPC-CNI plugin by default. The model:

1. Each worker node has a primary ENI (network interface) with one IP.
2. VPC-CNI attaches *additional* ENIs to the node, each with multiple
   secondary IPs reserved.
3. When a pod is scheduled, VPC-CNI assigns one of those secondary IPs to
   the pod.
4. **Pods get real VPC IPs.** That means a pod can talk directly to any AWS
   service in the VPC. No NAT, no overlay.

Consequences:
- **Pod density is limited by instance type** (each instance has a max number
  of ENIs and IPs per ENI). A t3.medium = 17 pods max. A m5.large = 29.
  An m5.4xlarge = 234. [Full table](https://github.com/awslabs/amazon-eks-ami/blob/main/templates/al2/runtime/eni-max-pods.txt).
- Pods consume subnet IPs. A /24 subnet with 256 IPs can fit ~250 pods.
- No overlay tax (vs Flannel/Calico VXLAN). Throughput = host throughput.

VPC-CNI's behavior is configurable: `WARM_IP_TARGET`, `MINIMUM_IP_TARGET`,
prefix delegation, custom networking. You'll tune one knob in the lab.

### 1.6 IRSA — IAM Roles for Service Accounts

The crown jewel. Pods get AWS credentials without long-lived keys.

**The mechanism, step by step:**

```
┌───────────────────────────────────────────────────────────────────────┐
│  1. EKS exposes an OIDC issuer URL                                     │
│     e.g., https://oidc.eks.ap-south-1.amazonaws.com/id/ABCD1234         │
│     This URL serves JSON Web Keys + discovery doc, like any IdP.       │
└───────────────────────────────────────────────────────────────────────┘
                                  │
┌───────────────────────────────────────────────────────────────────────┐
│  2. You register that URL as an OIDC IdP in your AWS account (IAM)     │
│     "trust this OIDC issuer to vouch for identities"                   │
└───────────────────────────────────────────────────────────────────────┘
                                  │
┌───────────────────────────────────────────────────────────────────────┐
│  3. You create an IAM Role with a trust policy:                        │
│     "principal: the OIDC IdP                                            │
│      condition: oidc:sub == system:serviceaccount:<ns>:<sa-name>"      │
└───────────────────────────────────────────────────────────────────────┘
                                  │
┌───────────────────────────────────────────────────────────────────────┐
│  4. You annotate the ServiceAccount in K8s:                            │
│     eks.amazonaws.com/role-arn: arn:aws:iam::123:role/my-role          │
└───────────────────────────────────────────────────────────────────────┘
                                  │
┌───────────────────────────────────────────────────────────────────────┐
│  5. When a pod uses that SA, EKS's mutating webhook injects:           │
│     - AWS_ROLE_ARN env var                                              │
│     - AWS_WEB_IDENTITY_TOKEN_FILE env var (path to a projected token)  │
│     - The projected SA token (signed by the cluster's OIDC issuer)     │
└───────────────────────────────────────────────────────────────────────┘
                                  │
┌───────────────────────────────────────────────────────────────────────┐
│  6. AWS SDK in the pod sees AWS_WEB_IDENTITY_TOKEN_FILE, calls         │
│     sts:AssumeRoleWithWebIdentity, presenting the projected token       │
│     AWS validates the token signature against the OIDC IdP             │
│     If trust policy allows it, AWS issues temp credentials             │
└───────────────────────────────────────────────────────────────────────┘
```

**Why this is better than node-IAM-role-as-credentials:**
- Pod-level granularity (not node-level)
- No shared credentials (each SA gets its own role)
- No hardcoded keys (no Secrets containing AWS creds)
- Short-lived tokens (auto-rotated)

**Trust policy anatomy** (this is the JSON you'll write by hand):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/ABCD1234"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-south-1.amazonaws.com/id/ABCD1234:sub": "system:serviceaccount:default:s3-reader",
          "oidc.eks.ap-south-1.amazonaws.com/id/ABCD1234:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

Note the `:sub` condition pins the role to a specific (namespace, SA name).
Forget this and any pod in any namespace using any SA can assume your role —
a real security bug.

---

## Part 2 — Lab

### Lab 1 — EKS cluster via Terraform (~3 hours)

Use the official `terraform-aws-modules/eks/aws` module — it's well-maintained
and saves you ~500 lines of boilerplate, while still letting you see every
resource that gets created (the module's docs explain each).

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "eks-lab"
  cluster_version = "1.32"

  vpc_id     = aws_vpc.eks_lab.id
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  cluster_endpoint_public_access = true

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      desired_size   = 2
      max_size       = 4
    }
  }

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
  }
}

output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
```

`terraform apply`. Takes ~15 minutes (control plane provisioning is slow).

When done:

```bash
aws eks --region ap-south-1 update-kubeconfig --name eks-lab
kubectl get nodes
kubectl get pods -A
```

You should see 2 nodes Ready, plus coredns, kube-proxy, vpc-cni pods running.

### Lab 2 — Inspect the cluster (~1 hour)

Spend an hour just exploring. Don't change anything; read.

```bash
# Where is the apiserver?
kubectl cluster-info

# What's the OIDC issuer for this cluster?
aws eks describe-cluster --name eks-lab --query "cluster.identity.oidc.issuer"

# What IAM role is each node using? (look for "instanceProfile" on the EC2)
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=eks-lab" \
  --query "Reservations[].Instances[].[InstanceId, IamInstanceProfile.Arn]"

# What addons are installed?
aws eks list-addons --cluster-name eks-lab

# Look at a vpc-cni pod's logs
kubectl -n kube-system logs -l k8s-app=aws-node --tail=50
```

Read the vpc-cni logs. You'll see lines about ENI allocation, IP reservation,
prefix delegation decisions. This is exactly the kind of stuff an
interviewer will ask you about.

### Lab 3 — Deploy a sample app + ALB Ingress preview (~1 hour)

(Full ALB Ingress with Load Balancer Controller is Week 4. Here just a
Service type=LoadBalancer to see something work.)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector: { matchLabels: { app: nginx } }
  template:
    metadata: { labels: { app: nginx } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  selector: { app: nginx }
  ports: [{ port: 80, targetPort: 80 }]
```

`kubectl apply -f`. Wait ~2 min, then `kubectl get svc nginx` — should
have an external NLB hostname. `curl http://<nlb-hostname>/` should work.

**Notice:** this Service used the legacy in-tree NLB controller (built into
cloud-controller-manager). Week 4 replaces this with AWS Load Balancer
Controller and Ingress objects.

### Lab 4 — IRSA from scratch by hand (~3 hours)

The exercise: create an S3 bucket, write an IRSA-enabled role, deploy a pod
that uses IRSA to list the bucket.

**Step 1.** Create S3 bucket via Terraform:

```hcl
resource "aws_s3_bucket" "irsa_lab" {
  bucket = "irsa-lab-${random_id.suffix.hex}"
}

resource "random_id" "suffix" { byte_length = 4 }

resource "aws_s3_object" "hello" {
  bucket  = aws_s3_bucket.irsa_lab.id
  key     = "hello.txt"
  content = "hello from S3"
}
```

**Step 2.** Write IRSA role + trust policy:

```hcl
data "aws_iam_policy_document" "irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:default:s3-reader"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_reader" {
  name               = "eks-lab-s3-reader"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json
}

resource "aws_iam_role_policy" "s3_reader" {
  role = aws_iam_role.s3_reader.id

  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetObject"]
      Resource = [
        aws_s3_bucket.irsa_lab.arn,
        "${aws_s3_bucket.irsa_lab.arn}/*"
      ]
    }]
  })
}

output "s3_reader_role_arn" { value = aws_iam_role.s3_reader.arn }
```

`terraform apply`. Copy the output `s3_reader_role_arn`.

**Step 3.** Create the ServiceAccount with annotation:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123:role/eks-lab-s3-reader  # paste your ARN
```

**Step 4.** Deploy a pod that uses it:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: aws-cli
  namespace: default
spec:
  serviceAccountName: s3-reader
  containers:
  - name: aws
    image: amazon/aws-cli:latest
    command: ["sleep", "3600"]
```

`kubectl apply -f`. Wait for it to be Ready.

**Step 5.** Verify IRSA is in effect:

```bash
# Inside the pod
kubectl exec aws-cli -- env | grep AWS
# Expect: AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE, AWS_DEFAULT_REGION

# Confirm pod is operating as the role
kubectl exec aws-cli -- aws sts get-caller-identity
# Expect: assumed-role/eks-lab-s3-reader/...

# Test the permission
kubectl exec aws-cli -- aws s3 ls s3://irsa-lab-XXXX/
# Expect: hello.txt
kubectl exec aws-cli -- aws s3 cp s3://irsa-lab-XXXX/hello.txt -
# Expect: "hello from S3"

# Negative test — try a bucket we don't have access to
kubectl exec aws-cli -- aws s3 ls s3://some-other-bucket/
# Expect: AccessDenied
```

If all green: you've done IRSA correctly. This is the same pattern every
production EKS deployment uses for AWS credentials.

### Lab 5 — Break IRSA, observe failure modes (~1 hour)

Intentionally break each piece and watch what breaks. Crucial for interview
debugging questions.

| What to break | Expected error |
|---|---|
| Remove the SA annotation | Pod operates as the NODE's instance profile (which doesn't have S3 read) → `AccessDenied` |
| Wrong `:sub` in trust policy (e.g., wrong namespace) | `AssumeRoleWithWebIdentity` fails: `Not authorized to perform sts:AssumeRoleWithWebIdentity` |
| Delete the OIDC provider in IAM | Same error as wrong :sub |
| Forget to attach permission policy | AssumeRole works, but `aws s3 ls` returns `AccessDenied` |

Restore after each test.

### Lab 6 — Teardown (~30 min)

```bash
terraform destroy
```

Takes ~10 minutes (EKS control plane delete is slow). Confirm:
- EKS cluster deleted (otherwise you keep paying $0.10/hr)
- Node group EC2 instances terminated
- NAT GW released
- S3 bucket emptied + deleted (or run `aws s3 rb s3://... --force`)

---

## Part 3 — Saturday review checkpoint

1. **Walk me through the full chain when a pod calls `s3:GetObject` via IRSA.
   Start from the moment the pod boots. List every component involved.**
2. **What's the difference between the cluster IAM role and the node IAM role?
   What happens if you forget to attach a specific AWS-managed policy to the
   node role?**
3. **Pod density: a t3.medium node runs out of pod slots at 17 pods. Why?
   What VPC-CNI knob can you flip to get more pods per node? (Hint: prefix
   delegation.)**
4. **An interviewer asks: "I have a pod that's failing to call AWS API with
   AccessDenied. Walk me through how you'd debug." List 5+ things you'd
   check, in order.**
5. **Cost question: an idle EKS cluster (no node groups, just control plane)
   costs how much per month? With a single t3.medium node group?**

Bring: your full Terraform, the working pod's `kubectl exec aws-cli -- aws s3 ls`
output, and a screenshot of the IAM role's trust policy.

---

## Resources

- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
  (read at least the "Networking" and "Security" sections)
- [IRSA deep dive blog (AWS)](https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/)
- [VPC-CNI design doc](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/docs/cni-proposal.md)
- [terraform-aws-modules/eks/aws](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)

---

## What's next: Week 4 — EKS production patterns

Karpenter for autoscaling (replaces node groups), AWS Load Balancer Controller
for Ingress (replaces in-tree Service LB), EBS CSI for persistent volumes,
and we deploy a stateful workload end-to-end. By end of Week 4 you'll have
a production-shaped EKS cluster you could actually ship a real app on.
