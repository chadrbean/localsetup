#!/usr/bin/env bash
# awsChadHomeIP - Keeps the home-access SG rule AND this box's public DNS
# records (me, grafana, serpbear, ... .chadrbean.com) at the current public IP.
#
# Tracked copy of the installed script. Install with:
#   sudo install -m 755 scripts/awsChadHomeIp.sh /usr/local/bin/awsChadHomeIp.sh
# To publish a new hostname: add it to DNS_RECORDS below, re-install, and run
# `bash /usr/local/bin/awsChadHomeIp.sh` as chad (the cron user) — the UPSERT loop
# creates the A record if missing.
#
# Target:  bean-home-networks (us-west-2) — shared home SG managed by aws-infrastructure.
#          The Ollama instance SG references this SG for tcp/22 (SG-based SSH),
#          so that's the only SG rule that ever changes.
#          me.chadrbean.com (Route53, chadrbean.com zone) — public DNS name for
#          this box (Hermes web/dashboard, exposed at https://me.chadrbean.com).
#          grafana.chadrbean.com — Grafana UI of the localsetup monitoring stack
#          (https://grafana.chadrbean.com via home Traefik). Declared in
#          aws-infrastructure terraform with ignore_changes=[records]; THIS script
#          owns its value (same as me.chadrbean.com, which is script-only).
#          serpbear.chadrbean.com — SerpBear keyword rank tracker (localsetup/serpbear,
#          https://serpbear.chadrbean.com via home Traefik); same terraform pattern.
# Region:  us-west-2 for EC2/SG calls (pinned — never rely on ~/.aws/config
#          defaults, cron has none). Route53 is a global service (no region).
# Log:     /var/log/awsChadHomeIP.log
# Cron:    0 */1 * * * chad bash /usr/local/bin/awsChadHomeIp.sh   (/etc/crontab)
#
# Robustness notes:
#   - SG found by NAME, rule found by (tcp/22 + description) — survives SG/rule
#     recreation; SGR IDs change on every rule replacement, so never hardcode one.
#   - Creates the SG rule if missing (bootstrap / post-recreation), updates if changed.
#   - DNS records checked/updated independently of the SG logic below, so a
#     "SG unchanged" run still creates/repairs any DNS record if it's missing
#     or stale.

set -euo pipefail

export AWS_DEFAULT_REGION="us-west-2"

SG_NAME="bean-home-networks"    # from Task 2 (home_sg_name variable, default "bean-home-networks")
RULE_DESCRIPTION="Chad Home IP" # must match the Terraform-declared rule description
DNS_RECORDS=("me.chadrbean.com" "grafana.chadrbean.com" "otb-local.chadrbean.com" "traefik.chadrbean.com" "otbla.chadrbean.com" "otbla-local.chadrbean.com" "accounting.chadrbean.com" "librecrawl.chadrbean.com" "serpbear.chadrbean.com" "litellm.chadrbean.com" "jenkins.chadrbean.com")
DNS_ZONE_NAME="chadrbean.com"
DNS_TTL=300                     # low TTL: home IP can change; keep resolvers from caching stale values long
LOG_FILE="/var/log/awsChadHomeIP.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "--- Starting awsChadHomeIP update ---"

