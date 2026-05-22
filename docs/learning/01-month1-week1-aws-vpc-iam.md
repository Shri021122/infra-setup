# Month 1, Week 1 — AWS networking + IAM

> The week that unlocks everything else in Month 1. Without solid VPC + IAM,
> EKS feels like magic. With them, EKS is just K8s in a VPC with IAM.

## Goal for the week

By Saturday, you can:
- Sketch a K8s-ready VPC on a whiteboard (public + private subnets, NAT, IGW,
  route tables) in 5 minutes
- Write an IAM role + trust policy in raw JSON without copy-pasting
- Explain why a pod in EKS gets AWS credentials via IRSA (preview — full deep
  dive in Week 3)
- Have a working "EKS-ready" VPC + IAM roles in your AWS account, built by
  hand via console, then re-built via Terraform

## Pre-reqs (assumed)

- AWS account created (personal, not work)
- AWS CLI installed and `aws configure` done with a programmatic IAM user
- Basic Linux + bash
- You know what an IP address, subnet, and CIDR are

## Time breakdown

- Theory reading: ~2 hours
- Hands-on lab: ~10 hours
- Buffer for breakage + review: ~3 hours

---

## Part 1 — Theory (read this first, before touching AWS console)

### 1.1 VPC fundamentals

**What is a VPC.** Virtual Private Cloud. It's a logically isolated network
in AWS. You define a CIDR block (e.g., `10.0.0.0/16`), and everything inside
the VPC has IPs from that block. By default, VPC instances can't reach the
internet and the internet can't reach them — you build that path explicitly.

**Why VPCs are isolated by design.** Two reasons:
1. Security boundary — you control what crosses in/out.
2. Multi-tenancy — different VPCs can have overlapping CIDRs (each is its
   own private space).

**The pieces inside a VPC:**

| Piece | What it is | Mental model |
|---|---|---|
| **VPC** | The container, defined by CIDR | A datacenter you own |
| **Subnet** | Subdivision of VPC, tied to a single AZ | A floor in the datacenter |
| **Availability Zone (AZ)** | Independent failure domain inside a region | Different power circuits |
| **Internet Gateway (IGW)** | Horizontal-scale gateway, attached to VPC. Lets traffic in/out via the public internet | Front door of the datacenter |
| **NAT Gateway (NAT GW)** | Managed NAT in a public subnet. Private instances reach internet through it (one-way: outbound only) | A receptionist who places outgoing calls but doesn't accept incoming |
| **Route Table** | Per-subnet (or per-VPC default). Defines where packets go based on destination CIDR | The "where do I send this?" lookup |
| **Security Group** | Stateful firewall, attached to ENI (network interface) | Inbox filter (return traffic auto-allowed) |
| **Network ACL (NACL)** | Stateless firewall, attached to subnet | Building-wide filter (both directions, manual) |

### 1.2 Public vs private subnets — there's no AWS flag for this

A subnet isn't "public" or "private" because of an attribute. It's purely
determined by its **route table**:

- **Public subnet** = its route table has a default route (`0.0.0.0/0`)
  pointing at an Internet Gateway
- **Private subnet** = its route table has a default route pointing at a
  NAT Gateway (or no default route at all, fully isolated)

That's the only difference. AWS just shows "Public IPv4 Auto-assign: Yes"
in the console for subnets that route through an IGW, but the routing
determines the behavior.

### 1.3 The K8s-ready VPC pattern

EKS doesn't strictly require this exact shape, but it's the production-grade
pattern. Master this and 95% of EKS deployments will fit it.

```
                                  ┌───────────────────────────────────┐
                                  │  VPC  10.0.0.0/16                  │
                                  │                                    │
                                  │  ┌─────────────────────────────┐  │
                                  │  │  AZ a (e.g. ap-south-1a)   │  │
                                  │  │                             │  │
                                  │  │  Public  10.0.0.0/24       │  │
                                  │  │  ────────┐   ┌── NAT GW    │  │
                                  │  │          │   │             │  │
                                  │  │  Private 10.0.10.0/24      │  │
                                  │  │  ─────── pods + nodes      │  │
                                  │  └─────────────────────────────┘  │
                                  │                                    │
                                  │  ┌─────────────────────────────┐  │
                                  │  │  AZ b (e.g. ap-south-1b)   │  │
                                  │  │                             │  │
                                  │  │  Public  10.0.1.0/24       │  │
                                  │  │  ────────┐   ┌── NAT GW    │  │
                                  │  │          │   │             │  │
                                  │  │  Private 10.0.11.0/24      │  │
                                  │  │  ─────── pods + nodes      │  │
                                  │  └─────────────────────────────┘  │
                                  │                                    │
                                  │           IGW (attached)           │
                                  └───────────────────────────────────┘
```

