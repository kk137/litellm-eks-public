# 通过 Amazon Bedrock 接入 OpenAI GPT 模型 — 完整指南

> **适用模型：** GPT-5.5、GPT-5.4、Codex（2026-06-01 GA）  
> **核心 API：** OpenAI Responses API（非 Chat Completions）  
> **Endpoint 格式：** `https://bedrock-mantle.{region}.api.aws/openai/v1`

本文提供两条接入路径，按场景选择：

| 路径 | 适用场景 | 鉴权 |
|------|----------|------|
| **路径 A — 直连 Bedrock** | 个人开发、快速验证、无统一网关 | Bedrock API Key |
| **路径 B — 走 LiteLLM Proxy** | 团队共用、统一网关、集中鉴权计费 | LiteLLM 虚拟 Key |

---

## 一、Bedrock API Key 生成

> 路径 A 必须，路径 B 由网关管理员操作（用户无需持有）。

### 方式 A：控制台手动生成

1. 登录 [AWS Console → Amazon Bedrock](https://console.aws.amazon.com/bedrock)
2. 左侧导航栏选择 **API keys**

#### 短期 Key（开发测试，最长 12 小时）

- 切到 **Short-term API keys** tab
- 点击 **Generate short-term API keys**
- 复制生成的 Key
- 有效期 = 当前 Console session 剩余时间（最长 12h）

#### 长期 Key（生产环境，可设过期时间）

- 切到 **Long-term API keys** tab
- 点击 **Generate long-term API keys**
- 选择要附加的 IAM 策略（控制可访问的模型）
- 设置过期时间
- 复制生成的 Key
- 底层会创建 IAM user，后续可通过 IAM 控制台修改权限

### 方式 B：程序化生成（推荐生产环境）

使用 `aws-bedrock-token-generator` 从当前 AWS 角色凭证自动生成：

```bash
pip install aws-bedrock-token-generator
```

```python
from aws_bedrock_token_generator import BedrockTokenGenerator

generator = BedrockTokenGenerator(region="us-east-2")
token = generator.get_token()  # 基于当前 IAM Role/凭证生成 bearer token
```

> 生成的 token 与 Console 手动生成的短期 Key 本质相同（pre-signed URL，SigV4），可直接作为 `OPENAI_API_KEY` 使用。适合集成到 CI/CD 或服务启动脚本中自动 rotate。

### 参考文档

- [生成 Bedrock API Key](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)
- [API Key 工作原理](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-how.html)

---

## 路径 A — 直连 Bedrock

> 客户端直接打 `bedrock-mantle` endpoint，自己持有 Bedrock API Key。

### A1. Python 客户端（OpenAI SDK）

```bash
pip install openai>=2.28.0
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://bedrock-mantle.us-east-2.api.aws/openai/v1",
    api_key="<BEDROCK_API_KEY>",
)

response = client.responses.create(
    model="openai.gpt-5.5",
    input=[
        {"role": "developer", "content": "You are a software engineer."},
        {"role": "user", "content": "Design a distributed architecture."},
    ],
    reasoning={"effort": "medium"},
)
print(response.output_text)
```

### A2. Codex Desktop / CLI（直连 Bedrock）

**Step 1：设置鉴权**

创建或编辑 `~/.codex/.env`：

```bash
AWS_BEARER_TOKEN_BEDROCK=<your-bedrock-api-key>
```

> Codex 优先使用 `AWS_BEARER_TOKEN_BEDROCK`；如果未设置，fallback 到 AWS SDK credential chain。

**Step 2：编辑 `~/.codex/config.toml`**

```toml
model = "openai.gpt-5.5"
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
region = "us-east-2"
```

**Step 3：重启客户端**

- **CLI：** 退出重进，查看 `/status` tab 确认 model 和 provider
- **VS Code 插件：** 重新加载窗口（Ctrl/Cmd + Shift + P → Reload Window）
- **Desktop App：** 关闭重开

---

## 路径 B — 走 LiteLLM Proxy（统一网关）

> 团队共用一个 LiteLLM Proxy，客户端用 LiteLLM 虚拟 Key，无需持有 Bedrock API Key。

### B1. LiteLLM 网关侧配置（管理员操作）

在 LiteLLM `config.yaml` 的 `model_list` 中添加：

```yaml
model_list:
  # GPT-5.5 — 最强推理/编码能力
  - model_name: gpt-5.5
    litellm_params:
      model: openai/openai.gpt-5.5
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY

  # GPT-5.4 — 最佳性价比（us-east-2 主 + us-west-2 fallback）
  - model_name: gpt-5.4
    litellm_params:
      model: openai/openai.gpt-5.4
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY

  - model_name: gpt-5.4
    litellm_params:
      model: openai/openai.gpt-5.4
      api_base: https://bedrock-mantle.us-west-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
```

> **原理**：LiteLLM 使用 `openai/` provider，调用时自动拼接 `api_base + /responses`，最终打到 `bedrock-mantle.{region}.api.aws/openai/v1/responses`。这是针对 LiteLLM v1.84.3 尚未原生支持 mantle Responses API 路由（[issue #29463](https://github.com/BerriAI/litellm/issues/29463)）的 workaround。

> **已知限制**：GPT 调用不会出现在 LiteLLM UI 的对话日志中（spend logging 不覆盖 `/v1/responses`）。

**Secret Manager 配置（EKS 部署）：**

在 AWS Secrets Manager（`us-east-1`）创建 secret：

- **路径名**：`litellm/bedrock-api-key`
- **值**：Bedrock API Key（`ABSK` 开头的长期 key）
- **ExternalSecret 映射**：`secretKey: BEDROCK_MANTLE_API_KEY`

### B2. Python 客户端（走 LiteLLM Proxy）

```bash
pip install openai>=2.28.0
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<your-litellm-domain>/v1",
    api_key="<LiteLLM-virtual-key>",  # LiteLLM 虚拟 key，不是 Bedrock Key
)

# 必须用 responses.create，不能用 chat.completions.create
response = client.responses.create(
    model="gpt-5.5",
    input=[
        {"role": "developer", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello!"},
    ],
    reasoning={"effort": "medium"},
)
print(response.output_text)
```

### B3. Codex Desktop（走 LiteLLM Proxy）

**Step 1：编辑 `~/.codex/config.toml`**

在**文件顶部**（任何 section 之前）指定 `model_provider`，否则 Codex 默认直连 OpenAI 官方：

```toml
model = "openai.gpt-5.5"
model_provider = "litellm-bedrock"
web_search = "disabled"             # mantle 不支持 web_search tool 类型

[model_providers.litellm-bedrock]
name = "LiteLLM Bedrock GPT"
base_url = "https://<your-litellm-domain>/v1"
wire_api = "responses"              # 必须指定，走 Responses API
env_key = "OPENAI_API_KEY"          # 指定从 .env 中读取哪个环境变量作为 API Key

[profiles.bedrock-55]
model = "openai.gpt-5.5"
model_provider = "litellm-bedrock"

[profiles.bedrock-54]
model = "openai.gpt-5.4"
model_provider = "litellm-bedrock"
```

**Step 2：编辑 `~/.codex/.env`**

文件不存在时手动创建：

```bash
OPENAI_API_KEY=<LiteLLM-virtual-key>   # LiteLLM 虚拟 key，不是 Bedrock Key
```

> **注意**：`.env` 中的变量名必须与 `config.toml` 里 `env_key` 指定的值一致。如果不配置 `env_key`，部分环境下 Codex 可能无法正确读取 API Key，导致 `401 Unauthorized` 报错。

**Step 3：重启 Codex Desktop**

### B4. 常见问题

**Q1：启动后报 `401 Unauthorized`，url 显示 `api.openai.com`**

原因：`config.toml` 顶部没有指定 `model_provider`，Codex Desktop 默认走 OpenAI 官方，LiteLLM 虚拟 key 被当成 OpenAI key 使用。

解决：确认 `config.toml` **文件最顶部**（第一个 `[section]` 之前）有：
```toml
model_provider = "litellm-bedrock"
```

**Q2：报 `400 Tool type 'web_search' is not supported`**

原因：Codex Desktop 内置 web_search 功能，请求里自动带了 `web_search` tool，但 Bedrock mantle 只支持 `function, mcp, custom, namespace, tool_search` 类型。

解决：在 `config.toml` 顶部加：
```toml
web_search = "disabled"
```

---

## 二、可用 Region 总览

### bedrock-mantle Endpoint（全量）

| Region | Endpoint |
|--------|----------|
| US East (Ohio) | `bedrock-mantle.us-east-2.api.aws` |
| US East (Virginia) | `bedrock-mantle.us-east-1.api.aws` |
| US West (Oregon) | `bedrock-mantle.us-west-2.api.aws` |
| AP Northeast (Tokyo) | `bedrock-mantle.ap-northeast-1.api.aws` |
| AP South (Mumbai) | `bedrock-mantle.ap-south-1.api.aws` |
| AP Southeast (Jakarta) | `bedrock-mantle.ap-southeast-3.api.aws` |
| AP Southeast (Sydney) | `bedrock-mantle.ap-southeast-2.api.aws` |
| EU Central (Frankfurt) | `bedrock-mantle.eu-central-1.api.aws` |
| EU West (Ireland) | `bedrock-mantle.eu-west-1.api.aws` |
| EU West (London) | `bedrock-mantle.eu-west-2.api.aws` |
| EU South (Milan) | `bedrock-mantle.eu-south-1.api.aws` |
| EU North (Stockholm) | `bedrock-mantle.eu-north-1.api.aws` |
| SA East (São Paulo) | `bedrock-mantle.sa-east-1.api.aws` |

### OpenAI GPT 模型可用 Region（当前）

| 模型 | Region |
|------|--------|
| GPT-5.5 | us-east-2 |
| GPT-5.4 | us-east-2, us-west-2 |

### 可选 Model ID

| Model ID | 说明 | 可用 Region |
|----------|------|------------|
| `openai.gpt-5.5` | 最强推理 | us-east-2 |
| `openai.gpt-5.4` | 性价比最优 | us-east-2, us-west-2 |
| `openai.gpt-oss-120b` | 大型通用 | 待确认 |
| `openai.gpt-oss-20b` | 轻量低延迟 | 待确认 |

---

## 三、注意事项

1. **不要混淆 Key** — Bedrock API Key ≠ OpenAI 官方 API Key ≠ AWS Access Key ≠ LiteLLM 虚拟 Key
2. **不要用 OpenAI 的 base_url** — `https://api.openai.com/v1` 会直连 OpenAI，不经过 Bedrock
3. **Responses API vs Chat Completions** — Bedrock 上 GPT 模型用 `client.responses.create`，不是 `client.chat.completions.create`
4. **数据驻留** — 所有处理在你选择的 Bedrock Region 内完成，不出 AWS 环境
5. **计费** — 按 token 计费，无 seat license，无 per-developer 承诺
6. **状态存储** — Responses API 默认 `store=true`，对话数据保留 30 天用于 multi-turn；如不需要可设 `store=false`

---

## 参考链接

- [AWS Blog: Get started with OpenAI GPT-5.5, GPT-5.4 on Bedrock](https://aws.amazon.com/cn/blogs/aws/get-started-with-openai-gpt-5-5-gpt-5-4-models-and-codex-on-amazon-bedrock/)
- [OpenAI on Amazon Bedrock 官方页面](https://aws.amazon.com/bedrock/openai/)
- [Bedrock Mantle Responses API 文档](https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html)
- [Bedrock API Key 生成](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)
- [OpenAI Cookbook: Getting Started with OpenAI on Bedrock](https://developers.openai.com/cookbook/examples/partners/aws/openai_models_with_amazon_bedrock)
- [LiteLLM Bedrock 文档](https://docs.litellm.ai/docs/providers/bedrock)
- [LiteLLM Issue #29463: mantle Responses API support](https://github.com/BerriAI/litellm/issues/29463)
