# Deploy dstack-kms on GCP and Provide Keys for AWS Nitro Enclaves

> Last updated: 2026-02-12
>
> This document provides a reproducible, public workflow:
> 1) Deploy dstack-kms on a GCP TDX CVM; 2) Complete on-chain authorization; 3) Have a Nitro Enclave retrieve keys from the KMS via RA-TLS.

---

## 1. Architecture and Goals

- **KMS Runtime**: dstack OS on GCP Confidential VM (TDX)
- **Authentication**: On-chain authorization (production mode)
- **Two Connectivity Modes**:
  - Direct RPC: `kms -> auth-api -> public RPC (contract execution)`
  - Light Client: `kms -> auth-api -> helios (contract execution) -> public RPC (data sync)`
- **Caller**: AWS Nitro Enclave application

---

## 2. Prerequisites

### 2.1 Tools

The following must be installed and authenticated:

- `gcloud` (logged in via `gcloud auth login`, with permissions to create Confidential VMs)
- `aws` CLI (configured via `aws configure`)
- `docker` / `docker compose`
- `node` + `npm`
- `jq`
- Rust toolchain (`cargo`) + musl target: `rustup target add x86_64-unknown-linux-musl`

### 2.2 Install `dstack-cloud`

```bash
# Download the dstack-cloud CLI
curl -fsSL -o ~/.local/bin/dstack-cloud \
  https://raw.githubusercontent.com/Phala-Network/meta-dstack-cloud/main/scripts/bin/dstack-cloud
chmod +x ~/.local/bin/dstack-cloud
```

