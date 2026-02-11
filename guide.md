# 在 GCP 部署 dstack-kms，并为 AWS Nitro Enclave 提供密钥

> 更新日期：2026-02-11
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

- `gcloud`
- `aws` CLI
- `docker` / `docker compose`
- `node` + `npm`
- `jq`

并已完成：

- `dstack-cloud config-edit` 全局配置（project / region / zone）
- 可用 dstack OS 镜像（示例：`dstack-cloud-0.6.0`）

### 2.2 代码仓库

```bash
git clone <this-repo-url> dstack-gcp-guide
cd dstack-gcp-guide
```

### 2.3 域名与端口

建议准备一个域名（示例：`gcp-kms.example.com`），解析到 KMS 公网地址。

开放端口：

- `12001/tcp`：KMS HTTPS
- `18000/tcp`：auth-api（调试，可选）
- `18545/tcp`：helios（调试，可选，仅 light client）

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

---

## 4. 链上部署与授权（Base Sepolia 示例）

> 说明：生产模式必须先完成合约部署和授权配置。

### 4.1 准备 Faucet 资金

创建一个测试钱包并领取 Base Sepolia Faucet。

### 4.2 部署 KMS 合约

```bash
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app/dstack/kms/auth-eth

npm ci
npx hardhat compile

export RPC_URL="https://sepolia.base.org"
export PRIVATE_KEY="<YOUR_PRIVATE_KEY>"

printf 'y\n' | PRIVATE_KEY="$PRIVATE_KEY" RPC_URL="$RPC_URL" \
  npx hardhat kms:deploy --with-app-impl --network test
```

记录输出中的：

- `DstackKms Proxy`（后续作为 `KMS_CONTRACT_ADDR`）

### 4.3 配置授权（最小闭环）

```bash
export KMS_CONTRACT_ADDRESS="<KMS_CONTRACT_ADDR>"
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000

# 1) 允许 OS image hash（演示用 ZERO32，生产请替换为真实 hash）
PRIVATE_KEY="$PRIVATE_KEY" RPC_URL="$RPC_URL" KMS_CONTRACT_ADDRESS="$KMS_CONTRACT_ADDRESS" \
  npx hardhat kms:add-image --network test "$ZERO32"

# 2) 创建应用（演示可用 allow-any-device，生产请收紧）
PRIVATE_KEY="$PRIVATE_KEY" RPC_URL="$RPC_URL" KMS_CONTRACT_ADDRESS="$KMS_CONTRACT_ADDRESS" \
  npx hardhat kms:create-app --network test --allow-any-device --hash "$ZERO32"

# 3) 允许 compose hash
export APP_ID="<APP_ID_FROM_CREATE_APP>"
PRIVATE_KEY="$PRIVATE_KEY" RPC_URL="$RPC_URL" KMS_CONTRACT_ADDRESS="$KMS_CONTRACT_ADDRESS" \
  npx hardhat app:add-hash --network test --app-id "$APP_ID" "$ZERO32"
```

---

## 5. 部署 KMS（生产模式：Direct RPC）

将本仓库提供的 compose 模板放入 `dstack-cloud new` 生成的项目目录。

```bash
# 假设当前目录为 dstack-gcp-guide
cp workshop/kms/.env.example workshop/kms/.env
```

编辑 `workshop/kms/.env`：

- `KMS_DOMAIN`
- `ETH_RPC_URL`
- `KMS_CONTRACT_ADDR`
- （可选）`DSTACK_REF` 固定到可复现提交

```bash
# 拷贝 Direct 模板到 dstack 项目目录
cp workshop/kms/docker-compose.direct.yaml <PATH_TO_KMS_PROJECT>/docker-compose.yaml
cp workshop/kms/.env <PATH_TO_KMS_PROJECT>/.env

cd <PATH_TO_KMS_PROJECT>
dstack-cloud deploy --delete

# 开放端口
dstack-cloud fw allow 12001
dstack-cloud fw allow 18000
```

> 是否绑定静态 IP：**非必须**。  
> 如果你需要长期稳定域名，建议绑定静态公网 IP；临时测试可直接使用实例当前公网 IP。

验证：

```bash
curl -s "http://<KMS_DOMAIN>:18000/" | jq .
curl -sk "https://<KMS_DOMAIN>:12001/prpc/GetMeta?json" -d '{}' | jq .
```

---

## 6. Nitro Host 部署示例（AWS）

> 参考 demo 仓库的 `deploy_host.sh`，下例为直接可跑示例。

```bash
git clone https://github.com/Phala-Network/dstack-nitro-enclave-app.git --recurse-submodules
cd dstack-nitro-enclave-app

# 可按需覆盖变量：REGION / INSTANCE_TYPE / KEY_NAME / KEY_PATH 等
REGION=us-east-1 \
INSTANCE_TYPE=c5.xlarge \
KEY_NAME=nitro-enclave-key \
KEY_PATH=./nitro-enclave-key.pem \
./deploy_host.sh
```

脚本完成后会生成 `deployment.json`，其中包含 `instance_id` 与 `public_ip`。

---

## 7. Nitro Enclave 拉取密钥（Direct RPC）

```bash
cd dstack-nitro-enclave-app

HOST=$(jq -r .public_ip deployment.json) \
KMS_URL="https://<KMS_DOMAIN>:12001" \
APP_ID="<APP_ID>" \
KEY_PATH=./nitro-enclave-key.pem \
./get_keys.sh
```

成功后本地会生成：

- `app_keys.json`
- `enclave_console.log`
- `ncat_keys.log`

---

## 8. 部署 KMS（生产模式：Light Client / Helios）

```bash
# 使用本仓库 light 模板
cp workshop/kms/docker-compose.light.yaml <PATH_TO_KMS_PROJECT>/docker-compose.yaml
cp workshop/kms/.env <PATH_TO_KMS_PROJECT>/.env

cd <PATH_TO_KMS_PROJECT>
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

Nitro 侧验证与第 7 章相同，只需保持 `KMS_URL` 不变。

---

## 9. 生产安全建议

1. 不要在生产长期使用 `ZERO32`。
2. 不要在生产长期使用 `--allow-any-device`。
3. 对调试端口（18000/18545）做网络收敛或关闭。
4. 私钥使用 KMS/HSM 或 CI Secret 管理，避免明文落盘。
5. 文档与对外材料建议使用占位符，避免暴露真实实例 ID、IP、钱包地址。

---

## 10. 常见问题

### 10.1 镜像拉取超时

表现：串口日志出现 `i/o timeout`。  
处理：重试部署，必要时更换镜像源或网络出口。

### 10.2 `deploy --delete` 卡在停止阶段

可在云侧确认实例状态后，再执行重试。

### 10.3 端口曾可用、重建实例后不通

在新版 `dstack-cloud` 中已修复“实例重建后防火墙 tag 未自动附加”的问题。  
若你使用旧版本，请升级后重试。

---

## 11. 资源回收

```bash
# GCP
cd <PATH_TO_KMS_PROJECT>
dstack-cloud stop
# 或彻底删除
dstack-cloud remove

# AWS
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region <REGION>
```

