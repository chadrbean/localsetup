# aws-signing-helper — CloudWatch credentials for Grafana

Grafana's CloudWatch datasource (`provisioning/datasources/cloudwatch.yml`) needs AWS credentials,
and this project uses no static keys. `aws_signing_helper serve` exchanges a certificate for
temporary credentials through IAM Roles Anywhere and serves them on an IMDSv2-compatible endpoint,
`127.0.0.1:9911`. The Grafana container (host networking) finds it through
`AWS_EC2_METADATA_SERVICE_ENDPOINT` in `docker-compose.yml`.

- Role: `grafana-cloudwatch-read`, CloudWatch metric reads only (aws-infrastructure
  `modules/ci-roles-anywhere`). Profile: `host-grafana`.
- Cert: CN `chad-host-grafana`, its own key, so a leak can't reach `host-admin-terraform`.
- Any local process can read the credentials from :9911. That is why the role is read-only.

## Deploy (once, on chad's host)

Needs the aws-infrastructure role/profile applied first (PR `feat/grafana-cloudwatch-role`).

```bash
# 1. Issue the cert (asks for the CA passphrase; renew every 180 days by re-running)
scripts/jenkins_ca.sh issue chad-host-grafana --host

# 2. Env file with the ARNs (no secrets); fill PROFILE_ARN from the aws-infrastructure output
mkdir -p ~/.config/aws-signing-helper
cp monitoring/aws-signing-helper/grafana.env.example ~/.config/aws-signing-helper/grafana.env
chmod 600 ~/.config/aws-signing-helper/grafana.env
terraform -chdir=~/git/aws-infrastructure/terraform output -raw ci_rolesanywhere_grafana_profile_arn
$EDITOR ~/.config/aws-signing-helper/grafana.env

# 3. Unit
cp monitoring/aws-signing-helper/aws-signing-helper-grafana.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now aws-signing-helper-grafana

# 4. Recreate Grafana so it picks up the env var, the datasource and the AWS dashboards folder
cd monitoring && podman-compose up -d --force-recreate grafana
```

## Check

```bash
systemctl --user status aws-signing-helper-grafana
TOKEN=$(curl -s -X PUT http://127.0.0.1:9911/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://127.0.0.1:9911/latest/meta-data/iam/security-credentials/
scripts/verify_dashboard.py --dashboard monitoring/dashboards-aws/email.json --alerts
```

The role list should show `grafana-cloudwatch-read`. Cert renewal: `scripts/jenkins_ca.sh issue
chad-host-grafana --host` and `systemctl --user restart aws-signing-helper-grafana`;
`scripts/jenkins_ca.sh list` shows expiry.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Unit fails, `AccessDenied` in `journalctl --user -u aws-signing-helper-grafana` | Role trust lacks CN `chad-host-grafana`, or the profile ARN in `grafana.env` is wrong |
| Dashboard panels: "failed to get credentials" | Helper not running, or the container lacks `AWS_EC2_METADATA_SERVICE_ENDPOINT` (recreate Grafana) |
| Alert rules `health=error` | Same, or the CloudWatch datasource uid changed (`cloudwatch-us-west-2`) |
