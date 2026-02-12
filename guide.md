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
  - Direct RPC：`auth-api -> 公共 RPC`
  - Light Client：`auth-api -> helios -> 公共 RPC`
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

### 2.5 代码仓库

```bash
git clone https://github.com/kvinwang/dstack-gcp-guide.git
cd dstack-gcp-guide
```

### 2.6 域名与端口

建议准备一个域名（示例：`gcp-kms.example.com`），解析到 KMS 公网地址。

开放端口：

- `12001/tcp`：KMS HTTPS
- `18000/tcp`：auth-api（调试，可选）
- `18545/tcp`：helios（调试，可选，仅 light client）

### 2.7 "最新版本"约定

- KMS 镜像默认使用：`cr.kvin.wang/dstack-kms:latest`
- `auth-api` 依赖源码默认使用：`DSTACK_REF=master`
- `dstack-nitro-enclave-app` 使用 `main` 分支 + 仓库内已更新的 submodule 指针（无需手工切换子模块 commit）

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

> **重要**：需要先 `export` 环境变量，再通过管道传入 `y` 确认。不要将 `PRIVATE_KEY=xxx` 写在 `echo` 之前，否则管道会导致后续命令丢失环境变量。

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

### 4.3 配置授权（最小闭环）

```bash
export KMS_CONTRACT_ADDRESS="<KMS_CONTRACT_ADDR>"
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000

# 1) 允许 OS image hash（演示用 ZERO32，生产请替换为真实 hash）
npx hardhat kms:add-image --network custom "$ZERO32"
```

```
Waiting for transaction 0xf5c5...a866 to be confirmed...
Image added successfully
```

```bash
# 2) 创建应用（演示可用 allow-any-device，生产请收紧）
npx hardhat kms:create-app --network custom --allow-any-device --hash "$ZERO32"
```

```
✅ App deployed and registered successfully!
Proxy Address (App Id): 0x1342...8BA0
Owner: 0xe359...EfB5
```

```bash
# 3) 允许 compose hash
export APP_ID="<APP_ID_FROM_CREATE_APP>"
npx hardhat app:add-hash --network custom --app-id "$APP_ID" "$ZERO32"
```

```
Waiting for transaction 0xd059...fefd to be confirmed...
Compose hash added successfully
```

> 在此期间，`RPC_URL`、`PRIVATE_KEY`、`KMS_CONTRACT_ADDRESS` 环境变量需保持有效。

---

## 5. 构建并推送 dstack-kms 镜像（可选但推荐）

本仓库 `workshop/kms/builder/` 提供了一站式构建脚本，生成的镜像同时包含 **dstack-kms** 和 **helios**（用于 Section 9 的 Light Client 模式）。

源码版本已 pin 在 `build-image.sh` 中（`DSTACK_REV` / `HELIOS_REV`），可通过环境变量覆盖。

```bash
cd workshop/kms/builder

# 构建（默认使用 pinned 版本）
./build-image.sh cr.kvin.wang/dstack-kms:latest

# 推送
docker push cr.kvin.wang/dstack-kms:latest
```

> 若只需要 Direct RPC 模式（Section 6），也可使用上游
> `meta-dstack-cloud/dstack/kms/dstack-app/builder` 构建不含 helios 的精简镜像。

---

## 6. 部署 KMS（生产模式：Direct RPC）

### 6.1 准备 compose 和环境变量

将本仓库提供的 compose 模板拷贝到 `dstack-cloud new` 生成的项目目录：

```bash
# 假设当前目录为 dstack-gcp-guide，项目目录为 workshop-run/kms-prod
cp workshop/kms/docker-compose.direct.yaml workshop-run/kms-prod/docker-compose.yaml
```

> **注意**：不要将 `.env` 文件直接放在项目目录中。`dstack-cloud` 会将项目根目录的 `.env` 当作"需要 KMS 加密的密钥文件"处理，在 TPM 模式下会报错。

### 6.2 通过 prelaunch.sh 注入环境变量

编辑项目目录中的 `prelaunch.sh`，写入 docker-compose 所需的环境变量：

