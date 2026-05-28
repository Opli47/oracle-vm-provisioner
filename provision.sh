#!/bin/bash

# =============================================================
# Oplify - Oracle Cloud VM Provisioner
# Runs on Railway. All secrets from environment variables.
# No secrets in code. Retries every 5 min indefinitely.
# =============================================================

# ---- Validate required env vars ----------------------------
REQUIRED_VARS="OCI_TENANCY OCI_USER OCI_FINGERPRINT OCI_PRIVATE_KEY OCI_REGION \
               OCI_COMPARTMENT_ID OCI_SUBNET_ID OCI_AVAILABILITY_DOMAIN \
               VM_SSH_PUBLIC_KEY"

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export SUPPRESS_LABEL_WARNING=True
export PYTHONWARNINGS="${PYTHONWARNINGS:-ignore::FutureWarning}"

MISSING=0
for VAR in $REQUIRED_VARS; do
    if [[ -z "${!VAR}" ]]; then
        echo "[ERROR] Missing required environment variable: $VAR"
        MISSING=$((MISSING+1))
    fi
done
if [[ $MISSING -gt 0 ]]; then
    echo ""
    echo "Set all required variables in Railway dashboard -> Variables."
    echo "See README.md for the full list."
    exit 1
fi

# ---- Write OCI config from env vars ------------------------
mkdir -p ~/.oci
cat > ~/.oci/config << EOF
[DEFAULT]
user=${OCI_USER}
fingerprint=${OCI_FINGERPRINT}
tenancy=${OCI_TENANCY}
region=${OCI_REGION}
key_file=/root/.oci/private_key.pem
EOF

# Write private key (Railway stores it as single-line with \n literals)
echo "${OCI_PRIVATE_KEY}" | sed 's/\\n/\n/g' > ~/.oci/private_key.pem
if ! tail -n 1 ~/.oci/private_key.pem | grep -qx 'OCI_API_KEY'; then
    echo 'OCI_API_KEY' >> ~/.oci/private_key.pem
fi
chmod 600 ~/.oci/private_key.pem

# ---- Fixed VM settings -------------------------------------
COMPARTMENT_ID="${OCI_COMPARTMENT_ID}"
SUBNET_ID="${OCI_SUBNET_ID}"
AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN}"
IMAGE_ID="${OCI_IMAGE_ID:-}"
SSH_PUB="${VM_SSH_PUBLIC_KEY}"
SSH_PUB_FILE="$(mktemp)"
printf '%s\n' "$SSH_PUB" > "$SSH_PUB_FILE"
chmod 600 "$SSH_PUB_FILE"

DISPLAY_NAME="${VM_DISPLAY_NAME:-oplify-agent}"
SHAPE="${VM_SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${VM_OCPUS:-4}"
MEMORY_GB="${VM_MEMORY_GB:-24}"
BOOT_VOLUME_GB="${VM_BOOT_VOLUME_GB:-200}"
RETRY_INTERVAL="${RETRY_INTERVAL_SECONDS:-300}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
FREE_TIER_STRICT="${FREE_TIER_STRICT:-true}"
OCI_IMAGE_OS="${OCI_IMAGE_OS:-Canonical Ubuntu}"
OCI_IMAGE_OS_VERSION="${OCI_IMAGE_OS_VERSION:-22.04}"

# ---- Helpers -----------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
hr()  { echo "-------------------------------------------------------------"; }

die() {
    log "ERROR: $1"
    exit 1
}

is_true() {
    [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]
}

validate_number() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        die "$name must be a number. Got: $value"
    fi
}

validate_integer() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "$name must be an integer. Got: $value"
    fi
}

float_lte() {
    python3 - "$1" "$2" <<'PY'
import sys
print("1" if float(sys.argv[1]) <= float(sys.argv[2]) else "0")
PY
}

int_lte() {
    [[ "$1" -le "$2" ]]
}

# ---- Verify OCI CLI works ----------------------------------
log "Verifying OCI CLI authentication..."
TEST=$(oci iam region-subscription list --tenancy-id "$OCI_TENANCY" --query 'length(data)' --raw-output 2>&1)
if [[ $? -ne 0 ]]; then
    log "ERROR: OCI CLI auth failed. Check your env vars."
    log "Detail: $TEST"
    exit 1
fi
log "OCI CLI authenticated. Tenancy has access to $TEST subscribed region(s)."

