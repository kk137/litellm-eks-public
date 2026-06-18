---
title: "AgentCore Web Search 部署 + Codex 接入 + LiteLLM 模型 Alias 修复"
subtitle: "可操作运维手册 · Runbook（脱敏版）"
author: "Sanitized public version"
date: "2026-06-18"
---

# AgentCore Web Search 运维手册（脱敏版）

> **环境**:AWS 账号 `<ACCOUNT_ID>` · 区域 `us-east-1`（AgentCore 仅此区可用）
> **性质**:**脱敏公开版** —— 真实值已替换为占位符（`<ACCOUNT_ID>` / `<DOMAIN>` / `<GATEWAY_ID>` / `<USER_EMAIL>`）。
> 使用前把占位符替换为你自己的值（真实值另存于本地、不入库的清单文件，参见附录 A）。
> **覆盖**:① 服务端部署 AgentCore Web Search Gateway ② Codex 连 LiteLLM 基础配置 ③ 客户端接入 WebSearch ④ LiteLLM 修复 Codex guardian 模型 alias ⑤ 验证 / 排错 / 回滚。

---

## 1. 概览与架构

这份手册涉及**三个相互独立、但在 Codex 里会联动**的系统：

| 系统 | 角色 | 位置 |
|---|---|---|
| **Amazon Bedrock AgentCore Web Search** | AWS 官方托管的"AI 专用搜索"（正文抽取型，单条约 1760 字符） | us-east-1，通过 AgentCore Gateway 以 MCP 协议暴露 |
| **LiteLLM** | 你的统一 LLM 网关（模型路由、计费、日志） | EKS（us-east-1）+ Docker（东京），本手册指 EKS |
| **Codex** | 本机 AI 编码客户端 | 本地 macOS，model_provider 指向 LiteLLM |

### 三者的联动关系（关键）

```
                 ┌──────────────────────────┐
   主对话/代码 →  │  Codex  (本机)            │
                 │  model_provider=litellm  │
                 └──────────┬───────────────┘
                            │ ① 主对话 /v1/responses
                            ▼
                 ┌──────────────────────────┐
                 │  LiteLLM (EKS, us-east-1) │ ── Bedrock / Mantle
                 └──────────────────────────┘
                            ▲
                            │ ② guardian 审批用 codex-auto-review 模型
                            │    （第 5 章修复点）
   web search 工具 ←────────┘
   ③ Codex 调 agentcore_websearch (MCP)
                 ┌──────────────────────────┐
                 │  AgentCore Gateway        │ → Web Search Tool
                 │  (MCP, AWS_IAM 认证)      │
                 └──────────────────────────┘
```

- **①** Codex 主对话走 LiteLLM（第 3 章）
- **③** Codex 的 web search 走 AgentCore（第 2、4 章），**不经过 LiteLLM**（客户端 MCP，独立链路）
- **②** Codex 执行工具调用前，`guardian_approval` 会用 `codex-auto-review` 模型做审批——这个审批走 LiteLLM，而 LiteLLM 默认没有这个模型 → 审批失败会**反过来阻断 ③ 的 web search**。第 5 章修这个。

> **要点**：AgentCore web search 与 LiteLLM 现有的 `websearch_interception + searxng` 是**两套并存**的搜索。AgentCore 只在装了它的客户端里生效，不计入 LiteLLM 的统一日志/计费。

---

## 2. 服务端：部署 AgentCore Web Search Gateway

### 2.0 前置条件（缺一不可）

| 条件 | 要求 | 检查命令 |
|---|---|---|
| AWS CLI | **≥ 2.35.7**（connector target 需要） | `aws --version` |
| Python | 3.10+ | `python3 --version` |
| uv / uvx | 已安装（客户端代理用） | `uvx --version` |
| 区域 | 必须 us-east-1 | — |
| IAM 权限 | 建 role/gateway/target + 调用 | 见下 |

> ⚠️ **CLI 版本是最大坑**：低于 2.35.7 会报 `Unknown parameter ... must be one of: openApiSchema,smithyModel,lambda,mcpServer,apiGateway`（缺 connector）。`bedrock-agentcore-control` 的 API 模型只随 aws-cli v2 分发，pip 装的 boto3（即便很新）也没有该模型。

升级 aws-cli（官方 pkg 安装方式，本机即此方式）：

```bash
curl -s "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
aws --version   # 确认 ≥ 2.35.7
```

权限自检（应全部 allowed）：

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::<ACCOUNT_ID>:user/bedrock-admin" \
  --action-names "iam:CreateRole" "iam:PutRolePolicy" \
    "bedrock-agentcore:CreateGateway" "bedrock-agentcore:CreateGatewayTarget" \
    "bedrock-agentcore:InvokeGateway" "bedrock-agentcore:InvokeWebSearch" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' --output table