**Why this shape:**
- Two AZs minimum: EKS requires it (HA control plane spans AZs).
- Public subnets: where the IGW-facing things live (NAT Gateways, ALBs).
- Private subnets: where EKS nodes and pods live. They egress via NAT.
- Inbound from internet only via load balancers in public subnets, never
  directly to nodes/pods.

**Cost gotcha:**
- NAT Gateway = $0.045/hour per AZ + $0.045/GB processed. Two AZs = ~$65/month
  even idle. **Destroy when not in use.**
- IGW is free.
- Multi-AZ NAT GW is for production; single-AZ NAT GW (cheaper but with
  AZ failure blast radius) is fine for dev/lab.

### 1.4 EKS-specific subnet tags

EKS requires subnets to be tagged so the AWS Load Balancer Controller knows
where to provision ALBs/NLBs:

| Tag | Value | Required for |
|---|---|---|
| `kubernetes.io/cluster/<cluster-name>` | `shared` or `owned` | EKS to know this subnet belongs to your cluster |
| `kubernetes.io/role/elb` | `1` | Public subnets — internet-facing ALBs go here |
| `kubernetes.io/role/internal-elb` | `1` | Private subnets — internal ALBs/NLBs |

If you forget these tags, ALB Ingress provisioning silently fails. This is
one of the top "why doesn't my Ingress work in EKS" debugging traps.

### 1.5 Security Groups vs NACLs

Both filter network traffic, but differently:

| | Security Group | NACL |
|---|---|---|
| **Layer** | Instance-level (per ENI) | Subnet-level |
| **State** | Stateful (return traffic auto-allowed) | Stateless (must allow return traffic explicitly) |
| **Rules** | Only "allow" rules | Both "allow" and "deny" |
| **Default** | All inbound denied; all outbound allowed | All allowed (default NACL) |
| **Evaluation** | All rules evaluated | Rules numbered, first match wins |

**Practical guidance:**
- Use Security Groups for almost everything.
- Use NACLs sparingly — they're for blanket subnet-level guards (e.g., "this
  whole subnet can never reach the database VPC").
- Don't try to be clever with NACLs; they're stateless and confusing for SSH/RDP.

### 1.6 IAM fundamentals

**The model.** AWS IAM has 4 things you'll deal with constantly:

1. **Users** — long-lived identity for humans. Have access keys for CLI.
2. **Groups** — collection of users; attaching a policy to a group attaches
   to all members.
3. **Roles** — identity that can be *assumed* (temporarily, with STS tokens).
   No long-lived credentials. Used by AWS services (EC2, Lambda, EKS pods),
   cross-account access, federation.
4. **Policies** — JSON documents granting permissions. Attached to users,
   groups, or roles.

**The two types of policies:**

| Type | Attached to | Says |
|---|---|---|
| **Identity-based** | A user / group / role | "this identity can do X on resource Y" |
| **Resource-based** | A resource (e.g., S3 bucket) | "principal X can do Y on me" |

For our purposes (EKS-focused), 99% of the time you're writing identity-based
policies attached to IAM roles.

### 1.7 IAM role anatomy

An IAM role has TWO policy documents:

```
┌─────────────────────────────────────────────────────────────────┐
│  IAM Role: my-app-role                                          │
│                                                                 │
│  Trust Policy (who can assume this role?)                       │
│  {                                                              │
│    "Effect": "Allow",                                           │
│    "Principal": { "Service": "ec2.amazonaws.com" },             │
│    "Action": "sts:AssumeRole"                                   │
│  }                                                              │
│                                                                 │
│  Permission Policy (what can this role do once assumed?)        │
│  {                                                              │
│    "Effect": "Allow",                                           │
│    "Action": ["s3:GetObject"],                                  │
│    "Resource": "arn:aws:s3:::my-bucket/*"                       │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘
```

The **trust policy** says "EC2 service is allowed to assume me." When you
attach this role to an EC2 instance (via instance profile), AWS automatically
calls `sts:AssumeRole` on behalf of the instance, and the instance gets
temporary credentials.

The **permission policy** says "once you've assumed me, you can read objects
from my-bucket."

### 1.8 IRSA (preview — full lab in Week 3)

In EKS, pods get AWS permissions via **IRSA** (IAM Roles for Service
Accounts). The mechanism:

1. EKS cluster has an OIDC issuer endpoint (a URL).
2. You configure AWS to trust that OIDC issuer (one-time setup).
3. You create an IAM role with a trust policy saying "the OIDC issuer for
   cluster X, for service account Y in namespace Z, can assume me."
4. You annotate the K8s ServiceAccount: `eks.amazonaws.com/role-arn: <role>`.
5. Pods using that ServiceAccount get the role's temporary credentials,
   injected by the EKS-pod-identity webhook.

This is how a pod gets to call `s3:GetObject` without anyone hardcoding AWS
keys into a Secret. It's the "right way" to do AWS auth in EKS.

