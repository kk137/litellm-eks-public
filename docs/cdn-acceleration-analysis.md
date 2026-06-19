# CloudFront / Global Accelerator 加速分析

针对 LiteLLM on EKS (us-east-1) 方案，评估是否需要在 ALB 前加 CloudFront 或 Global Accelerator。

**结论：取决于客户端地理位置。美东客户端无需加；有亚太客户端建议加 CloudFront。**

---

## 1. 当前架构

```
客户端 ──HTTPS──→ ALB (us-east-1, Internet-facing) ──→ EKS Pod (LiteLLM)
```

- ALB 直接暴露公网
- TLS 在 ALB 终止
- SSE streaming（text/event-stream）逐 token 返回

---

## 2. Global Accelerator vs CloudFront vs 裸 ALB

| 维度 | 裸 ALB（当前） | Global Accelerator | CloudFront (VPC Origin) |
|------|--------------|-------------------|------------------------|
| 入口位置 | us-east-1 ALB | Anycast Edge → AWS 骨干 → ALB | Edge POP → AWS 骨干 → Internal ALB |
| TCP+TLS 握手位置 | 客户端直连 ALB | 就近 Edge | 就近 Edge |
| 亚太→美东首字节延迟 | ~580ms | ~401ms (↓31%) | **~179ms (↓69%)** |
| 同区域（美东→美东） | ~10ms | ~10ms | ~15ms（多一跳） |
| SSE streaming 支持 | ✅ | ✅ | ✅ (byte streaming, 逐 chunk 透传) |
| POST 请求支持 | ✅ | ✅ | ✅ |
| 缓存行为 | N/A | 不缓存（纯网络层） | 不缓存（POST 默认不缓存，可显式 CachingDisabled） |
| WAF 集成 | ✅ ALB 关联 WAFv2 | ❌ 需单独加 | ✅ 内置 CloudFront WAF |
| ALB 暴露方式 | Internet-facing | Internet-facing | **Internal**（安全面更小） |
| 固定费 | $0 | $18/月 | ~$10-50/月（按请求量） |
| 适合场景 | 同区域访问 | TCP/UDP 非 HTTP | **HTTP/S 动态内容（LLM API）** |

---

## 2.5 Global Accelerator 的 TCP idle timeout（为什么 GA 治不了长请求超时）

常见误解：以为 GA 是 TCP 层透传、没有应用层超时限制，所以能扛住 CloudFront（VPC Origin 120s）扛不住的长请求。**这个理解是错的**，原因在 GA 的 idle timeout 机制。

### idle timeout ≠ 连接总时长

| | CloudFront OriginReadTimeout | GA TCP idle timeout |
|------|------------------------------|---------------------|
| 计什么 | **等待 origin 响应**的时间 | 连接上**两次数据传输之间的静默**时间 |
| 触发 | origin 在 N 秒内没开始/没继续响应 | 连接 N 秒**完全没有任何字节**流动 |
| 上限 | ~120s（VPC Origin，受限） | **340s**（TCP），有数据就重置；UDP 30s |
| 关键特性 | 应用层等待超时 | **有字节流动就不断重置计时器** |

GA 的 340s 计的是**静默时间**，不是连接总时长。只要连接上持续有字节流动，计时器不断重置，连接永不因 idle 断开。

### 对本项目两种请求的实际影响

**流式请求（stream=true）：**
```
模型边生成边吐 token → 连接上持续有字节 → idle 计时器不断重置 → 永远到不了 340s
```
✅ 流式请求 GA 的 340s idle 根本不触发，即使总时长 20 分钟也没事（从没静默 340s）。但流式请求在裸 ALB 上本来也不超时，所以 GA 在这点上没带来新价值。

**非流式请求（stream=false，本项目的痛点场景）：**
```
客户端发请求 → LiteLLM 调 Bedrock → Bedrock 生成中（这段时间连接上没有任何字节！）
                                      ↑ 如果这段静默 > 340s，GA 断开
            → 全部生成完才一次性返回
```
⚠️ 非流式请求在 Bedrock 生成期间**连接是静默的**。生成超过 340s 还没吐第一个字节，GA 会因 idle 断开。

### 结论：GA 在长非流式请求上比裸 ALB 更差

