#!/usr/bin/env bash
# Private CA for IAM Roles Anywhere (Jenkins CI + host AWS access). Free: AWS only
# stores the CA *certificate* in a trust anchor (aws-infrastructure module
# ci-roles-anywhere); private keys never leave this host.
#
#   scripts/jenkins_ca.sh init                  # once: root CA (10y), passphrase-protected key
#   scripts/jenkins_ca.sh issue <cn> --jenkins  # leaf for Jenkins  -> ~/.local/share/jenkins/secrets/roles-anywhere/
#   scripts/jenkins_ca.sh issue <cn> --host     # leaf for this host -> ~/.local/share/aws-roles-anywhere/
#   scripts/jenkins_ca.sh list                  # expiry of every issued cert
#
# CNs must match the role trust policies (aws:PrincipalTag/x509Subject/CN):
#   jenkins-aws-infrastructure, jenkins-blog-deploy, jenkins-blog-terraform,
#   jenkins-zca-dev, jenkins-zca-prod, jenkins-traderintel, chad-host-terraform
# Leaf certs last 180 days; ci-maintenance/cert-expiry in Jenkins warns at <30 days.
# Renewal = run `issue` again (same CN) — no AWS change needed.
# The CA passphrase is read from $JENKINS_CA_PASSPHRASE or prompted. Back up
# ~/.local/share/jenkins/ca (Kopia) — losing ca.key means re-issuing the trust anchor.
set -euo pipefail

CA_DIR=${JENKINS_CA_DIR:-$HOME/.local/share/jenkins/ca}
JENKINS_DEST=${JENKINS_RA_DEST:-$HOME/.local/share/jenkins/secrets/roles-anywhere}
HOST_DEST=${HOST_RA_DEST:-$HOME/.local/share/aws-roles-anywhere}
LEAF_DAYS=${LEAF_DAYS:-180}

die() { echo "error: $*" >&2; exit 1; }

passarg() {
  if [ -n "${JENKINS_CA_PASSPHRASE:-}" ]; then echo "env:JENKINS_CA_PASSPHRASE"; else echo "stdin"; fi
}

cmd_init() {
  [ -e "$CA_DIR/ca.key" ] && die "CA already exists in $CA_DIR"
  umask 077
  mkdir -p "$CA_DIR/issued"
  chmod 700 "$CA_DIR"
  if [ -z "${JENKINS_CA_PASSPHRASE:-}" ]; then
    read -r -s -p "New CA passphrase: " JENKINS_CA_PASSPHRASE; echo
    export JENKINS_CA_PASSPHRASE
  fi
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -aes-256-cbc -pass env:JENKINS_CA_PASSPHRASE -out "$CA_DIR/ca.key"
  openssl req -x509 -new -sha256 -days 3650 -key "$CA_DIR/ca.key" -passin env:JENKINS_CA_PASSPHRASE \
    -subj "/O=chadrbean/CN=chadrbean Roles Anywhere CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$CA_DIR/ca.pem"
  chmod 644 "$CA_DIR/ca.pem"
  echo "CA created: $CA_DIR/ca.pem"
  echo "Next: cp $CA_DIR/ca.pem ~/git/aws-infrastructure/ci/jenkins-ca.pem (public cert, safe to commit)"
}

cmd_issue() {
  local cn=${1:-} mode=${2:-}
  [ -n "$cn" ] || die "usage: issue <cn> --jenkins|--host"
  [[ "$cn" =~ ^[a-z0-9-]+$ ]] || die "cn must be [a-z0-9-]+"
  [ -e "$CA_DIR/ca.key" ] || die "no CA — run init first"
  local dest
  case "$mode" in
    --jenkins) dest=$JENKINS_DEST ;;
    --host)    dest=$HOST_DEST ;;
    *) die "specify --jenkins or --host" ;;
  esac
  umask 077
  mkdir -p "$dest"; chmod 700 "$dest"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/leaf.key"
  openssl req -new -sha256 -key "$tmp/leaf.key" -subj "/O=chadrbean/CN=$cn" -out "$tmp/leaf.csr"
  cat > "$tmp/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
  local pass; pass=$(passarg)
  if [ "$pass" = stdin ]; then
    read -r -s -p "CA passphrase: " JENKINS_CA_PASSPHRASE; echo
    export JENKINS_CA_PASSPHRASE
  fi
  openssl x509 -req -sha256 -days "$LEAF_DAYS" -in "$tmp/leaf.csr" \
    -CA "$CA_DIR/ca.pem" -CAkey "$CA_DIR/ca.key" -passin env:JENKINS_CA_PASSPHRASE \
    -CAcreateserial -CAserial "$CA_DIR/ca.srl" -extfile "$tmp/ext.cnf" -out "$tmp/leaf.pem"
  install -m 600 "$tmp/leaf.key" "$dest/$cn.key"
  install -m 644 "$tmp/leaf.pem" "$dest/$cn.pem"
  install -m 644 "$tmp/leaf.pem" "$CA_DIR/issued/$cn.pem"
  echo "issued $cn -> $dest/$cn.{pem,key} (expires $(openssl x509 -enddate -noout -in "$tmp/leaf.pem" | cut -d= -f2))"
}

cmd_list() {
  local c
  for c in "$CA_DIR"/issued/*.pem; do
    [ -e "$c" ] || { echo "no issued certs"; return; }
    printf '%-32s %s\n' "$(basename "$c" .pem)" "$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"
  done
}

case "${1:-}" in
  init)  cmd_init ;;
  issue) shift; cmd_issue "$@" ;;
  list)  cmd_list ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
