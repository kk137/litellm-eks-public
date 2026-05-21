# CloudFront 配置要点：LLM API 代理场景

基于 AWS 官方文档验证，记录 CloudFront 代理 LiteLLM（LLM API）时的关键配置项。

> 来源：https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html
> 来源：https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html

---

## 配置总览

| # | 配置项 | 推荐值 | 默认值 | 原因 |
|---|--------|--------|--------|------|
| 1 | Cache Policy | `CachingDisabled` | — | POST 动态内容不可缓存 |
| 2 | Origin Response Timeout | **60s** | 30s | Opus 首 token 10-30s，默认 30s 不够 |
| 3 | Response Completion Timeout | **300s** | 无限制 | 长对话 streaming 可能持续 2-5 分钟 |
| 4 | Origin Request Policy | `AllViewerAndCloudFrontHeaders-2022-06` | — | 必须转发 Authorization/Content-Type 等 |
| 5 | Allowed Methods | 全部 7 种 | GET/HEAD | LLM API 是 POST |
| 6 | Viewer Protocol Policy | `redirect-to-https` | — | 强制 HTTPS |
| 7 | Compress | 开启 | — | JSON 响应有压缩收益 |
| 8 | Keep-alive Timeout | 60s | 5s | 复用连接降低延迟 |

---

## 详细说明

### 1. Cache Policy: CachingDisabled

LLM API 全是 POST 请求，POST 响应本身不会被 CloudFront 缓存（只有 GET/HEAD 响应可缓存）。但显式设置 `CachingDisabled` (ID: `4135ea2d-6df8-44a3-9df3-4b5a84be39ad`) 确保：
- 不为响应分配 cache key
- 不存储任何响应内容
- 避免边缘情况下的意外缓存

### 2. Origin Response Timeout（核心配置）

**AWS 官方限制**：

| 项 | 值 |
|----|-----|
| 默认值 | **30 秒** |
| 可配范围 | 1-120 秒 |
| 可申请提高 | ✅（通过 Service Quotas） |

**行为说明**（来自 AWS 文档）：
- 对 POST 请求：origin 在 timeout 内未响应 → CloudFront 断连 → **不重试**（不同于 GET 会重试）
- 此超时是"两个 packet 之间的间隔"，不是总时间
- 一旦 streaming 开始（首 token 返回），后续 token 间隔只要 < 60s 就不会触发超时

**LLM 场景分析**：

| 模型 | 典型首 token 时间 | 30s 默认够？ | 60s 够？ |
|------|-----------------|-------------|---------|
| Claude Haiku 4.5 | ~300ms | ✅ | ✅ |
| Claude Sonnet 4.6 | ~800ms | ✅ | ✅ |
| Claude Opus 4.6 | ~1.5s（普通） | ✅ | ✅ |
| Claude Opus 4.6 extended thinking | 10-30s | ⚠️ 边界 | ✅ |
| Opus 超长 chain-of-thought | 可能 >30s | ❌ 504 | ✅ |

**结论**：设为 **60s** 足以覆盖所有当前模型。如需支持未来更慢的模型，可提高到 120s。

### 3. Response Completion Timeout（新发现）

**AWS 官方说明**：
> The time (in seconds) that a request from CloudFront to the origin can stay open and wait for a response. If the complete response isn't received from the origin by this time, CloudFront ends the connection.

| 项 | 值 |
|----|-----|
| 默认值 | **无限制**（不设则不强制） |
| 可配范围 | ≥ Response Timeout |

**LLM 场景**：
- 长对话 streaming 可能持续 2-5 分钟（生成几千 token）
- 如果不设此值 → CloudFront 不强制断连（✅ 对 streaming 友好）
- **建议：不设置此值**（保持默认无限制），或设 300s 作为安全上限

### 4. Origin Request Policy

必须转发以下 header 到 origin：

| Header | 用途 |
|--------|------|
| `Authorization` | Bearer token 鉴权 |
| `Content-Type` | `application/json` |
| `anthropic-version` | Anthropic SDK 要求 |
| `x-api-key` | 备用鉴权方式 |
| `Accept` | SSE streaming 需要 `text/event-stream` |

推荐使用 managed policy `AllViewerAndCloudFrontHeaders-2022-06` (ID: `33f36d7e-f396-46d9-90e0-52428a34d9dc`)，或 `AllViewerExceptHostHeader` (ID: `b689b0a8-53d0-40ab-baf2-68738e2966ac`)。

⚠️ **不要使用 `AllViewer`**（会转发 Host header），VPC Origin 场景下 Host header 应该由 CloudFront 设置为 origin domain。

### 5. Allowed Methods

| 设置 | 包含的方法 |
|------|-----------|
| GET, HEAD（默认） | ❌ 不支持 POST |
| GET, HEAD, OPTIONS | ❌ 不支持 POST |
| **全部 7 种** | ✅ GET/HEAD/OPTIONS/PUT/POST/PATCH/DELETE |

