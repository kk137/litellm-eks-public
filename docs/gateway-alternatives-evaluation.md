# LLM 网关选型评估：LiteLLM vs Bifrost vs new-api

> 调研日期：2026-06-12
> 背景：当前生产用 LiteLLM（EKS us-east-1 + Docker Tokyo）。评估是否有更优替代方案，并为未来选型留档。
> 结论先行：**保持 LiteLLM；Bifrost 作为唯一有效备选（触发条件见下）；new-api 不推荐。**

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
- **换网关治不了超时** —— 超时在入口层（ALB/CloudFront）与 Bedrock 生成时间。解法：调 ALB idle / web_search 流式化（难，非流式是拦截必须）/ UI-API 分路。这些在任何网关上做都一样。
- **换网关的唯一合理理由是性能**（Go vs Python），不是超时、不是安全。