```

### 2.1 建 Gateway 服务角色

Gateway 由这个角色 assume，用来调 Web Search。

```bash
# 建角色（信任 bedrock-agentcore 服务）
aws iam create-role --role-name AgentCoreWebSearchGatewayRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# 附权限：InvokeGateway + InvokeWebSearch
aws iam put-role-policy --role-name AgentCoreWebSearchGatewayRole \
  --policy-name WebSearchPerms \
  --policy-document '{"Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":"bedrock-agentcore:InvokeGateway",
     "Resource":"arn:aws:bedrock-agentcore:us-east-1:<ACCOUNT_ID>:gateway/*"},
    {"Effect":"Allow","Action":"bedrock-agentcore:InvokeWebSearch",
     "Resource":"arn:aws:bedrock-agentcore:us-east-1:aws:tool/web-search.v1"}]}'
```

### 2.2 建 Gateway（关键：`--authorizer-type AWS_IAM`）

```bash
aws bedrock-agentcore-control create-gateway \
  --name websearch-gw \
  --role-arn "arn:aws:iam::<ACCOUNT_ID>:role/AgentCoreWebSearchGatewayRole" \
  --protocol-type MCP \
  --authorizer-type AWS_IAM \
  --region us-east-1
# 返回 gatewayId / gatewayUrl，等 status=READY
```

选 `AWS_IAM` 而非 `CUSTOM_JWT`：省掉自建 IdP（Cognito）和 token 刷新，用本机 AWS 凭证直接签名。

> **本次部署结果**：gatewayId `<GATEWAY_ID>`，URL
> `https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp`

等 READY：

```bash
aws bedrock-agentcore-control get-gateway --region us-east-1 \
  --gateway-identifier <GATEWAY_ID> --query 'status' --output text
```

### 2.3 加 Web Search connector target

```bash
aws bedrock-agentcore-control create-gateway-target \
  --gateway-identifier <GATEWAY_ID> \
  --name web-search-tool \
  --target-configuration '{"mcp":{"connector":{"source":{"connectorId":"web-search"},
    "configurations":[{"name":"WebSearch","parameterValues":{}}]}}}' \
  --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
  --region us-east-1
```

（可选）域名黑名单——禁止搜索特定站点，服务端强制、对模型隐藏：

```bash
# parameterValues 内加 "domainFilter":{"exclude":["blocked-1.com","blocked-2.com"]}
```

### 2.4 给"调用方"加权限

本机用哪个 IAM 身份跑客户端，就给谁 `InvokeGateway`：

```bash
aws iam put-user-policy --user-name bedrock-admin \
  --policy-name InvokeWebSearchGW \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Action":"bedrock-agentcore:InvokeGateway",
    "Resource":"arn:aws:bedrock-agentcore:us-east-1:<ACCOUNT_ID>:gateway/<GATEWAY_ID>"}]}'
```

### 2.5 服务端踩坑清单

| 坑 | 现象 | 解 |
|---|---|---|
| CLI 版本 | `Unknown parameter ... connector` | 升级 aws-cli ≥ 2.35.7 |
| `--service` 错 | 403 签名失败 | 客户端代理 `--service` 必须 `bedrock-agentcore` |
| 区域 | 找不到工具 | 只 us-east-1 |
| `--read-only` | 连上了但工具列表为空 | **别加**——WebSearch 无 readOnlyHint，会被过滤器误删 |

---

## 3. 客户端：Codex 连 LiteLLM 基础配置

文件：`~/.codex/config.toml`。这是 Codex 主对话走你 LiteLLM 的前提。

```toml
model = "gpt-5.4"
model_provider = "litellm-bedrock"
model_reasoning_effort = "medium"
web_search = "disabled"           # 用 AgentCore MCP 提供搜索，关掉 Codex 内置

[model_providers.litellm-bedrock]
name = "LiteLLM Bedrock GPT"
base_url = "https://litellm.<DOMAIN>/v1"
wire_api = "responses"            # 走 Responses API
env_key = "..."                   # 指向存 LiteLLM key 的环境变量

[profiles.bedrock-55]
model = "openai.gpt-5.5"
model_provider = "litellm-bedrock"

[profiles.bedrock-54]
model = "openai.gpt-5.4"
model_provider = "litellm-bedrock"
```

> 切换模型：`codex --profile bedrock-55`。
> `wire_api = "responses"` 很关键——GPT-5.x 在 Bedrock 只支持 Responses API（`/v1/responses`），不支持 Chat Completions。

---

## 4. 客户端：接入 AgentCore WebSearch

三端用**同一个 uvx 代理、同一个 gateway**，只是填入位置不同。先持久化代理：

```bash
uv tool install mcp-proxy-for-aws==1.6.0
```

### 4.1 Claude Code（CLI 一行注册）

```bash
claude mcp add --scope user --transport stdio agentcore-websearch \
  -- uvx mcp-proxy-for-aws@1.6.0 \
  https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp \
  --service bedrock-agentcore --region us-east-1

