# Deploying to AWS

## Architecture

```
Users
  │
  ├── CloudFront (CDN) ─────── S3 (frontend static build)
  │
  └── EC2 t3.small (Docker) ── EBS 8GB (strategy data)
            └── ECR (Docker image registry)
```

**Estimated monthly cost:** ~$20
| Resource | Cost |
|----------|------|
| EC2 t3.small | ~$17/mo |
| EBS 8 GB gp3 | ~$0.64/mo |
| Elastic IP | Free (attached) |
| S3 | ~$0.02/mo |
| CloudFront | ~$0.50/mo |
| ECR | Free (500 MB free tier) |

---

## Prerequisites

```bash
# Install tools
brew install terraform awscli   # macOS
# or: https://developer.hashicorp.com/terraform/install

# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, region (us-east-1), output format (json)

# Generate an SSH key pair if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/trading-strategy
cat ~/.ssh/trading-strategy.pub   # copy this into terraform.tfvars
```

---

## Step 1 — Provision infrastructure with Terraform

```bash
cd infrastructure/terraform

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Apply
terraform init
terraform plan    # review what will be created
terraform apply   # type 'yes' to confirm
```

After apply, note the outputs:
```
backend_ip              = "1.2.3.4"
backend_url             = "http://1.2.3.4:8000"
ecr_repository_url      = "123456789.dkr.ecr.us-east-1.amazonaws.com/trading-strategy-backend"
cloudfront_domain       = "https://d1234abc.cloudfront.net"
cloudfront_distribution_id = "E1ABCDEF"
s3_bucket_name          = "trading-strategy-ui-yourname-2026"
```

---

## Step 2 — Set GitHub Actions secrets

In each repo go to **Settings → Secrets and variables → Actions → New repository secret**.

### Both repos need:
| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | Your AWS access key |
| `AWS_SECRET_ACCESS_KEY` | Your AWS secret key |
| `AWS_REGION` | `us-east-1` |

### `trading-strategy-backend` also needs:
| Secret | Value |
|--------|-------|
| `ECR_REGISTRY` | `123456789.dkr.ecr.us-east-1.amazonaws.com` (from Terraform output, without `/trading-strategy-backend`) |
| `EC2_HOST` | Elastic IP from Terraform output |
| `EC2_SSH_KEY` | Contents of `~/.ssh/trading-strategy` (private key) |
| `FRONTEND_URL` | CloudFront URL from Terraform output |

### `trading-strategy-ui` also needs:
| Secret | Value |
|--------|-------|
| `VITE_API_BASE_URL` | `http://<backend_ip>:8000` |
| `S3_BUCKET` | S3 bucket name from Terraform output |
| `CLOUDFRONT_DISTRIBUTION_ID` | Distribution ID from Terraform output |

---

## Step 3 — First deploy

Push any change to `claude/serene-euler-Gq1ma` in either repo — GitHub Actions picks it up automatically.

Or trigger manually: **Actions → Deploy → Run workflow**.

The first backend deploy takes ~5 minutes (Docker build + ECR push + EC2 pull).
Frontend deploys take ~2 minutes.

---

## Step 4 — Access your app

Frontend: `https://<cloudfront_domain>` (from Terraform output)
Backend API docs: `http://<backend_ip>:8000/docs`

---

## Optional: Add a custom domain

1. Register a domain in Route 53 (or point your existing DNS)
2. Request an ACM certificate (must be in `us-east-1` for CloudFront)
3. Add `aliases` and `viewer_certificate` to the CloudFront Terraform resource
4. Add a Route 53 A record pointing to the CloudFront distribution

---

## Teardown

```bash
cd infrastructure/terraform
terraform destroy   # removes all AWS resources
```
