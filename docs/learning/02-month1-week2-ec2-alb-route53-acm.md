# Month 1, Week 2 — EC2 + ALB + Route53 + ACM

> Last week you built the empty VPC. This week you put a real web app
> behind it — without K8s yet — so each AWS service is understandable in
> isolation before EKS glues them together in Week 3.

## Goal for the week

By Saturday, you can:
- Provision an Auto Scaling Group of EC2 in private subnets via Terraform
- Stand up an internet-facing ALB in public subnets, terminating TLS via ACM
- Point a Route53 record at the ALB, with a real DNS name working
- Explain target groups, listeners, listener rules, target group attachments
- Describe what AWS Load Balancer Controller does for EKS Ingress — because
  it's the same ALB, just provisioned by K8s instead of by you

## Time breakdown

- Theory: ~2 hours
- Lab: ~10 hours
- Buffer: ~3 hours

---

## Part 1 — Theory

### 1.1 The ELB family

AWS has three load balancer types. Know which is which:

| LB | Layer | Best for | Notes |
|---|---|---|---|
| **ALB** (Application LB) | L7 (HTTP/HTTPS/gRPC) | Web apps, microservices, host/path-based routing | Used by 95% of EKS Ingress |
| **NLB** (Network LB) | L4 (TCP/UDP/TLS passthrough) | High-throughput, static IPs, non-HTTP | Used by EKS Service type=LoadBalancer with `nlb` annotation |
| **CLB** (Classic LB) | L4 + L7 legacy | Legacy, don't use | Deprecated for new workloads |

We focus on ALB this week. NLB shows up in Week 4 (when Service type=LoadBalancer
in EKS provisions one by default).

### 1.2 ALB anatomy

```
                    ┌──────────────────────────────────────┐
                    │             ALB                       │
                    │                                       │
                    │  Listener :443 (HTTPS)                │
                    │  ├─ ACM cert: example.com             │
                    │  └─ Listener rules:                   │
                    │     ├─ path /api/* → TG-api           │
                    │     ├─ host app.example.com → TG-app  │
                    │     └─ default → TG-default           │
                    │                                       │
                    │  Listener :80 (HTTP)                  │
                    │  └─ default action: redirect to :443  │
                    └──────────────────────────────────────┘
                                 │
                                 │ targets
                                 ▼
                    ┌──────────────────────┐
                    │  Target Group         │
                    │  ─ health check       │
                    │  ─ stickiness         │
                    │  ─ deregister timeout │
                    │  ─ targets: EC2 IDs / IPs / Lambda
                    └──────────────────────┘
```

**Listener** — port + protocol the ALB listens on. You can have multiple
(e.g., :80 and :443).

**Listener rule** — IF (host/path/method/header matches) THEN (forward to
target group OR redirect OR return fixed response). Rules have priority
(lower number wins).

**Target Group** — a pool of backends. Has its own health check config.
Targets can be EC2 instance IDs, IP addresses, or Lambda functions.

**Health check** — independent per target group. The ALB pulls a path (e.g.,
`/healthz`) every N seconds; if 2 consecutive fails the target is taken out
of rotation. (This is the same mechanism K8s Service health checks use under
the hood when AWS LB Controller provisions an ALB.)

### 1.3 ACM (AWS Certificate Manager)

ACM is AWS's managed cert authority. Two flows:

| Flow | Purpose | Cost |
|---|---|---|
| **Public certificate** | TLS for internet-facing endpoints | Free (AWS-issued) |
| **Private certificate** | TLS for internal endpoints (via Private CA) | Paid |

You'll use public certs. Validation by DNS (preferred — automated renewal)
or email.

**Hard rule:** ACM certs are regional. A cert in `us-east-1` cannot be
attached to an ALB in `ap-south-1`. Provision the cert in the same region
as your ALB.

**Wildcard certs:** `*.example.com` is supported. Costs the same (free).

### 1.4 Route53 fundamentals

| Concept | What it is |
|---|---|
| **Hosted zone** | A DNS domain you own (e.g., `example.com`). Costs $0.50/month per zone. |
| **Record set** | A DNS entry: type (A/AAAA/CNAME/TXT/MX...), name, value, TTL |
| **Alias record** | Route53-specific. Like a CNAME, but works at the apex (`example.com`, not just `www.example.com`), zero TTL, and free queries to other AWS services |
| **Health check** | DNS-level health check; can fail over between records |