```bash
cat > workshop-run/kms-prod/prelaunch.sh <<'EOF'
#!/bin/sh
# Prelaunch script - write .env for docker-compose
cat > .env <<'ENVEOF'
KMS_DOMAIN=gcp-kms.example.com
KMS_HTTPS_PORT=12001
AUTH_HTTP_PORT=18000
KMS_IMAGE=cr.kvin.wang/dstack-kms:latest
ETH_RPC_URL=https://sepolia.base.org
KMS_CONTRACT_ADDR=<KMS_CONTRACT_ADDR>
DSTACK_REPO=https://github.com/Phala-Network/dstack-cloud.git
DSTACK_REF=master
ENVEOF
EOF
```

替换其中的 `<KMS_CONTRACT_ADDR>` 和 `KMS_DOMAIN` 为实际值。

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

> 是否绑定静态 IP：**非必须**。
> 如果你需要长期稳定域名，建议绑定静态公网 IP；临时测试可直接使用实例当前公网 IP。

### 6.4 验证

容器启动约需 1-2 分钟（拉取镜像 + auth-api 编译）。可通过串口日志观察进度：

```bash
dstack-cloud logs
```

看到 `Reached target Multi-User System` 表示容器已全部启动。

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

验证 KMS：

```bash
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

```json
{
  "ca_cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "allow_any_upgrade": false,
  "k256_pubkey": "02...",
  "is_dev": false,
  "kms_contract_address": "0xFaAD...4DBC",
  "chain_id": 84532,
  "app_auth_implementation": "0x43ac...A578"
}
```

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
KEY_NAME=nitro-enclave-key \
KEY_PATH=./nitro-enclave-key.pem \
./deploy_host.sh
```

> **注意**：如果 AWS 中已存在同名 Key Pair（`nitro-enclave-key`）但本地没有对应的 PEM 文件，脚本会报错退出。此时需先删除 AWS 上的旧密钥对：
> ```bash
> aws ec2 delete-key-pair --region us-east-1 --key-name nitro-enclave-key
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

脚本全部完成后会生成 `deployment.json`：

```json
{
  "instance_id": "i-0324740db36bfeb08",
  "public_ip": "18.207.xxx.xxx"
}
```

---

## 8. Nitro Enclave 拉取密钥（Direct RPC）

> 前提：本地需要 Rust 工具链（含 musl target），因为 `get_keys.sh` 会从源码编译 `dstack-util`。

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./nitro-enclave-key.pem \
./get_keys.sh
```

示例输出：

```
[local] Building dstack-util (musl)...
[local] Built .../dstack/target/x86_64-unknown-linux-musl/release/dstack-util
[local] Uploading dstack-util and get-keys scripts to host...
[remote] Starting tinyproxy and vsock proxy bridge...
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

> `cr.kvin.wang/dstack-kms:latest` 镜像已内置 helios 二进制（见 `workshop/kms/builder/`），
> helios 容器直接复用 KMS 镜像，无需额外下载或编译。

只需将 compose 文件替换为 light 模板，`prelaunch.sh` 与 Direct RPC 版本完全相同：

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

验证：

```bash
# helios RPC
curl -s -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://<KMS_DOMAIN>:18545"

# auth-api
curl -s "http://<KMS_DOMAIN>:18000/" | jq .

# kms
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

Nitro 侧验证与第 8 章相同，只需保持 `KMS_URL` 不变。

---

## 10. KMS Onboard（交互式 Bootstrap 与多节点密钥复制）

### 10.1 背景

前面第 6、9 章使用的 compose 模板中，`kms.toml` 设置了 `auto_bootstrap_domain = "${KMS_DOMAIN}"`。
这意味着 KMS 首次启动时**自动生成密钥**并跳过交互，简单直接。

但 `auto_bootstrap_domain` 有一个限制：它**不会保存 `bootstrap-info.json`**（包含 TDX attestation quote），因此 `GetMeta` 返回的 `bootstrap_info` 为 `null`。

**交互式 Onboard** 提供两个额外能力：

