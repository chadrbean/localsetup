# Email hosting for otbla.com

Date: 2026-09-26. Decision: **don't self-host mail (not locally, not on ECS/EC2).**
otbla.com gets **SES inbound receiving → S3 → Lambda forwarder → Proton alias**, which costs
about $0/mo. We also request SES production access so replies can go out *as* otbla.com.

Status: **live since 2026-09-26.** `hello@otbla.com` (and any `*@otbla.com`) forwards to the Proton
alias; an end-to-end test passed SPF, DKIM and DMARC. Still open: the SES production-access
request and send-as replies (§5). Built as described in [§6 Implementation & ownership](#6-implementation--ownership).

> If you're asking "should I run my own mail server?" again, read §3 first. The answer
> changes only if one of the [§7 revisit triggers](#7-revisit-triggers) fires.

## 1. Requirements

| Need | Detail |
|---|---|
| Official addresses on the site | `hello@otbla.com` as a contact link and in Organization structured data (SEO / trust signals) |
| Platform sign-ups | `socialmedia@`, `accounts@`, … for social media and cloud accounts: verification, 2FA and password-reset mail must arrive reliably |
| No new inbox | Everything lands in the existing Proton mailbox (forward to a Proton alias) |
| Near-free, low-ops | No servers to patch, and no blocklist or deliverability babysitting |
| Fits the estate | AWS us-west-2, Terraform-managed (shared infra in `aws-infrastructure`, otbla.com resources in `blogLosAngeles`) |

Proton constraint: the paid Mail Plus plan allows **1 custom domain, and it's already used**.
Mail Plus can't buy extra domains (only Proton business plans can). The next tier,
Proton Unlimited, gives 3 domains for $9.99/mo billed annually (~$120/yr).

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Run a mail server | **No**, not at home, not on ECS Fargate, not on EC2 | See §3. Deliverability, port-25 and PTR problems cost more (money plus time) than the whole problem is worth |
| Receiving | **SES inbound (us-west-2) → S3 → Lambda forwarder** | Pennies/mo, no server, Terraform-native, reuses the existing SES account |
| Destination | **Existing Proton alias** | No extra inbox. Proton accepts forwarded mail reliably (Yahoo is stricter) |
| Addressing | **Catch-all** `*@otbla.com` | Any new `something@otbla.com` for a platform works instantly, with no per-alias config |
| Replying as otbla.com | **Request SES production access**, then Gmail "send mail as" via SES SMTP | The sandbox only sends to verified recipients (see §5) |
| Where it lives | Shared SES pieces in `aws-infrastructure`; otbla.com identity/DNS/rule in `blogLosAngeles` | aws-infrastructure holds core/shared infra. App repos own their app resources and consume the shared ones |
| Fallback | Purelymail ($10/yr) if SES production access is denied or a real mailbox is needed | Cheapest real IMAP/SMTP with unlimited domains |

## 3. Options compared

Prices checked 2026-09-26 (USD). "Ops" is ongoing maintenance effort.

### 3a. Self-host locally (home host): **rejected**

| | |
|---|---|
| Complexity | High: mail stack plus DNS, TLS, spam and AV, backups, and exposing ports 25/465/587/993 through the home edge (Traefik is HTTP-only today) |
| Cost | ~$0 cash, high time |
| Blockers | Home IP is **residential and dynamic**: it changed 2026-09-11 after a router reboot and `scripts/awsChadHomeIp.sh` chases it hourly. Residential ranges sit on the **Spamhaus PBL**, so direct-to-MX mail from them is rejected or junked. ISPs commonly block port 25 and don't let you set **reverse DNS (PTR)**. Downtime from a reboot or power cut means bounced verification mail |
| Verdict | Not viable for a live domain. The workaround (SES relay out, VPS or tunnel in) is just the cloud option with extra pieces |

### 3b. AWS ECS Fargate: **rejected**

| | |
|---|---|
| Candidate software | docker-mailserver (single container, 512 MB min / 2 GB recommended, no webmail); Stalwart (single container, 1–2 GB); Mailu (multi-container, 1–3 GB); mailcow (6 GB+, wants a full VM, so it's out) |
| Complexity | High |
| Blockers | Fargate tasks **can't hold an Elastic IP**, so inbound needs an NLB, and **PTR is only settable on an Elastic IP**. Outbound **port 25 is blocked** by AWS by default (the removal process is documented for EC2/Lambda, not Fargate), so you must relay through SES anyway. Mailbox state needs EFS |
| Cost | Fargate 0.5 vCPU/1 GB ≈ $14–18/mo (1 vCPU/2 GB ≈ $36). NLB ≈ $16.43/mo plus capacity units. Public IPv4 $3.65/mo each. EFS. **≈ $35–55/mo** |
| Verdict | The most expensive option and still depends on SES for sending |

### 3c. EC2 / Lightsail VM (Mail-in-a-Box, Mox, Stalwart): **rejected, noted as the only sane self-host path**

| | |
|---|---|
| Complexity | Medium-high: port-25 unblock request (AWS may deny it), rDNS on the Elastic IP, OS patching, blocklist monitoring, backups |
| Cost | t4g.small (2 GB) ≈ $12.26/mo + disk + $3.65 IPv4 ≈ **$15–20/mo** |
| Functionality | Full mailboxes, IMAP/SMTP, webmail (Mail-in-a-Box / Mox) |
| Verdict | Only worth it if many real mailboxes are ever needed, and hosted plans beat it on cost even then |

### 3d. Hosted providers: **not chosen, the upgrade path**

| Provider | Price | Domains / users | IMAP/SMTP | Notes |
|---|---|---|---|---|
| Purelymail | **$10/yr** | Unlimited / unlimited | Yes | Cheapest real mailbox. **The fallback** |
| Migadu Micro | $19/yr | Unlimited | Yes | 20 sends/day cap |
| Proton Unlimited | $9.99/mo annual (~$120/yr) | 3 domains | Via Bridge | Keeps everything in Proton, ~12× Purelymail |
| iCloud+ 50 GB | $0.99/mo | 5 domains, 3 addresses each | Yes | Address cap |
| Zoho Mail Forever Free | $0 | 1 domain, 5 users | **No** | Web/app only |
| Fastmail Individual | $5/mo annual | Custom domains | Yes | |
| Google Workspace / M365 Basic | ~$7/user/mo annual | Multi-domain | Yes | Overkill |
| Amazon WorkMail | — | — | — | **Closed to new customers 2026-04-30; shuts down 2027-03-31** |

### 3e. Free forwarders

| Option | Cost | Why not chosen |
|---|---|---|
| Cloudflare Email Routing | Free | Requires the otbla.com zone on Cloudflare DNS. It's on Route53, Terraform-managed by blogLosAngeles |
| ImprovMX free | Free (1 domain, 25 aliases, 500 forwards/day) | Works with Route53 via MX records only, the simplest non-AWS fallback. A third party holds the account-recovery path, and replies need paid tiers |
| SimpleLogin (Proton) | Custom domains need Premium (~$30/yr, unverified) | Pays for what SES does for pennies |
| **SES inbound + Lambda** | **≈ $0** | **Chosen**: in-account, Terraform-managed, no new vendor |

## 4. Will platforms accept a forwarded address like `socialmedia@otbla.com`?

**Yes.** This was the main worry, so here are the reasons in full:

- A platform sends to `socialmedia@otbla.com`, looks up otbla.com's MX (SES) and delivers there.
  Forwarding to Proton happens **after** delivery and is invisible to the sender.
- Sign-up filters block **disposable-email domains** (known throwaway services). A domain you
  own isn't on those lists. Role-style names (`socialmedia@`, `accounts@`) are normal for
  businesses.
- Domain-ownership checks (Meta Business, Google Search Console) use **DNS TXT records** in
  Route53, not mail, so they're unaffected.
- Receiving is never limited by the SES sandbox. Only *sending* is.

Real risks and how they're handled:

| Risk | Mitigation |
|---|---|
| The forwarder breaks, so password-reset mail is lost | CloudWatch alarm on Lambda errors. Raw mail is kept in S3 for 30 days, so nothing is lost while it's fixed. Set the Proton address as each platform's **secondary/recovery** email where allowed |
| Forwarded mail flagged as spam at Proton | The forwarder re-sends from `forwarder@otbla.com` (DKIM-signed by SES, aligned) with `Reply-To` set to the original sender, so SPF/DKIM/DMARC pass on the forward hop |
| Spam arriving via the catch-all | SES spam/virus verdicts; the Lambda drops FAIL verdicts |
| Domain lapses | Keep otbla.com auto-renew on in Route 53 Registrar. Every account's recovery depends on it |

## 5. SES sandbox and why we request production access

The account is in the **SES sandbox**, the default for every new SES account. As of
2026-09-26: 200 emails/day and 1/s, sharing that quota with Grafana/Kopia/Jenkins alerts.

- **Sandbox** = you can *send* only to **verified** addresses. **Receiving is unrestricted.**
- The forwarder works in the sandbox because it only ever sends to one verified address,
  the Proton alias.
- **Production access** (a request to AWS, reviewed in about a day, can be denied) lifts the
  verified-recipient rule and raises the quota. We need it to **reply as `hello@otbla.com`**
  to arbitrary people through Gmail "send mail as" → `email-smtp.us-west-2.amazonaws.com:587`.
- Obligations once approved: handle bounces and complaints (SNS topic → email, through a
  configuration set) and keep the bounce rate under 5% and complaints under 0.1%.
- If denied: the forwarder is unaffected. For replies, use Purelymail.

## 6. Implementation & ownership

Split by ownership. aws-infrastructure provides the shared pieces and blogLosAngeles
(authoritative for otbla.com) consumes them. Wiring follows the existing pattern:
aws-infrastructure outputs are passed as blogLosAngeles input variables (like
`ci_rolesanywhere_trust_anchor_arn`), with no remote state.

| Repo | Module | Owns |
|---|---|---|
| `aws-infrastructure` | `terraform/modules/ses-inbound` | The **single active receipt rule set** (one per account per region), the inbound S3 bucket (30-day expiry), the generic `ses-forwarder` Lambda (destination looked up per domain from SSM `/ses-forwarder/<domain>/destination`), the config set + SNS bounce/complaint topic, the Lambda error alarm, and the production-access request (account-level, recorded in its README) |
| `blogLosAngeles` | `terraform/modules/email` | The otbla.com SES identity + DKIM, MX, apex SPF (**merged into the existing Google-verification TXT**, since Route53 allows one apex TXT set), MAIL FROM `bounce.otbla.com`, `_dmarc`, the `otbla` receipt rule, the SSM destination, the Proton-alias identity, and later the SMTP send-as IAM user (Terraform-managed, like `hermes-ses-email`) |

Apply order: aws-infrastructure → pass its outputs to blogLosAngeles tfvars → blogLosAngeles →
click the Proton verification link → file the production-access request.

**Onboarding another domain later** (e.g. chadrbean.com) happens entirely in the owning repo:
SES identity + DKIM, MX to `inbound-smtp.us-west-2.amazonaws.com`, a receipt rule in the shared
rule set, and an SSM destination parameter. No aws-infrastructure change is needed.

Addresses in use (catch-all, so these are conventions, not config): `hello@` (site contact),
`socialmedia@`, `accounts@`.

**As built (2026-09-26)**, where it differs from the plan above:
- aws-infrastructure PRs #12, #13 and #14. #13 was needed because `github-actions-deploy-role`
  had no SES receiving, config-set or Lambda rights. The apply also raced IAM propagation, and
  because apply runs only on a push to main, a manual re-run only planned.
- blogLosAngeles PR #239 (spec 072), and #238 (spec 071) publishes `hello@otbla.com` on the site.
- **Two out-of-band steps**, because the address must not be committed:
  - the SSM destination value (`aws ssm put-parameter --overwrite`; Terraform keeps a placeholder
    and ignores the value)
  - the SES identity for the Proton alias, created from the CLI while the account is in the
    sandbox (not needed after production access)
- The blog Terraform CI role can't edit its own policy, so its new SES/SSM statements were applied
  once locally by an admin. `ses:CreateEmailIdentity` is authorized only against `Resource "*"`,
  not an identity ARN. Check with `simulate-principal-policy` before trusting a scoped resource.

## 7. Revisit triggers

Reopen this decision only if one of these happens:

- **You need a real mailbox, or regular two-way mail as otbla.com** → Purelymail ($10/yr,
  unlimited domains) before anything self-hosted.
- **SES production access is denied** → replies via Purelymail; keep the SES forwarder.
- **Several domains need real mailboxes** → Purelymail, or Proton Unlimited if staying in Proton
  matters more than ~$110/yr.
- **Forwarding volume nears the quota** (200/day in the sandbox, shared with alerts) → production
  access raises it.
- **Self-hosting ever reconsidered** → only on a VM with an Elastic IP, an approved port-25
  unblock and rDNS (§3c). **Never at home or on Fargate.**

## 8. Sources (checked 2026-09-26)

- Proton plans and add-ons: <https://proton.me/pricing>, <https://proton.me/support/proton-add-ons>
- AWS port 25: <https://repost.aws/knowledge-center/ec2-port-25-throttle>, Lightsail <https://repost.aws/knowledge-center/lightsail-port-25-throttle>
- Fargate static IP: <https://repost.aws/knowledge-center/ecs-fargate-static-elastic-ip-address>
- Pricing: VPC/IPv4 <https://aws.amazon.com/vpc/pricing/>, ELB <https://aws.amazon.com/elasticloadbalancing/pricing/>, SES <https://aws.amazon.com/ses/pricing/>
- SES receiving regions: <https://docs.aws.amazon.com/ses/latest/dg/regions.html>
- WorkMail end of support: <https://docs.aws.amazon.com/workmail/latest/adminguide/workmail-end-of-support.html>
- Spamhaus PBL: <https://www.spamhaus.org/blocklists/policy-blocklist/>
- Mail servers: mailcow <https://docs.mailcow.email/getstarted/prerequisite-system/>, Mailu <https://mailu.io/master/compose/requirements.html>, docker-mailserver <https://docker-mailserver.github.io/docker-mailserver/latest/faq/>, Stalwart <https://stalw.art/docs/install/requirements/>, Mail-in-a-Box <https://mailinabox.email/guide.html>, Mox <https://www.xmox.nl/>
- Hosted: Purelymail <https://purelymail.com/pricing>, Migadu <https://migadu.com/pricing/>, Zoho <https://www.zoho.com/mail/zohomail-pricing.html>, Fastmail <https://www.fastmail.com/pricing/us/>, iCloud+ <https://support.apple.com/en-us/102540>, ImprovMX <https://improvmx.com/pricing/>, Cloudflare Email Routing <https://developers.cloudflare.com/email-service/platform/limits/>

Figures marked unverified during research: Proton Duo/Family/Workspace USD prices, the Fargate
port-25 policy (inferred from the EC2/Lambda docs), us-west-2 Fargate/EFS rates, and SimpleLogin
Premium pricing.