# 1. Current public IP (multiple providers for resilience)
CURRENT_IP=$(curl -sf --max-time 10 https://checkip.amazonaws.com \
    || curl -sf --max-time 10 https://api.ipify.org \
    || curl -sf --max-time 10 https://ifconfig.me)

if [[ -z "$CURRENT_IP" ]]; then
    log "ERROR: Could not determine public IP address. Aborting."
    exit 1
fi
CURRENT_IP=$(echo "$CURRENT_IP" | tr -d '[:space:]')
CIDR="${CURRENT_IP}/32"
log "Current public IP: ${CIDR}"

# 2. Update DNS: A records for this box -> current IP (independent of the
#    SG logic below — runs every invocation, regardless of SG state).
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$DNS_ZONE_NAME" \
    --query "HostedZones[?Name=='${DNS_ZONE_NAME}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>>"$LOG_FILE")
ZONE_ID=${ZONE_ID#/hostedzone/}

if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
    log "ERROR: Public hosted zone '${DNS_ZONE_NAME}' not found. Skipping DNS update."
else
    for DNS_RECORD_NAME in "${DNS_RECORDS[@]}"; do
        EXISTING_DNS_IP=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$ZONE_ID" \
            --query "ResourceRecordSets[?Name=='${DNS_RECORD_NAME}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
            --output text 2>>"$LOG_FILE")

        if [[ "$EXISTING_DNS_IP" == "$CURRENT_IP" ]]; then
            log "DNS unchanged (${DNS_RECORD_NAME} -> ${CURRENT_IP})."
        else
            log "DNS changed: ${DNS_RECORD_NAME} ${EXISTING_DNS_IP:-<none>} -> ${CURRENT_IP}"
            CHANGE_BATCH=$(printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","TTL":%d,"ResourceRecords":[{"Value":"%s"}]}}]}' \
                "$DNS_RECORD_NAME" "$DNS_TTL" "$CURRENT_IP")
            if aws route53 change-resource-record-sets \
                --hosted-zone-id "$ZONE_ID" \
                --change-batch "$CHANGE_BATCH" \
                >> "$LOG_FILE" 2>&1; then
                log "SUCCESS: DNS record ${DNS_RECORD_NAME} updated to ${CURRENT_IP}"
            else
                log "ERROR: Failed to update DNS record ${DNS_RECORD_NAME}."
            fi
        fi
    done
fi

# 3. Resolve the home SG by name
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>>"$LOG_FILE")

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    log "ERROR: Security group '${SG_NAME}' not found in ${AWS_DEFAULT_REGION}. Aborting."
    exit 1
fi
log "Target security group: ${SG_ID} (${SG_NAME})"

# 4. Find our rule: ingress, tcp/22, matching description
RULE_JSON=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${SG_ID}" \
    --query 'SecurityGroupRules' \
    --output json 2>>"$LOG_FILE")

SGR_INFO=$(echo "$RULE_JSON" | python3 -c "
import sys, json
rules = json.load(sys.stdin)
want = '$RULE_DESCRIPTION'
for r in rules:
    if (not r.get('IsEgress') and r.get('IpProtocol') == 'tcp'
            and r.get('FromPort') == 22 and r.get('ToPort') == 22
            and r.get('Description') == want):
        print(r['SecurityGroupRuleId'] + '\t' + (r.get('CidrIpv4') or ''))
        break
")

if [[ -z "$SGR_INFO" ]]; then
    log "Rule '${RULE_DESCRIPTION}' not found — creating it with ${CIDR}"
    if aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CIDR},Description=${RULE_DESCRIPTION}}]" \
        >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: Rule created with ${CIDR}"
    else
        log "ERROR: Failed to create rule."
        exit 1
    fi
    log "--- Done ---"
    exit 0
fi

SGR_ID=${SGR_INFO%$'\t'*}
OLD_CIDR=${SGR_INFO#*$'\t'}

if [[ "$OLD_CIDR" == "$CIDR" ]]; then
    log "SG IP unchanged (${CIDR}). No SG update needed."
    log "--- Done ---"
    exit 0
fi
log "SG IP changed: ${OLD_CIDR} -> ${CIDR}"

# 5. Atomic in-place update of the existing rule (keeps SGR ID stable)
PAYLOAD=$(printf '[{"SecurityGroupRuleId":"%s","SecurityGroupRule":{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"CidrIpv4":"%s","Description":"%s"}}]' \
    "$SGR_ID" "$CIDR" "$RULE_DESCRIPTION")

if aws ec2 modify-security-group-rules \
    --group-id "$SG_ID" \
    --security-group-rules "$PAYLOAD" \
    >> "$LOG_FILE" 2>&1; then
    log "SUCCESS: Rule ${SGR_ID} updated to ${CIDR}"
else
    log "ERROR: Failed to update security group rule."
    exit 1
fi

log "--- Done ---"
