# 在 GCP 部署 dstack-kms，并为 AWS Nitro Enclave 提供密钥

> 更新日期：2026-02-12
>
> 本文提供一条可复现的公开流程：
> 1) 在 GCP TDX CVM 部署 dstack-kms；2) 完成链上授权；3) 由 Nitro Enclave 通过 RA-TLS 调用 KMS 获取密钥。

---

## 1. 架构与目标

- **KMS 运行环境**：GCP Confidential VM (TDX) 上的 dstack OS
- **认证方式**：链上授权（生产模式）
- **两种链路**：
  - Direct RPC：`kms -> auth-api -> 公共 RPC（合约调用）`
  - Light Client：`kms -> auth-api -> helios（合约调用） -> 公共 RPC（数据同步）`
- **调用方**：AWS Nitro Enclave 应用

---

## 2. 前置条件

### 2.1 工具

已安装并登录：

- `gcloud`（已通过 `gcloud auth login` 登录，有创建 Confidential VM 的权限）
- `aws` CLI（已通过 `aws configure` 配置）
- `docker` / `docker compose`
- `node` + `npm`
- `jq`
- Rust 工具链（`cargo`）+ musl target：`rustup target add x86_64-unknown-linux-musl`

### 2.2 安装 `dstack-cloud`

```bash
# 下载 dstack-cloud CLI
curl -fsSL -o ~/.local/bin/dstack-cloud \
  https://raw.githubusercontent.com/Phala-Network/meta-dstack-cloud/main/scripts/bin/dstack-cloud
chmod +x ~/.local/bin/dstack-cloud
```