1. **Bootstrap**：手动触发密钥生成，返回 `ca_pubkey`、`k256_pubkey` 和 TDX `attestation`（可用于链上验证 KMS 完整性）
2. **Onboard**：从已运行的 KMS 实例复制密钥到新实例，实现多节点共享身份（高可用 / 灾备）

### 10.2 交互式 Bootstrap

使用本仓库提供的 `docker-compose.onboard.yaml`（与 direct 模板唯一区别：`auto_bootstrap_domain = ""`）：

```bash
cp workshop/kms/docker-compose.onboard.yaml workshop-run/kms-prod/docker-compose.yaml

cd workshop-run/kms-prod
dstack-cloud deploy --delete
```

部署后，KMS 在端口 12001 上启动 **HTTP**（非 HTTPS）Onboard 服务：

- 浏览器访问 `http://<KMS_DOMAIN>:12001/` 可看到交互式 UI
- 也可用 curl 直接调用 RPC

**调用 Bootstrap：**

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

**验证：**

```bash
# 等待约 10 秒重启完成，此时为 HTTPS
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .bootstrap_info
```

应返回非 `null` 的 `bootstrap_info`，包含与 Bootstrap 时相同的 `ca_pubkey`、`k256_pubkey` 和 `attestation`。

### 10.3 Onboard 从已有 KMS（多节点密钥复制）

> 此场景需要两个 GCP TDX 实例同时运行，且源 KMS 已完成 Bootstrap。

假设已有一个运行中的 KMS（源）地址为 `https://source-kms.example.com:12001`。

1. 部署第二个 KMS 实例，同样使用 `docker-compose.onboard.yaml`
2. 调用 Onboard RPC，指定源 KMS URL 和新实例域名：

```bash
curl -s "http://<NEW_KMS_DOMAIN>:12001/prpc/Onboard.Onboard?json" \
  -d '{
    "source_url": "https://source-kms.example.com:12001/prpc",
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

两者的 `k256_pubkey` 和 `ca_cert` 应完全一致。

> **注意**：Onboard 过程中，新 KMS 需要通过 RA-TLS 连接源 KMS（`quote_enabled = true`），
> 因此两个实例都必须运行在支持 TDX attestation 的 dstack 环境中。

---

## 11. 生产安全建议

1. 不要在生产长期使用 `ZERO32`。
2. 不要在生产长期使用 `--allow-any-device`。
3. 对调试端口（18000/18545）做网络收敛或关闭。
4. 私钥使用 KMS/HSM 或 CI Secret 管理，避免明文落盘。
5. 文档与对外材料建议使用占位符，避免暴露真实实例 ID、IP、钱包地址。

---

## 12. 常见问题

### 12.1 镜像拉取超时

表现：串口日志出现 `i/o timeout`。
处理：重试部署，必要时更换镜像源或网络出口。

### 12.2 `deploy --delete` 卡在停止阶段

可在云侧确认实例状态后，再执行重试。

### 12.3 端口曾可用、重建实例后不通

在新版 `dstack-cloud` 中已修复"实例重建后防火墙 tag 未自动附加"的问题。
若你使用旧版本，请升级后重试。

### 12.4 合约部署报 "no code at address"

公共 RPC 上的读取延迟导致。合约通常已成功部署，可通过 [Base Sepolia 区块浏览器](https://sepolia.basescan.org) 确认。

### 12.5 `.env` 文件与 `dstack-cloud` 冲突

`dstack-cloud` 会将项目目录中的 `.env` 当作需要加密的密钥文件（仅 `--key-provider kms` 模式支持）。在 TPM 模式下使用 `.env` 会报错：

```
.env found but KMS is not enabled. Enable KMS with --key-provider kms or remove .env
```

**解决方法**：不要在项目目录放 `.env`，改为在 `prelaunch.sh` 中生成 `.env` 文件（参见第 6.2 节）。

### 12.6 Helios 容器启动失败

- helios 已内置在 KMS 镜像中。如果启动报 `network not recognized`，说明镜像中的 helios 版本不支持当前网络，需要使用 `workshop/kms/builder/` 重新构建镜像。
- 检查 `consensus-rpc` / `execution-rpc` 端点是否可访问。

---

## 13. 资源回收

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