For now, just understand it exists. Week 3 has the deep dive.

### 1.9 Instance profiles (the EC2 equivalent)

For EC2 instances (and EKS worker nodes, since they're EC2 under the hood),
the equivalent of IRSA is an **instance profile**. An instance profile is
basically a container that holds a single role and gets attached to an EC2
instance. From inside the instance, you can hit `http://169.254.169.254/...`
(IMDS) to get the role's temporary credentials.

EKS nodes need an instance profile with these AWS-managed policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy` (deprecated, use VPC-CNI IRSA instead — Week 3)
- `AmazonEC2ContainerRegistryReadOnly`

---

## Part 2 — Lab (hands-on)

### Lab 0 — AWS account setup (~30 min)

1. If you haven't already, sign up for AWS Free Tier with a personal email.
2. Install AWS CLI v2: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
3. In the AWS Console, create an IAM user named `terraform-cli` with:
   - Programmatic access (access key + secret)
   - Attach AWS-managed policy `AdministratorAccess` (for lab use only)
4. Run `aws configure` and paste the keys.
5. Verify: `aws sts get-caller-identity` should print your user ARN.
6. Set up a billing alarm: Billing → Budgets → Create budget. Cost budget,
   $50, alert at 80% and 100%. Don't skip this.

### Lab 1 — Build a K8s-ready VPC via the Console (~2 hours)

Goal: build the VPC shape from §1.3 by clicking through the AWS console.
You'll re-build it via Terraform next, so this is the "see what each piece
is" pass.

In the AWS Console → VPC service:

1. **Create VPC** named `eks-lab-vpc`, CIDR `10.0.0.0/16`. Disable
   "VPC endpoint" defaults to keep things minimal.
2. **Create 4 subnets:**
   - `eks-lab-public-a` — 10.0.0.0/24, AZ `ap-south-1a`
   - `eks-lab-public-b` — 10.0.1.0/24, AZ `ap-south-1b`
   - `eks-lab-private-a` — 10.0.10.0/24, AZ `ap-south-1a`
   - `eks-lab-private-b` — 10.0.11.0/24, AZ `ap-south-1b`
3. **Create Internet Gateway** named `eks-lab-igw`, attach to VPC.
4. **Create NAT Gateway** named `eks-lab-natgw-a` in `eks-lab-public-a`,
   allocate an Elastic IP. (One NAT GW for both private subnets in dev. Two
   for prod.)
5. **Create Route Tables:**
   - `eks-lab-public-rt`: route `0.0.0.0/0 → IGW`. Associate with both public subnets.
   - `eks-lab-private-rt`: route `0.0.0.0/0 → NAT GW`. Associate with both private subnets.
6. **Tag the subnets for EKS** (do this now even though no cluster exists yet):
   - All 4 subnets: `kubernetes.io/cluster/eks-lab = shared`
   - Public subnets: `kubernetes.io/role/elb = 1`
   - Private subnets: `kubernetes.io/role/internal-elb = 1`

Cross-check: open one private subnet's "Route table" tab. The default route
should be the NAT GW. Same for the other private subnet.

### Lab 2 — Test connectivity by launching EC2 instances (~1.5 hours)

1. Launch a `t3.micro` EC2 in `eks-lab-public-a`:
   - AMI: Amazon Linux 2023
   - Auto-assign public IP: yes
   - Security Group: new SG `bastion-sg`, allow SSH (22) from your IP only
   - Keypair: create a new one and save the .pem file
2. Launch another `t3.micro` in `eks-lab-private-a`:
   - Auto-assign public IP: no
   - Security Group: new SG `private-sg`, allow SSH from `bastion-sg` only
3. SSH to the bastion: `ssh -i bastion.pem ec2-user@<bastion-public-ip>`.
4. From the bastion, SSH to the private instance using its private IP. You'll
   need to `scp` the keypair or use SSH agent forwarding.
5. From the private instance: `curl -v https://www.google.com`. This MUST
   work — it confirms the NAT GW path is functional.
6. Take screenshots of all of these working — you'll want them for your
   blog post in Month 2.

### Lab 3 — IAM role + trust policy by hand (~1 hour)

1. Create an S3 bucket named `<your-name>-eks-lab-bucket-<random>`. Upload
   any file to it.
2. In IAM → Roles → Create role:
   - Trusted entity: AWS service → EC2
   - Permission policy: skip (you'll attach next)
3. After creating, attach an inline policy named `s3-read-only`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:ListBucket"],
         "Resource": [
           "arn:aws:s3:::<your-bucket>",
           "arn:aws:s3:::<your-bucket>/*"
         ]
       }
     ]
   }
   ```
4. Look at the role's "Trust relationships" tab. Read the JSON. Confirm
   you understand what each field means.
5. Attach the role to the private EC2 instance (Actions → Security →
   Modify IAM role).
6. SSH to the private instance (via bastion).
7. Run `aws sts get-caller-identity` from inside the instance. Note the ARN
   says `assumed-role/<your-role-name>/...` — the instance is now operating
   as the role.
8. Run `aws s3 ls s3://<your-bucket>`. Must succeed (proof: trust + perm
   policies work).
