#!/usr/bin/env bash
# One-time setup for a new machine. Safe to re-run.
#   1. Installs Terraform and the AWS CLI if missing (into gpu-workers/.tools when possible)
#   2. Signs you in to AWS (browser login, IAM Identity Center/SSO, or access keys)
#   3. Creates terraform/terraform.tfvars with your public IP if it doesn't exist
#   4. Checks your EC2 GPU vCPU quota
# Works on Linux, macOS and Windows (Git Bash).
source "$(dirname "$0")/common.sh"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.13.3}"
TF_MIN_VERSION="1.5.0"

# --- Platform ----------------------------------------------------------------
case "$(uname -s)" in
  Linux*)               OS=linux ;;
  Darwin*)              OS=darwin ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
log "Platform: $OS/$ARCH"

mkdir -p "$TOOLS_BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_zip() {  # extract_zip <zip> <dest>
  if command -v unzip >/dev/null; then
    unzip -q -o "$1" -d "$2"
  else
    "$PYTHON" -m zipfile -e "$1" "$2"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

version_ge() {  # version_ge <have> <need>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# --- Base tools --------------------------------------------------------------
for cmd in curl ssh scp; do
  command -v "$cmd" >/dev/null || die "'$cmd' is required. Install it and re-run."
done
[ -n "$PYTHON" ] || die "Python 3 is required (used to parse API responses). Install it from https://www.python.org/downloads/ and re-run."
log "curl, ssh and python found"

# --- Terraform ---------------------------------------------------------------
install_terraform() {
  local zip="terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  local base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  log "Downloading Terraform $TERRAFORM_VERSION"
  curl -fsSL -o "$TMP/$zip" "$base/$zip"
  curl -fsSL -o "$TMP/SHA256SUMS" "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS"

  local expected actual
  expected="$(grep " $zip\$" "$TMP/SHA256SUMS" | cut -d' ' -f1)"
  actual="$(sha256 "$TMP/$zip")"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Terraform checksum mismatch (expected $expected, got $actual)"

  extract_zip "$TMP/$zip" "$TOOLS_BIN"
  chmod +x "$TOOLS_BIN"/terraform* 2>/dev/null || true
}

tf_version() { terraform version -json 2>/dev/null | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null; }

if command -v terraform >/dev/null && version_ge "$(tf_version)" "$TF_MIN_VERSION"; then
  log "Terraform $(tf_version) found at $(command -v terraform)"
else
  command -v terraform >/dev/null && warn "Terraform $(tf_version) is older than $TF_MIN_VERSION; installing $TERRAFORM_VERSION locally"
  install_terraform
  hash -r
  log "Terraform $(tf_version) installed to $TOOLS_BIN"
fi

# --- AWS CLI v2 --------------------------------------------------------------
install_aws_cli() {
  log "Installing AWS CLI v2"
  case "$OS" in
    linux)
      local arch; arch="$([ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64)"
      curl -fsSL -o "$TMP/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
      extract_zip "$TMP/awscli.zip" "$TMP"
      chmod +x "$TMP/aws/install" "$TMP"/aws/dist/aws* 2>/dev/null || true
      "$TMP/aws/install" --install-dir "$TOOLS_DIR/aws-cli" --bin-dir "$TOOLS_BIN" --update
      ;;
    darwin)
      if command -v brew >/dev/null; then
        brew install awscli
      else
        # Per-user install, no sudo needed. Ends up in ~/aws-cli.
        curl -fsSL -o "$TMP/AWSCLIV2.pkg" "https://awscli.amazonaws.com/AWSCLIV2.pkg"
        cat > "$TMP/choices.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>choiceAttribute</key><string>customLocation</string>
  <key>attributeSetting</key><string>$HOME</string>
  <key>choiceIdentifier</key><string>default</string>
</dict></array></plist>
EOF
        installer -pkg "$TMP/AWSCLIV2.pkg" -target CurrentUserHomeDirectory -applyChoiceChangesXML "$TMP/choices.xml"
        ln -sf "$HOME/aws-cli/aws" "$TOOLS_BIN/aws"
      fi
      ;;
    windows)
      # The MSI installs system-wide (asks for admin rights).
      if command -v winget >/dev/null; then
        winget install --id Amazon.AWSCLI -e --accept-source-agreements --accept-package-agreements
      else
        curl -fsSL -o "$TMP/AWSCLIV2.msi" "https://awscli.amazonaws.com/AWSCLIV2.msi"
        msiexec.exe //i "$(cygpath -w "$TMP/AWSCLIV2.msi")" //passive
      fi
      export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
      ;;
  esac
  hash -r
}

if command -v aws >/dev/null && aws --version 2>&1 | grep -q 'aws-cli/2'; then
  log "AWS CLI found: $(aws --version 2>&1)"
else
  command -v aws >/dev/null && warn "AWS CLI v1 found; v2 is required"
  install_aws_cli
  command -v aws >/dev/null || die "AWS CLI install finished but 'aws' is not on PATH. Open a new terminal and re-run."
  log "AWS CLI installed: $(aws --version 2>&1)"
fi

# --- AWS authentication ------------------------------------------------------
aws_authed() { aws sts get-caller-identity --profile "$1" >/dev/null 2>&1; }

profile_cfg() { aws configure get "$2" --profile "$1" 2>/dev/null || true; }

ask() {  # ask <prompt> <default>
  local reply
  read -r -p "$1 [$2]: " reply </dev/tty || true
  echo "${reply:-$2}"
}