# 验证
claude mcp list | grep agentcore-websearch     # 期望 ✔ Connected
```

### 4.2 Codex（编辑 `~/.codex/config.toml`）

```toml
[mcp_servers.agentcore_websearch]
command = "uvx"
args = ["mcp-proxy-for-aws@1.6.0",
        "https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
        "--service", "bedrock-agentcore", "--region", "us-east-1"]
startup_timeout_sec = 120
```

```bash
codex mcp list      # 期望 agentcore_websearch ... enabled
```
（`Auth: Unsupported` 正常——它靠 AWS 凭证签名，不走 MCP 层 OAuth。）

### 4.3 Cowork（Claude 桌面 App，需先装 App）

本机未装 Claude.app 则跳过。装好后编辑
`~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "agentcore-websearch": {
      "command": "uvx",
      "args": ["mcp-proxy-for-aws@1.6.0",
        "https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
        "--service", "bedrock-agentcore", "--region", "us-east-1"]
    }
  }
}
```

> ⚠️ **生效方式（三端通用）**：新加 MCP 必须**全新启动**客户端。Claude Code 用 `claude` 起，`claude -r` 恢复旧会话不进工具列表；Codex / Cowork 设置里加完后新开会话。

---

## 5. LiteLLM 修复：Codex guardian 模型 alias

### 5.1 根因

Codex 的 `guardian_approval`（自动审批审查，stable·默认开）在执行工具调用（含 AgentCore web search）前，会用 **`codex-auto-review`** 模型做一次"风险审批"。Codex 的 provider 指向 LiteLLM，但这些内部任务仍用 **OpenAI 原生 slug**（来自 `~/.codex/models_cache.json`），而 LiteLLM 没有这些模型 →

```
400: Invalid model name passed in model=codex-auto-review
→ guardian 审批失败 → 工具调用被拒（"rejected due to unacceptable risk"）
→ AgentCore web search 实际被阻断
```

同类失败的 slug：`codex-auto-review`、`gpt-5.4-mini`、`gpt-5`、`gpt-5-codex`。

### 5.2 修法：LiteLLM configmap 加 alias 模型条目

保留 Codex 审批能力（不关 guardian），在网关侧把这些 slug 映射到真实模型。

要加的条目（追加到 `litellm-config` 的 model_list 末尾）：

```yaml
  - model_name: codex-auto-review
    litellm_params:
      model: openai/openai.gpt-5.5
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
      drop_params: true
  - model_name: gpt-5.4-mini
    litellm_params:
      model: openai/openai.gpt-5.4
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
      drop_params: true
  - model_name: gpt-5            # 历史 session 出现，顺手兜底
    litellm_params:
      model: openai/openai.gpt-5.5
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
      drop_params: true
  - model_name: gpt-5-codex
    litellm_params:
      model: openai/openai.gpt-5.5
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
      drop_params: true
```

### 5.3 安全改 live configmap（⚠️ 绝不裸 apply 仓库脱敏版）

公开仓库的 `04-configmap.yaml` 是脱敏占位符版，**直接 apply 会把占位符推上生产搞崩**。正确做法是基于 **live 真实配置**修改：

```bash
# 1) 导出 live 真实 config（不是仓库版）
kubectl get configmap litellm-config -n litellm \
  -o jsonpath='{.data.config\.yaml}' > /tmp/config-live.yaml
cp /tmp/config-live.yaml /tmp/config-live.bak     # 备份，回滚用

# 2) 本地编辑 /tmp/config-live.yaml，在 model_list 末尾插入 5.2 的条目

# 3) 用 --from-file + dry-run 生成再 apply（只更新 config.yaml key）
kubectl create configmap litellm-config -n litellm \
  --from-file=config.yaml=/tmp/config-live.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 4) 滚动重启让 LiteLLM 重新加载 config（启动时才加载）
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status  deployment/litellm -n litellm --timeout=180s
```

> LiteLLM **启动时才读 config**，改完 configmap **必须滚动重启**才生效。滚动策略 maxSurge=0/maxUnavailable=1，原地滚，启动慢（startupProbe 窗口 5 分钟），`rollout status` 超时不等于失败。

---

## 6. 验证 / 排错 / 回滚

### 6.1 验证 AgentCore web search（端到端）

```bash
# 通过代理列工具，应看到 web-search-tool___WebSearch
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| uvx mcp-proxy-for-aws@1.6.0 \
  https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp \
  --service bedrock-agentcore --region us-east-1
