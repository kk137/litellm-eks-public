---
title: "LiteLLM 搜索后端对比测试报告：AgentCore vs exa vs tavily vs SearXNG"
---

> 在 LiteLLM websearch interception 的 `_execute_search` 位置，对四个搜索后端做**延迟**与
> **效果**横向实测。测试从生产环境的 LiteLLM Pod（ap-southeast-1）发起，反映真实链路。
> 本报告为技术评估，不含密钥/账号/内部端点；测试日期 2026-06-23。

## 1. 测试目的与方法

### 1.1 目的

LiteLLM 通过 websearch interception 为 Bedrock Claude 补充 web 搜索能力，搜索那一步收口在
`_execute_search`。本测试回答：**同一位置换不同搜索后端，延迟和效果各如何**，为后端选型提供数据。

### 1.2 被测后端

| 后端 | 调用方式 | 部署位置 | 鉴权 |
|---|---|---|---|
| **exa_ai** | `litellm.asearch(search_provider="exa_ai")` | 境外托管 API | API Key |
| **tavily** | `litellm.asearch(search_provider="tavily")` | 境外托管 API | API Key |
| **searxng** | `litellm.asearch(search_provider="searxng")` | **集群内自建**（同区） | 无 |
| **agentcore** | 子类化重写 `_execute_search`，裸 SigV4 调 AgentCore MCP | AWS 托管 @ us-east-1 | AWS IAM / IRSA |

> `_execute_search` 内部即 `litellm.asearch(query, search_provider)`，故 exa/tavily/searxng
> 用原生 provider、agentcore 用子类化的自定义实现，三者在 interception 中角色等价，对比公平。

### 1.3 测试条件

| 项 | 值 |
|---|---|
| 发起位置 | LiteLLM Pod @ EKS ap-southeast-1（生产同环境） |
| query 集 | 10 条，覆盖时效/事实/技术长尾/中文 |
| 延迟样本 | 每后端 × 每 query × 3 轮，warmup 2 轮丢弃 |
| 结果条数 | 统一请求 maxResults=10，取 top-5 评效果 |
| 效果评审 | GPT-5.5（经本网关 `/v1/responses`）**盲评**：匿名化 A/B/C/D + 打乱顺序 |
| LiteLLM 版本 | v1.84.3 |

---

## 2. 延迟结果

每后端 30 次有效样本（10 query × 3 轮），单位 ms：

| 后端 | p50 | p95 | p99 | mean | 错误率 |
|---|---|---|---|---|---|
| **exa_ai** | **232** | 339 | 395 | 247 | 0 |
| **tavily** | **231** | 1136 | 1333 | 328 | 0 |
| **searxng** | **560** | 961 | 1141 | 655 | 0 |
| **agentcore** | **1680** | 1813 | 1863 | 1690 | 0 |

延迟排序：**exa ≈ tavily（~230ms）< searxng（560ms）< agentcore（1680ms）**。

- exa 最快且最稳（p95 仅 339ms）；tavily p50 相同但尾部抖动大（p95 1136ms）。
- searxng 居中：同区零跨区，但要聚合多个上游引擎，处理偏慢。
- agentcore 最慢，主因是**跨区**（新加坡 Pod → us-east-1），且延迟极稳（p50≈p99），说明瓶颈是固定的网络距离而非服务抖动。

### 2.1 AgentCore 延迟拆解（跨区开销）

实测新加坡 Pod → us-east-1 端点：

| 测量 | p50 | min |
|---|---|---|
| TCP 连接建立（≈1×RTT） | 231ms | **217ms** |
| TCP+TLS 握手（≈2–3×RTT） | 450ms | 432ms |

单程网络 RTT ≈ **217ms**（符合新加坡↔美东物理距离）。AgentCore 单次 1680ms 估算拆解：

| 组成 | 估算 | 说明 |
|---|---|---|
| TCP+TLS 握手 | ~450ms | 跨区，且 benchmark 每次新建连接（无连接复用） |
| 请求往返 | ~217ms | 至少 1×RTT |
| 搜索服务本身 | **~1000ms** | 扣除网络后的 AgentCore 实际搜索耗时 |

> **结论**：跨区网络占 AgentCore 总延迟约 40%（~660ms）。若 LiteLLM 与 AgentCore **同区**
> （都在 us-east-1）或**复用连接**，AgentCore 延迟会显著下降（可省去每次 ~450ms 握手）。
> 本测试每次新建连接，**高估**了 AgentCore 的握手成本。

---

## 3. 效果结果（GPT-5.5 盲评）

各维度 1–5 分（noise 维度：5=无噪声）。GPT-5.5 在不知后端名、顺序打乱的前提下评分。

| 后端 | 相关性 | 时效性 | 来源质量 | 噪声(高=干净) | **总均** |
|---|---|---|---|---|---|
| **exa_ai** | 4.50 | 4.10 | 4.60 | 4.50 | **4.42** |
| **tavily** | 3.80 | 3.80 | 3.50 | 3.70 | **3.70** |
| **agentcore** | 3.30 | 3.70 | 4.20 | 3.50 | **3.67** |
| **searxng** | 2.50 | 3.00 | 3.10 | 2.00 | **2.65** |

效果排序：**exa（4.42）> tavily（3.70）≈ agentcore（3.67）> searxng（2.65）**。

