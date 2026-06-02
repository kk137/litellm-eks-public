# 通过 LiteLLM 接入 Amazon Bedrock 上的 OpenAI GPT 模型 — 完整指南

> **适用模型：** GPT-5.5、GPT-5.4、Codex（2026-06-01 GA）  
> **核心 API：** OpenAI Responses API（非 Chat Completions）  
> **Endpoint 格式：** `https://bedrock-mantle.{region}.api.aws/openai/v1`

---

## 一、Bedrock API Key 生成

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

## 二、LiteLLM Proxy 配置

### 前提

```bash
pip install litellm openai>=2.28.0
```

### config.yaml

```yaml
model_list:
  # GPT-5.5 — 最强推理/编码能力
  - model_name: "gpt-5.5"
    litellm_params:
      model: "openai/openai.gpt-5.5"
      api_base: "https://bedrock-mantle.us-east-2.api.aws/openai/v1"
      api_key: "os.environ/BEDROCK_API_KEY"

  # GPT-5.4 — 最佳性价比
  - model_name: "gpt-5.4"
    litellm_params:
      model: "openai/openai.gpt-5.4"
      api_base: "https://bedrock-mantle.us-east-2.api.aws/openai/v1"
      api_key: "os.environ/BEDROCK_API_KEY"

  # GPT-5.4 (Oregon fallback)
  - model_name: "gpt-5.4"
    litellm_params:
      model: "openai/openai.gpt-5.4"
      api_base: "https://bedrock-mantle.us-west-2.api.aws/openai/v1"
      api_key: "os.environ/BEDROCK_API_KEY"
```

### 启动 Proxy

```bash
export BEDROCK_API_KEY="<your-bedrock-api-key>"
litellm --config config.yaml --port 4000
```

### 客户端调用（OpenAI SDK 兼容）

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://your-litellm-proxy:4000",
    api_key="your-litellm-master-key"
)

# Responses API（需要 openai SDK >= 2.28.0）
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

### 不经过 LiteLLM，直连 Bedrock

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
    text={"verbosity": "low"},
)
print(response.output_text)
```

### 关键配置说明

| 配置项 | 说明 |
|--------|------|
| `model` 前缀 | 用 `openai/` 而非 `bedrock/`（因为 mantle endpoint 本身是 OpenAI 兼容格式） |
| `api_base` | `https://bedrock-mantle.{region}.api.aws/openai/v1` |
| `api_key` | Bedrock API Key（不是 OpenAI 官方 Key，也不是 AWS Access Key） |
| SDK 版本 | 需要 `openai >= 2.28.0` 才支持 Responses API |

---

## 三、Codex 客户端配置（CLI / VS Code / Desktop App）

### Step 1：设置鉴权

**方式一：环境变量（CLI 直接使用）**

```bash
export AWS_BEARER_TOKEN_BEDROCK="<your-bedrock-api-key>"
```

**方式二：.env 文件（VS Code 插件 / Desktop App 使用）**

创建或编辑 `~/.codex/.env`：

```bash
AWS_BEARER_TOKEN_BEDROCK=<your-bedrock-api-key>
```

> Codex 优先使用 `AWS_BEARER_TOKEN_BEDROCK`；如果未设置，fallback 到 AWS SDK credential chain。

### Step 2：编辑配置文件

编辑 `~/.codex/config.toml`：

```toml
model = "openai.gpt-5.5"
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
region = "us-east-2"
```

### Step 3：重启客户端

- **CLI：** 退出重进，查看 `/status` tab 确认 model 和 provider
- **VS Code 插件：** 重新加载窗口（Ctrl/Cmd + Shift + P → Reload Window）
- **Desktop App：** 关闭重开

### 可选 Model ID

| Model ID | 说明 | 可用 Region |
|----------|------|------------|
| `openai.gpt-5.5` | 最强推理 | us-east-2 |
| `openai.gpt-5.4` | 性价比最优 | us-east-2, us-west-2 |
| `openai.gpt-oss-120b` | 大型通用 | 待确认 |
| `openai.gpt-oss-20b` | 轻量低延迟 | 待确认 |

### 配置文件位置汇总

```
~/.codex/
├── config.toml      # 模型、provider、region 配置
└── .env             # 环境变量（Desktop App / VS Code 插件读取）
```

---

## 四、可用 Region 总览

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

---

## 五、注意事项