```

### 6.2 验证 LiteLLM alias（在 pod 内打自己）

```bash
POD=$(kubectl get pods -n litellm -l app=litellm -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n litellm "$POD" -- /app/.venv/bin/python3 -c '
import os,json,urllib.request
key=os.environ["LITELLM_MASTER_KEY"]
b=json.dumps({"model":"codex-auto-review","input":"hi","max_output_tokens":16}).encode()
r=urllib.request.Request("http://localhost:4000/v1/responses",data=b,
  headers={"Authorization":"Bearer "+key,"Content-Type":"application/json"})
try: print("HTTP", urllib.request.urlopen(r,timeout=60).status)   # 期望 200
except urllib.error.HTTPError as e: print("HTTP",e.code,e.read().decode()[:200])
'
```

### 6.3 查 LiteLLM 日志里的模型报错

```bash
kubectl logs -n litellm -l app=litellm --tail=500 --since=10m \
  | grep -iE "Invalid model name|ProxyModelNotFoundError"
```

### 6.4 查调用方（谁在发坏请求）

LiteLLM 把请求写进 RDS `LiteLLM_SpendLogs`。在 pod 内用 prisma 查（pod 无 psql/asyncpg，只有 prisma）：

```bash
kubectl exec -n litellm "$POD" -- /app/.venv/bin/python3 -c '
import asyncio,json
async def m():
    from prisma import Prisma
    db=Prisma(); await db.connect()
    rows=await db.query_raw("""
      select model,status,count(*) n from \"LiteLLM_SpendLogs\"
      where (metadata->>'"'"'user_api_key_team_alias'"'"')='"'"'SDR-Team'"'"'
      group by model,status order by n desc limit 30""")
    [print(r) for r in rows]; await db.disconnect()
asyncio.run(m())'
```

### 6.5 回滚

```bash
# LiteLLM configmap 回滚
kubectl create configmap litellm-config -n litellm \
  --from-file=config.yaml=/tmp/config-live.bak \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/litellm -n litellm

# 删 AgentCore（按依赖逆序）
aws bedrock-agentcore-control delete-gateway-target --gateway-identifier <GATEWAY_ID> --target-id <TID> --region us-east-1
aws bedrock-agentcore-control delete-gateway --gateway-identifier <GATEWAY_ID> --region us-east-1
aws iam delete-role-policy --role-name AgentCoreWebSearchGatewayRole --policy-name WebSearchPerms
aws iam delete-role --role-name AgentCoreWebSearchGatewayRole
aws iam delete-user-policy --user-name bedrock-admin --policy-name InvokeWebSearchGW
# 客户端：claude mcp remove agentcore-websearch；Codex 删 config.toml 对应段
```

---

## 附录 A · 占位符清单（用前替换为你自己的值）

本文所有 `<...>` 占位符的含义如下。真实值请勿写进本文件或任何入库文件；
建议放在本地不入库的清单（如 `docs/agentcore-runbook.values.local`，已 gitignore）。

| 占位符 | 含义 | 示例 / 格式 |
|---|---|---|
| `<ACCOUNT_ID>` | AWS 账号 | 12 位数字 |
| `<DOMAIN>` | LiteLLM 域名 | `litellm.<DOMAIN>` → 你的网关域名 |
| `<GATEWAY_ID>` | AgentCore Gateway id | `create-gateway` 返回，形如 `websearch-gw-xxxxxxxxxx` |
| `<USER_EMAIL>` | 调用方 / team 标识 | 用于查 SpendLogs 的 team_alias |
| 区域 | 固定 | `us-east-1`（AgentCore）/ `us-east-2`（Mantle GPT api_base） |
| 服务角色 | 固定名（可自定） | `AgentCoreWebSearchGatewayRole` |
| 调用方身份 | IAM user/role | `arn:aws:iam::<ACCOUNT_ID>:user/<YOUR_IAM_USER>` |
| 代理 | 固定 | `mcp-proxy-for-aws@1.6.0`（`uvx` 拉起） |

## 附录 B · 关键命令速查

```bash
# AgentCore 状态
aws bedrock-agentcore-control get-gateway --region us-east-1 --gateway-identifier <GATEWAY_ID> --query 'status' --output text
aws bedrock-agentcore-control list-gateway-targets --region us-east-1 --gateway-identifier <GATEWAY_ID>

# 客户端连接状态
claude mcp list | grep agentcore
codex mcp list

# LiteLLM
kubectl get pods -n litellm -l app=litellm
kubectl rollout restart deployment/litellm -n litellm
kubectl get configmap litellm-config -n litellm -o jsonpath='{.data.config\.yaml}' | grep model_name
```