# ---- Free-tier guardrails ----------------------------------
validate_number "VM_OCPUS" "$OCPUS"
validate_number "VM_MEMORY_GB" "$MEMORY_GB"
validate_integer "VM_BOOT_VOLUME_GB" "$BOOT_VOLUME_GB"

if is_true "$FREE_TIER_STRICT"; then
    if [[ "$SHAPE" != "VM.Standard.A1.Flex" && "$SHAPE" != "VM.Standard.E2.1.Micro" ]]; then
        die "FREE_TIER_STRICT=true allows only VM.Standard.A1.Flex or VM.Standard.E2.1.Micro. Got: $SHAPE"
    fi

    if [[ "$SHAPE" == "VM.Standard.A1.Flex" ]]; then
        [[ "$(float_lte "$OCPUS" "4")" == "1" ]] || die "A1 Always Free allows 4 OCPUs total. Requested VM_OCPUS=$OCPUS"
        [[ "$(float_lte "$MEMORY_GB" "24")" == "1" ]] || die "A1 Always Free allows 24 GB memory total. Requested VM_MEMORY_GB=$MEMORY_GB"
    fi

    int_lte "$BOOT_VOLUME_GB" 200 || die "Always Free block volume budget is 200 GB total. Requested boot volume: ${BOOT_VOLUME_GB}GB"
    if [[ "$BOOT_VOLUME_GB" -lt 50 ]]; then
        die "Use at least 50 GB for boot volume. OCI Always Free boot volumes commonly default to 50 GB."
    fi

    if [[ "$BOOT_VOLUME_GB" -eq 200 ]]; then
        log "Using the full 200 GB Always Free block volume allowance for this VM."
        log "Do not create additional boot/block volumes unless you intentionally move beyond Always Free."
    fi
fi

# Warn if the configured region is not the tenancy home region. Always Free
# compute/block volume resources must be created in the home region.
HOME_REGION=$(oci iam region-subscription list \
    --tenancy-id "$OCI_TENANCY" \
    --query 'data[?"is-home-region"==`true`]."region-name"|[0]' \
    --raw-output 2>/dev/null || true)

if [[ -n "$HOME_REGION" && "$HOME_REGION" != "null" && "$HOME_REGION" != "$OCI_REGION" ]]; then
    log "WARNING: OCI_REGION=$OCI_REGION but tenancy home region appears to be $HOME_REGION."
    log "Always Free compute and boot volumes should be created in the home region."
fi

resolve_image_id() {
    if [[ -n "$IMAGE_ID" ]]; then
        echo "$IMAGE_ID"
        return 0
    fi

    log "OCI_IMAGE_ID not set. Looking up latest Always Free-compatible image..." >&2
    oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "$OCI_IMAGE_OS" \
        --operating-system-version "$OCI_IMAGE_OS_VERSION" \
        --shape "$SHAPE" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[0].id' \
        --raw-output 2>/dev/null
}

IMAGE_ID="$(resolve_image_id)"
if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
    die "Could not resolve OCI image. Set OCI_IMAGE_ID manually, or adjust OCI_IMAGE_OS/OCI_IMAGE_OS_VERSION."
fi
log "Image ID : $IMAGE_ID"