| 场景 | 裸 ALB（idle 600/1200s） | GA（idle 340s） | CloudFront（120s） |
|------|--------------------------|------------------|---------------------|
| 流式（正常对话） | ✅ | ✅ 永不 idle | ✅ |
| 非流式 < 340s | ✅ | ✅ | < 120s 才行 |
| **非流式 > 600s（websearch 大请求）** | ✅ 能等 1200s | ❌ **340s 就断** | ❌ 120s 就断 |

- GA 340s 比 CloudFront 120s 宽松，但**仍扛不住本项目最痛的非流式 >600s 场景**
- 而且 340s < 当前 ALB 的 600/1200s，**GA 在长非流式请求上反而比直连 ALB 更早断**

**根因复述**：超时根在 “websearch 必须非流式 → 非流式大请求 Bedrock 生成时间长（连接静默）→ 撞任何入口层超时”。这在网络层（GA/CF/DNS 路由）无解，因为根不在网络建连，在 Bedrock 生成时间 + 非流式静默。换 GA 既治不了超时痛点，TTFT 优化又不如 CloudFront（见第 4、6、10 节）。

---

## 3. SSE Streaming 与 CloudFront 兼容性

### CloudFront 是否 buffer SSE？

**不 buffer。** AWS 文档明确：CloudFront 使用 byte streaming，从 origin 收到第一个 byte 就立即转发给客户端。

```
LiteLLM Pod 生成 token
    ↓ data: {"content":"Hello"}\n\n
Internal ALB
    ↓ 立即转发
CloudFront Edge
    ↓ 立即转发（byte streaming）
客户端看到 "Hello"
```

### Timeout 配置（关键）

| 参数 | 默认值 | LLM 场景需要 | 说明 |
|------|--------|-------------|------|
| Origin Response Timeout | 30s | **≥60s** | 等首字节超时。Claude Opus 首 token 可能 10-30s |
| Origin Keep-alive Timeout | 5s | 默认够用 | 空闲连接保持 |
| Response Completion Timeout | 可配 | ≥120s | 控制整个 streaming 完成时间 |

⚠️ **必须调 Origin Response Timeout 到 60s**，否则 Claude Opus 长推理请求会在首 token 返回前被 CloudFront 断开。

### Chunked Transfer Encoding

CloudFront 完全支持 `Transfer-Encoding: chunked` 响应，原样转发，无特殊限制。

---

## 4. TTFT 影响量化

假设模型推理 TTFT 基线：

| 模型 | 推理 TTFT |
|------|----------|
| Claude Haiku 4.5 | ~300ms |
| Claude Sonnet 4.6 | ~800ms |
| Claude Opus 4.6 | ~1500ms |

### 加上网络延迟的总 TTFT

| 场景 | 网络延迟 | Opus 总 TTFT | 加 CF 后 | 改善 |
|------|---------|-------------|---------|------|
| 美东客户端 | ~10ms | 1510ms | 1525ms（多一跳） | ❌ 略差 |
| 亚太客户端（首次连接） | ~500ms | 2000ms | **1680ms** | ✅ ↓16% |
| 亚太客户端（keep-alive） | ~150ms | 1650ms | **1550ms** | ✅ ↓6% |
| 欧洲客户端 | ~100ms | 1600ms | **1530ms** | ✅ ↓4% |

### 关键发现

- **首次连接**改善最大（省 TCP 3-way + TLS 2-3 RTT = 3-4 × 单程延迟）
- **keep-alive 复用**后改善缩小（只省路由优化部分）
- **同区域反而略慢**（多经过一跳 CloudFront edge）

---

## 5. 之前删除 GA 的理由复盘

原理由：**"LLM API 是 POST 请求不可缓存，ms 级优化对 s 级 token 生成无意义"**

### 这个理由哪里对、哪里错

| 论点 | 评估 |
|------|------|
| "POST 不可缓存" | ✅ 对，POST 确实不走 CDN 缓存 |
| "ms 级优化" | ❌ **不是 ms 级**。跨大洲 TCP+TLS 握手是 300-600ms，不是个位数 ms |
| "对 s 级 token 生成无意义" | ❌ **混淆了两件事**。优化的不是 token 生成速度，是首 token 到达前的网络空白期 |

### 正确理解

