# LiteLLM 监控、日志与审计指南

> **集群：** EKS `litellm-cluster`（us-east-1），namespace `litellm`
> **更新日期：** 2026-06-07
> **现状基线：** 本文所有命令/路径均已在当前集群实测验证

本文按三个维度梳理监控体系，每个维度回答：**存什么、存哪里、怎么看、保留多久**。

| 维度 | 内容 | 存储位置 | 保留期 |
|------|------|----------|--------|
| **① 用户/Key 用量** | 每次请求的 model、token、花费、归属 key/user/team | RDS Aurora PostgreSQL（`LiteLLM_SpendLogs` 等表） | 永久（除非手动清理） |
| **② 集群/应用运行** | LiteLLM 进程日志、Pod 状态、实时指标 | Pod stdout（`kubectl logs`）+ Prometheus `/metrics` | 临时（Pod 重启即丢） |
| **③ 审计** | 谁在何时调用了 K8s API / 谁改了集群 | CloudWatch `/aws/eks/litellm-cluster/cluster`（audit 类型） | 30 天 |

> ⚠️ **重要前提**：社区版 LiteLLM **不提供**应用层 AuditLog（`LiteLLM_AuditLog` 表 = Enterprise-only，见 `litellm/__init__.py` 的 `store_audit_logs`）。本文维度③的"审计"指的是 **Kubernetes/AWS 基础设施层审计**，不是 LiteLLM 内部的操作审计。

---

## ① 用户使用日志：Key 消耗、请求内容

### 1.1 存什么、存哪里

LiteLLM 把**每一次请求**写入 RDS Aurora PostgreSQL（`<YOUR_RDS_ENDPOINT>`），核心表：

| 表名 | 内容 |
|------|------|
| `LiteLLM_SpendLogs` | 每次请求一行：model、prompt/completion/total tokens、spend（美元）、归属 `api_key`/`user`/`team`、起止时间、`request_id`、`call_type` |
| `LiteLLM_DailyUserSpend` / `*TeamSpend` / `*TagSpend` | 按天聚合，UI 趋势图的数据源 |
| `LiteLLM_VerificationToken` | 虚拟 Key 本体（含 budget、rpm/tpm 限制、过期时间） |
| `LiteLLM_UserTable` / `LiteLLM_TeamTable` | 用户/团队及其预算 |

#### 是否记录请求"内容"（prompt/response 正文）？—— 记录，但有 2048 截断

**会记录正文**（UI 的 **Admin Access → Logging Settings → Store Prompts in Spend Logs** 开关已开启，实测生效）。正文存放位置（实测确认，注意**不在** `messages` 列）：

| 数据 | 存放字段 | 说明 |
|------|---------|------|
| 用户提问 + 多轮历史 | `proxy_server_request` / `request`（即 `input` 数组） | 完整对话上下文 |
| 模型回答 | `response`（`choices[].message.content`） | 模型输出 |
| 账目元数据 | `litellm_metadata` | key/team/spend/token/IP/user-agent 等 |

