# Oracle VM Provisioner — Railway Deployment

Runs 24/7 on Railway. Retries every 5 min until Oracle ARM capacity is available in Mumbai.
No secrets in code — all config via Railway environment variables.

---

## Deploy in 5 steps

### Step 1 — Push this repo to GitHub

```bash
git init
git add .
git commit -m "oracle vm provisioner"
git remote add origin https://github.com/YOUR_USERNAME/oracle-vm-provisioner.git
git push -u origin main
```

### Step 2 — Create Railway project

1. Go to https://railway.app
2. New Project -> Deploy from GitHub repo -> select this repo
3. Railway detects Dockerfile and starts building

### Step 3 — Add environment variables in Railway

Go to your service -> Variables tab -> add each variable below.

---

## Environment Variables

### Required — OCI Authentication

| Variable | Value |
|---|---|
| `OCI_TENANCY` | `ocid1.tenancy.oc1..aaaaaaaa7duoqojub334gbrhsiemwuuzcen5bzuuykrujvhx72xsc3embenq` |
| `OCI_REGION` | `ap-mumbai-1` |
| `OCI_COMPARTMENT_ID` | `ocid1.tenancy.oc1..aaaaaaaa7duoqojub334gbrhsiemwuuzcen5bzuuykrujvhx72xsc3embenq` |
| `OCI_USER` | Get from: OCI Console -> Profile -> My Profile -> copy OCID |
| `OCI_FINGERPRINT` | Get from: OCI Console -> Profile -> My Profile -> API Keys -> copy fingerprint |
| `OCI_PRIVATE_KEY` | Contents of the private_key.pem file (see Step 4 below) |

### Required — VM Config

| Variable | Value |
|---|---|
| `OCI_SUBNET_ID` | `ocid1.subnet.oc1.ap-mumbai-1.aaaaaaaaq4o4otcmx5g5gtcq7gbq2zhqqge2hw6hh3w2qyina6mybewn5g5a` |
| `OCI_AVAILABILITY_DOMAIN` | `nhWd:AP-MUMBAI-1-AD-1` |
| `OCI_IMAGE_ID` | `ocid1.image.oc1.ap-mumbai-1.aaaaaaaa2op2x2s5rnduo5osx6zojr526qxtrvhddkdhks5nllbwjzcylwya` |
| `VM_SSH_PUBLIC_KEY` | Your SSH public key (from Cloud Shell: `cat ~/.ssh/oplify_vm_key.pub`) |

### Optional — VM Sizing (defaults shown)

| Variable | Default | Description |
|---|---|---|
| `VM_DISPLAY_NAME` | `oplify-agent` | Name shown in OCI Console |
| `VM_OCPUS` | `4` | CPU count |
| `VM_MEMORY_GB` | `24` | RAM in GB |
| `VM_BOOT_VOLUME_GB` | `100` | Disk size in GB |
| `RETRY_INTERVAL_SECONDS` | `300` | Seconds between retries (300 = 5 min) |

---

## Step 4 — Create OCI API Key (for OCI_USER, OCI_FINGERPRINT, OCI_PRIVATE_KEY)

Cloud Shell cannot authenticate Railway — you need a user API key:

1. OCI Console -> top-right profile avatar -> **My Profile**
2. Left sidebar -> **API Keys** -> **Add API Key**
3. Select **Generate API Key Pair** -> Download both files
4. Copy the config snippet shown — it contains `user=`, `fingerprint=`, `tenancy=`
5. Use those values for `OCI_USER` and `OCI_FINGERPRINT`
6. Open the downloaded private key file -> copy entire contents
7. Paste as `OCI_PRIVATE_KEY` in Railway (Railway handles multiline values fine)

---

## Step 5 — Watch logs

Railway dashboard -> your service -> **Logs** tab.

You will see:
```
Attempt #1 | AD: nhWd:AP-MUMBAI-1-AD-1
Capacity unavailable. Retrying in 5 min...
Attempt #2 | AD: nhWd:AP-MUMBAI-1-AD-1
...
VM CREATED SUCCESSFULLY
Instance ID : ocid1.instance...
Public IP   : x.x.x.x
SSH: ssh -i oplify_vm_key ubuntu@x.x.x.x
```

When you see the IP, SSH in using your saved private key.

---

## SSH into the VM

**Windows PowerShell:**
```
ssh -i C:\Users\Sandeep\.ssh\oplify_vm_key ubuntu@<PUBLIC_IP>
```

**Mac / Linux:**
```bash
chmod 600 ~/oplify_vm_key
ssh -i ~/oplify_vm_key ubuntu@<PUBLIC_IP>
```

---

## After VM is created — stop the Railway service

Once the VM is running, the Railway service keeps logging every hour but does nothing.
Stop it from Railway dashboard to save free tier hours:
Service -> Settings -> Remove Service (or just pause deployment).

---

## After SSH — open ports on the VM

```bash
# Oracle Security List is set via OCI Console (Networking -> VCNs -> Security Lists)
# Also run inside the VM:
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 5678 -j ACCEPT
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

---

## Files in this repo

```
oracle-vm-provisioner/
├── Dockerfile      — builds container with OCI CLI installed
├── provision.sh    — retry loop, reads all config from env vars
└── README.md       — this file
```

No secrets in any file. Safe to push to a public GitHub repo.