```
TTFT = 网络建连延迟 + 模型推理时间

GA/CF 优化的是 "网络建连延迟" 这部分
模型推理时间无法通过网络层优化

对于跨大洲场景：
  网络延迟占 TTFT 的 20-30%（500ms / 2000ms）
  优化这部分 → 用户感知到"等待空白期"缩短
```

---

## 6. 成本分析

### CloudFront（推荐方案）

| 费用项 | 估算（基于当前 ~321 requests/day） |
|--------|----------------------------------|
| 请求费 | ~10K requests/月 × $0.01/10K = **~$0.01** |
| 数据传输（Origin→Edge） | ~100MB/月 × $0.085/GB = **~$0.01** |
| 数据传输（Edge→Viewer） | ~100MB/月 × $0.085/GB = **~$0.01** |
| **月总计** | **< $1/月** |

在流量增长 100 倍后（30K requests/day）：约 $5-10/月。

### Global Accelerator

| 费用项 | 估算 |
|--------|------|
| 固定费 | **$18/月**（不管用不用） |
| 数据传输 | $0.015-0.035/GB |
| **月总计** | **~$20/月** |

### 结论

CloudFront 便宜得多（< $1 vs $20），且效果更好（TTFB 179ms vs 401ms）。

---

## 7. 安全面对比

| 维度 | 裸 ALB（当前） | CloudFront + Internal ALB |
|------|--------------|--------------------------|
| ALB 暴露 | Internet-facing（公网可达） | **Internal**（只接受 CloudFront 流量） |
| DDoS 防护 | AWS Shield Standard | AWS Shield Standard + CloudFront 边缘过滤 |
| WAF | ALB 关联 WAFv2 | CloudFront WAF（边缘拦截，origin 不受影响） |
| IP 暴露 | ALB DNS 直接暴露 | CloudFront domain（origin IP 隐藏） |
| 攻击面 | ALB 直接承受所有流量 | 恶意流量在 edge 被拦截 |

CloudFront 方案的**安全面明显更小**。

---

## 8. 改造工作量

### 如果加 CloudFront + VPC Origin

| 步骤 | 耗时 | 说明 |
|------|------|------|
| 创建 CloudFront Distribution | 15min | VPC Origin 指向 Internal ALB |
| ALB 改 Internal | 10min | 修改 07-ingress.yaml annotation |
| 配置 Origin Request Policy | 5min | 转发所有 header |
| 配置 Cache Policy | 5min | CachingDisabled |
| 配置 Origin Response Timeout | 5min | 60s |
| DNS 切换 | 5min | CNAME 从 ALB → CloudFront domain |
| WAF 迁移（从 ALB 到 CF） | 15min | 可选 |
| 验证 SSE streaming | 15min | 端到端测试 |
| **总计** | **~1.5 小时** |  |

### 参考

- guide 第 10 章（`litellm-on-eks-guide/docs/10-cloudfront.md`）有完整配置步骤
- 一键部署方案 `CloudNativeFormationLitellm.yaml` 里有 CloudFront + VPC Origin 的 CF 模板

---

## 9. 决策矩阵

| 你的客户端分布 | 建议 | 优先级 |
|--------------|------|--------|
| **全在美东** | 不加（收益 < 15ms，多一跳反而略慢） | 不做 |
| **美国多地** | 可选（收益 50-100ms，感知不明显） | 低 |
| **有亚太客户端** | **加 CloudFront**（TTFT ↓200-400ms，体感明显） | 中高 |
| **有中国大陆客户端** | 加 CloudFront + 考虑中国区域限制 | 高（但涉及合规） |

---

## 10. 总结

| 方案 | 推荐度 | 理由 |
|------|--------|------|
| **保持裸 ALB** | ✅ 如果客户端全在美国 | 零改动零费用 |
| **加 CloudFront** | ✅✅ 如果有跨区域客户端 | 效果最好 + 费用最低 + 安全面更小 |
| 加 Global Accelerator | ❌ | 效果不如 CF + 贵 20 倍 + 无 WAF |
| CloudFront + GA 双层 | ❌ | 过度设计，无额外收益 |

**最终建议**：如果未来有亚太客户端需求，按 guide 第 10 章做 CloudFront + VPC Origin。当前全美国访问则维持现状。