> ⚠️ **关键：DB 里的正文被截断到 2048 字符/段**
> - 由 LiteLLM 应用层常量 **`MAX_STRING_LENGTH_PROMPT_IN_DB`（默认 `2048`）** 控制，**不是 Aurora 的限制**（Aurora 单字段可达 ~1GB）。当前 pod **未设此环境变量 → 用默认 2048**。
> - 超长正文写 DB 前被砍：**保留开头 35% + 结尾 65%**（结尾对排查更重要），中间插入 `litellm_truncated` 提示。
> - 所以 **UI / DB 里看到的长对话是残缺的**。要**完整正文**，官方明示需走 logging callback（OTEL/Datadog/**S3**）—— 见改进项 #2。
> - 调大阈值（如 `MAX_STRING_LENGTH_PROMPT_IN_DB=50000`）可让 DB 存更全，但在高 token 量级下会显著推高 RDS 存储 / Serverless ACU，**不推荐**。

> ✅ **截断只影响 DB 日志，绝不影响客户端输出**（源码验证）
> 截断函数 `_sanitize_request_body_for_spend_logs_payload` 仅在 `spend_tracking` 写日志路径被调用（构造 `*_for_spend_logs_payload`）。返回给客户端的响应是另一条独立链路、用另一份数据副本，**完整不截断**。"DB 里残缺" ≠ "客户端收到的残缺"。
> 该函数还会**自动剥离敏感字段**（`_SENSITIVE_REQUEST_BODY_KEYS`，如含 Authorization token 的原始 headers），降低密钥落库风险。

> **GPT-5.5/5.4 的特例：UI Pretty 视图显示空，但数据完整（实测确认）**
> 经 `/v1/responses` 走的 GPT 请求（`call_type=aresponses`）**token/花费记账完全正常**（实测 161 条 token 全部正确），正文也存进了 `response` 字段。但 **LiteLLM UI 的 "Pretty" 视图会显示 "No response data available"**——因为 Pretty 渲染器是为 Chat Completions 格式写的（找 `choices[].message.content`），而 Responses API 把回答放在 **`output[].content[].text`**、请求放在 `input` 数组（不在 `messages`），渲染器解析不了。
> - ✅ **数据没丢**：实测该记录 `response` 字段长度 4629 字节，内容完整。
> - **怎么看 GPT 内容**：点 UI 右上角切到 **"JSON" 视图**（不是 Pretty），或直接查 **S3 日志**（S3 存的是完整 JSON，是查看 GPT Responses 内容最可靠的途径）。
> - ⚠️ 不要因为 Pretty 显示空就误判"GPT 日志丢了"。

> **token=0 的"空壳"记录说明（实测）**：DB 里有一批 `total_tokens=0`、`call_type` 为空的记录（model 名为 `gpt-5`/`gpt-5-codex`/`gpt-5.4-mini` 等**网关未配置的名字**）。这些是**客户端请求了不存在的模型名、被 LiteLLM 路由前拒绝**的失败请求，记 0 token 是正确的（确实没消耗）。成功请求（`acompletion`/`anthropic_messages`/`aresponses`）token 记录 100% 正常。**账目是准的**，空壳不影响花费统计。

### 1.2 怎么看

**方式 A — LiteLLM UI（最直观）**

- 地址：`https://<YOUR_DOMAIN>/ui/`
- **Usage** tab：按天/模型/Key/Team 看请求数、token、花费趋势
- **Logs** tab：逐条请求明细（点开可看该次的 token/花费/耗时）
- **Virtual Keys** tab：每个 Key 的累计消耗 vs 预算

**方式 B — 管理 API（脚本化 / 自动化）**

```bash
# 准备：master key
POD=$(kubectl get pods -n litellm -l app=litellm -o jsonpath='{.items[0].metadata.name}')
MK=$(kubectl exec -n litellm $POD -- sh -c 'echo $LITELLM_MASTER_KEY')
kubectl port-forward -n litellm svc/litellm 14000:4000 &

# 全局每日用量（请求数 + token）—— 已实测可用
curl -s -H "Authorization: Bearer $MK" \
  "http://localhost:14000/global/activity?start_date=2026-06-01&end_date=2026-06-07" | python3 -m json.tool

# 列出所有虚拟 Key
curl -s -H "Authorization: Bearer $MK" "http://localhost:14000/key/list?page=1&size=50"

# 查某个 Key 的请求明细（必须带 api_key 参数，否则默认只查"今天 UTC"返回空）
curl -s -H "Authorization: Bearer $MK" "http://localhost:14000/spend/logs?api_key=<KEY_HASH>"

# 某个 Key 的当前消耗 / 预算 / 限速
curl -s -H "Authorization: Bearer $MK" "http://localhost:14000/key/info?key=<KEY>"
```

> 实测：当前集群有 **4 个虚拟 Key**；最近几天用量约 Jun 02=290 请求 / 1.15M tokens，Jun 04=160 请求 / 6.79M tokens。

**方式 C — 直查 RDS（最底层，做对账/导出时用）**

```sql
-- 按 Key 汇总最近 7 天消耗
SELECT api_key, count(*) AS reqs, sum(total_tokens) AS tokens, sum(spend) AS usd
FROM "LiteLLM_SpendLogs"
WHERE "startTime" > now() - interval '7 days'
GROUP BY api_key ORDER BY usd DESC;
```
连接信息从 Secrets Manager（`us-east-1`）的 `DATABASE_URL` 取，不要硬编码。

---

## ② 集群/应用运行日志与状态

### 2.1 LiteLLM 应用日志（进程日志）

**存哪里**：仅 Pod stdout（`json_logs: true`，JSON 格式）。
**⚠️ 当前是临时的** —— LogHub/fluent-bit 已于本轮清理中删除，**现在没有任何采集器**把 Pod 日志转存到 CloudWatch/S3。即 **Pod 重启或被替换后，旧日志丢失**。

```bash
# 最近请求（过滤健康检查等噪音）
kubectl logs -n litellm -l app=litellm --tail=200 --since=5m \
  | grep -v "health\|readiness\|liveliness\|Synced\|ToolPolicy\|MCP\|Proxy initialized\|spend\|team\|key/list"

# 只看错误
kubectl logs -n litellm -l app=litellm --tail=500 --since=10m \
  | grep -iE "error|exception|fail|4[0-9][0-9]|5[0-9][0-9]"

# HTTP 访问日志（状态码）
kubectl logs -n litellm -l app=litellm --tail=200 --since=5m | grep -E "POST|GET" \
  | grep -v "health\|spend\|key/list"
```
（更多查询模板见 `CLAUDE.md` 的 Log Queries 段。）

> **如果需要持久化应用日志**：可选方案是装 **CloudWatch Container Insights**（`amazon-cloudwatch` namespace 的 cloudwatch-agent + fluent-bit），日志进 `/aws/containerinsights/litellm-cluster/application`。当前**未安装**（实测 `amazon-cloudwatch` ns 为空、无该 log group）。要不要重新引入需权衡成本 —— 之前的 LogHub 方案正因 NAT/OpenSearch 烧钱而被拆除。

### 2.2 实时指标（Prometheus）

**LiteLLM 已开启 `prometheus` callback**（实测 `/metrics` 端点存在，进程启动时自动建了 `PROMETHEUS_MULTIPROC_DIR`）。

```bash
# /metrics 需要 master key 鉴权（实测：无 key 返回 Unauthorized）
kubectl port-forward -n litellm svc/litellm 14000:4000 &
curl -s -H "Authorization: Bearer $MK" http://localhost:14000/metrics | grep "^litellm_"
```
暴露的指标含：`litellm_requests_total`、`litellm_spend_metric`、`litellm_total_tokens`、各 deployment 的延迟/失败率等。

> **⚠️ 当前没有任何 Prometheus server 在采集这些指标**（实测集群内无 prometheus/grafana/ServiceMonitor）。指标只是"暴露在端点上"，没有被存储或画图。如需图表，需部署 Prometheus（或 AMP + Grafana）来 scrape 这个端点。

### 2.3 Pod / 集群健康状态

```bash
kubectl get pods -n litellm                 # Pod 状态、重启次数
kubectl top pods -n litellm                 # CPU/内存实时占用（需 metrics-server）
kubectl describe pod <pod> -n litellm        # 事件、调度、探针失败原因
kubectl get hpa -n litellm                   # 自动扩缩状态（如配置了）
```

---

## ③ 审计日志

### 3.1 应用层审计（LiteLLM 内部操作）—— 社区版不可用

LiteLLM 的 `LiteLLM_AuditLog` 表（记录"谁创建/删除了 Key、改了 Team 预算"等管理操作）是 **Enterprise 专属功能**。
- 代码依据：`litellm/__init__.py` 的 `store_audit_logs` 标记为 enterprise-only。
- **社区版无法通过 console/config 开启**（已查证）。
- 因此**当前没有** LiteLLM 内部的操作审计。

> 替代手段：Key/Team 的管理操作可通过 ② 的 Pod 日志（`POST /key/generate`、`/key/delete` 等访问日志）间接观察，但不结构化、且随 Pod 重启丢失。

### 3.2 基础设施层审计（Kubernetes / AWS）—— 已启用

这是当前**唯一可靠的审计来源**，记录"谁对集群做了什么操作"。

**存哪里**：CloudWatch Logs `/aws/eks/litellm-cluster/cluster`
**保留期**：**30 天**（本轮已从"永久"改为 30 天，约 7.5 GB）
**已启用的控制面日志类型**（实测全开）：`api`、`audit`、`authenticator`、`controllerManager`、`scheduler`

```bash
# 看审计日志流（每种类型一个 stream 前缀）
aws logs describe-log-streams --region us-east-1 \
  --log-group-name "/aws/eks/litellm-cluster/cluster" \
  --log-stream-name-prefix "kube-apiserver-audit"

# 查"谁在最近1小时对 litellm namespace 的 secret 做了操作"
aws logs filter-log-events --region us-east-1 \
  --log-group-name "/aws/eks/litellm-cluster/cluster" \
  --log-stream-name-prefix "kube-apiserver-audit" \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '{ $.objectRef.namespace = "litellm" && $.objectRef.resource = "secrets" }'
```

**AWS 层操作审计（IAM/RDS/EKS API 调用）**：由 **CloudTrail** 记录（账户级，独立于本集群），在 CloudWatch/CloudTrail console 查 `eks.amazonaws.com`、`rds.amazonaws.com`、`secretsmanager.amazonaws.com` 事件源。

---

## 现状总结与建议

**当前实际具备的能力（实测确认）：**
- ✅ Key/用户用量：RDS SpendLogs + UI + 管理 API（最完整的一层）；**保留期已设 30 天，清理任务每天自动运行**（实测生效）
- ✅ 请求正文持久化：**S3 callback `s3_v2` 已配置**（桶 `litellm-request-logs-<YOUR_ACCOUNT_ID>-us-east-1`），完整未截断、对 pod 零影响（见改进项 #2）
- ✅ 实时指标：Prometheus `/metrics` 端点已暴露
- ✅ K8s 基础设施审计：EKS 控制面 5 类日志 → CloudWatch（30 天）
- ✅ 应用日志：`kubectl logs`（实时可看）+ S3（持久化完整版）

**当前缺口（按需补，注意成本）：**
- ⚠️ Prometheus 指标**无人采集**（无 Prometheus server）→ 需要图表时部署 AMP+Grafana（见改进项 #3）
- ⚠️ LiteLLM 内部操作审计**不存在**（社区版 `store_audit_logs` 实测无效，0 行写入）→ 仅能靠 K8s 审计 + Pod 访问日志间接覆盖（见 ③）
- ⚠️ S3 / RDS 正文均含 PII（IP/email/key hash）→ 合规需要时配 `turn_off_message_logging` 脱敏

---

## ④ 对照官方文档：可改进项

> 以下均已对照 LiteLLM 官方文档核实，并标注**社区版可用 / Enterprise-only**。当前集群实测基线：累计 **$298 花费、约 14,000 次请求**（Apr–May 窗口 48 个活跃天）。

### 改进项 1：SpendLogs 表无限增长，且社区版无自动清理 ⚠️ 最该关注

- **问题**：`LiteLLM_SpendLogs` 每请求一行、**永久保留**。当前已积累约 14K 行,会持续增长，最终影响 RDS 存储成本和 UI 查询性能。
- **官方的自动清理（`maximum_spend_logs_retention_period` / `_cleanup_cron`）是 Enterprise-only** —— 我们用不了。
- **社区版可行的替代方案**：
  - **(a) 定时 SQL 清理**：用 CronJob 或 EventBridge 定期 `DELETE FROM "LiteLLM_SpendLogs" WHERE "startTime" < now() - interval '90 days'`（先导出到 S3 再删，做冷归档）。
  - **(b) Postgres 原生分区**：按 `startTime` 范围分区，直接 `DROP` 过期分区，比批量 DELETE 高效（官方在 Enterprise 清理里也用这招，但分区表本身是 PG 能力，社区可自建）。
- **建议**：先定个保留策略（例如热数据 90 天留 RDS，更早的归档到 S3）。

### 改进项 2：用 S3 callback 持久化完整请求日志 ✅ 社区版可用 —— **已配置（2026-06-07）**

**它是做什么的**：`s3_v2` 是 LiteLLM 内置的 callback（社区版可用，区别于 Enterprise-only 的 GCS/Azure）。启用后，**每次 LLM 调用（成功+失败），LiteLLM 把该次完整记录（模型、token、花费、时间、prompt/response 正文、IP、trace_id 等）打包成 JSON 直接 PUT 到 S3**。数据流：`LiteLLM Pod ──异步批量写──> S3`，无中间组件。

**解决什么问题**：两个缺口。① 应用日志只在 Pod stdout、重启即丢（见维度 ②）；② **RDS SpendLogs 里的正文被截断到 2048 字符**（见 1.2）。`s3_v2` 把**完整、未截断**的记录永久落 S3 —— 实测下载验证 S3 对象 `litellm_truncated=false`，正文/响应完整。这正是 1.2 截断提示里官方建议的方案（"Full, untruncated data is logged to logging callbacks"）。

**当前实际配置**（已写入 `04-configmap.yaml` 的 `litellm_settings`，实测生效）：

```yaml
litellm_settings:
  callbacks:                          # 与 prometheus / websearch_interception 并存
    - "prometheus"
    - "websearch_interception"
    - "s3_v2"
  s3_callback_params:
    s3_bucket_name: litellm-request-logs-<YOUR_ACCOUNT_ID>-us-east-1
    s3_region_name: us-east-1
```

- **S3 桶**：`litellm-request-logs-<YOUR_ACCOUNT_ID>-us-east-1`（us-east-1，永久保留，公开访问全阻断，SSE-S3 加密）。对象按 `YYYY-MM-DD/time-...<call_id>.json` 分目录。
- **凭证**：用 IRSA —— ServiceAccount `litellm-sa` → IAM Role `litellm-irsa-role`，额外 inline policy `litellm-s3-logs-write`（仅 `s3:PutObject` 到该桶）。**未使用 access key**。
- **写入机制**（实测对 pod 影响≈0）：异步批量，攒 `DEFAULT_S3_BATCH_SIZE=512` 条或每 `DEFAULT_S3_FLUSH_INTERVAL_SECONDS=10` 秒 flush 一次，**不阻塞请求**。
- ⚠️ **S3 里含完整 prompt/response 正文 + PII（IP/email/key hash）**。桶已加密 + 阻断公开访问；如需进一步脱敏，配合改进项 #4 的 `turn_off_message_logging`，或在 `s3_callback_params` 加 `s3_strip_base64_files: true` 去附件。
- **查看**：`aws s3 ls s3://litellm-request-logs-<YOUR_ACCOUNT_ID>-us-east-1/<日期>/`，或用 Athena 建表查询。

### 改进项 3：给 `/metrics` 接入 Prometheus 采集，并显式锁鉴权 ✅ 社区版可用

#### 采集的到底是什么？—— 实时运行指标，不是日志

`/metrics` 暴露的是 **Prometheus 格式的数值指标**（一堆累计计数器 / 瞬时测量值）。"采集"（scrape）就是：**一个 Prometheus server 每隔 N 秒（如 15s）HTTP GET 一次 `/metrics`，把那一刻的数值记成时间序列**。它采集的内容（官方命名）：

| 类别 | 指标 | 含义 |
|------|------|------|
| 流量 | `litellm_requests_metric` | 累计请求数（按 model/key/team 打标签） |
| Token | `litellm_total_tokens_metric` | 累计 input+output token |
| 花费 | `litellm_spend_metric` | 累计花费（$） |
| 失败 | `litellm_proxy_failed_requests_metric` / `litellm_deployment_failure_responses` | 失败请求数 / 某后端模型失败数 |
| 预算余额 | `litellm_remaining_api_key_budget_metric` | 每个 Key 还剩多少预算 |
| 限速余额 | `litellm_remaining_requests_metric` / `litellm_remaining_tokens_metric` | 还剩多少 RPM/TPM（来自上游 Bedrock 返回的 ratelimit 头） |

#### 与 SpendLogs 的关系：相辅相成，不是二选一

两者数据同源（都来自每次请求），但**视角和用途互补**——一个管"历史明细账本"，一个管"实时健康仪表盘"：

| | **SpendLogs（RDS）** | **Prometheus 指标** |
|---|---|---|
| 粒度 | 每次请求一行（**明细**） | 聚合数值（**无单条记录**） |
| 回答的问题 | "6/3 14:07 这个 Key 调了什么、花了多少" | "**现在**QPS 多少？失败率？哪个模型在抖？" |
| 强项 | 事后**对账 / 审计 / 查账**、精确到单笔 | 实时**监控 / 告警 / 趋势**、秒级反应 |
| 弱项 | 查"实时失败率/QPS"很笨重、给 DB 加压 | 查不到"具体哪一笔请求"的明细 |
| 存储 | 数据库，永久（见改进项 #1） | 时间序列库，可设保留期 |

> **一句话**：SpendLogs 是「账本」（查谁花了多少、审计追溯），Prometheus 是「仪表盘」（看系统此刻是否健康、出问题立刻告警）。
> 典型分工：日常**告警/大盘看 Prometheus**（如"GPT-5.5 失败率 >5% 持续 5 分钟就通知"）；**对账/排查某笔请求翻 SpendLogs**。把实时监控压力从 DB 卸到 Prometheus，也顺带保护了 RDS。

#### 现状与落地

- ✅ LiteLLM **已在暴露**这些指标（`/metrics` 端点实测存活）。
- ❌ 但**没有任何 Prometheus server 去 scrape**——指标当前没被记录、没画图、没告警，纯"挂在端点上无人问津"。本质是：**传感器已就位，缺记录仪 + 仪表盘**。
- 落地需要两端：
  - **采集端**：EKS 上最省事是 **AMP（Amazon Managed Prometheus）**，或自建 kube-prometheus-stack，定时拉 `/metrics`。官方**未提供** ServiceMonitor 资源，需自己写 scrape config（带 master key 的 Bearer）。
  - **展示/告警端**：**Managed Grafana** 画图 + 配告警规则。
- 顺手加固：`/metrics` 实测需 master key（已要求鉴权）。建议在 config 里**显式声明**，避免默认值变化导致裸奔：
  ```yaml
  litellm_settings:
    require_auth_for_metrics_endpoint: true
  ```

### 改进项 4：明确 PII / 正文日志策略 ✅ 社区版可用

官方提供了细粒度开关，建议在文档/config 里**显式定义**当前立场（现在是隐式"不记录正文"）：

| 设置 | 作用 | 位置 |
|------|------|------|
| `turn_off_message_logging: true` | 仍记录 token/花费，但**不记录消息正文**（合规推荐） | `litellm_settings` |
| `redact_user_api_key_info: true` | 脱敏 hashed token / user_id / team_id（Langfuse/OTEL 等） | `litellm_settings` |
| `no-log: true`（请求体） | 单次请求完全不记录 | 客户端 |
| `x-litellm-call-id`（响应头） | 每请求唯一 ID，用于跨组件追踪一次调用 | 自动返回 |

- **建议**：若启用改进项 2 的 S3 日志，**同时**设 `turn_off_message_logging: true`（记录元数据但不落正文），在"可审计"和"防 PII 泄露"之间取平衡。

### 改进项 5（前瞻）：高并发时的 DB 保护 — 暂不需要

- 官方的 `use_redis_transaction_buffer: true`（所有实例先写 Redis 队列、单实例加锁刷 DB）是**为 1000+ req/s 设计**的。
- 我们当前峰值约**每天百级请求**，远未到该阈值，**现在不需要开**。记录在此，待量级上来再考虑（我们已有 Redis，届时开启成本低）。

### 小结：优先级建议

| 优先级 | 改进项 | 为什么 | 社区版 |
|--------|--------|--------|--------|
| 🔴 高 | #1 SpendLogs 保留策略 | 唯一会随时间持续恶化的问题 | ✅（需自建） |
| 🟡 中 | #4 显式 PII 策略 | 一行配置，合规明确 | ✅ |
| 🟡 中 | #2 S3 日志持久化 | 省钱地补回"日志持久化"缺口 | ✅ |
| 🟢 低 | #3 Prometheus 采集 | 要图表/告警时再上 | ✅ |
| ⚪ 暂缓 | #5 Redis 事务缓冲 | 量级远未到 | ✅ |
