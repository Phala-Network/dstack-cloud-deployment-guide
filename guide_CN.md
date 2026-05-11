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
# 下载并解压（注意：必须使用 -uki.tar.gz 版本）
dstack-cloud pull https://github.com/Phala-Network/meta-dstack-cloud/releases/download/v0.6.0-test/dstack-cloud-0.6.0-uki.tar.gz
```

> 当前为测试版本（v0.6.0-test），尚未提供 reproducible build 脚本。
>
> **重要**：release 中包含两个镜像版本，必须下载 **`-uki.tar.gz`** 文件（包含 `disk.raw` + `auth_hash.txt`），而非不带 `-uki` 后缀的 `.tar.gz` 文件（后者包含分离的 kernel/rootfs 文件，用于裸机 VMM）。使用错误的版本会导致 `dstack-cloud deploy` 报 "Boot image not found" 错误，并导致 attestation 中 `os_image_hash` 为空。

### 2.5 clone本教程代码仓库

```bash
git clone https://github.com/Phala-Network/dstack-cloud-deployment-guide.git
cd dstack-cloud-deployment-guide
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
# （留在 dstack-cloud-deployment-guide 根目录——后续章节的路径都以此为基准）
mkdir -p workshop-run

dstack-cloud new workshop-run/kms-prod \
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
# 使用支持 Hardhat 网络自省方法的 provider RPC(见下方“已知问题”)。
# 同一个 URL 后面 §9 也会用到。
export RPC_URL="https://base-sepolia.g.alchemy.com/v2/<YOUR_ALCHEMY_KEY>"
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