> Source code and latest releases: [Phala-Network/meta-dstack-cloud](https://github.com/Phala-Network/meta-dstack-cloud/blob/main/scripts/bin/dstack-cloud)

### 2.3 Configure `dstack-cloud`

```bash
dstack-cloud config-edit
```

Edit `~/.config/dstack-cloud/config.json` and fill in the following fields:

```jsonc
{
  // Local search paths for OS images
  "image_search_paths": [
    "/path/to/your/images"
  ],
  "gcp": {
    "project": "your-gcp-project",       // GCP Project ID
    "zone": "us-central1-a",             // Availability zone
    "bucket": "gs://your-bucket-dstack"  // GCS Bucket (for storing deployment images)
  }
}
```

### 2.4 Download the dstack OS Image

```bash
# Download and extract
dstack-cloud pull https://github.com/Phala-Network/meta-dstack-cloud/releases/download/v0.6.0-test/dstack-cloud-0.6.0.tar.gz
```

> This is currently a test release (v0.6.0-test); reproducible build scripts are not yet available.

### 2.5 Clone This Guide's Repository

```bash
git clone https://github.com/Phala-Network/dstack-cloud-deployment-guide.git
cd dstack-cloud-deployment-guide
```

### 2.6 Domain and Ports

It is recommended to prepare a domain name (e.g., `test-kms.kvin.wang`) pointing to the KMS GCP instance's public IP.

Open ports:

- `12001/tcp`: KMS API
- `18000/tcp`: internal auth-api (debugging, optional)
- `18545/tcp`: internal helios eth RPC (debugging, optional, light client only)

---

## 3. Create GCP KMS Project (TPM Mode)

```bash
# Create a dstack-cloud project in your working directory
# (stay in the dstack-cloud-deployment-guide root — later sections reference paths relative to it)
mkdir -p workshop-run

dstack-cloud new workshop-run/kms-prod \
  --os-image dstack-cloud-0.6.0 \
  --key-provider tpm \
  --instance-name dstack-kms
```

Example output:

```
Initialized project in /path/to/workshop-run/kms-prod

Created files:
  app.json - Application configuration (with embedded GCP config)
  shared/ - System-generated files
  docker-compose.yaml - Docker compose file
  prelaunch.sh - Prelaunch script
  .user-config - User configuration

Created new project: kms-prod
Project directory: /path/to/workshop-run/kms-prod
```

Key files in the generated project:
- `app.json`: Project configuration (OS image, key provider, instance name, etc.)
- `docker-compose.yaml`: Container orchestration (will be replaced in subsequent steps)
- `prelaunch.sh`: Script executed before containers start

---

## 4. On-Chain Deployment and Authorization (Base Sepolia Example)

> Note: Production mode requires completing contract deployment and authorization configuration first.

### 4.1 Fund the Wallet

Prepare a test wallet and ensure it has sufficient balance (approximately 0.003 ETH on Base Sepolia is enough for the deployment steps).

### 4.2 Deploy the KMS Contract

```bash
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app/dstack/kms/auth-eth

npm ci
npx hardhat compile
```

Compilation output:

```
Generating typings for: 19 artifacts in dir: typechain-types for target: ethers-v6
Successfully generated 72 typings!
Compiled 19 Solidity files successfully (evm target: paris).
```

Deploy the contract:

```bash
export RPC_URL="https://sepolia.base.org"
export PRIVATE_KEY="<YOUR_PRIVATE_KEY>"

echo "y" | npx hardhat kms:deploy --with-app-impl --network custom
```

Example output:

```
Deploying with account: 0xe359...EfB5
Account balance: 0.002689232335867312
Step 1: Deploying DstackApp implementation...
✅ DstackApp implementation deployed to: 0x43ac...A578
Step 2: Deploying DstackKms...
DstackKms Proxy deployed to: 0xFaAD...4DBC
```

Record from the output:

- `DstackKms Proxy` (used later as `KMS_CONTRACT_ADDR`)

> **Known issue**: When deploying on a public RPC, the script may report a `Contract deployment failed - no code at address` error.
> This is typically a race condition caused by RPC read latency — the contract has actually been deployed successfully.
> The `DstackKms Proxy deployed to:` line still appears in the output before the error — record that address.
> You can verify the contract was deployed by checking for code at the address:
> ```bash
> cast code <KMS_CONTRACT_ADDR> --rpc-url https://sepolia.base.org
> # Should return bytecode (not "0x") if deployment succeeded
> ```
> Alternatively, confirm via a block explorer such as https://sepolia.basescan.org.

### 4.3 Create an Application

```bash
export KMS_CONTRACT_ADDRESS="<KMS_CONTRACT_ADDR>"

# Create app (allow-any-device is fine for demos; tighten for production)
npx hardhat kms:create-app --network custom --allow-any-device
```

```
✅ App deployed and registered successfully!
Proxy Address (App Id): 0x1342...8BA0
Owner: 0xe359...EfB5
```

```bash
export APP_ID="<APP_ID_FROM_CREATE_APP>"
```

> The `RPC_URL`, `PRIVATE_KEY`, and `KMS_CONTRACT_ADDRESS` environment variables must remain set throughout this process.

---

## 5. Build and Push the dstack-kms Image (Optional)

The `workshop/kms/builder/` directory in this repository provides a one-step build script that produces an image containing both **dstack-kms** and **helios** (for the Light Client mode in Section 9).

Source versions are pinned in `build-image.sh` (`DSTACK_REV` / `HELIOS_REV`) and can be overridden via environment variables.

```bash
cd workshop/kms/builder

# Build (uses pinned versions by default)
# Replace cr.kvin.wang with your own registry if needed
./build-image.sh cr.kvin.wang/dstack-kms:latest

# Push
docker push cr.kvin.wang/dstack-kms:latest
```

---

## 6. Deploy KMS (Production Mode: Direct RPC)

### 6.1 Prepare Compose and Environment Variables

Copy the compose template from this repository to the project directory generated by `dstack-cloud new`:

```bash
# Assuming current directory is dstack-cloud-deployment-guide and project is at workshop-run/kms-prod
cp workshop/kms/docker-compose.direct.yaml workshop-run/kms-prod/docker-compose.yaml
```

### 6.2 Inject Environment Variables via prelaunch.sh

Edit `prelaunch.sh` in the project directory to write the environment variables needed by docker-compose:

```bash
cat > workshop-run/kms-prod/prelaunch.sh <<'EOF'
#!/bin/sh
# Prelaunch script - write .env for docker-compose
cat > .env <<'ENVEOF'
KMS_HTTPS_PORT=12001
AUTH_HTTP_PORT=18000
KMS_IMAGE=cr.kvin.wang/dstack-kms:latest
ETH_RPC_URL=https://sepolia.base.org
KMS_CONTRACT_ADDR=<KMS_CONTRACT_ADDR>
DSTACK_REPO=https://github.com/Phala-Network/dstack-cloud.git
DSTACK_REF=14963a2ccb0ec7bef8a496c1ac5ac40f5593145d
ENVEOF
EOF
```

Replace `<KMS_CONTRACT_ADDR>` with the actual value.

### 6.3 Deploy

```bash
cd workshop-run/kms-prod
dstack-cloud deploy --delete
```

Example output:

```
=== GCP TDX VM Deployment ===
Project: your-project
Zone: us-central1-a
Instance: dstack-kms
...
=== Deployment Complete ===
Instance: dstack-kms
External IP: 35.188.xxx.xxx
```

```bash
# Open ports
dstack-cloud fw allow 12001
dstack-cloud fw allow 18000
```

After deployment, point your domain DNS to the External IP shown in the output.

### 6.4 Bootstrap (Interactive Initialization)

Container startup takes approximately 1-2 minutes (image pull + auth-api compilation). You can monitor progress via serial port logs:

```bash
dstack-cloud logs
```

On first boot, the KMS starts an **HTTP** (not HTTPS) Onboard service on port 12001. Opening `http://<KMS_DOMAIN>:12001/` in a browser shows an interactive UI that automatically displays **Attestation Info** (device_id, mr_aggregated, os_image_hash) — these are the real values needed for on-chain registration.

**Call Bootstrap to generate keys:**

```bash
curl -s "http://<KMS_DOMAIN>:12001/prpc/Onboard.Bootstrap?json" \
  -d '{"domain": "<KMS_DOMAIN>"}' | jq .
```

```json
{
  "ca_pubkey": "3059301306072a8648ce3d0201...",
  "k256_pubkey": "03548465f50fca3aec29ec1569...",
  "attestation": "0001017d040002008100..."
}
```

> `attestation` is the TDX quote (because `quote_enabled = true`), containing the key fingerprint. It can be verified on-chain or off-chain to confirm the KMS is running in a trusted environment.

**Complete initialization:**

```bash
curl "http://<KMS_DOMAIN>:12001/finish"
# Returns "OK"
```

`/finish` causes the Onboard service to exit(0), and docker-compose's `restart: unless-stopped` automatically restarts the container.
At this point, keys are written to the persistent volume. The KMS detects existing keys, skips Onboard, and starts the main service directly over **HTTPS**.

### 6.5 Verify

Verify auth-api:

```bash
curl -s "http://<KMS_DOMAIN>:18000/" | jq .
```

```json
{
  "status": "ok",
  "kmsContractAddr": "0xFaAD...4DBC",
  "gatewayAppId": "",
  "chainId": 84532,
  "appAuthImplementation": "0x43ac...A578",
  "appImplementation": "0x43ac...A578"
}
```

Verify KMS (note: HTTPS at this point):

```bash
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

```json
{
  "ca_cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "allow_any_upgrade": false,
  "k256_pubkey": "02...",
  "bootstrap_info": {
    "ca_pubkey": "3059...",
    "k256_pubkey": "03...",
    "attestation": "0001..."
  },
  "is_dev": false,
  "kms_contract_address": "0xFaAD...4DBC",
  "chain_id": 84532,
  "app_auth_implementation": "0x43ac...A578"
}
```

> `bootstrap_info` contains the `ca_pubkey`, `k256_pubkey`, and TDX `attestation` returned during Bootstrap.

---

## 7. Nitro Host Deployment Example (AWS)

### 7.1 Deploy EC2 Instance

```bash
# If not already cloned (skip if done in step 4)
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app

# Override variables as needed: REGION / INSTANCE_TYPE / KEY_NAME / KEY_PATH, etc.
REGION=us-east-1 \
INSTANCE_TYPE=c5.xlarge \
KEY_NAME=dstack-nitro-enclave-key \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./deploy_host.sh
```

> **Note**: If a Key Pair with the same name (`dstack-nitro-enclave-key`) already exists in AWS but you don't have the corresponding local PEM file, the script will fail. Delete the old key pair first:
> ```bash
> aws ec2 delete-key-pair --region us-east-1 --key-name dstack-nitro-enclave-key
> ```

### 7.2 Known Issue: Enclave CPU Allocator Startup Failure

If you see `Insufficient CPUs available in the pool` (E22), first check for leftover enclaves occupying CPUs:

```bash
# Check for leftover enclaves (common when running multiple times on the same instance)
nitro-cli describe-enclaves

# If the output shows RUNNING enclaves, terminate them first
nitro-cli terminate-enclave --all
```

If the issue persists after terminating leftover enclaves, manually configure the allocator:

```bash
# Check available CPUs on this instance (enclave can use at most nproc - 1)
nproc

# Run on the EC2 instance (cpu_count must be less than nproc output)
sudo bash -c 'cat > /etc/nitro_enclaves/allocator.yaml <<YAML
---
memory_mib: 512
cpu_count: 2
YAML'

# Free memory fragments and restart
sudo bash -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
sudo systemctl restart nitro-enclaves-allocator.service
```

After `./deploy_host.sh` completes, it generates `deployment.json`:

```json
{
  "instance_id": "i-0324740db36bfeb08",
  "public_ip": "18.207.xxx.xxx"
}
```

---

## 8. Nitro Enclave Key Retrieval (Direct RPC)

> Prerequisite: A local Rust toolchain (with musl target) is required, as `get_keys.sh` compiles `dstack-util` from source.

### 8.1 Register Enclave OS Image Hash

`get_keys.sh --show-mrs` builds the EIF image on the EC2 host, computes `sha256(pcr0 || pcr1 || pcr2)`, and prints the `OS_IMAGE_HASH` directly:

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./get_keys.sh --show-mrs
```

Example output:

```
PCR0: 1415501c7caeba0a7aea20f...
PCR1: 4b4d5b3661b3efc1292090...
PCR2: 33ae855210ea2ce171925831...
OS_IMAGE_HASH: 0x1078395c3151831924c255f7b7dec87b3f6bb3bf9db98fe17d43abfbe506407d
```

Register on-chain (run in the `dstack-nitro-enclave-app/dstack/kms/auth-eth` directory):

```bash
# Register OS image hash in the KMS contract
npx hardhat kms:add-image ${OS_IMAGE_HASH} --network custom

# Register compose hash in the APP contract (hash value is the same as OS image hash)
npx hardhat app:add-hash --app-id ${APP_ID} ${OS_IMAGE_HASH} --network custom
```

> **Important**: Both `KMS_URL` and `APP_ID` are baked into the EIF image (via `enclave_run_get_keys.sh`). They affect PCR values and therefore `OS_IMAGE_HASH`. The values used for `--show-mrs` **must be identical** to those used in the actual key retrieval run (Section 8.2). If either value differs, the PCR measurements will not match the registered hash, causing a "Boot denied: OS image is not allowed" error.

### 8.2 Retrieve Keys

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./get_keys.sh
```

Example output:

```
[local] Building dstack-util (musl)...
[local] Built .../dstack/target/x86_64-unknown-linux-musl/release/dstack-util
[local] Uploading dstack-util and get-keys scripts to host...
[remote] Starting forward proxy (squid) and vsock proxy bridge...
...
[enclave] run dstack-util get-keys
[enclave] dstack-util exit=0
[enclave] keys-bytes=2325
[enclave] sending keys to host vsock:9999
...
Saved app keys to .../app_keys.json (size: 2325 bytes)
Saved enclave console log to .../enclave_console.log
```

On success, the following files are generated locally:

- `app_keys.json` — contains `ca_cert`, `disk_crypt_key`, `env_crypt_key`, `k256_key`, etc.

```bash
# Verify app_keys.json structure
jq 'keys' app_keys.json
```

```json
["ca_cert", "disk_crypt_key", "env_crypt_key", "gateway_app_id", "k256_key", "k256_signature", "key_provider"]
```

- `enclave_console.log` — enclave kernel boot log (only generated when `DEBUG_ENCLAVE=1` is set; absent by default)
- `ncat_keys.log`

---

## 9. Deploy KMS (Production Mode: Light Client / Helios)

> The `cr.kvin.wang/dstack-kms:latest` image already includes the helios binary (see `workshop/kms/builder/`).

Simply replace the compose file with the light template. The `prelaunch.sh` is the same as the Direct RPC version — `ETH_RPC_URL` in the `.env` file is ignored because the light compose template hardcodes `ETH_RPC_URL=http://helios:8545` for auth-api:

```bash
# Use the light template from this repository
cp workshop/kms/docker-compose.light.yaml workshop-run/kms-prod/docker-compose.yaml
```

> To build a KMS image with helios yourself, see `workshop/kms/builder/README.md`.

```bash
cd workshop-run/kms-prod
dstack-cloud deploy --delete

# Ports: KMS + auth-api + helios (debugging)
dstack-cloud fw allow 12001
dstack-cloud fw allow 18000
dstack-cloud fw allow 18545
```

The Bootstrap process is the same as Section 6.4: wait for the containers to start, then call `Onboard.Bootstrap` + `/finish`.

Verify:

```bash
# helios RPC
curl -s -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://<KMS_DOMAIN>:18545"

# auth-api
curl -s "http://<KMS_DOMAIN>:18000/" | jq .

# KMS (HTTPS, after Bootstrap)
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

Nitro-side verification is the same as Chapter 8 — just keep the same `KMS_URL`.

---

## 10. KMS Onboard (Multi-Node Key Replication)

> This scenario requires two GCP TDX instances running simultaneously, with the source KMS having completed Bootstrap (Section 6.4).

Onboard allows a new KMS instance to replicate keys from a running source KMS, enabling multi-node shared identity (high availability / disaster recovery).

### 10.1 On-Chain Authorization

During Onboard, the new KMS requests keys from the source KMS via RA-TLS. The source KMS's auth-api verifies the new KMS's TDX attestation quote and calls the on-chain contract's `isKmsAllowed()` to check:

- **OS image hash**: Must be registered via `npx hardhat kms:add-image`
- **Aggregated MR**: Must be registered via `npx hardhat kms:add`
- **Device ID**: Must be registered via `npx hardhat kms:add-device`

> **Note**: `isKmsAllowed()` performs exact matching on each field — there are no wildcards. Real values must be registered.

### 10.2 Obtain Real Attestation Values

While the new KMS is in Onboard mode (HTTP), open `http://<NEW_KMS_DOMAIN>:12001/` to see the Attestation Info, or retrieve it via RPC:

```bash
curl -s "http://<NEW_KMS_DOMAIN>:12001/prpc/Onboard.GetAttestationInfo?json" | jq .
```

```json
{
  "device_id": "7c05db197ea451c8...",
  "mr_aggregated": "77eea120a230044f...",
  "os_image_hash": "182e89740db72378...",
  "attestation_mode": "dstack-gcp-tdx"
}
```

> **Important**: The `device_id` shown in serial port logs (`dstack-util show`) is a dummy value `e3b0c442...` (`SHA256("")`) and cannot be used for on-chain registration. You must obtain the real values from the `GetAttestationInfo` RPC or the Web UI.

Register the real values for on-chain authorization:

```bash
# Register KMS-specific on-chain authorizations (run in the auth-eth directory)
npx hardhat kms:add-image 0x<OS_IMAGE_HASH> --network custom
npx hardhat kms:add 0x<MR_AGGREGATED> --network custom
npx hardhat kms:add-device 0x<DEVICE_ID> --network custom
```

### 10.3 Execute Onboard

Assume a running KMS (source) is available at `https://source-kms.example.com:12001`.

1. Deploy a second KMS instance (using `docker-compose.direct.yaml` or `docker-compose.light.yaml`, both use interactive Bootstrap)
2. Instead of calling Bootstrap, call the Onboard RPC, specifying the source KMS URL and the new instance's domain:

```bash
curl -s "http://<NEW_KMS_DOMAIN>:12001/prpc/Onboard.Onboard?json" \
  -d '{
    "source_url": "https://source-kms.example.com:12001",
    "domain": "<NEW_KMS_DOMAIN>"
  }' | jq .
```

```json
{}
```

> An empty object `{}` indicates success. The new KMS has obtained `ca_key`, `k256_key`, and `tmp_ca_key` from the source KMS, and has generated its own RPC certificate.

3. Complete initialization:

```bash
curl "http://<NEW_KMS_DOMAIN>:12001/finish"
```

4. Verify both KMS instances share the same identity:

```bash
# Source KMS
curl -sk "https://source-kms.example.com:12001/prpc/GetMeta?json" -d '{}' | jq .k256_pubkey

# New KMS
curl -sk "https://<NEW_KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .k256_pubkey
```

Both should return the same `k256_pubkey` (shared identity). Different `ca_cert` values are expected — each instance generates its own RPC certificate.

> **Notes**:
> - During Onboard, the new KMS connects to the source KMS via RA-TLS (`quote_enabled = true`). Both instances must run in a dstack environment that supports TDX attestation.
> - After a successful Onboard, the new KMS's `bootstrap_info` is `null` (only the source KMS retains the attestation from Bootstrap).


---


## 11. Resource Cleanup

```bash
# GCP
cd workshop-run/kms-prod
dstack-cloud stop
# Or remove completely
dstack-cloud remove
```

```
Deleting instance dstack-kms...
Deleting shared disk image dstack-kms-shared...
Instance removed.
```

```bash
# AWS
aws ec2 terminate-instances \
  --instance-ids <INSTANCE_ID> \
  --region <REGION>
```

```json
{
  "TerminatingInstances": [{
    "InstanceId": "i-0324...",
    "CurrentState": { "Name": "shutting-down" },
    "PreviousState": { "Name": "running" }
  }]
}
```

> Don't forget to clean up DNS records and AWS Key Pairs (if no longer needed).