必须选**全部 7 种**，否则 POST 请求会返回 403。

### 6. Request Body 大小限制

**AWS 官方限制**：

| 场景 | 最大 body 大小 |
|------|---------------|
| **直传 origin（无 Lambda@Edge）** | **64 GB** |
| Lambda@Edge viewer-request 触发 | 40 KB |
| Lambda@Edge origin-request 触发 | 1 MB |
| WAF body 检查 | 16 KB（默认，可调高） |

**LLM 场景**：不使用 Lambda@Edge 时，body 大小不受限。即使超长 prompt（几万 token ≈ 几百 KB）也完全不是问题。

⚠️ **WAF 注意**：如果启用 WAF 并检查 request body，默认只检查前 16KB。对 LLM 请求无影响（WAF 主要做 IP/Rate limit，不需检查 body 内容）。

### 7. SSE Streaming 兼容性

**结论：完全兼容，无需特殊配置。**

原理：
- CloudFront 使用 **byte streaming**：从 origin 收到第一个 byte 就立即转发给 viewer
- `Transfer-Encoding: chunked` 原样透传
- `Content-Type: text/event-stream` 原样透传
- 不会 buffer 整个响应后再发送

```
LiteLLM Pod: data: {"content":"Hello"}\n\n
    ↓ 立即
Internal ALB → CloudFront Edge → 客户端看到 "Hello"
```

**验证方法**：
```bash
curl -sN https://litellm.<YOUR_DOMAIN>/v1/chat/completions \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-haiku45","messages":[{"role":"user","content":"count 1 to 5"}],"stream":true}'
# 应该逐 token 流式返回，响应头包含 x-cache: Miss from cloudfront
```

### 8. Keep-alive Timeout

| 项 | 值 |
|----|-----|
| 默认值 | **5 秒** |
| 可配范围 | 1-120 秒 |
| 推荐值 | **60s** |

设高一点的好处：CloudFront 与 origin 之间复用 TCP 连接，省去后续请求的 TCP+TLS 握手时间。

⚠️ **origin 端也必须配合**：ALB 的 idle timeout 必须 ≥ CloudFront keep-alive timeout。ALB 默认 idle timeout = 60s，刚好匹配。

---

## 安全加固（可选）

### Custom Origin Header 验证

在 CloudFront 添加 custom header：
```
X-CF-Secret: <随机生成的长字符串>
```

在 ALB 添加 listener rule：
```
如果 Header X-CF-Secret ≠ 预期值 → 返回 403
```

这样即使安全组配错暴露了 ALB，没有 secret header 也无法访问。

---

## 不需要担心的问题

| 担忧 | 实际情况 |
|------|---------|
| "POST body 有大小限制" | 64 GB，远超 LLM 需求 |
| "SSE 会被 buffer" | 不会，byte streaming 逐 chunk 透传 |
| "CloudFront 会缓存 API 响应" | POST 不可缓存 + CachingDisabled 双保险 |
| "超时导致 504" | 设 60s timeout，Opus 也够用 |
| "增加延迟" | 同区域多 ~5ms（一跳），跨区域反而更快 |

---

## 配置 Checklist

```
[ ] Cache Policy = CachingDisabled (4135ea2d-6df8-44a3-9df3-4b5a84be39ad)
[ ] Origin Request Policy = AllViewerAndCloudFrontHeaders 或 AllViewerExceptHostHeader
[ ] Allowed Methods = ALL (7 methods)
[ ] Viewer Protocol Policy = redirect-to-https
[ ] Origin Response Timeout = 60s
[ ] Response Completion Timeout = 不设（默认无限制）或 300s
[ ] Keep-alive Timeout = 60s
[ ] Compress = Enabled
[ ] Origin Protocol Policy = HTTPS-only
[ ] Minimum Origin SSL Protocol = TLSv1.2
```

---

## 之前文档的修正

| 项 | 之前说法 | 实际（经文档验证） |
|----|---------|------------------|
| Origin Response Timeout 最大值 | "60s（Enterprise 可更高）" | **120s**（标准账户即可，可申请更高） |
| Request Body 限制 | "46KB（Lambda@Edge）" | **64 GB**（不用 Lambda@Edge 就无实际限制） |
| Response Completion Timeout | 未提及 | **存在此配置**，对 streaming 很重要 |
| Keep-alive Timeout 默认 | 未明确 | **5s**（建议调高到 60s） |

---

## 关联文档

- [CLOUDFRONT-MIGRATION-PLAN.md](./CLOUDFRONT-MIGRATION-PLAN.md) — 零停机迁移步骤
- [CDN-ACCELERATION-ANALYSIS.md](./CDN-ACCELERATION-ANALYSIS.md) — 加速效果分析
- AWS 文档：[CloudFront Origin Settings](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- AWS 文档：[CloudFront Quotas](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html)
