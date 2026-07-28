# LLM API 协议速查 — chat/completions · responses · messages · Converse · InvokeModel

> 面向在本网关（LiteLLM）上接入模型、排查 `404` / `does not support` / 参数格式类报错的人。
> 所有请求体/响应体样例均为 **2026-07** 在本环境实测抓取（gpt-5.6-luna / grok-4.3 / claude-sonnet-4-6）。

## 一句话结论

- 客户端方言主要就三家：**OpenAI**（`/chat/completions` + `/responses`）、**Anthropic**（`/v1/messages`）、**Google**（`generateContent`）。
- **Bedrock 的 `Converse` / `InvokeModel` 不是客户端方言**，是「Bedrock 平台把各家模型统一到自己接口」的平台层。
- **LiteLLM 靠 `model:` 前缀在这些协议之间翻译**。前缀写错 = 打到错协议/错端点 → 报错（见文末「常见报错」）。

---

## 两大阵营

### 阵营一 · OpenAI 系（Mantle 上的 GPT / Grok 走这个）

在 Bedrock Mantle 上通过 `https://bedrock-mantle.{region}.api.aws/openai/v1/{chat/completions|responses}` 暴露。
**两个端点都存在**；但**某个模型支持哪个端点是模型级的**（见下表），别把「端点存在」当成「模型都支持」。

| 端点 | 请求体关键字段 | 响应关键结构 | 定位 |
|---|---|---|---|
| `/v1/chat/completions` | `messages: [{role, content}]` + `max_tokens` | `choices[].message` | OpenAI 最经典的对话 API，多数「OpenAI 兼容」客户端默认用它 |
| `/v1/responses` | `input` + `max_output_tokens` | `output[]`（内含 `message`/`reasoning`/`function_call` 等 item） | OpenAI 较新的 Responses API（reasoning、tool、状态管理） |

**模型支持矩阵（本环境实测）：**

| 模型 | `/chat/completions` | `/responses` |
|---|---|---|
| gpt-5.4 / 5.5 / 5.6（Sol/Terra/Luna） | ❌ 不支持（模型级拒绝） | ✅ **唯一可用** |
| grok-4.3 | ✅ 支持 | ✅ 支持 |

> gpt-5.x 打 `/chat/completions` 的实测报错（**模型级** `400`，不是端点不存在的 `404`）：
> `The model 'openai.gpt-5.6-luna' does not support the '/v1/chat/completions' API`

### 阵营二 · Bedrock 原生系（Claude / Nova 走这个）

在 `bedrock-runtime.{region}.amazonaws.com` 上，端点形如 `/model/{modelId}/{invoke|converse}`。

| 端点 | 请求体 | 定位 |
|---|---|---|
| `InvokeModel`（`/model/{id}/invoke`） | **每个模型私有格式**（Claude=Anthropic 格式、Nova=Nova 格式，互不相同） | Bedrock 最早的原生单发推理端点，基本不直接用 |
| `Converse`（`/model/{id}/converse`） | **跨模型统一的 `messages` 格式**（多轮 / tool use / system） | Bedrock 后来推的统一对话 API，**本环境 Claude/Nova 走这个** |

> 本环境的 per-team 成本归因 hook 靠 `Converse` 的 `requestMetadata` 打 team 标签 —— 只有 Converse 路径认这个字段。

### 阵营三之外 · Anthropic / Google（客户端方言）

| 端点 | 谁家 | 请求体关键字段 | 响应关键结构 | 本环境哪里用 |
|---|---|---|---|---|
| `/v1/messages` | Anthropic | `messages` + **顶层独立 `system`** + `max_tokens` | `content: [{type:"text"\|"tool_use", ...}]` | **Claude Code 客户端**、kiro-gateway |
| `generateContent` | Google Gemini | `contents: [{parts:[...]}]` | `candidates[].content.parts` | gemini-3.5-flash 等 |

> `/v1/messages` 与 OpenAI `chat/completions` 长得像但**不兼容**：`system` 是顶层字段（不塞进 messages）、工具用 `tool_use`/`tool_result` block、响应是 `content[]` 而非 `choices[]`。
> 注意：路径是 `/v1/messages`，**没有 `anthropic/` 前缀**——`anthropic/` 是 LiteLLM 内部的 provider 标记，不是 URL 路径。

---

## 同一个 "Reply exactly: pong" 在三种协议下的请求/响应（实测）

### A) OpenAI `/responses`（gpt-5.6-luna）