1. **不要混淆 Key** — Bedrock API Key ≠ OpenAI 官方 API Key ≠ AWS Access Key
2. **不要用 OpenAI 的 base_url** — `https://api.openai.com/v1` 会直连 OpenAI，不经过 Bedrock
3. **Responses API vs Chat Completions** — Bedrock 上 GPT 模型用 `client.responses.create`，不是 `client.chat.completions.create`
4. **数据驻留** — 所有处理在你选择的 Bedrock Region 内完成，不出 AWS 环境
5. **计费** — 按 token 计费，无 seat license，无 per-developer 承诺
6. **状态存储** — Responses API 默认 `store=true`，对话数据保留 30 天用于 multi-turn；如不需要可设 `store=false`

---

## 六、通过 LiteLLM Proxy 接入（走统一网关）

如果团队已部署 LiteLLM Proxy，客户端可以通过 LiteLLM 统一接入 GPT 模型，无需直接持有 Bedrock API Key。

### LiteLLM config.yaml 配置

```yaml
model_list:
  - model_name: gpt-5.5
    litellm_params:
      model: openai/openai.gpt-5.5
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY

  - model_name: gpt-5.4
    litellm_params:
      model: openai/openai.gpt-5.4
      api_base: https://bedrock-mantle.us-east-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY

  # GPT-5.4 Oregon fallback（同名条目，router 自动负载均衡/故障转移）
  - model_name: gpt-5.4
    litellm_params:
      model: openai/openai.gpt-5.4
      api_base: https://bedrock-mantle.us-west-2.api.aws/openai/v1
      api_key: os.environ/BEDROCK_MANTLE_API_KEY
```

> **原理**：LiteLLM 使用 `openai/` provider，调用时自动拼接 `api_base + /responses`，最终打到 `bedrock-mantle.{region}.api.aws/openai/v1/responses`。客户端通过 LiteLLM 的 `/v1/responses` 端点调用即可，无需关心 Bedrock 鉴权。

> **已知限制**：LiteLLM v1.84.3 尚未原生支持 mantle Responses API 路由（见 [issue #29463](https://github.com/BerriAI/litellm/issues/29463)），以上配置为 workaround。GPT 调用不会出现在 LiteLLM UI 的对话日志中（spend logging 不覆盖 `/v1/responses`）。

### Codex Desktop 接入 LiteLLM Proxy

编辑 `~/.codex/config.toml`，在**文件顶部**添加 `model_provider`（必须在顶部，否则 Codex 默认直连 OpenAI 官方）：

```toml
model = "openai.gpt-5.5"
model_provider = "litellm-bedrock"   # 必须在顶部指定，否则 401

[model_providers.litellm-bedrock]
name = "LiteLLM Bedrock GPT"
base_url = "https://<your-litellm-domain>/v1"
wire_api = "responses"               # 告诉 Codex 用 Responses API

[profiles.bedrock-55]
model = "openai.gpt-5.5"
model_provider = "litellm-bedrock"

[profiles.bedrock-54]
model = "openai.gpt-5.4"
model_provider = "litellm-bedrock"
```

编辑 `~/.codex/.env`（文件不存在时手动创建）：

```bash
OPENAI_API_KEY=<LiteLLM-virtual-key>   # LiteLLM 虚拟 key，不是 Bedrock Key
```

### 常见问题

**Q1：启动后报 `401 Unauthorized`，url 显示 `api.openai.com`**

原因：`config.toml` 顶部没有指定 `model_provider`，Codex Desktop 默认走 OpenAI 官方。

解决：在 `config.toml` **文件顶部**（第一个 section 之前）加上：
```toml
model_provider = "litellm-bedrock"
```

**Q2：报 `400 Tool type 'web_search' is not supported`**

原因：Codex Desktop 内置 web_search 功能，请求里自动带了 `web_search` tool，但 Bedrock mantle 只支持 `function, mcp, custom, namespace, tool_search` 类型。

解决：在 `config.toml` 顶部禁用 web search：
```toml
web_search = "disabled"
```

---

## 参考链接

- [AWS Blog: Get started with OpenAI GPT-5.5, GPT-5.4 on Bedrock](https://aws.amazon.com/cn/blogs/aws/get-started-with-openai-gpt-5-5-gpt-5-4-models-and-codex-on-amazon-bedrock/)
- [OpenAI on Amazon Bedrock 官方页面](https://aws.amazon.com/bedrock/openai/)
- [Bedrock Mantle Responses API 文档](https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html)
- [Bedrock API Key 生成](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)
- [OpenAI Cookbook: Getting Started with OpenAI on Bedrock](https://developers.openai.com/cookbook/examples/partners/aws/openai_models_with_amazon_bedrock)
- [LiteLLM Bedrock 文档](https://docs.litellm.ai/docs/providers/bedrock)