> **已知问题(公共 RPC)**:`https://sepolia.base.org` 已经不能用于 `kms:deploy`。自 2026-04-20 Base V1 / `base-reth-node` 在 Sepolia 上线后(见 §9.1),公共 RPC 拒绝 OpenZeppelin upgrades-core 在部署代理前调用的 Hardhat 自省方法:
> ```
> ProviderError: Method not found
>     at HttpProvider.request ...
>     at async isDevelopmentNetwork (.../@openzeppelin/upgrades-core/src/provider.ts:160)
> ```
> `kms:deploy` / `kms:create-app` / `kms:add*` 都用上面那个 Alchemy/Infura/QuickNode URL。CVM 内部 auth-api 的 `eth_call` 在公共 RPC 上仍能跑,所以 §6.2 里 `ETH_RPC_URL` 可以继续填 `https://sepolia.base.org`。
>
> 历史上(更老的 RPC 后端)这一步偶尔还会以 `Contract deployment failed - no code at address` 形式出现:合约其实已经上链,但部署后立即读 RPC 拿不到 code 的竞态。如果你在别的 RPC 上遇到这个,报错前 `DstackKms Proxy deployed to:` 行仍会输出 —— 记录该地址,然后用 `cast code <addr> --rpc-url <RPC>` 或 [sepolia.basescan.org](https://sepolia.basescan.org) 验证即可。

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
# 假设当前目录为 dstack-cloud-deployment-guide，项目目录为 workshop-run/kms-prod
cp workshop/kms/docker-compose.direct.yaml workshop-run/kms-prod/docker-compose.yaml
```

> **Datadog(可选)**:改用 `workshop/kms/docker-compose.direct.datadog.yaml`,服务相同,但多一个 sidecar `datadog-agent`,把 KMS 的 Prometheus `/metrics` 和容器日志推到 Datadog。后续 §6 流程不变,只需在 §6.2 里追加 `DD_*` 环境变量,并按 §6.5 末尾的验证块自检。

### 6.2 通过 prelaunch.sh + `.user-config` 注入环境变量

> **安全边界**:`prelaunch.sh` 内容会被嵌入到 `app-compose.json` 里,而 dstack guest-agent 在 `public_tcbinfo: true`(默认)下会把 `app-compose.json` 通过 HTTP 对外公开;部署时上传到 GCS 的 shared-disk tarball 同样包含它。**千万不要把密钥放进 `prelaunch.sh`。**
>
> 密钥放 `.user-config`:这个文件在 CVM 内挂在 `/dstack/.host-shared/.user-config`,dstack 原样存储——**不属于 `app-compose.json`**、**不参与 measurement**(改了不会改 `mr_aggregated`,所以可以轮换密钥而不用重新链上注册)、**不会被 public TCB-info HTTP endpoint 暴露**。完整边界契约见 [`docs/security/cvm-boundaries.md`](https://github.com/Phala-Network/dstack-cloud/blob/main/docs/security/cvm-boundaries.md)。
>
> 但正因为 `.user-config` **不参与 measurement**,恶意 host 可以替换它的内容。所以消费方式必须做两件事:
> 1. **JSON 格式**,用 `jq` 解析。如果直接 `cat`-then-source,被替换的文件可以塞 shell 元字符(`KEY="; rm -rf / "`)进 `.env`。
> 2. **prelaunch.sh 里写死一份 key 白名单**。`prelaunch.sh` 是被 measure 的(嵌在 `app-compose.json` 里、参与 `mr_aggregated`),所以恶意 host 可以换白名单里某个 key 的*值*,但没法塞新的 env 变量进去。

把非密钥的默认值写进 `prelaunch.sh`,然后用白名单从 `.user-config` 里取值:

```bash
cat > workshop-run/kms-prod/prelaunch.sh <<'EOF'
#!/bin/sh
# Prelaunch script - write .env for docker-compose (仅非密钥)
cat > .env <<'ENVEOF'
KMS_HTTPS_PORT=12001
AUTH_HTTP_PORT=18000
KMS_IMAGE=cr.kvin.wang/dstack-kms:latest
ETH_RPC_URL=https://sepolia.base.org
KMS_CONTRACT_ADDR=<KMS_CONTRACT_ADDR>
DSTACK_REPO=https://github.com/Phala-Network/dstack-cloud.git
DSTACK_REF=14963a2ccb0ec7bef8a496c1ac5ac40f5593145d
ENVEOF

# 允许从 .user-config(JSON)里读取的 key 白名单。
# 纯 Direct RPC 不需要任何密钥;Datadog variant 加 DD_*(见 §6.1 提示);
# Light Client(§9)加 EXECUTION_RPC。
ALLOWED=""

UC=/dstack/.host-shared/.user-config
if [ -f "$UC" ] && [ -n "$ALLOWED" ]; then
  for key in $ALLOWED; do
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$UC" | tr -d '\n\r')
    [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> .env
  done
fi
EOF
```

替换其中的 `<KMS_CONTRACT_ADDR>` 为实际值。`jq` 在 dstack OS rootfs 里默认就有。

`dstack-cloud new` 创建的 `.user-config` 默认是 `{}`。纯 Direct RPC 不需要任何密钥——保留 `{}` 即可。

> **Datadog**:如果在 §6.1 选了 `docker-compose.direct.datadog.yaml`:
>
> 1. 在 `prelaunch.sh` 里把白名单改成:
>    ```
>    ALLOWED="DD_API_KEY DD_SITE DD_ENV DD_SERVICE DD_TAGS"
>    ```
> 2. 把 `.user-config` 写成 JSON:
>    ```bash
>    cat > workshop-run/kms-prod/.user-config <<'EOF'
>    {
>      "DD_API_KEY": "<Datadog 给的 32 位字母数字>",
>      "DD_SITE": "datadoghq.com",
>      "DD_ENV": "production",
>      "DD_SERVICE": "dstack-kms",
>      "DD_TAGS": "env:production,service:dstack-kms"
>    }
>    EOF
>    ```
> `DD_API_KEY` 必须**正好 32 位字母数字**。某些下载链路会给值额外加人类前缀(比如 `pub<32hex>`),只复制 32 位的部分,否则 agent 会无声重试,什么都到不了 Datadog(CVM 外完全看不到失败)。deploy 前先 sanity-check:
> ```bash
> curl -sw '%{http_code}\n' -X POST "https://api.${DD_SITE}/api/v2/series" \
>   -H "DD-API-KEY: $DD_API_KEY" -H "Content-Type: application/json" \
>   -d '{"series":[{"metric":"sanity.test","type":3,"points":[{"timestamp":'$(date +%s)',"value":1}],"resources":[{"name":"laptop","type":"host"}]}]}'
> # 202 {"errors":[]}  -> OK;403 + 格式错误 -> key 不对。
> ```

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

> **Bootstrap 前的链上注册**:`Onboard.Bootstrap` 会调 `bootAuth/kms`,这一步会查 KMS 合约的 `isKmsAllowed()`。新部署的合约(或者任何时候改了 compose / `prelaunch.sh` 内容,包括切到 `.datadog.yaml`)当前的 `mr_aggregated` 和 `device_id` 都不在 allow-list 里,Bootstrap 会被拒:
> ```json
> {"error": "KMS is not allowed to bootstrap: boot denied: Aggregated MR not allowed"}
> ```
> 调 Bootstrap 之前先把值读出来注册:
> ```bash
> curl -s "http://<KMS_DOMAIN>:12001/prpc/Onboard.GetAttestationInfo?json" | jq .
>
> # 在 auth-eth/ 目录,RPC_URL / PRIVATE_KEY / KMS_CONTRACT_ADDRESS 已 export
> npx hardhat kms:add-image  0x<OS_IMAGE_HASH>  --network custom   # 已注册过的话幂等
> npx hardhat kms:add        0x<MR_AGGREGATED>  --network custom
> npx hardhat kms:add-device 0x<DEVICE_ID>      --network custom
> ```
> 如果 `kms:add` 之后紧接着的 `kms:add-device` 报 `nonce too low`,重试一次 —— 公共 RPC 偶尔会在前一笔交易传播完成前返回过期的 nonce。

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

**Datadog(仅 `.datadog.yaml` 变体需要):**

KMS 的 Prometheus `/metrics` 和 RPC 在同一个 TLS 端口:

```bash
curl -sk "https://<KMS_DOMAIN>:12001/metrics"
```

```
# HELP dstack_kms_attestation_requests_total Total number of KMS attestation requests.
# TYPE dstack_kms_attestation_requests_total counter
dstack_kms_attestation_requests_total 0
# HELP dstack_kms_attestation_failures_total Total number of failed KMS attestation requests.
# TYPE dstack_kms_attestation_failures_total counter
dstack_kms_attestation_failures_total 0
```

两个 counter,enclave 调 `GetAppKey` / `GetKmsKey` / `SignCert` 时才会自增。

串口日志只能看到 `app-compose.sh` 的输出(容器内部 stdout 不上串口),host 侧最多能确认两个容器都起来了:

```bash
dstack-cloud logs --lines 400 | grep -E "Container dstack-(kms|datadog-agent)-1"
```

```
[   41.747276] app-compose.sh[768]:  Container dstack-datadog-agent-1  Starting
[   41.934329] app-compose.sh[768]:  Container dstack-datadog-agent-1  Started
```

(CVM 上 compose project name 是 `dstack`,不是项目目录名 `kms-prod`,所以容器叫 `dstack-*-1`。)

在 Datadog 端,*Metrics Explorer* 搜 `dstack_kms_attestation_requests_total`;*Logs Explorer* 按 `service:dstack-kms` 过滤。openmetrics 的 namespace 设为 `""`,这样指标名和上游 Prometheus 完全一致(写成 `namespace: dstack_kms` 会得到双重前缀 `dstack_kms.dstack_kms_*`)。模板用的是 bridge 网络而不是 `network_mode: host`(避开 TDX iptables 冲突),代价是 dstack guest agent(端口 8090)的 systemd 级指标抓不到 —— 本模板只覆盖 KMS 应用层指标。

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

`get_keys.sh --show-mrs` 会在 EC2 上构建 EIF 镜像，计算 `sha256(pcr0 || pcr1 || pcr2)` 并直接输出 `OS_IMAGE_HASH`：

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./dstack-nitro-enclave-key.pem \
./get_keys.sh --show-mrs
```

输出示例：

```
PCR0: 1415501c7caeba0a7aea20f...
PCR1: 4b4d5b3661b3efc1292090...
PCR2: 33ae855210ea2ce171925831...
OS_IMAGE_HASH: 0x1078395c3151831924c255f7b7dec87b3f6bb3bf9db98fe17d43abfbe506407d
```

将 `OS_IMAGE_HASH` 注册到链上（在 `dstack-nitro-enclave-app/dstack/kms/auth-eth` 目录下执行）：

```bash
# 注册 OS image hash 到 KMS 合约
npx hardhat kms:add-image ${OS_IMAGE_HASH} --network custom

# 注册 compose hash 到 APP 合约（hash 值与 OS image hash 相同）
npx hardhat app:add-hash --app-id ${APP_ID} ${OS_IMAGE_HASH} --network custom
```

> **重要**：`KMS_URL` 和 `APP_ID` 都会被烘焙进 EIF 镜像（通过 `enclave_run_get_keys.sh`），影响 PCR 值从而影响 `OS_IMAGE_HASH`。`--show-mrs` 使用的值**必须与**实际拉取密钥时（8.2 节）使用的值完全一致。如果任一值不同，PCR 度量值将与链上注册的 hash 不匹配，导致 "Boot denied: OS image is not allowed" 错误。

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

- `enclave_console.log` — enclave 内核启动日志（仅在设置 `DEBUG_ENCLAVE=1` 时生成，默认不存在）
- `ncat_keys.log`

---

## 9. 部署 KMS（生产模式：Light Client / Helios）

> `cr.kvin.wang/dstack-kms:latest` 镜像已内置 helios 二进制（见 `workshop/kms/builder/`）。

### 9.1 选一个支持 `eth_getProof` 的 `EXECUTION_RPC`

Helios 每次读账户都会用 `eth_getProof` 拿状态证明并对 block state root 进行验证（[`core/src/execution/providers/rpc.rs`](https://github.com/a16z/helios/blob/master/core/src/execution/providers/rpc.rs)），没有 "trusted" 降级路径。

**`https://sepolia.base.org` 已经不能用了。** 自 2026-04-20 Base V1 在 Sepolia 激活后（[base/node#1035](https://github.com/base/node/pull/1035)、[#980](https://github.com/base/node/pull/980)），公共 RPC 跑的是默认关闭 historical-proofs ExEx 的 `base-reth-node`。`eth_getProof` 现在返回 `403 -32601 "rpc method is unsupported"`，表现为 auth-api 500（`missing revert data` / `CALL_EXCEPTION`）以及 `Onboard.Bootstrap` 报 `boot denied: ...`。

任何暴露 `eth_getProof` 的 provider 都行，Alchemy 免费 tier 够用：

```
EXECUTION_RPC=https://base-sepolia.g.alchemy.com/v2/<YOUR_ALCHEMY_KEY>
```

### 9.2 替换 compose 文件并把 `EXECUTION_RPC` 写到 `.user-config`

```bash
# 使用本仓库 light 模板
cp workshop/kms/docker-compose.light.yaml workshop-run/kms-prod/docker-compose.yaml
```

light compose 模板要求 `.env` 里提供 `EXECUTION_RPC`(缺则 compose 直接报错退出)。Alchemy URL 属于密钥,把它放进 `.user-config`,同时在 §6.2 的 `prelaunch.sh` 白名单里加上 `EXECUTION_RPC`:

```sh
# prelaunch.sh —— 把白名单改成:
ALLOWED="EXECUTION_RPC"
# (同时要 Datadog: ALLOWED="EXECUTION_RPC DD_API_KEY DD_SITE DD_ENV DD_SERVICE DD_TAGS")
```

```bash
cat > workshop-run/kms-prod/.user-config <<'EOF'
{
  "EXECUTION_RPC": "https://base-sepolia.g.alchemy.com/v2/<YOUR_ALCHEMY_KEY>"
}
EOF
```

> **Datadog(可选)**:改用 `workshop/kms/docker-compose.light.datadog.yaml`,然后按 §6.2 追加 `DD_*` 环境变量、按 §6.5 末尾的验证块自检。

> 如需自行构建包含 helios 的 KMS 镜像，参见 `workshop/kms/builder/README.md`。

### 9.3 部署

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
> - **DNS 必须正确**：`source_url` 中的域名由新 KMS 在 GCP VM 内部通过公共 DNS 解析——而非本机的 `/etc/hosts`。如果你重新部署过源 KMS 导致 IP 变化，**必须**在调用 Onboard 前更新 DNS 记录。过期的 DNS 记录（例如指向新 KMS 自身）会导致 TLS 握手失败：`received corrupt message of type InvalidContentType`。也可以在 `source_url` 中直接使用源 KMS 的 IP 地址来避免 DNS 相关问题。


---


## 11. 资源回收

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

> **注意**:`dstack-cloud remove` 只删 instance 和 shared-disk image,通过 `dstack-cloud fw allow` 创建的防火墙规则**不会**被一并删除。这些规则会以 `dstack-<instance>-allow-tcp-<port>` 留在 GCP 上,下次复用同名 instance 时会冲突。手动清理:
> ```bash
> dstack-cloud fw remove 12001
> dstack-cloud fw remove 18000
> dstack-cloud fw remove 18545   # 只有 §9 Light Client 用过才需要
> ```

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
