# LLM 网关选型评估：LiteLLM vs Bifrost vs new-api

> 调研日期：2026-06-12（**2026-07-27 有一处修订，见 [超时](#超时换-bifrost-解决不了重要) 一节**）
> 背景：当前生产用 LiteLLM（EKS us-east-1 + Docker Tokyo）。评估是否有更优替代方案，并为未来选型留档。
> 结论先行：**保持 LiteLLM；Bifrost 作为唯一有效备选（触发条件见下）；new-api 不推荐。**
> ⚠️ 2026-07-27 修订要点：原文"超时与网关无关"**不完整** —— 网关的超时**实现质量**是一个真实变量（LiteLLM v1.84.3 的 `/v1/messages` 路由写死 600s、忽略所有超时配置）。选型时必须验证超时配置**在目标路由上**是否真生效，不能只看有没有该配置项。总体决策不变（仍不换网关）。

---

## 1. 候选横向对比

| 维度 | **LiteLLM（现状）** | **Bifrost** | **new-api** |
|---|---|---|---|
| 仓库 | BerriAI/litellm | maximhq/bifrost | QuantumNous/new-api（fork 自 one-api） |
| 语言 | Python | Go | Go |
| 许可证 | MIT（宽松） | Apache-2.0（宽松） | **AGPL-3.0 + Section 7 署名/回链（传染性，需法务）** |
| 定位 | 企业 LLM 网关 | 企业 LLM 网关（高性能） | **API 分销/转售 + AI 资产管理（国内市场）** |
| 性能 | Python，一般 | 自称 50x faster，5000 RPS 仅 11µs 开销 | Go，未给基准 |
| **Bedrock IRSA / STS 短期凭证** | ✅ | ✅（LoadDefaultConfig 默认凭证链，文档点名 EKS IRSA） | ❌ **仅静态 AK/SK 或 API Key Bearer** |
| **web_search 拦截 + SearXNG 注入** | ✅ 现成 callback（websearch_interception） | ⚠️ 需自研（PreLLMHook 或 MCP Agent Mode） | ❌ 无机制 |
| Vertex/Gemini | ✅ | ✅ | ✅（vertex 渠道） |
| 企业 RBAC / 审计 | ✅ team/key RBAC | ✅ governance | ⚠️ 弱 |
| OpenAI 兼容 API / 流式 / 工具调用 | ✅ | ✅ | ✅ |
| spend log → Postgres | ✅ Aurora | ✅ Postgres | ✅ |
| 全量日志 → S3 | ✅ s3_v2 | ✅ S3/GCS（object_storage，非 enterprise 限定） | 未确认 |
| EKS Helm 部署 | ✅（当前单镜像） | ✅ 官方 Helm | ✅ |
| **非流式 `/v1/messages` 超时上限**（2026-07-27 补测，详见 §5） | 🔴 **写死 600s，所有超时配置无效**（v1.84.3 bug #30836；v1.94.0-dev.2+ 已修） | 🟢 **可配 1200s+，无上限** | 见 §5 |
| **对本项目适配度** | 🟢 最高 | 🟡 可作备选 | 🔴 不推荐 |

---

## 2. Bifrost 详细评估（已逐页核实官方文档）

来源：`docs.getbifrost.ai`、`github.com/maximhq/bifrost`

### 能平迁的（核实确认）
- **Bedrock 鉴权**：`bedrock_key_config` 支持 4 种流程 —— 显式 key / **默认凭证链（文档点名 `EKS IRSA: AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN`）** / STS AssumeRole（role_arn+external_id）/ API Key Bearer。**IRSA 完整支持，这是关键。**
- **日志**：`logs_store` 支持 Postgres；`logs_store.object_storage` 支持 **S3**（+GCS），可 `disable_content_logging` 关消息体（对应零留存口径）。
- **插件**：`PreLLMHook` / `PostLLMHook`，内置 HTTP client pool，可 mid-request 调外部服务。PreHook 正序、PostHook 反序，支持 short-circuit。
- virtual key / 预算 / 限流 / RBAC / UI / Prometheus / fallback / 多租户 / OIDC —— 全有。

### 需自研 / 待实测的
- 🟡 **web_search 拦截**：无现成功能。两条自研路径：(1) PreLLMHook 检测 web_search 工具→调 SearXNG→注入；(2) SearXNG 包成 MCP server + Agent Mode 自动执行。**无论哪条，拦截仍需非流式，超时问题不变。**
- 🟡 **`/v1/messages` 原生 passthrough**：仅"drop-in replace Anthropic SDK"，未逐字确认。你的 Claude Code 走这条，需实测。
- 🟡 **多副本共享状态**：依赖外部 Postgres（应用层应无状态），但多副本下 spend/budget 一致性（LiteLLM 靠 Redis）未确认，EKS 多副本需实测。

### 超时：换 Bifrost 解决不了（重要）
超时根因不在网关：
```
客户端 → CloudFront(120s) / ALB(600s) → 网关 → Bedrock(非流式大请求生成 >600s)
              ↑ 入口层砍连接                       ↑ 真正的慢
```
- 入口层超时（ALB/CloudFront）是 AWS 的，与网关品牌无关。
- Bedrock 生成时间与网关无关。
- Bifrost 的 `default_request_timeout_in_seconds` 和 LiteLLM 的 timeout 一样是可配项，从不是瓶颈。
- **结论：超时 =「非流式大请求生成时间 > 入口层超时上限」，等式里没有"网关"变量。换 Bifrost 超时照旧。**

> #### ⚠️ 修订（2026-07-27）：上面这条结论**不完整** —— 存在一个真实的"网关变量"
>
> 上面的分析漏掉了一类超时：**网关自身的实现缺陷**。2026-07-27 排查客户 Claude Code 报 `API Error: The operation timed out`，在美东 LiteLLM **v1.84.3** 上定位到：
>
> **LiteLLM 的 `/v1/messages`（anthropic_messages）路由在发起 HTTP 请求时不读任何超时配置，写死用 httpx 默认的 600s read timeout。**
> `router_settings.timeout` / `litellm_settings.request_timeout` / per-model `timeout` / `stream_timeout` **四个配置对该路由全部无效**（Router 算对了 1200 放进 `kwargs["timeout"]`，但 handler 不读）。仅影响**非流式**；流式正常跑满 1200s。
> 上游 issue **#30836**，修复 PR #33418（2026-07-15 merged），**修复未 backport 到 1.84~1.93 任何 stable**；截至 2026-07-27 最新 stable 仍是 v1.93.0（无修复），v1.94.0 只到 rc.3。
>
> **对本文结论的影响：**
> - ✅ **入口层那部分仍然成立** —— ALB/CloudFront 上限、Bedrock 生成时间确实与网关品牌无关。
> - ❌ **但"等式里没有网关变量"是错的** —— 网关的超时**实现质量**是一个独立变量。同样配 1200s，LiteLLM v1.84.3 在该路由上实际只跑 600s。
> - 📌 **选型启示**：评估网关时，不能只看"有没有 timeout 配置项"（Bifrost 的 `default_request_timeout_in_seconds`、LiteLLM 的 `timeout` 都"有"），**必须验证该配置在目标路由上是否真的生效** —— 尤其 `/v1/messages` 这类非 OpenAI 格式的路由，往往是二等公民（LiteLLM 的 `/chat/completions` 和 `/responses` 都正确传了 timeout，**只有 `/v1/messages` 没接线**）。上文"`/v1/messages` 原生 passthrough 需实测"这条 🟡 风险项，事后看是**低估了**：要测的不只是"能不能用"，还有"超时/重试/流式等横切能力在这条路由上是否等价"。
>
> **本次决策仍是不换网关**：换网关要重做 websearch_interception、`/mcp/` 网关、BedrockTeamTagHook 成本归因、S3+Athena 日志体系、虚拟 key/team/budget 迁移；而这个 bug 一次版本升级即可修复，实际影响仅 0.14%（当日 2/1449 次请求）。等 v1.94.0/v1.95.0 stable，先在 SG 验证再升美东。
>
> 详见 memory `project-litellm-v1-messages-600s-timeout-bug`、buglog `bug-049`。

### EKS 部署可行性
✅ 可行，形态与现状几乎相同：官方 Helm、外部 Postgres、IRSA。多副本/HPA/Redis 共享态需实测。

---

## 3. new-api 详细评估

来源：`github.com/QuantumNous/new-api`、源码 `relay/channel/aws/`

- **出身**：fork 自 one-api（MIT），定位 AI 资产管理 + **API 转售/分销**，强中国市场属性（BaoTa、EPay、Stripe、TZ=Shanghai）。
- **Bedrock 鉴权（致命）**：源码 `aws/adaptor.go` 仅 `ClientModeApiKey`（`<key>|<region>` Bearer）与 `ClientModeAKSK`（静态 AK/SK），**无 IRSA/STS/默认凭证链**。
- 无 web_search 拦截，无插件/中间件扩展机制。
- 企业 RBAC/审计偏弱。

### 不推荐的硬伤
1. 🔴 **Bedrock 不支持 IRSA，强制静态 AK/SK** —— 与应答核心合规卖点「IRSA 零长期 Key」直接冲突。
2. 🔴 **AGPL-3.0 + 署名回链** —— 对客交付（零跑）有传染性风险，需法务评估；远不如 MIT/Apache 省心。
3. 🔴 定位是 API 分销/转售，非企业专属合规接入，赛道不符。

---

## 4. 最终建议

| 优先级 | 方案 | 说明 |
|---|---|---|
| 1 | **LiteLLM（现状）** | 保持。当前所有问题（超时/安全）都有解，应答已围绕它写好。 |
| 2 | **Bifrost** | 唯一有效备选。**触发条件：Python 性能成为高并发瓶颈**，且愿意投入自研 web_search 插件。换它**不能解决超时**（超时与网关无关）。 |
| ✗ | **new-api** | 不推荐。IRSA 缺失 + AGPL 传染性 + 定位不符。 |

### 关键认知（避免重复绕弯）
- ~~**换网关治不了超时**~~ —— **2026-07-27 修订：这条不完整，见 §5。** 入口层（ALB/CloudFront）与 Bedrock 生成时间确实与网关无关，但**网关自身的超时实现质量是一个独立变量**，且三个候选表现差异极大。
- **换网关的唯一合理理由是性能**（Go vs Python），不是超时、不是安全 —— 这条仍成立（超时有更便宜的解：升级 LiteLLM）。

---

## 5. 非流式 `/v1/messages` 超时实测对比（2026-07-27 补充）

> 起因：客户 Claude Code 报 `API Error: The operation timed out`，最终定位到 **LiteLLM 自身的实现缺陷**，而非入口层。这证明 §4 原结论"超时与网关无关"不完整，故对三个候选 + 新增候选 Portkey 逐个做了**源码级**核实。

### 5.1 结论表

| | **LiteLLM v1.84.3**（现状） | **Bifrost** | **Portkey**（自托管） | **new-api** |
|---|---|---|---|---|
| 原生 Anthropic `/v1/messages` 入站 | ✅ | ✅ `POST /anthropic/v1/messages` | ✅ | ✅（还支持 `x-api-key`） |
| 超时配置项 | `router_settings.timeout` 等 4 处 | `network_config.default_request_timeout_in_seconds`（默认 300） | `request_timeout`（ms，默认无） | `RELAY_TIMEOUT`（env，秒，**默认 0=无限**） |
| **配置在该路由上真生效吗** | 🔴 **否** | 🟢 **是** | 🟡 传对了，但被运行时卡住 | 🟢 **是** |
| **非流式实际上限** | **600s** | **可配 1200s+，无上限** | **~300s** | **可配 1200s+，无上限（默认无限）** |
| 超时错误形态 | `litellm.Timeout`（干净） | 504 | **500 `TypeError: fetch failed`**（不干净） | — |
| 上游修复 | ✅ v1.94.0-dev.2+（rc 阶段） | 无此缺陷 | ❌ issue #1127 开 1 年+未修 | 无此缺陷 |
| 要修得怎么办 | 等版本升级/打补丁 | 不用 | **fork 改源码** | 不用 |

> **注意这张表最反直觉的一点：四个候选里只有 LiteLLM（我们的现状）有这个缺陷。** Bifrost 和 new-api 都正确处理，Portkey 是被 Node 运行时卡住（性质不同）。这不是"我们选错了网关" —— LiteLLM 在其它维度（IRSA、websearch 拦截、RBAC、成本归因）仍是最适配的，但说明**超时实现质量必须单独验证，不能假定成熟项目一定做对**。

### 5.2 LiteLLM：`/v1/messages` 路由写死 600s（本次事故根因）

`/v1/messages`（anthropic_messages）路由发 HTTP 请求时**不读任何超时配置**：
- 600s 来自 `litellm/constants.py:441` `COMPLETION_HTTP_FALLBACK_SECONDS = 600.0`
- Router **算对了** 1200 并放进 `kwargs["timeout"]`（`router.py:2708`），但 `async_anthropic_messages_handler`（`llm_http_handler.py:1917-2119`）**零处引用 timeout**，`.post()` 不带 `timeout=` → 回落 600s
- ⚠️ **`router_settings.timeout` / `litellm_settings.request_timeout` / per-model `timeout` / `stream_timeout` 四者全部无效**
- **只影响非流式**；流式正常跑满 1200s
- 同文件的 `/responses` 路由（`async_response_api_handler`，`:2285`）**有**正确传 timeout —— **说明这是该路由漏接线，不是设计取舍**

**版本**：上游 issue **#30836**，修复 PR #33418（2026-07-15 merged）。**未 backport 到 1.84~1.93 任何 stable**（逐 tag grep `_resolve_anthropic_messages_timeout` + git ancestry 确认）。注意 **`v1.84.13` 这个 tag 不存在**，1.84 线止于 v1.84.10。截至 2026-07-27 最新 stable 是 v1.93.0（无修复），v1.94.0 仅到 rc.3。

### 5.3 Bifrost：唯一正确处理的（🟢）

配置被正确传进 HTTP client，两条路径都验证过：
- Anthropic：`core/providers/anthropic/anthropic.go:85-92` → fasthttp `ReadTimeout`/`WriteTimeout`
- Bedrock：`core/providers/bedrock/bedrock.go:80-125` → `http.Client{Timeout: requestTimeout}`

**无上限**：校验只有下限（`core/schemas/provider.go:566-568`，`<=0 则取 300`），对比 `stream_idle_timeout_in_seconds` 明确有 `.max(3600)` —— 说明不设上限是**刻意的**。配 1200s 端到端生效。

方向也是对的：**非流式受配置约束，流式只受 per-chunk idle（`stream_idle_timeout_in_seconds`，默认 120）管** —— 正好是 LiteLLM 那个 bug 的反面。

**但有两个限制**（迁移前必知）：
1. 超时**只能按 provider 配**，不能 per-model / per-request（issue #1406、PR #3292 均未合并）。粒度**比现在的 LiteLLM 差**。
2. **流式侧有 Bedrock 长请求已知问题**：#5211（安静的流被中间层掐断报 unexpected EOF）、#5010/#5214（无服务端 SSE keepalive 心跳）、#5213（提议 HTTP/2 PING）。迁移前需自行实测。

### 5.4 Portkey（新增候选）：比现状更差（🔴）

**它没有 LiteLLM 那个 bug**（`request_timeout` 正确经 AbortController 传入 fetch，无硬编码常量），**但结果更糟**：

自托管跑在 Node 上，`fetch` 即 undici，**undici 默认 `headersTimeout`/`bodyTimeout` = 300s**，而 Portkey **从未配置 dispatcher**（全仓 grep `setGlobalDispatcher`/`headersTimeout`/`bodyTimeout` **零命中**，undici 甚至不是直接依赖）。

后果：
- 设 `request_timeout: 1200000` **无效** —— 300s 时 undici 先抛 `HeadersTimeoutError`
- 返回**不干净的 500**（`fetch failed / HeadersTimeoutError / TypeError`），连 408 都不是
- **无任何环境变量可调**
- 非流式恰是最惨路径：undici 的 300s measure 的是"等 header 的时间"，流式 header 很快到所以没事，**非流式要等整个生成完才有 header**

上游 issue **#1127**（2025-06-06 开，**至今 OPEN**），维护者自认：*"native fetch from node js has a default 300s timeout... it's entirely strange that this is not configurable"*，2025-12-24 仍 *"keeping this open"*。要修**只能 fork**（装自定义 undici Agent + `setGlobalDispatcher`）。

### 5.5 new-api：也没有此缺陷（🟢，但仍不推荐——理由与超时无关）

超时被正确应用在两条路径上：
- 通用 HTTP relay：`service/http_client.go:101-110` → `if common.RelayTimeout != 0 { client.Timeout = ... }`，请求经 `relay/channel/api_request.go:478` 发出
- **Bedrock AK/SK 路径**（走 AWS SDK 而非裸 http）：`relay/channel/aws/relay-aws.go:43-48` `newAwsInvokeContext()` 用 `context.WithTimeout`，且把同一个 `http.Client` 注入 SDK。此处**曾经**是真 bug（AWS 侧不应用 relay timeout），已由 PR #2580 修复（2026-01-05 merged）

**无任何上限**：`RELAY_TIMEOUT` 只有 `!= 0` / `<= 0` 三处比较，无 clamp、无 max 校验。默认 **0 = 无限制**。服务端也没设 `ReadTimeout`/`WriteTimeout`（`main.go:207-210`，提议加的 PR #4342 被关闭未合并），无 gin timeout 中间件。

原生 Anthropic 支持完整：路由 `router/relay-router.go:88-90`，鉴权特判 `x-api-key`（`middleware/auth.go:370-373`），Bedrock 侧 `formatRequest` 会打 `anthropic_version: bedrock-2023-05-31` 并透传 `anthropic-beta`（`relay/channel/aws/dto.go:34-57`）。

**但仍不推荐 —— 原因和超时无关**（§3 的硬伤不变）：
- ❌ **IRSA 缺失被再次证实**：`relay-aws.go:56-78` 只用 `credentials.NewStaticCredentialsProvider`，**没有默认凭证链**，即只能静态 AK/SK
- ❌ AGPL-3.0 传染性
- ⚠️ 超时只有**全局 env**（无 per-channel / per-model / UI），且设了 `RELAY_TIMEOUT` **会同时限制流式**（已知设计缺陷，PR #6300 提议拆分但被关闭未合并）
- ⚠️ 附带发现一个疑似真 bug（与超时无关）：`relay/channel/aws/adaptor.go:99` 在 Bedrock **api_key 模式**下 `Sprintf` 参数顺序颠倒，model ID 落进 region 槽位。仅影响 bearer token 模式，AK/SK 模式不受影响。未见 issue

补充：流式另有独立空闲超时 `STREAMING_TIMEOUT`（默认 300s，`relay/helper/stream_scanner.go:88`），但**不覆盖** Bedrock AK/SK 事件流路径（那条不走 StreamScannerHandler）。

### 5.6 对选型方法论的启示（本节最大价值）

1. **不能只看"有没有 timeout 配置项"**。三个候选**都有**该配置项，但实际上限是 600s / 1200s+ / 300s —— 差异全在实现。**必须验证配置在目标路由上是否真生效**。
2. **非 OpenAI 格式的路由往往是二等公民**。LiteLLM 的 `/chat/completions` 和 `/responses` 都正确传了 timeout，**只有 `/v1/messages` 漏了**。Claude Code 走的正是这条路由。
3. **语言/运行时会引入隐式上限**。Portkey 的 300s 不在它自己代码里，而在 Node/undici 默认值 —— 这类坑**只能靠读源码 + 翻 issue 发现**，文档不会写。
4. **原文 §2 那条 🟡 "`/v1/messages` passthrough 需实测"事后看是低估了**：要测的不只是"能不能用"，还有超时/重试/流式等横切能力在该路由上**是否等价**。

### 5.7 本次决策：不换网关，但**必须在服务端修**

⚠️ **不要用"当日只失败 2 次 / 0.14%"来判断严重性** —— 那是**前期小规模测试**的数据，会严重低估规模化后的影响：

- 撞 600s 的画像不是"上下文大"，而是**大输入 + 大输出的非流式请求**（多 agent 汇总正是这一类）。实测非流式即使输入 150k token，只要输出小就只花几秒
- 当日非流式耗时 >60s 的 9 次里**有 3 次失败**，且分布在**3 个不同的 virtual key**（即 3 个不同使用者），不是个别用户的用法问题
- 成功的长请求已逼近危险区：144s / 112s / 100s（输出 6800~9400 token）—— **输出再大几倍就撞 600s**
- 多 agent 大规模铺开后，这类请求的绝对数量线性增长，失败率会显著高于 0.14%

❌ **"让客户自己提前 `/compact` / 减少 teammate"不是可接受的方案** —— 那是把服务端缺陷转嫁给每个用户，规模化后不可行。

**不换网关的理由（迁移代价，与严重性无关）**：需重做 websearch_interception（Bifrost 需自研插件）、`/mcp/` 网关（AgentCore WebSearch）、BedrockTeamTagHook 成本归因、Codex additional_tools 摊平 hook、S3+Athena 日志体系、虚拟 key/team/budget 迁移。

**服务端可选路径**：

| 方案 | 根治 | 说明 |
|---|---|---|
| **A. 打补丁自建镜像**（把 PR #33418 backport 到 v1.84.3） | ✅ | 改动面极小（把已算好的 timeout 传进 `.post()`），不跳大版本 → 规避上次 v1.90 升级引入 4 个回归的风险。已有自建镜像能力（kiro-gateway 在 ECR） |
| B. 升级到含修复的正式版 | ✅ | 需等 v1.94.0/v1.95.0 stable（截至 2026-07-27 仅 rc/dev），且要重新评估大版本回归 |
| C. 上 rc/dev 版 | ✅ | ❌ 不建议：预发布版上生产风险大于 bug 本身 |

**结论：优先评估方案 A（打补丁自建镜像），在 SG 测试环境验证后上美东。**

> 详见 memory `project-litellm-v1-messages-600s-timeout-bug`（根因+版本核实）、`project-athena-litellm-s3-logs`（诊断方法：真因只在 S3 日志 `error_str` 里，pod 日志和 SpendLogs 都看不到）、buglog `bug-049`。
