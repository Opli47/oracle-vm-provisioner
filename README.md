# Oracle VM Provisioner for Always Free OCI

Runs on Railway and retries until Oracle Cloud Infrastructure capacity is available for an Always Free VM.

The default target is the current Always Free Arm shape:

- Shape: `VM.Standard.A1.Flex`
- OCPUs: `4`
- Memory: `24 GB`
- Boot volume: `200 GB`
- Region: your tenancy home region
- Image: latest Ubuntu 22.04 image compatible with the selected shape

Oracle's Always Free guidance currently allows up to 4 OCPUs and 24 GB memory total for `VM.Standard.A1.Flex`, plus 200 GB total block volume storage in the tenancy home region. This provisioner now claims the full compute and block-volume allowance for one max-size free A1 VM.

Source: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

---

## Deploy on Railway

1. Push this repo to GitHub.
2. In Railway, create a new project from the GitHub repo.
3. Railway detects the `Dockerfile` and starts the container.
4. Add the environment variables below.
5. Watch Railway logs until the VM is created.

---

## Required Environment Variables

### OCI Authentication

| Variable | Description |
|---|---|
| `OCI_TENANCY` | Tenancy OCID |
| `OCI_REGION` | Your tenancy home region, for example `ap-mumbai-1` |
| `OCI_COMPARTMENT_ID` | Compartment OCID, often the tenancy OCID for the root compartment |
| `OCI_USER` | User OCID from OCI Console -> Profile -> My Profile |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_PRIVATE_KEY` | Full private key PEM contents |

### VM Placement

| Variable | Description |
|---|---|
| `OCI_SUBNET_ID` | Subnet OCID where the instance will be launched |
| `OCI_AVAILABILITY_DOMAIN` | Availability domain name, for example `xxxx:AP-MUMBAI-1-AD-1` |
| `VM_SSH_PUBLIC_KEY` | SSH public key to inject into the VM |

`OCI_IMAGE_ID` is now optional. If omitted, the script looks up the latest Ubuntu image for the selected region, OS version, and shape.

---

## Optional Environment Variables

| Variable | Default | Description |
|---|---:|---|
| `VM_DISPLAY_NAME` | `oplify-agent` | Name shown in OCI Console |
| `VM_SHAPE` | `VM.Standard.A1.Flex` | Default Always Free Arm shape |
| `VM_OCPUS` | `4` | OCPU count for A1 Flex |
| `VM_MEMORY_GB` | `24` | Memory for A1 Flex |
| `VM_BOOT_VOLUME_GB` | `200` | Boot disk size; consumes the full 200 GB Always Free block volume quota |
| `OCI_IMAGE_ID` | empty | Optional explicit image OCID |
| `OCI_IMAGE_OS` | `Canonical Ubuntu` | Used only when auto-looking up an image |
| `OCI_IMAGE_OS_VERSION` | `22.04` | Used only when auto-looking up an image |
| `ASSIGN_PUBLIC_IP` | `true` | Set `false` if you will connect through OCI Bastion/VPN/private networking |
| `FREE_TIER_STRICT` | `true` | Enforces Always Free shape and size guardrails |
| `RETRY_INTERVAL_SECONDS` | `300` | Retry delay after capacity/rate-limit errors |

---

## Create OCI API Key

1. OCI Console -> profile avatar -> **My Profile**.
2. Left sidebar -> **API Keys** -> **Add API Key**.
3. Select **Generate API Key Pair** and download the private key.
4. Copy the config snippet shown by OCI.
5. Use `user`, `fingerprint`, and `tenancy` from that snippet.
6. Paste the entire private key PEM into Railway as `OCI_PRIVATE_KEY`.

Railway supports multiline values. If your key is stored with literal `\n` characters, the script converts them back to newlines.

---

## Logs

Expected log flow:

```text
Oplify Oracle Cloud VM Provisioner starting on Railway
Shape    : VM.Standard.A1.Flex | 4 OCPU | 24GB RAM | 200GB disk
Region   : ap-mumbai-1
Using the full 200 GB Always Free block volume allowance for this VM.
Attempt #1 | AD: ...
Capacity/rate limit in ...
Retrying in 5 min...
...
VM CREATED SUCCESSFULLY
Instance ID : ocid1.instance...
Public IP   : x.x.x.x
```

When capacity is unavailable, the script retries the single `OCI_AVAILABILITY_DOMAIN` you configured. Free OCI accounts are often effectively pinned to one availability domain, so this provisioner does not poll or rotate through other ADs.

---

## SSH

If `ASSIGN_PUBLIC_IP=true`:

```bash
ssh -i oplify_vm_key ubuntu@<PUBLIC_IP>
```

Windows PowerShell:

```powershell
ssh -i C:\Users\Sandeep\.ssh\oplify_vm_key ubuntu@<PUBLIC_IP>
```

If `ASSIGN_PUBLIC_IP=false`, connect through OCI Bastion, VPN, or another private networking path.

---

## After the VM Is Created

Stop or remove the Railway service after the VM is running. The provisioner has done its job and does not need to consume Railway runtime continuously.

---

## Files

```text
oracle-vm-provisioner/
├── Dockerfile
├── provision.sh
└── README.md
```

No OCI secrets are stored in this repo. Keep all secrets in Railway environment variables.