> 源码与最新版本参见 [Phala-Network/meta-dstack-cloud](https://github.com/Phala-Network/meta-dstack-cloud/blob/main/scripts/bin/dstack-cloud)

### 2.3 配置 `dstack-cloud`

```bash
dstack-cloud config-edit
```

编辑 `~/.config/dstack-cloud/config.json`，确保以下字段已填写：

```jsonc
{
  // OS 镜像本地搜索路径
  "image_search_paths": [
    "/path/to/your/images"
  ],
  "gcp": {
    "project": "your-gcp-project",       // GCP 项目 ID
    "zone": "us-central1-a",             // 可用区
    "bucket": "gs://your-bucket-dstack"  // GCS Bucket（用于存储部署镜像）
  }
}
```

### 2.4 下载 dstack OS 镜像

```bash
# 下载并解压
dstack-cloud pull https://github.com/Phala-Network/meta-dstack-cloud/releases/download/v0.6.0-test/dstack-cloud-0.6.0.tar.gz
```

> 当前为测试版本（v0.6.0-test），尚未提供 reproducible build 脚本。

### 2.5 clone本教程代码仓库

```bash
git clone https://github.com/kvinwang/dstack-gcp-guide.git
cd dstack-gcp-guide
```

### 2.6 域名与端口

建议准备一个域名（示例：`test-kms.kvin.wang`），解析到 KMS GCP instance公网地址。

开放端口：

- `12001/tcp`：KMS API
- `18000/tcp`：internal auth-api（调试，可选）
- `18545/tcp`：internal helios eth RPC（调试，可选，仅 light client）

---

## 3. 创建 GCP KMS 项目（TPM 模式）

```bash
# 在你的工作目录中创建 dstack-cloud 项目
mkdir -p workshop-run && cd workshop-run

dstack-cloud new kms-prod \
  --os-image dstack-cloud-0.6.0 \
  --key-provider tpm \
  --instance-name dstack-kms
```

示例输出：

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

生成的项目包含以下关键文件：
- `app.json`：项目配置（OS 镜像、key provider、实例名等）
- `docker-compose.yaml`：容器编排（将在后续步骤中替换）
- `prelaunch.sh`：在容器启动前执行的脚本

---

## 4. 链上部署与授权（Base Sepolia 示例）

> 说明：生产模式必须先完成合约部署和授权配置。

### 4.1 准备链上资金

准备一个测试钱包并确保钱包有足够余额（Base Sepolia需要约 0.003 ETH 即可完成部署步骤）。

### 4.2 部署 KMS 合约

```bash
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app/dstack/kms/auth-eth

npm ci
npx hardhat compile
```

编译输出：

```
Generating typings for: 19 artifacts in dir: typechain-types for target: ethers-v6
Successfully generated 72 typings!
Compiled 19 Solidity files successfully (evm target: paris).
```

部署合约：

```bash
export RPC_URL="https://sepolia.base.org"
export PRIVATE_KEY="<YOUR_PRIVATE_KEY>"

echo "y" | npx hardhat kms:deploy --with-app-impl --network custom
```

示例输出：

```
Deploying with account: 0xe359...EfB5
Account balance: 0.002689232335867312
Step 1: Deploying DstackApp implementation...
✅ DstackApp implementation deployed to: 0x43ac...A578
Step 2: Deploying DstackKms...
DstackKms Proxy deployed to: 0xFaAD...4DBC
```

记录输出中的：

- `DstackKms Proxy`（后续作为 `KMS_CONTRACT_ADDR`）

> **已知问题**：在公共 RPC 上部署时，脚本可能报 `Contract deployment failed - no code at address` 错误。
> 这通常是 RPC 读取延迟导致的竞态条件，合约实际已成功部署。可通过区块浏览器确认合约地址是否有代码。

### 4.3 创建应用

```bash
export KMS_CONTRACT_ADDRESS="<KMS_CONTRACT_ADDR>"

# 创建应用（演示可用 allow-any-device，生产请收紧）
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

> 在此期间，`RPC_URL`、`PRIVATE_KEY`、`KMS_CONTRACT_ADDRESS` 环境变量需保持有效。

---

## 5. 构建并推送 dstack-kms 镜像（可选）

本仓库 `workshop/kms/builder/` 提供了一站式构建脚本，生成的镜像同时包含 **dstack-kms** 和 **helios**（用于 Section 9 的 Light Client 模式）。

源码版本已 pin 在 `build-image.sh` 中（`DSTACK_REV` / `HELIOS_REV`），可通过环境变量覆盖。

```bash
cd workshop/kms/builder

# 构建（默认使用 pinned 版本）
# cr.kvin.wang 可替换为其他镜像仓库
./build-image.sh cr.kvin.wang/dstack-kms:latest

# 推送
docker push cr.kvin.wang/dstack-kms:latest
```

---

## 6. 部署 KMS（生产模式：Direct RPC）

### 6.1 准备 compose 和环境变量

将本仓库提供的 compose 模板拷贝到 `dstack-cloud new` 生成的项目目录：

```bash
# 假设当前目录为 dstack-gcp-guide，项目目录为 workshop-run/kms-prod
cp workshop/kms/docker-compose.direct.yaml workshop-run/kms-prod/docker-compose.yaml
```

### 6.2 通过 prelaunch.sh 注入环境变量

编辑项目目录中的 `prelaunch.sh`，写入 docker-compose 所需的环境变量：

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
DSTACK_REF=6054b84d54c943ff76c975fde8fa478dfc09968c
ENVEOF
EOF
```

替换其中的 `<KMS_CONTRACT_ADDR>` 为实际值。

### 6.3 部署

```bash
cd workshop-run/kms-prod
dstack-cloud deploy --delete
```

示例输出：

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
# 开放端口
dstack-cloud fw allow 12001
dstack-cloud fw allow 18000
```

部署完成后将域名解析到输出中的 External IP。

### 6.4 Bootstrap（交互式初始化）

容器启动约需 1-2 分钟（拉取镜像 + auth-api 编译）。可通过串口日志观察进度：

```bash
dstack-cloud logs
```

首次启动时，KMS 在端口 12001 上启动 **HTTP**（非 HTTPS）Onboard 服务。浏览器访问 `http://<KMS_DOMAIN>:12001/` 可看到交互式 UI，页面会自动显示 **Attestation Info**（device_id、mr_aggregated、os_image_hash），这些是链上注册所需的真实值。

**调用 Bootstrap 生成密钥：**

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

> `attestation` 是 TDX quote（因 `quote_enabled = true`），包含密钥指纹，可在链上或链下验证 KMS 运行在可信环境中。

**完成初始化：**

```bash
curl "http://<KMS_DOMAIN>:12001/finish"
# 返回 "OK"
```

`/finish` 使 Onboard 服务 exit(0)，docker-compose `restart: unless-stopped` 自动重启容器。
此时密钥已写入持久卷，KMS 检测到密钥存在，跳过 Onboard，直接以 **HTTPS** 启动主服务。

### 6.5 验证

验证 auth-api：

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

验证 KMS（注意此时为 HTTPS）：

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

> `bootstrap_info` 包含 Bootstrap 时返回的 `ca_pubkey`、`k256_pubkey` 和 TDX `attestation`。

---

## 7. Nitro Host 部署示例（AWS）

### 7.1 部署 EC2 实例

```bash
# 如果尚未 clone（第 4 步已 clone 则跳过）
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app

# 可按需覆盖变量：REGION / INSTANCE_TYPE / KEY_NAME / KEY_PATH 等
REGION=us-east-1 \
INSTANCE_TYPE=c5.xlarge \
KEY_NAME=dstack-nitro-enclave-key \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./deploy_host.sh
```

> **注意**：如果 AWS 中已存在同名 Key Pair（`dstack-nitro-enclave-key`）但本地没有对应的 PEM 文件，脚本会报错退出。此时需先删除 AWS 上的旧密钥对：
> ```bash
> aws ec2 delete-key-pair --region us-east-1 --key-name dstack-nitro-enclave-key
> ```

### 7.2 已知问题：Enclave CPU 分配器启动失败

若看到 `Insufficient CPUs available in the pool` (E22)，先检查是否有残留的 enclave 占用 CPU：

```bash
# 检查是否有残留 enclave（同一实例多次运行时常见）
nitro-cli describe-enclaves

# 如果输出中有 RUNNING 状态的 enclave，先终止它们
nitro-cli terminate-enclave --all
```

若终止残留 enclave 后问题仍存在，手动配置分配器：

```bash
# 查看当前实例可用 CPU 数（enclave 最多用 nproc - 1）
nproc

# 在 EC2 实例上执行（cpu_count 必须小于 nproc 输出值）
sudo bash -c 'cat > /etc/nitro_enclaves/allocator.yaml <<YAML
---
memory_mib: 512
cpu_count: 2
YAML'

# 释放内存碎片后重启
sudo bash -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
sudo systemctl restart nitro-enclaves-allocator.service
```

`./deploy_host.sh`脚本全部完成后会生成 `deployment.json`：

```json
{
  "instance_id": "i-0324740db36bfeb08",
  "public_ip": "18.207.xxx.xxx"
}
```

---

## 8. Nitro Enclave 拉取密钥（Direct RPC）

> 前提：本地需要 Rust 工具链（含 musl target），因为 `get_keys.sh` 会从源码编译 `dstack-util`。

### 8.1 注册 Enclave OS Image Hash

`get_keys.sh` 会先构建 EIF 镜像，输出中可以看到 PCR 值。**首次运行前**，需要先跑一遍获取 PCR，然后计算 `sha256(pcr0 || pcr1 || pcr2)` 并注册到链上。

> 也可以先单独构建 EIF 来获取 PCR（无需 EC2）：在 `get-keys/` 目录下执行 `docker build`，然后 `nitro-cli build-enclave`。但最简单的方式是先跑一次 `get_keys.sh`，从输出中提取 PCR 值。

计算 OS image hash：

```bash
# 将 EIF 构建输出中的 PCR0/PCR1/PCR2 替换到下方
PCR0="<PCR0_HEX>"
PCR1="<PCR1_HEX>"
PCR2="<PCR2_HEX>"

OS_IMAGE_HASH=$(echo -n "${PCR0}${PCR1}${PCR2}" | xxd -r -p | sha256sum | awk '{print "0x"$1}')
echo "OS_IMAGE_HASH=${OS_IMAGE_HASH}"
```

注册到链上（在 `dstack-nitro-enclave-app/dstack/kms/auth-eth` 目录下执行）：

```bash
# 注册 OS image hash 到 KMS 合约
npx hardhat kms:add-image ${OS_IMAGE_HASH} --network custom

# 注册 compose hash 到 APP 合约（hash 值与 OS image hash 相同）
npx hardhat app:add-hash --app-id ${APP_ID} ${OS_IMAGE_HASH} --network custom
```

> **注意**：`APP_ID` 会被烘焙进 EIF 镜像（通过 `enclave_run_get_keys.sh`）。不同的 `APP_ID` 会产生不同的 `PCR2`，因此需要重新计算和注册。

### 8.2 拉取密钥

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./get_keys.sh
```

示例输出：

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

成功后本地会生成：

- `app_keys.json` — 包含 `ca_cert`、`disk_crypt_key`、`env_crypt_key`、`k256_key` 等

```bash
# 验证 app_keys.json 结构
jq 'keys' app_keys.json
```

```json
["ca_cert", "disk_crypt_key", "env_crypt_key", "gateway_app_id", "k256_key", "k256_signature", "key_provider"]
```

- `enclave_console.log` — enclave 内核启动日志
- `ncat_keys.log`

---

## 9. 部署 KMS（生产模式：Light Client / Helios）

> `cr.kvin.wang/dstack-kms:latest` 镜像已内置 helios 二进制（见 `workshop/kms/builder/`）。

只需将 compose 文件替换为 light 模板。`prelaunch.sh` 与 Direct RPC 版本相同（无需 `ETH_RPC_URL`，因为 auth-api 使用 helios 本地 RPC）：

```bash
# 使用本仓库 light 模板
cp workshop/kms/docker-compose.light.yaml workshop-run/kms-prod/docker-compose.yaml
```

> 如需自行构建包含 helios 的 KMS 镜像，参见 `workshop/kms/builder/README.md`。

```bash
cd workshop-run/kms-prod
dstack-cloud deploy --delete

# 端口：KMS + auth-api + helios(调试)
dstack-cloud fw allow 12001
dstack-cloud fw allow 18000
dstack-cloud fw allow 18545
```

Bootstrap 流程与第 6.4 节相同：等待容器启动后，调用 `Onboard.Bootstrap` + `/finish`。

验证：

```bash
# helios RPC
curl -s -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://<KMS_DOMAIN>:18545"

# auth-api
curl -s "http://<KMS_DOMAIN>:18000/" | jq .

# kms（HTTPS，Bootstrap 完成后）
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

Nitro 侧验证与第 8 章相同，只需保持 `KMS_URL` 不变。

---

## 10. KMS Onboard（多节点密钥复制）

> 此场景需要两个 GCP TDX 实例同时运行，且源 KMS 已完成 Bootstrap（第 6.4 节）。

Onboard 允许新 KMS 实例从已运行的源 KMS 复制密钥，实现多节点共享身份（高可用 / 灾备）。

### 10.1 链上授权

Onboard 过程中，新 KMS 通过 RA-TLS 向源 KMS 请求密钥。源 KMS 的 auth-api 会验证新 KMS 的 TDX attestation quote，并调用链上合约的 `isKmsAllowed()` 检查：

- **OS image hash**：需通过 `npx hardhat kms:add-image` 注册
- **Aggregated MR**：需通过 `npx hardhat kms:add` 注册
- **Device ID**：需通过 `npx hardhat kms:add-device` 注册

> **注意**：`isKmsAllowed()` 对每个字段做精确匹配，不存在通配符。必须注册真实值。

### 10.2 获取真实的 Attestation 值

在新 KMS 处于 Onboard 模式（HTTP）时，打开 `http://<NEW_KMS_DOMAIN>:12001/` 页面即可看到 Attestation Info，或者用 RPC 获取：

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

> **重要**：串口日志（`dstack-util show`）中显示的 `device_id` 是假值 `e3b0c442...`（`SHA256("")`），不能用于链上注册。必须从 `GetAttestationInfo` RPC 或 Web UI 获取真实值。

用获取到的真实值注册链上授权：

```bash
# 注册 KMS 专用的链上授权（在 auth-eth 目录下执行）
npx hardhat kms:add-image 0x<OS_IMAGE_HASH> --network custom
npx hardhat kms:add 0x<MR_AGGREGATED> --network custom
npx hardhat kms:add-device 0x<DEVICE_ID> --network custom
```

### 10.3 执行 Onboard

假设已有一个运行中的 KMS（源）地址为 `https://source-kms.example.com:12001`。

1. 部署第二个 KMS 实例（使用 `docker-compose.direct.yaml` 或 `docker-compose.light.yaml`，两者均使用交互式 Bootstrap）
2. 不要调用 Bootstrap，而是调用 Onboard RPC，指定源 KMS URL 和新实例域名：

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

> 空对象 `{}` 表示成功。新 KMS 已从源 KMS 获取 `ca_key`、`k256_key`、`tmp_ca_key`，并生成了自己的 RPC 证书。

3. 完成初始化：

```bash
curl "http://<NEW_KMS_DOMAIN>:12001/finish"
```

4. 验证两个 KMS 共享相同身份：

```bash
# 源 KMS
curl -sk "https://source-kms.example.com:12001/prpc/GetMeta?json" -d '{}' | jq .k256_pubkey

# 新 KMS
curl -sk "https://<NEW_KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .k256_pubkey
```

两者的 `k256_pubkey` 应完全一致（共享同一身份）。`ca_cert` 不同是正常的——每个实例生成自己的 RPC 证书。

> **注意**：
> - Onboard 过程中，新 KMS 通过 RA-TLS 连接源 KMS（`quote_enabled = true`），两个实例都必须运行在支持 TDX attestation 的 dstack 环境中。
> - Onboard 成功后，新 KMS 的 `bootstrap_info` 为 `null`（仅源 KMS 保留 Bootstrap 时的 attestation）。


---


## 12. 资源回收

```bash
# GCP
cd workshop-run/kms-prod
dstack-cloud stop
# 或彻底删除
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

> 别忘了清理 DNS 记录和 AWS Key Pair（如不再使用）。