# Refresh an existing profile's credentials using the method it was set up with.
refresh_profile() {
  local p="$1"
  if [ -n "$(profile_cfg "$p" sso_session)$(profile_cfg "$p" sso_start_url)" ]; then
    log "Profile '$p' uses IAM Identity Center - opening browser for 'aws sso login'"
    aws sso login --profile "$p"
  elif [ -n "$(profile_cfg "$p" login_session)" ]; then
    log "Profile '$p' uses console sign-in - opening browser for 'aws login'"
    aws login --profile "$p"
  else
    warn "Profile '$p' has no working credentials - re-enter access keys"
    aws configure --profile "$p"
  fi
}

create_profile() {
  local p="$1" have_login=false
  aws login help >/dev/null 2>&1 && have_login=true

  echo
  echo "How do you sign in to AWS?"
  $have_login && echo "  1) Browser login with your AWS console account   (aws login)        [recommended]"
  echo "  2) IAM Identity Center / SSO (company login)      (aws configure sso)"
  echo "  3) IAM user access keys                           (aws configure)"
  local choice; choice="$(ask "Choose" "$($have_login && echo 1 || echo 2)")"

  case "$choice" in
    1) $have_login || die "'aws login' needs a newer AWS CLI v2. Pick 2 or 3, or upgrade the CLI."
       aws login --profile "$p" ;;
    2) aws configure sso --profile "$p" ;;
    3) echo "Create keys in the AWS console: IAM > Users > <you> > Security credentials > Create access key"
       aws configure --profile "$p" ;;
    *) die "Invalid choice: $choice" ;;
  esac
}

log "Checking AWS credentials"
PROFILE="${AWS_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  PROFILES="$(aws configure list-profiles 2>/dev/null | tr '\n' ' ')"
  if [ -n "$PROFILES" ]; then
    echo "Existing AWS profiles: $PROFILES"
    PROFILE="$(ask "AWS profile to use (a new name creates one)" "$(echo "$PROFILES" | awk '{print $1}')")"
  else
    PROFILE="$(ask "Name for a new AWS profile" "default")"
  fi
fi

if ! aws_authed "$PROFILE"; then
  if aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; then
    refresh_profile "$PROFILE"
  else
    create_profile "$PROFILE"
  fi
fi
aws_authed "$PROFILE" || die "Still not signed in to AWS with profile '$PROFILE'. Re-run ./scripts/setup.sh"

export AWS_PROFILE="$PROFILE"
printf 'export AWS_PROFILE=%q\n' "$PROFILE" > "$TOOLS_ENV"
log "Signed in to AWS (profile '$PROFILE'):"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table

# --- terraform.tfvars --------------------------------------------------------
TFVARS="$TF_DIR/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
  MY_IP="$(curl -sf --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]' || true)"
  REGION="$(aws configure get region 2>/dev/null || true)"
  REGION="$(ask "AWS region for the cluster" "${REGION:-us-east-1}")"
  cp "$TF_DIR/terraform.tfvars.example" "$TFVARS"
  sed -i.bak -e "s|^region *=.*|region       = \"$REGION\"|" "$TFVARS"
  [ -n "$MY_IP" ] && sed -i.bak -e "s|^allowed_cidrs *=.*|allowed_cidrs = [\"$MY_IP/32\"]|" "$TFVARS"
  rm -f "$TFVARS.bak"
  log "Created $TFVARS (region=$REGION, allowed_cidrs=${MY_IP:-<edit me>}/32)"
else
  log "Using existing $TFVARS"
fi

# --- GPU quota check (informational) -----------------------------------------
tfvar() { sed -n "s/^$1 *= *\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$TFVARS" | head -1 | tr -d ' '; }
REGION="$(tfvar region)";              REGION="${REGION:-us-east-1}"
ITYPE="$(tfvar worker_instance_type)"; ITYPE="${ITYPE:-g4dn.xlarge}"
COUNT="$(tfvar worker_count)";         COUNT="${COUNT:-2}"
SPOT="$(tfvar worker_use_spot)"

# Service Quotas codes: G/VT vs P families, on-demand vs spot.
case "${ITYPE%%.*}:$SPOT" in
  p*:true) QUOTA=L-7212CCBC; QNAME="All P Spot Instance Requests" ;;
  p*:*)    QUOTA=L-417A185B; QNAME="Running On-Demand P instances" ;;
  *:true)  QUOTA=L-3819A6DF; QNAME="All G and VT Spot Instance Requests" ;;
  *)       QUOTA=L-DB2E81BA; QNAME="Running On-Demand G and VT instances" ;;
esac

VCPUS="$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$ITYPE" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null || true)"
LIMIT="$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code "$QUOTA" \
  --query 'Quota.Value' --output text 2>/dev/null || true)"

if [[ "$VCPUS" =~ ^[0-9]+$ ]] && [[ "$LIMIT" =~ ^[0-9.]+$ ]]; then
  NEED=$((VCPUS * COUNT)); LIMIT="${LIMIT%.*}"
  if [ "$LIMIT" -ge "$NEED" ]; then
    log "GPU quota OK in $REGION: '$QNAME' = $LIMIT vCPUs, need $NEED ($COUNT x $ITYPE)"
  else
    warn "GPU quota too low in $REGION: '$QNAME' = $LIMIT vCPUs, need $NEED ($COUNT x $ITYPE)."
    warn "Request an increase: https://$REGION.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/$QUOTA"
  fi
else
  warn "Couldn't check the GPU quota ('$QNAME') for $ITYPE in $REGION - check it in the Service Quotas console"
fi

echo
log "Setup complete. Review terraform/terraform.tfvars, then run: ./scripts/deploy.sh"