```jsonc
// 请求 POST /openai/v1/responses
{ "model": "openai.gpt-5.6-luna", "input": "Reply exactly: pong", "max_output_tokens": 16 }
// 响应（节选）
{ "output": [ { "type": "message",
    "content": [ { "type": "output_text", "text": "pong", "annotations": [] } ] } ] }
```

### B) OpenAI `/chat/completions`（grok-4.3）

```jsonc
// 请求 POST /openai/v1/chat/completions
{ "model": "xai.grok-4.3", "messages": [ { "role": "user", "content": "Reply exactly: pong" } ], "max_tokens": 16 }
// 响应（节选）
{ "choices": [ { "message": { "role": "assistant", "content": "pong" } } ],
  "object": "chat.completion", "usage": { ... } }
```

### C) Anthropic `/v1/messages`（claude-sonnet-4-6，经 LiteLLM → Bedrock Converse）

```jsonc
// 请求 POST /v1/messages   (header: anthropic-version: 2023-06-01)
{ "model": "claude-sonnet-4-6", "max_tokens": 16,
  "system": "You are terse.",                                  // ← system 是顶层字段
  "messages": [ { "role": "user", "content": "Reply exactly: pong" } ] }
// 响应（节选）
{ "type": "message", "role": "assistant",
  "content": [ { "type": "text", "text": "pong" } ],           // ← content[] 不是 choices[]
  "stop_reason": "end_turn", "usage": { ... } }
```

三者对比：`input`(str) vs `messages[]`+`max_tokens` vs `messages[]`+顶层`system`+`max_tokens`；响应 `output[]` vs `choices[]` vs `content[]`。

---

## LiteLLM 前缀 → 后端协议 映射

LiteLLM 是**协议翻译中枢**：客户端用任意方言进来，LiteLLM 按 `model:` 前缀翻译成后端要的方言出去。

| `model:` 前缀 | 翻译成的后端协议 | 本环境示例 |
|---|---|---|
| `openai/...` | OpenAI（`/chat/completions` 或 `/responses`） | `openai/openai.gpt-5.6-sol`、`openai/xai.grok-4.3` |
| `anthropic/...` | Anthropic `/v1/messages` | kiro-gateway（`anthropic/claude-...`） |
| `bedrock/...` | Bedrock `Converse` / `InvokeModel` | `bedrock/anthropic.claude-opus-4-8` |
| `gemini/...` | Google `generateContent` | `gemini/gemini-3.5-flash` |

**真实链路举例：**
- Claude Code（发 Anthropic `/v1/messages`）→ LiteLLM → 配 `bedrock/anthropic.claude-opus-4-8` → **翻译成 Bedrock `Converse`** 打后端。客户端方言 = Anthropic，后端方言 = Bedrock，LiteLLM 转。
- Codex（发 OpenAI `/responses`）→ LiteLLM → `openai/openai.gpt-5.6-sol` → 转发到 Mantle `/openai/v1/responses`。

---

## 常见报错 → 病根（前缀/端点/协议对不上）

| 报错 | 病根 | 修法 |
|---|---|---|
| `404 Not Found`，URL 里出现 `/openai/v1/model/{id}/invoke` | 把 Mantle 的 OpenAI 兼容模型当成 **Bedrock 原生**（`model` 写成 `bedrock/...` 或裸 id），LiteLLM 去拼 `InvokeModel` 路径，而 Mantle 没这条 | `model` 前缀改 **`openai/`**，`api_base` 到 `/openai/v1` 为止（别自己拼 `/responses` 或 `/invoke`） |
| `400 The model '...' does not support the '/v1/chat/completions' API` | 模型（如 gpt-5.x）**只支持 `/responses`**，客户端却用了 chat/completions | 客户端改用 `responses.create`（Responses API）；LiteLLM 侧 `openai/` 前缀会自动补 `/responses` |
| 工具参数 `SchemaError(Missing key ...)` / 嵌套 `parameters` 信封 | **模型侧**间歇畸形输出（非协议问题，见 Mantle luna 已知问题） | 与本协议无关；换模型/区域或等模型侧修复 |

> 记忆口诀：**`openai/` → OpenAI 协议（chat/completions 或 responses）；`bedrock/` → Bedrock 协议（Converse/InvokeModel）；`anthropic/` → `/v1/messages`；`gemini/` → generateContent。** 前缀选错就打到错协议。

---

## 参考

- 本仓 [docs/bedrock-openai-gpt-guide.md](bedrock-openai-gpt-guide.md) — GPT 经 Bedrock Mantle 接入（直连 + LiteLLM 两条路径）
- 本环境 `04-configmap.yaml` — 各模型的 `model:` 前缀 + `api_base` 实际写法
