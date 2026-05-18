#!/bin/bash

# =============================================================
# Oplify - Oracle Cloud VM Provisioner
# Runs on Railway. All secrets from environment variables.
# No secrets in code. Retries every 5 min indefinitely.
# =============================================================

# ---- Validate required env vars ----------------------------
REQUIRED_VARS="OCI_TENANCY OCI_USER OCI_FINGERPRINT OCI_PRIVATE_KEY OCI_REGION \
               OCI_COMPARTMENT_ID OCI_SUBNET_ID OCI_AVAILABILITY_DOMAIN \
               OCI_IMAGE_ID VM_SSH_PUBLIC_KEY"

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
chmod 600 ~/.oci/private_key.pem

# ---- Fixed VM settings -------------------------------------
COMPARTMENT_ID="${OCI_COMPARTMENT_ID}"
SUBNET_ID="${OCI_SUBNET_ID}"
AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN}"
IMAGE_ID="${OCI_IMAGE_ID}"
SSH_PUB="${VM_SSH_PUBLIC_KEY}"

DISPLAY_NAME="${VM_DISPLAY_NAME:-oplify-agent}"
SHAPE="VM.Standard.A1.Flex"
OCPUS="${VM_OCPUS:-4}"
MEMORY_GB="${VM_MEMORY_GB:-24}"
BOOT_VOLUME_GB="${VM_BOOT_VOLUME_GB:-100}"
RETRY_INTERVAL="${RETRY_INTERVAL_SECONDS:-300}"

# ---- Helpers -----------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
hr()  { echo "-------------------------------------------------------------"; }

# ---- Verify OCI CLI works ----------------------------------
log "Verifying OCI CLI authentication..."
TEST=$(oci iam region list --query 'data[0].name' --raw-output 2>&1)
if [[ $? -ne 0 ]]; then
    log "ERROR: OCI CLI auth failed. Check your env vars."
    log "Detail: $TEST"
    exit 1
fi
log "OCI CLI authenticated. Region check: $TEST"

# ---- Collect all ADs for rotation --------------------------
get_all_ads() {
    oci iam availability-domain list \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data[*].name' --raw-output 2>/dev/null \
        | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

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
log "Shape    : $SHAPE | ${OCPUS} OCPU | ${MEMORY_GB}GB RAM | ${BOOT_VOLUME_GB}GB disk"
log "Region   : ${OCI_REGION}"
log "AD       : $AVAILABILITY_DOMAIN"
log "Retry    : every $((RETRY_INTERVAL / 60)) min on failure"
hr

ALL_ADS=$(get_all_ads)
AD_LIST=($ALL_ADS)
AD_INDEX=0
CURRENT_AD="$AVAILABILITY_DOMAIN"
ATTEMPT=1

log "Available ADs: ${AD_LIST[*]}"

while true; do
    log "Attempt #$ATTEMPT | AD: $CURRENT_AD"

    OUTPUT=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$CURRENT_AD" \
        --display-name "$DISPLAY_NAME" \
        --image-id "$IMAGE_ID" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --ssh-authorized-keys-file <(echo "$SSH_PUB") \
        2>&1)

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
        log "Public IP   : $PUBLIC_IP"
        log "Region      : ${OCI_REGION}"
        log "AD          : $CURRENT_AD"
        hr
        log "SSH command (run on your local machine):"
        log "  ssh -i oplify_vm_key ubuntu@$PUBLIC_IP"
        log ""
        log "Windows PowerShell:"
        log "  ssh -i C:\Users\Sandeep\.ssh\oplify_vm_key ubuntu@$PUBLIC_IP"
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
            log "VM is running. Instance: $INSTANCE_ID | IP: $PUBLIC_IP"
        done

    elif echo "$OUTPUT" | grep -qi "capacity\|Out of host capacity\|InternalError\|LimitExceeded\|host capacity\|429\|TooManyRequests\|QuotaExceeded\|RateLimitExceeded"; then
        log "Capacity/rate limit in $CURRENT_AD."
        # Rotate AD
        if [[ ${#AD_LIST[@]} -gt 1 ]]; then
            AD_INDEX=$(( (AD_INDEX + 1) % ${#AD_LIST[@]} ))
            CURRENT_AD="${AD_LIST[$AD_INDEX]}"
            log "Rotating to next AD: $CURRENT_AD"
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