- **exa** 全面领先，相关性/来源/低噪声都最高。
- **tavily ≈ agentcore** 几乎打平。agentcore **来源质量 4.20 仅次于 exa**（结果几乎全是 AWS 官方页面），但相关性 3.30 偏低拖累总分。
- **searxng** 垫底，尤其噪声 2.0 最差——多个 query 中混入无关新闻站/疑似垃圾页（含受 Pod 出口地理影响的本地化结果）。

### 3.1 逐 query 总均分

| query | exa_ai | tavily | searxng | agentcore |
|---|---|---|---|---|
| latest AWS Bedrock announcements June 2026 | 5.0 | 4.8 | 2.0 | 4.5 |
| 2026 年 AWS re:Inforce 大会有哪些新发布 | 3.2 | 2.5 | 1.0 | 2.0 |
| newest Claude model released 2026 | 5.0 | 2.5 | 1.8 | 4.5 |
| what is Amazon Bedrock AgentCore | 4.8 | 3.8 | 2.8 | 4.2 |
| how does AWS IRSA work for EKS pods | 4.5 | 3.2 | 2.2 | 4.8 |
| LiteLLM websearch interception non-streaming | 4.2 | 4.2 | 4.2 | 2.5 |
| mcp-proxy-for-aws sigv4 authentication | 4.2 | 4.0 | 2.8 | 3.8 |
| Amazon Bedrock Nova web grounding | 4.2 | 4.5 | 3.0 | 4.2 |
| LiteLLM 如何配置 Bedrock Claude 模型 | 4.2 | 3.8 | 4.2 | 2.8 |
| EKS 节点自动扩缩容 Karpenter 原理 | 4.8 | 3.8 | 2.5 | 3.5 |

观察：

- 没有后端在所有 query 上全胜。agentcore 在偏 AWS 生态的 query（Claude 模型 5.0、IRSA 4.8）表现强，但在通用技术（Q6）和部分中文 query（Q9）偏弱。
- 时效类（Q1–Q3 带 2026/latest）区分度最大，exa 稳定命中最新内容。
- "2026 AWS re:Inforce"（Q2）全员偏低——该会议信息可能确实稀少，非后端缺陷。

---

## 4. 综合画像

| 后端 | 延迟 p50 | 效果总分 | 综合定位 |
|---|---|---|---|
| **exa_ai** | 232ms | 4.42 | 又快又好（本测试综合最优） |
| **tavily** | 231ms | 3.70 | 快、效果中上 |
| **agentcore** | 1680ms | 3.67 | 跨区慢、来源权威但相关性一般 |
| **searxng** | 560ms | 2.65 | 中速、效果最弱（噪声大） |

---

## 5. 局限与解读（重要）

本测试的数据需在以下限定条件下理解，不可直接外推：

1. **发起位置绑定新加坡**：AgentCore 仅 us-east-1，从新加坡测天然跨区。这是 AgentCore 延迟
   垫底的主因——**换 us-east-1 部署 LiteLLM，结论会显著不同**（见 §2.1）。
2. **连接未复用**：benchmark 每次新建 HTTPS 连接，AgentCore 每次多付 ~450ms TLS 握手。生产
   中 LiteLLM 用持久连接会更快，本测试**高估**了 AgentCore 延迟。
3. **样本量小**：每后端 30 次，p95/p99 仅供参考，主看 p50/mean。
4. **judge 偏差**：用 GPT-5.5 单模型盲评，已隐藏后端名+打乱顺序去偏，但单一 judge 仍有其
   口味偏好；评分是相对参考，非绝对真值。
5. **searxng 地理污染**：SearXNG 聚合上游引擎，结果受 Pod 出口地理影响（混入新加坡本地新闻），
   这是其低分的部分原因，换出口/调引擎配置可能改善。
6. **效果维度未覆盖"对最终答案的影响"**：本测试只评搜索结果质量，未测注入结果后模型最终回答
   的准确性差异。

---

## 6. 结论与选型建议

- **纯延迟/效果论**：exa 综合最优，tavily 次之。若团队只追求搜索质量与速度、且能接受引入第三方
  API Key 与境外依赖，exa/tavily 是更强的选择。
- **AgentCore 的价值不在性能排名**，而在工程与治理维度：
  - 全托管，免维护搜索引擎（对比 searxng 要自己跑容器/维护）；
  - 搜索查询由 Amazon 自营索引在 AWS 基础设施内服务（query 不发往第三方搜索引擎）；
  - 复用 IAM/IRSA 鉴权，无需第三方 API Key 与账号；
  - 计费并入 AWS 账单。
- **适用判断**：已重度使用 AWS/Bedrock、看重凭证统一治理与计费归并的团队，AgentCore 的省心
  与合规优势可抵消其延迟/效果上的非领先。若把 LiteLLM 部署到 us-east-1 并复用连接，其延迟劣势
  还会大幅缩小。
- **searxng**：本测试中效果最弱、噪声最大，除非有自建可控/数据完全私有的硬性诉求，性价比不高。

---

> 附：本报告基于一次内部 benchmark 的汇总结论；原始延迟 CSV、搜索结果 jsonl、逐 query 逐维度
> 评分与盲评映射，以及延迟/LLM-judge 测试脚本，均保留在内部仓库，未随本公开文档发布。