wait_for_running() {
    local id="$1" attempt=0
    log "Waiting for RUNNING state..."
    sleep 20
    while [[ $attempt -lt 20 ]]; do
        STATE=$(oci compute instance get \
            --instance-id "$id" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
        if [[ "$STATE" == "RUNNING" ]]; then
            log "Instance is RUNNING."
            return 0
        fi
        log "  State: $STATE ($((attempt+1))/20)"
        sleep 15
        attempt=$((attempt+1))
    done
    log "WARNING: Timed out waiting. Check OCI Console."
}

get_public_ip() {
    sleep 15
    oci compute instance list-vnics \
        --instance-id "$1" \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data[0]."public-ip"' --raw-output 2>/dev/null
}

# ---- Main loop ---------------------------------------------
hr
log "Oplify Oracle Cloud VM Provisioner starting on Railway"
if [[ "$SHAPE" == "VM.Standard.A1.Flex" ]]; then
    log "Shape    : $SHAPE | ${OCPUS} OCPU | ${MEMORY_GB}GB RAM | ${BOOT_VOLUME_GB}GB disk"
else
    log "Shape    : $SHAPE | fixed shape size | ${BOOT_VOLUME_GB}GB disk"
fi
log "Region   : ${OCI_REGION}"
log "AD       : $AVAILABILITY_DOMAIN"
log "Public IP: $ASSIGN_PUBLIC_IP"
log "Strict AF: $FREE_TIER_STRICT"
log "Retry    : every $((RETRY_INTERVAL / 60)) min on failure"
hr

CURRENT_AD="$AVAILABILITY_DOMAIN"
ATTEMPT=1
log "Pinned AD : $CURRENT_AD"

while true; do
    log "Attempt #$ATTEMPT | AD: $CURRENT_AD"

    LAUNCH_ARGS=(
        compute instance launch
        --compartment-id "$COMPARTMENT_ID"
        --availability-domain "$CURRENT_AD"
        --display-name "$DISPLAY_NAME"
        --image-id "$IMAGE_ID"
        --shape "$SHAPE"
        --subnet-id "$SUBNET_ID"
        --assign-public-ip "$ASSIGN_PUBLIC_IP"
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB"
        --ssh-authorized-keys-file "$SSH_PUB_FILE"
    )

    if [[ "$SHAPE" == "VM.Standard.A1.Flex" ]]; then
        LAUNCH_ARGS+=(--shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}")
    fi

    OUTPUT=$(oci "${LAUNCH_ARGS[@]}" 2>&1)

    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 0 ]]; then
        INSTANCE_ID=$(echo "$OUTPUT" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d['data']['id'])" 2>/dev/null)

        wait_for_running "$INSTANCE_ID"
        PUBLIC_IP=$(get_public_ip "$INSTANCE_ID")

        hr
        log "VM CREATED SUCCESSFULLY"
        hr
        log "Instance ID : $INSTANCE_ID"
        log "Public IP   : ${PUBLIC_IP:-none}"
        log "Region      : ${OCI_REGION}"
        log "AD          : $CURRENT_AD"
        hr
        if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]]; then
            log "SSH command (run on your local machine):"
            log "  ssh -i oplify_vm_key ubuntu@$PUBLIC_IP"
            log ""
            log "Windows PowerShell:"
            log "  ssh -i C:\\Users\\Sandeep\\.ssh\\oplify_vm_key ubuntu@$PUBLIC_IP"
        else
            log "No public IP was assigned. Connect through OCI Bastion/VPN/private network."
        fi
        hr
        log "NEXT STEPS:"
        log "  1. SSH into VM"
        log "  2. Open ports: Security List + iptables"
        log "  3. Install Docker + Docker Compose"
        log "  4. Deploy n8n stack"
        hr
        log "Container will stay alive. Check Railway logs for this output."

        # Stay alive so Railway logs remain visible
        while true; do
            sleep 3600
            log "VM is running. Instance: $INSTANCE_ID | IP: ${PUBLIC_IP:-none}"
        done

    elif echo "$OUTPUT" | grep -qi "capacity\|Out of host capacity\|InternalError\|LimitExceeded\|host capacity\|429\|TooManyRequests\|QuotaExceeded\|RateLimitExceeded\|RequestException\|ServiceError"; then
        log "Capacity/rate/temporary OCI error in $CURRENT_AD."
        if echo "$OUTPUT" | grep -qi "RequestException\|ServiceError"; then
            log "OCI CLI returned a transient request/service exception. Will retry without changing AD."
        fi
        log "Retrying in $((RETRY_INTERVAL / 60)) min..."
        ATTEMPT=$((ATTEMPT+1))
        sleep "$RETRY_INTERVAL"

    elif echo "$OUTPUT" | grep -qi "NotAuthenticated\|NotAuthorized\|Authorization"; then
        log "ERROR: Authentication failed. Check OCI env vars in Railway."
        log "$OUTPUT" | tail -10
        exit 1

    elif echo "$OUTPUT" | grep -qi "image.*not found\|InvalidParameter.*image"; then
        log "ERROR: IMAGE_ID not valid for this region."
        log "Find correct image ID with:"
        log "  oci compute image list --compartment-id \$OCI_COMPARTMENT_ID \\"
        log "    --operating-system 'Canonical Ubuntu' \\"
        log "    --operating-system-version '22.04' \\"
        log "    --shape VM.Standard.A1.Flex \\"
        log "    --query 'data[0].id' --raw-output"
        log "Then update OCI_IMAGE_ID env var in Railway."
        exit 1

    else
        log "Unexpected error (will retry):"
        echo "$OUTPUT" | tail -15
        log "Retrying in $((RETRY_INTERVAL / 60)) min..."
        ATTEMPT=$((ATTEMPT+1))
        sleep "$RETRY_INTERVAL"
    fi

done