**The pattern you'll use this week:**
- Hosted zone for your domain (or get a free one)
- A-record alias pointing your domain at the ALB

### 1.5 Auto Scaling Group (ASG)

ASG = "keep N EC2 instances running, replace dead ones, scale in/out based
on metrics."

Pieces:
- **Launch template** — the recipe for new instances (AMI, instance type,
  SG, IAM profile, user-data script)
- **ASG** — references a launch template, specifies min/desired/max count
  and target subnets
- **Scaling policies** — optional, e.g., "add an instance when CPU > 70%"

In an EKS world, the ASG is what backs your worker node group — but Karpenter
(Week 4) replaces it for newer EKS shops. For this week we use ASG directly
to demystify the AWS layer.

### 1.6 User-data scripts

When EC2 boots, AWS runs a "user-data" script (basically a cloud-init
bootstrap). You'll use this to install nginx and have it serve a simple page.

```bash
#!/bin/bash
yum install -y nginx
systemctl enable --now nginx
echo "<h1>$(hostname)</h1>" > /usr/share/nginx/html/index.html
```

### 1.7 Free domains for labs

Three options if you don't want to buy a domain:

1. **`nip.io`** — free wildcard DNS. `1-2-3-4.nip.io` resolves to `1.2.3.4`.
   No Route53 zone needed, but you can't get an ACM cert for nip.io (you
   don't own it).
2. **`sslip.io`** — same as nip.io.
3. **Buy a `.click` or `.xyz`** — ~$2/year on Namecheap or Cloudflare. Then
   you can do real ACM certs and have a portfolio domain.

For this week we go with option 3 — buy a cheap domain, since the lab needs
ACM working end-to-end. The portfolio value is worth $2.

---

## Part 2 — Lab

### Lab 0 — Buy a domain + delegate to Route53 (~30 min)

1. Register a domain on Cloudflare Registrar or Namecheap (~$2-10/year).
   Suggested TLDs: `.click`, `.xyz`, `.online`, `.work`.
2. In AWS → Route53 → Hosted zones → Create hosted zone with your domain.
3. Route53 gives you 4 NS records. Copy them.
4. Back in your registrar, set the domain's nameservers to those 4 Route53 NS values.
5. Verify: `dig NS yourdomain.click @8.8.8.8` should return AWS nameservers
   within ~30 minutes.

### Lab 1 — Request ACM certificate (~30 min)

1. AWS Console → ACM → Request certificate (in `ap-south-1`, same region as
   your ALB will be).
2. Request public certificate for: `*.yourdomain.click` AND `yourdomain.click`
   (so both apex and subdomains work).
3. Validation method: DNS.
4. ACM gives you CNAME records to add. Click "Create records in Route53" —
   ACM does it for you.
5. Wait ~5-10 min. Status should go to "Issued."

### Lab 2 — Recreate the VPC (~30 min)

If you destroyed last week's VPC, run `terraform apply` again from your
Week 1 Terraform. You need: VPC + 4 subnets + IGW + NAT GW + route tables.

### Lab 3 — Launch template + ASG via Terraform (~3 hours)

Create `web-app.tf` in the same Terraform workspace as your VPC.

```hcl
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "web_app" {
  name        = "web-app-sg"
  description = "Allow HTTP from ALB only"
  vpc_id      = aws_vpc.eks_lab.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]  # only ALB SG
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # outbound to anywhere (via NAT GW)
  }
}

resource "aws_launch_template" "web_app" {
  name_prefix   = "web-app-"
  image_id      = data.aws_ssm_parameter.amazon_linux.value
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.web_app.id]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf install -y nginx
    systemctl enable --now nginx
    echo "<h1>Served by $(hostname)</h1>" > /usr/share/nginx/html/index.html
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "web-app" }
  }
}

resource "aws_autoscaling_group" "web_app" {
  name                = "web-app-asg"
  desired_capacity    = 2
  min_size            = 2
  max_size            = 4
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  launch_template {
    id      = aws_launch_template.web_app.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web_app.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 60
}
```