9. Run `aws s3 ls` (no bucket specified, lists all buckets). Must fail with
   AccessDenied (proof: only listed bucket is accessible).

### Lab 4 — Re-build everything in Terraform (~3 hours)

You've done it by hand. Now do it as code.

Create `eks-lab-vpc.tf`:

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# VPC
resource "aws_vpc" "eks_lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "eks-lab-vpc" }
}

# (write the rest yourself:
#  - 4 subnets with the right CIDRs, AZs, and EKS tags
#  - 1 IGW attached to the VPC
#  - 1 EIP for NAT GW
#  - 1 NAT GW in public subnet a
#  - 2 route tables (public, private) with correct routes
#  - 4 route table associations
# )
```

**Don't copy from the console-built version's terraform export.** Write it
from scratch using the AWS provider docs:
- <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc>
- <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet>
- <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table>

Hint: use `count` or `for_each` to avoid duplicating subnet resources by hand.

Once your `terraform plan` looks right, **destroy the console-built version**
(easy: Console → VPC → delete VPC, but you might need to delete instances
first). Then `terraform apply` to build it via code.

Cross-check: `terraform plan` after apply should report "No changes" — the
state matches reality.

### Lab 5 — Cost teardown (~30 min)

Before you stop for the day:

```bash
terraform destroy -auto-approve
```

Then in the AWS Console:
- Confirm VPC is gone
- Confirm NAT GW and Elastic IP are released (these are the expensive bits)
- Confirm EC2 instances are terminated
- Confirm S3 bucket is empty + deleted

Check Billing dashboard tomorrow morning to make sure your spend looks right
(should be < $5 for this week if you destroyed promptly).

---

## Part 3 — Saturday review checkpoint

Bring me these answers on Saturday:

1. **Why does EKS require subnets in 2+ AZs? What breaks with 1 AZ?**
   (Hint: think about the control plane.)
2. **What's the cost difference between 1 NAT GW vs 2 NAT GWs (one per AZ)?
   What's the trade-off?**
3. **In your IAM trust policy, the `Principal` was `{"Service": "ec2.amazonaws.com"}`.
   What would it need to be if you wanted EKS pods (via IRSA) to assume the
   role instead? (Preview of Week 3 — try to figure it out by reading the
   IRSA docs.)**
4. **You created an S3 bucket and a role that can read it. Suppose another
   user in your AWS account also wants to use this role. How would they get
   permission to assume it?** (Hint: trust policy with their ARN.)
5. **Why did `aws s3 ls` (no bucket) fail when the permission policy did
   include `s3:ListBucket`?** (Hint: read the IAM action docs carefully —
   `s3:ListBucket` ≠ `s3:ListAllMyBuckets`.)

Also bring:
- Your final Terraform code for the VPC (committed to a Git repo of your own,
  or paste it here)
- A diagram of your VPC (hand-drawn or Cloudcraft / draw.io — your choice)

---

## Resources

**Authoritative docs (read at least skim):**
- AWS VPC User Guide: <https://docs.aws.amazon.com/vpc/latest/userguide/>
- AWS IAM User Guide: <https://docs.aws.amazon.com/IAM/latest/UserGuide/>
- EKS networking docs: <https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html>

**Free courses worth your time:**
- AWS Skill Builder — "AWS Cloud Practitioner Essentials" (free, ~6 hours).
  Skip if you've used AWS for 1+ years.
- Adrian Cantrill's AWS courses are excellent paid alternatives if you want
  depth across all AWS services.

**Pretty diagrams tools:**
- Cloudcraft (free tier) — for AWS diagrams
- draw.io — generic, free

**Cost-saving tips:**
- Use `ap-south-1` (Mumbai) for lower data egress costs to your laptop.
- Set up a `~/.aws/credentials` with multiple profiles if you have work + lab
  accounts — don't mix.
- AWS Cost Explorer (free) → set it to refresh daily so you spot mistakes early.

---

## What's next: Week 2 — EC2 + ALB + Route53 + ACM

Next week, we use the VPC you built to host a real web app:
- A small auto-scaling group of EC2 in private subnets
- An ALB in public subnets routing to them
- A Route53 record pointing your custom domain (or a sub of `nip.io` for
  free) to the ALB
- TLS via ACM (free, AWS-managed certificate)

By end of Week 2 you'll have provisioned a fully-managed AWS web app stack
without K8s yet — so you understand each AWS service in isolation before EKS
glues them all together in Week 3.