(You'll write the matching `aws_security_group.alb` resource next — referenced
above for the SG-to-SG rule.)

### Lab 4 — ALB + target group + listener (~3 hours)

```hcl
resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Allow HTTPS from internet"
  vpc_id      = aws_vpc.eks_lab.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # for HTTP→HTTPS redirect
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "web_app" {
  name               = "web-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

resource "aws_lb_target_group" "web_app" {
  name        = "web-app-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.eks_lab.id
  target_type = "instance"

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web_app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = data.aws_acm_certificate.wildcard.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.web_app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

data "aws_acm_certificate" "wildcard" {
  domain   = "*.yourdomain.click"
  statuses = ["ISSUED"]
}
```

### Lab 5 — Route53 record (~30 min)

```hcl
data "aws_route53_zone" "main" {
  name = "yourdomain.click."
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "app.yourdomain.click"
  type    = "A"

  alias {
    name                   = aws_lb.web_app.dns_name
    zone_id                = aws_lb.web_app.zone_id
    evaluate_target_health = true
  }
}
```

`terraform apply`. Wait ~2 minutes for ALB to provision and ASG instances
to register (target group: 2/2 healthy in console).

Then: `curl -v https://app.yourdomain.click/`

You should see the nginx welcome with `<h1>Served by ip-10-0-10-XX.ap-south-1.compute.internal</h1>`.

Refresh — sometimes you see different hostnames (the ALB load-balances
between the two ASG instances).

### Lab 6 — Verify HA + observe scaling (~1 hour)

1. In EC2 console, terminate one of the ASG instances. Watch:
   - ASG auto-replaces it within ~2 min.
   - During replacement, traffic flows uninterrupted to the surviving instance.
2. Drop ASG desired to 1. Watch target group go from 2/1 to 1/1.
3. Bump ASG max to 6 and add a CPU-based scaling policy. Use `stress` to
   spike CPU; observe scale-out.
4. Take screenshots of ALB metrics in CloudWatch — these are your blog/
   portfolio fodder.

### Lab 7 — Teardown (~30 min)

```bash
terraform destroy -auto-approve
```

Confirm: ALB deleted (don't pay $0.025/hour for nothing), ASG drained, EIPs
released, NAT GW deleted.

Keep:
- Hosted zone in Route53 (it's $0.50/month and you'll reuse it for EKS)
- ACM certificate (free, regional)

---

## Part 3 — Saturday review checkpoint

Bring me:

1. **In an ALB, what determines which target group receives a request?**
   (Answer: listener rules, in priority order. The default action of the
   listener is the fallback.)
2. **Your target group health check failed and all targets are unhealthy.
   What URLs would you check, in order, to debug?**
3. **Why is the ALB's SG used as the source in the EC2 SG's inbound rule,
   instead of `0.0.0.0/0`?** (Answer: SG-to-SG referencing is the AWS
   pattern for "only the LB can hit my backends.")
4. **Cost question: what does this stack cost per hour, idle?** (Approx:
   ALB $0.0225/hr + NAT GW $0.045/hr + 2× t3.micro $0.0104/hr×2 = ~$0.10/hr.)
5. **Preview question: when AWS LB Controller in EKS provisions an ALB for
   an Ingress object, who creates the target group? Who registers the pods
   as targets?**

Bring:
- Your full Terraform code (committed to a personal Git repo)
- A screenshot of `https://app.yourdomain.click/` working
- A diagram showing the request path: browser → Route53 → ALB → ASG → EC2

---

## Resources

- [ALB User Guide](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)
- [ACM User Guide](https://docs.aws.amazon.com/acm/latest/userguide/)
- [Route53 docs](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/)
- [Auto Scaling Groups docs](https://docs.aws.amazon.com/autoscaling/ec2/userguide/)

---

## What's next: Week 3 — EKS cluster setup (Terraform) + IRSA

You've now built a full AWS web stack without K8s. Next week we replace
the ASG with an EKS cluster, the EC2 nginx with a pod, and the AWS LB
controller provisions the same ALB you provisioned by hand this week —
but on demand from a K8s Ingress object.

IRSA gets deep-dive treatment: how a pod gets AWS credentials via OIDC
without any hardcoded secrets.
