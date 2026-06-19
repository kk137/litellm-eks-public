# LiteLLM EKS 运维手册

本文档覆盖 LiteLLM on EKS 的日常运维、升级、故障处理流程。

- **项目**：litellm-eks-public
- **集群**：`litellm-cluster` (us-east-1)
- **Namespace**：`litellm`
- **部署方式**：kubectl + YAML（非 Helm）
- **最后更新**：2026-05-21

---

## 1. 版本与发布

### 1.1 版本策略

| 项 | 策略 |
|----|------|
| 当前版本 | `v1.83.14-stable.patch.3` |
| 版本来源 | `ghcr.io/berriai/litellm-database` |
| Tag 类型 | **固定 stable tag**（禁用 `main-stable`、`latest` 等移动 tag）|
| 升级频率 | 每 4 周跟随 upstream stable patch |
| 安全补丁 | 立即（< 24h） |
| EKS 版本 | 1.35 |
| 系统 NG releaseVersion | 1.35.4-20260505 |

**禁止**：
- 使用 `:latest` / `:main-stable` / `:main-latest` / `:nightly` 等移动 tag
- 直接在集群 `kubectl edit` 改 image（会被下次 `kubectl apply` 覆盖）
- 跳过 release notes 直接升级

### 1.2 查当前运行版本

```bash
# Deployment 声明的 tag
kubectl get deploy litellm -n litellm \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Pod 实际运行的 digest（多副本验证一致）
kubectl get pods -n litellm -l app=litellm \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'

# LiteLLM 内部版本号（通过 UI 或 API）
# 访问 https://<your-endpoint>/ui → Settings → About
```

### 1.3 查可用 stable release

```bash
# LiteLLM GitHub releases（近 20 个）
gh release list --repo BerriAI/litellm --limit 20

# 规则：
# - v1.XX.YY-stable           — base stable（首发）
# - v1.XX.YY-stable.patch.N   — hotfix patch（推荐跟最新）
# - v1.XX.YY-nightly          — 每日快照（不要用）
# - v1.XX.YY-rc.N             — 候选版（不要用于生产）
# - v1.XX.YY-dev.N            — 开发版（不要用）
```

### 1.4 查某个 tag 的 digest（pin 之前必看）

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:berriai/litellm-database:pull" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

TAG="v1.83.14-stable.patch.3"
curl -sI "https://ghcr.io/v2/berriai/litellm-database/manifests/$TAG" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
  | grep -i "docker-content-digest"
```

---

## 2. 升级流程

### 2.1 Pre-flight Checklist

升级前**必须**完成以下所有项：

```
环境准备：
[ ] 非工作时间窗口（避开业务高峰）
[ ] 当前集群健康（kubectl get pods -n litellm 全 Running）
[ ] PDB 处于激活状态（ALLOWED DISRUPTIONS >= 1）

备份：
[ ] Aurora PostgreSQL RDS snapshot 已创建
[ ] Secrets Manager 中的密钥已备份（或确认 versioning 开启）
[ ] 当前 05-deployment.yaml 已 git commit 或另存

变更评估：
[ ] 已阅读目标版本的 release notes（BerriAI/litellm releases）
[ ] 确认无 breaking change 影响你的配置
[ ] 确认 DB migration 向前兼容（release notes 中 "database migration" 章节）
[ ] 确认未破坏你已启用的功能（SSO、SpendLogs、Prompt Cache 等）

基线记录：
[ ] 当前 /v1/models 返回模型数量
[ ] 当前 P99 延迟基线
[ ] 当前错误率基线（24h）
[ ] 当前 /health 响应
```

#### 备份命令

```bash
# Aurora snapshot（替换 DB_CLUSTER_ID）
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier <DB_CLUSTER_ID> \
  --db-cluster-snapshot-identifier pre-upgrade-$(date +%Y%m%d-%H%M) \
  --region us-east-1

# 备份当前 deployment YAML
kubectl get deploy litellm -n litellm -o yaml > ~/litellm-backup-$(date +%Y%m%d).yaml
```

### 2.2 升级步骤

```bash
# Step 1: 更新 05-deployment.yaml 的 image tag
# 例如从 v1.83.10-stable → v1.83.14-stable.patch.3

# Step 2: 应用变更
kubectl apply -f 05-deployment.yaml

# Step 3: 观察滚动升级
kubectl rollout status deployment/litellm -n litellm --timeout=600s
# 注：3 副本 + PDB minAvailable=2 + readiness probe 偏慢，实测一次滚动约 7 分钟。
# 超时设 600s 给足余量；若 timeout 触发，用 kubectl get pods 看真实状态再决定是否回滚。

# Step 4: 验证所有 pod 为新版本
kubectl get pods -n litellm -l app=litellm \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Step 5: 冒烟测试
# /health/liveliness
kubectl port-forward -n litellm deploy/litellm 4000:4000 &
curl localhost:4000/health/liveliness
# 或者直接走外网端点
curl -s https://<your-endpoint>/health/liveliness

# /v1/models
curl -s https://<your-endpoint>/v1/models -H "Authorization: Bearer <KEY>" \
  | python3 -c "import json,sys; print('Total:', len(json.load(sys.stdin)['data']))"

# 实际推理测试
curl -s https://<your-endpoint>/v1/chat/completions \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-haiku45","messages":[{"role":"user","content":"hi"}]}'
```

### 2.3 Post-upgrade 观察

```
观察周期：24-48 小时

监控项：
- pod restart count（应保持 0）
- /health 成功率
- P99/P50 延迟
- 错误率（400/500/502）
- LiteLLM SpendLogs 记录是否正常
- Aurora 连接池（不应大量波动）
```

### 2.4 回滚

#### 快速回滚（推荐，< 1 分钟）

```bash
# 查看升级历史
kubectl rollout history deployment/litellm -n litellm

# 回滚到上一版本
kubectl rollout undo deployment/litellm -n litellm

# 指定版本回滚
kubectl rollout undo deployment/litellm -n litellm --to-revision=<N>

# 等完成
kubectl rollout status deployment/litellm -n litellm
```

#### 完整回滚（涉及 DB migration）

如果新版本改了 DB schema 且不兼容旧版：

```bash
# 1. Pod 回滚
kubectl rollout undo deployment/litellm -n litellm

# 2. 从 snapshot 还原 Aurora
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier litellm-restored \
  --snapshot-identifier pre-upgrade-<timestamp>

# 3. 切换 Aurora endpoint（改 Secrets Manager 中 litellm/database-url）

# 4. 触发 pod 重启读取新 secret
kubectl rollout restart deployment/litellm -n litellm
```

### 2.5 升级演练

首次用 SOP 升级前，先做一次"空升级"演练（升到相同版本）：

```bash
# 重启现有 pod，测试 PDB/rolling update 机制
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status deployment/litellm -n litellm --timeout=600s
# 注：3 副本 + PDB minAvailable=2 + readiness probe 偏慢，实测一次滚动约 7 分钟。
# 超时设 600s 给足余量；若 timeout 触发，用 kubectl get pods 看真实状态再决定是否回滚。

# 观察：
# - 是否真的零停机（客户端持续请求应无失败）
# - rolling update 是否遵守 PDB（minAvailable=2）
# - 新 pod Ready 时间（应 < 60s）
```

---

## 3. 日常运维

### 3.1 查 Spend Logs

```bash
# 通过 API（需要 master key 或 admin key）
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id litellm/master-key --region us-east-1 \
  --query SecretString --output text)

# 最近 24h 全量
curl -s "https://<your-endpoint>/spend/logs?start_date=$(date -v-1d +%Y-%m-%d)" \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool

# 按 team 聚合
curl -s "https://<your-endpoint>/spend/logs?team_id=<TEAM_ID>" \
  -H "Authorization: Bearer $MASTER_KEY"

# 按 key 聚合
curl -s "https://<your-endpoint>/spend/logs?api_key=<KEY>" \
  -H "Authorization: Bearer $MASTER_KEY"
```

或登录 UI → Analytics → Usage 查报表。

### 3.2 查 Pod 日志

```bash
# 实时 tail
kubectl logs -n litellm -l app=litellm --tail=100 -f

# 特定 pod
kubectl logs -n litellm litellm-xxxxx --tail=200

# 过滤错误
kubectl logs -n litellm -l app=litellm --tail=500 | grep -iE "error|exception|traceback"

# 从 External Secrets Operator（secrets 同步问题）
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
```

### 3.3 热重载配置（不改 image 时）

```bash
# 修改 04-configmap.yaml 后应用
kubectl apply -f 04-configmap.yaml

# 触发 rolling restart 让 pod 重新读取
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status deployment/litellm -n litellm
```

### 3.4 Secrets Manager 轮换

当前 Secret 清单（12 个）：

| Secret | 用途 | 轮换频率建议 |
|--------|------|------|
| `litellm/master-key` | LiteLLM 管理 key | 90 天 |
| `litellm/salt-key` | 加密盐 | **不轮换**（轮换会使存量 key 失效） |
| `litellm/database-url` | Aurora 连接串 | 随 Aurora 密码 |
| `litellm/redis-host` / `redis-password` | ElastiCache | 随 cache 密码 |
| `litellm/ui-password` | UI 登录 | 90 天 |
| `litellm/cognito-client-id` / `client-secret` | SSO | 随 Cognito App Client |
| `litellm/azure-api-key` / `api-base` | Azure OpenAI | 随 Azure 轮换 |
| `litellm/gemini-api-key` | Google Gemini | 90 天 |
| `litellm/openai-api-key` | OpenAI | 90 天 |

#### 轮换流程（以 master-key 为例）

```bash
# Step 1: 生成新 key
NEW_KEY="sk-$(openssl rand -hex 32)"

# Step 2: 更新 Secrets Manager（会自动创建新 version）
aws secretsmanager update-secret \
  --secret-id litellm/master-key \
  --secret-string "$NEW_KEY" \
  --region us-east-1

# Step 3: ExternalSecret 按 refreshInterval (1h) 自动同步
# 或手动触发立即同步：
kubectl annotate externalsecret -n litellm litellm-secrets \
  force-sync=$(date +%s) --overwrite

# Step 4: 验证 K8s secret 更新
kubectl get secret -n litellm litellm-secrets -o yaml | grep LITELLM_MASTER_KEY

# Step 5: 触发 pod 重启读取新值
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status deployment/litellm -n litellm
```

⚠️ **风险提示**：
- `salt-key` 禁止轮换（会使所有已加密的 virtual key 失效）
- `database-url` 轮换时需要同步更新 Aurora 密码，两端必须同步切换
- 轮换期间可能短暂 5xx，选非高峰时段

### 3.5 Karpenter 节点替换

Karpenter 管理的 OD 节点会按 `disruption.consolidateAfter: 60s` 自动回收空闲节点。人工干预场景：

```bash
# 查看 Karpenter 管理的节点
kubectl get nodes -L karpenter.sh/capacity-type -L node.kubernetes.io/instance-type

# 手动触发节点替换（drift 检测会自动重建）
kubectl delete node <node-name> --wait=false

# 强制替换所有 Karpenter 节点（如 AMI 升级后）
kubectl get nodes -l karpenter.sh/nodepool=litellm-nodepool -o name \
  | xargs -I {} kubectl delete {} --wait=false

# 查看 Karpenter controller 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100
```

### 3.6 Managed NG 节点升级

```bash
# 查看当前版本
aws eks describe-nodegroup \
  --cluster-name litellm-cluster \
  --nodegroup-name litellm-system \
  --region us-east-1 \
  --query 'nodegroup.{version:version,releaseVersion:releaseVersion}'

# 查看可用 AMI 版本
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.35/amazon-linux-2023/arm64/standard/recommended/release_version \
  --region us-east-1 --query 'Parameter.Value' --output text

# 升级到最新
aws eks update-nodegroup-version \
  --cluster-name litellm-cluster \
  --nodegroup-name litellm-system \
  --region us-east-1

# 观察升级进度
aws eks describe-update \
  --name litellm-cluster \
  --nodegroup-name litellm-system \
  --update-id <UPDATE_ID> \
  --region us-east-1
```

升级过程：AWS 按 `maxUnavailable` 滚动替换节点，Karpenter controller 和其他系统组件会被 PDB 保护。

### 3.7 EKS 集群升级

```bash
# 版本+1 升级（EKS 不支持跨版本）
# 1.35 → 1.36 → 1.37 ...

# 1. 升级 control plane
aws eks update-cluster-version \
  --name litellm-cluster \
  --kubernetes-version 1.36 \
  --region us-east-1

# 2. 升级 managed NG（同 3.6）
# 3. 升级 Karpenter NodeClass AMI（改 11-karpenter-nodepool.yaml 的 amiSelectorTerms）
# 4. 升级 Addons
aws eks update-addon --cluster-name litellm-cluster --addon-name vpc-cni --region us-east-1
# 重复 coredns, kube-proxy, pod-identity, metrics-server 等
```

---

## 4. 已知问题

### 4.1 AIP ARN + /v1/messages 下 prompt caching 失效

- **影响版本**：所有已发布版本（截至 2026-05-11）
- **场景**：当 model 配置为 Bedrock Application Inference Profile ARN 格式（`bedrock/arn:aws:bedrock:...:application-inference-profile/xxx`）且客户端走 `/v1/messages` 端点（Claude Code）时，`cache_control` 被 LiteLLM 静默丢弃
- **症状**：
  - Bedrock CloudWatch invocation log 中 `cacheWriteInputTokens` / `cacheReadInputTokens` 全为 0
  - 费用与延迟显著上升
- **根因**：`is_anthropic_claude_model()` 不识别 ARN 字符串
- **Upstream**：
  - Issue: [#26625](https://github.com/BerriAI/litellm/issues/26625)
  - PR: [#26627](https://github.com/BerriAI/litellm/pull/26627)（未合并）
- **Workaround**：
  - **我们当前方案：不使用 AIP**，config 中全部用标准 inference profile id（`bedrock/us.anthropic.claude-*`）
  - 等 PR 合并后可评估是否切 AIP
- **跟踪**：每月升级评估时确认 PR 状态

### 4.2 AIP 下 SpendLogs cost=0

- **影响版本**：所有已发布版本
- **场景**：使用 AIP ARN 时，LiteLLM 无法识别底层模型，SpendLogs 中记录 cost=0
- **Workaround**：在 `model_info.base_model` 显式指定底层模型
  ```yaml
  - model_name: claude-opus-team-a
    litellm_params:
      model: bedrock/arn:aws:bedrock:us-east-1:<ACCT>:application-inference-profile/xxx
    model_info:
      base_model: anthropic.claude-opus-4-6-v1
      id: claude-opus-team-a-app
  ```
- **状态**：我们当前不使用 AIP，无影响

### 4.3 AWS LB Controller IMDS 获取 VPC ID 失败

- **影响版本**：Graviton 节点下的 aws-load-balancer-controller
- **症状**：LB Controller CrashLoopBackOff，日志显示 IMDS 超时
- **Workaround**：启动参数显式指定 VPC ID
  ```yaml
  args:
    - --aws-vpc-id=vpc-0e7f126d308a4c050
  ```
- **状态**：已应用到生产集群

### 4.4 SSO 免费限制 5 用户

- **影响版本**：v1.76.0+
- **限制**：LiteLLM 免费 SSO 最多支持 5 个用户
- **Workaround**：
  - 短期：控制 SSO 用户数 ≤ 5
  - 中期：评估 LiteLLM Enterprise License 或自建 auth 代理
- **状态**：当前使用未超限

---

## 5. Monitoring & Alerting

### 5.1 关键指标

| 指标 | 来源 | 基线 | 告警阈值 |
|------|------|------|---------|
| Pod Ready Count | K8s | 3/3 | < 2 持续 5min |
| Pod Restart | K8s | 0 | > 3 in 10min |
| P99 Latency | LiteLLM | 待测 | > 基线 × 2 |
| 错误率 (5xx) | LiteLLM + ALB | < 0.1% | > 1% |
| Aurora CPU | RDS | < 50% | > 80% |
| Aurora Connections | RDS | < 100 | > 300 |
| Redis CPU | ElastiCache | < 30% | > 70% |
| Bedrock Quota 使用率 | CloudWatch | < 70% | > 85% |
| Spend 异常增长 | LiteLLM | baseline | 日环比 > 2× |

### 5.2 Bedrock Quota 查询

```bash
# Claude Opus us-east-1 RPM quota
aws service-quotas get-service-quota \
  --service-code bedrock \
  --quota-code <QUOTA_CODE> \
  --region us-east-1

# 列出 bedrock 所有 quota
aws service-quotas list-service-quotas \
  --service-code bedrock \
  --region us-east-1 \
  --query 'Quotas[?contains(QuotaName, `Claude`)].{Name:QuotaName,Value:Value,Unit:Unit}' \
  --output table

# 实际使用量（CloudWatch metric）
aws cloudwatch get-metric-statistics \
  --namespace AWS/Bedrock \
  --metric-name Invocations \
  --dimensions Name=ModelId,Value=us.anthropic.claude-opus-4-6-v1 \
  --start-time $(date -v-1H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region us-east-1
```

### 5.3 集群 baseline（截至 2026-05-21）

| 项 | 值 |
|----|----|
| 入口 | CloudFront → VPC Origin → Internal ALB |
| CloudFront Distribution | `<YOUR_CF_DISTRIBUTION_ID>` |
| VPC Origin | `<YOUR_VPC_ORIGIN_ID>` |
| 节点数 | 5（3 Karpenter r6g.xlarge OD + 2 Managed m7g.large OD） |
| LiteLLM pod | 3 副本 |
| /v1/models 返回数量 | 255 |
| LiteLLM 版本 | v1.83.14-stable.patch.3 |
| EKS 版本 | 1.35 |
| Aurora | Serverless v2 (0.5–8 ACU) |
| Redis | cache.r7g.large × 2 |

### 5.4 Prompt Cache（Claude 原生）

Claude 原生 Prompt Cache 是 Bedrock 侧的能力，LiteLLM 透传 `cache_control` 指令即可生效。我们**不做任何配置改动**，依赖客户端（Claude Code / Anthropic SDK）自带的 cache_control 注入。

#### 当前状态

| 项 | 值 | 数据源 |
|----|----|-------|
| 生产命中率基线 | **~99.98%** | CloudWatch `CacheReadInputTokenCount` / `InputTokenCount` |
| 24h cache read | ~29M tokens | CloudWatch |
| 24h cache write | ~3.4M tokens | CloudWatch |
| 24h uncached input | ~4.5K tokens | CloudWatch |
| 启用的模型 | Opus 4.6/4.7, Sonnet 4.5/4.6, Haiku 4.5 | CloudWatch 按 ModelId 维度 |
| 月节省预估 | **$3,000–$11,000**（依模型组合） | 基于 Anthropic cache 定价（read 10% / write 125%） |

#### 生效条件

1. **最小 token 阈值**（未达不缓存）：
   - Opus / Sonnet：**1024 tokens**
   - Haiku 4.5：**2048 tokens**
2. **客户端需发送 `cache_control` 标记**：
   - Claude Code / Anthropic SDK：默认自动发
   - OpenAI SDK（`/v1/chat/completions`）：需显式在 system content 传 `cache_control: {type: ephemeral}`
3. **cache TTL**：
   - `ephemeral_5m`（默认）：5 分钟
   - `ephemeral_1h`：1 小时（需客户端显式请求）

#### 监控命令

```bash
# 过去 24h 总命中数据
START=$(date -u -v-24H +%Y-%m-%dT%H:%M:%S)
END=$(date -u +%Y-%m-%dT%H:%M:%S)

for metric in Invocations InputTokenCount CacheWriteInputTokenCount CacheReadInputTokenCount; do
  val=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Bedrock --metric-name "$metric" \
    --start-time "$START" --end-time "$END" \
    --period 86400 --statistics Sum --region us-east-1 \
    --query 'Datapoints[0].Sum' --output text)
  echo "$metric = $val"
done

# 命中率计算:
#   hit_rate = CacheReadInputTokenCount / (CacheReadInputTokenCount + InputTokenCount)

# 按模型维度
for model in us.anthropic.claude-opus-4-6-v1 us.anthropic.claude-sonnet-4-6 us.anthropic.claude-haiku-4-5-20251001-v1:0; do
  echo "--- $model ---"
  for metric in CacheReadInputTokenCount InputTokenCount; do
    aws cloudwatch get-metric-statistics \
      --namespace AWS/Bedrock --metric-name "$metric" \
      --dimensions Name=ModelId,Value="$model" \
      --start-time "$START" --end-time "$END" \
      --period 86400 --statistics Sum --region us-east-1 \
      --query "Datapoints[0].Sum" --output text | xargs -I {} echo "  $metric = {}"
  done
done
```

#### 异常阈值

| 症状 | 可能原因 | 排查方向 |
|------|---------|---------|
| 命中率突然降到 < 80% | 客户端版本升级改了 cache_control 发送逻辑 / system prompt 被重写 | 看 invocation log 里的 `cache_control` 字段 |
| CacheWriteInputTokenCount 暴增 | system prompt 频繁变化（每次新建缓存） | 查 Claude Code 版本更新 / CLAUDE.md 变动频率 |
| 全 0（完全不命中） | LiteLLM 丢 cache_control / 切 AIP ARN 踩 PR 26627 坑 | 参考 4.1 |

---

### 5.5 Bedrock Invocation Logging（S3 审计日志）

#### 当前状态

| 项 | 值 |
|----|----|
| 启用日期 | 2026-05-11 |
| 日志目的地 | `s3://bedrock-invocation-logs-<YOUR_ACCOUNT_ID>-us-east-1/` |
| IAM Role | `arn:aws:iam::<YOUR_ACCOUNT_ID>:role/BedrockInvocationLoggingRole` |
| Text 数据 | ✅ 记录 |
| Image / Embedding / Video | ❌ 不记录 |
| 生命周期 | 90 天 → IA，180 天 → Glacier |
| 加密 | SSE-S3 (AES256) |
| 版本控制 | Enabled（非 current version 30 天后删除） |

#### 日志结构

```
s3://<bucket>/AWSLogs/<account>/BedrockModelInvocationLogs/<region>/YYYY/MM/DD/HH/
  ├── <timestamp>_<hash>.json.gz              ← 主日志（请求+响应摘要）
  └── data/
      └── <requestId>_input.json.gz           ← 大请求体单独存（防止单 log 过大）
```

**主日志字段**（摘要）：
```json
{
  "timestamp": "2026-05-11T14:50:57Z",
  "accountId": "<YOUR_ACCOUNT_ID>",
  "requestId": "43d260f6-...",
  "operation": "InvokeModelWithResponseStream",
  "modelId": "arn:aws:bedrock:us-east-1:...:inference-profile/us.anthropic.claude-opus-4-7",
  "input": {
    "inputTokenCount": 1,
    "cacheReadInputTokenCount": 238604,
    "cacheWriteInputTokenCount": 1314
  },
  "output": { /* streaming event list */ }
}
```

#### 常用查询

```bash
# 查今天的日志文件
aws s3 ls "s3://bedrock-invocation-logs-<YOUR_ACCOUNT_ID>-us-east-1/AWSLogs/<YOUR_ACCOUNT_ID>/BedrockModelInvocationLogs/us-east-1/$(date +%Y/%m/%d)/" --recursive | tail -20

# 下载并解析单条日志
aws s3 cp "s3://<path-to-log>.json.gz" /tmp/log.json.gz
gunzip -c /tmp/log.json.gz | python3 -m json.tool

# 用 Athena 做批量分析（推荐，未来需求）
# 1. 建 external table 指向 bucket
# 2. 用 SQL 按 requestId / modelId / cache metric 聚合
```

#### 对分账的作用

未来如果做多账号 / 多 team 分账，可以将 **Bedrock invocation log 的 requestId** 与 **LiteLLM SpendLogs 的 request_id** 关联，实现"谁花了这笔钱"的双向审计：

```
LiteLLM SpendLogs (team/key/user 维度)
        ↓ JOIN on request_id
Bedrock Invocation Log (模型/cache/真实 token 维度)
        ↓ JOIN on modelId + timestamp
AWS Bedrock 账单（account/region/模型 维度）
```

#### 成本估算

按当前流量（24h ~321 invocations），S3 月存储和请求费用约 **< $1/月**。生命周期规则确保老日志自动降级到 IA / Glacier。

---

## 6. 紧急场景

### 6.1 Pod 全挂（0 Ready）

```bash
# 1. 先确认是 pod 问题还是节点问题
kubectl get pods -n litellm -o wide
kubectl get nodes

# 2. 查 pod 事件
kubectl describe pod -n litellm <pod-name> | tail -30
kubectl logs -n litellm <pod-name> --previous

# 3. 常见原因排查
# (a) Image pull 失败 → 检查 image tag 是否存在
# (b) Secret 获取失败 → kubectl get externalsecret -n litellm + describe
# (c) DB 连接失败 → 参考 6.2
# (d) Redis 连接失败 → 检查 VPC/SG/endpoint
# (e) Cognito SSO 配置错误 → 临时禁用 SSO 环境变量

# 4. 紧急回滚到上一版本
kubectl rollout undo deployment/litellm -n litellm
```

### 6.2 DB 连接失败

```bash
# 1. 检查 Aurora 状态
aws rds describe-db-clusters --region us-east-1 \
  --query 'DBClusters[?starts_with(DBClusterIdentifier, `litellm`)].{id:DBClusterIdentifier,status:Status}'

# 2. 检查 Secrets Manager 中的 DATABASE_URL
aws secretsmanager get-secret-value \
  --secret-id litellm/database-url --region us-east-1 \
  --query SecretString --output text

# 3. 从 pod 内部测试连接
kubectl exec -n litellm deploy/litellm -- python -c "
import os
import psycopg2
conn = psycopg2.connect(os.environ['DATABASE_URL'])
print('OK:', conn.server_version)
"

# 4. 检查 SG 规则（Aurora SG 入站应允许 pod ENI CIDR 的 5432）
```

### 6.3 Bedrock 全 Region quota 打满

```bash
# 症状：大量 429 + cooldown 触发
# 临时应急：

# 1. 切 fallback 到更便宜的模型（减少 Opus/Sonnet 压力）
#    修改 04-configmap.yaml 的 fallbacks 列表，优先降级到 Haiku

# 2. 临时降低 rpm 避免全部 cooldown
kubectl edit configmap -n litellm litellm-config
# 修改 model_list 中每个 deployment 的 rpm，更严格

# 3. 提 quota 工单
aws service-quotas request-service-quota-increase \
  --service-code bedrock \
  --quota-code <CODE> \
  --desired-value <VALUE> \
  --region us-east-1

# 长期：启用多账号路由（参考 README 后续 roadmap）
```

### 6.4 成本异常飙升

```bash
# 1. 查 LiteLLM Spend Logs 定位来源
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id litellm/master-key --region us-east-1 \
  --query SecretString --output text)

curl -s "https://<your-endpoint>/spend/logs?start_date=$(date -v-1d +%Y-%m-%d)" \
  -H "Authorization: Bearer $MASTER_KEY" \
  | python3 -c "
import json, sys
logs = json.load(sys.stdin)
# 按 api_key 聚合
from collections import defaultdict
agg = defaultdict(float)
for l in logs:
    agg[l.get('api_key', 'unknown')] += l.get('spend', 0)
for k, v in sorted(agg.items(), key=lambda x: -x[1])[:10]:
    print(f'{k[:20]:30} \${v:.2f}')
"

# 2. 临时封禁异常 key
curl -X POST https://<your-endpoint>/key/block \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"key": "<SUSPICIOUS_KEY>"}'

# 3. 查 AWS Cost Explorer（1 天延迟）
# 确认 Bedrock 调用确实飙升
```

---

## 7. CloudFront 运维

### 7.1 架构概览

```
用户 → Route53 → CloudFront (WAF+TLS) → VPC Origin → Internal ALB → EKS Pod
```

| 组件 | 说明 |
|------|------|
| CloudFront Distribution | 边缘 TLS 终止 + WAF + byte streaming |
| VPC Origin | CloudFront 通过 AWS 内部网络直达 Internal ALB |
| Internal ALB | 仅接受 CloudFront managed prefix list 流量 |
| 安全组 | 入站仅允许 CloudFront prefix list (`pl-3b927c52`) on 443 |

### 7.2 查看状态

```bash
# Distribution 状态
aws cloudfront get-distribution --id <DIST_ID> \
  --query 'Distribution.{Status:Status,Domain:DomainName,Enabled:DistributionConfig.Enabled}'

# VPC Origin 状态
aws cloudfront list-vpc-origins \
  --query 'VpcOriginList.Items[?Name==`litellm-internal-alb`].{Id:Id,Status:Status}'

# 验证流量走 CloudFront
curl -sI https://<YOUR_DOMAIN>/health/liveliness | grep -i "x-cache\|via\|server"
```

### 7.3 缓存失效（Invalidation）

LLM API 全是 POST 请求，不会被缓存。但如果你修改了 CloudFront 行为或需要清理边缘缓存：

```bash
aws cloudfront create-invalidation --distribution-id <DIST_ID> \
  --paths "/*"
```

### 7.4 Origin Response Timeout

当前设置 60s（Origin Read Timeout）。如果 Opus 模型首 token 超时：

```bash
# 查看当前超时
aws cloudfront get-distribution-config --id <DIST_ID> \
  --query 'DistributionConfig.Origins.Items[0].ConnectionTimeout'

# 调整需要 update-distribution（修改 Origin 配置中的 ReadTimeout）
# 最大可设 180s（需联系 AWS Support 提升到 180s）
```

### 7.5 安全组管理

ALB 安全组入站规则仅允许 CloudFront managed prefix list：

```bash
# 查看当前规则
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=<ALB_SG_ID>" \
  --query 'SecurityGroupRules[?IsEgress==`false`]'

# CloudFront managed prefix list ID（us-east-1）
# pl-3b927c52 (com.amazonaws.global.cloudfront.origin-facing)
```

### 7.6 回滚到直连 ALB

如果 CloudFront 出现问题，快速回滚：

```bash
# 1. 改 ALB 为 Internet-facing
# 修改 07-ingress.yaml: scheme: internet-facing
kubectl apply -f 07-ingress.yaml

# 2. DNS 切回 ALB
ALB_DNS=$(kubectl get ingress litellm -n litellm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_ZONE=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" --output text)

aws route53 change-resource-record-sets --hosted-zone-id <ZONE_ID> \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"<YOUR_DOMAIN>\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"$ALB_ZONE\",
          \"DNSName\": \"dualstack.$ALB_DNS\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }"

# 3. 恢复 ALB 安全组允许公网（临时）
aws ec2 authorize-security-group-ingress --group-id <ALB_SG_ID> \
  --protocol tcp --port 443 --cidr <YOUR_CIDR>/32
```

### 7.7 CloudFront 配置要点

详见 [CLOUDFRONT-LLM-CONFIG.md](./CLOUDFRONT-LLM-CONFIG.md)，关键配置：

| 配置项 | 值 | 原因 |
|--------|-----|------|
| Cache Policy | CachingDisabled | POST 动态内容 |
| Origin Response Timeout | 60s | Opus 首 token 可能 10-30s |
| Origin Request Policy | AllViewerAndCloudFrontHeaders | 需转发 Authorization |
| Allowed Methods | 全部 7 种 | LLM API 是 POST |
| Keep-alive Timeout | 60s | 复用连接 |

---

## 附录

### A. 联系 & 资源

- Upstream: https://github.com/BerriAI/litellm
- Parallel reference guide: https://github.com/harryzsh/litellm-on-eks-guide
- LiteLLM docs: https://docs.litellm.ai/
- Release notes: https://github.com/BerriAI/litellm/releases

### B. 版本历史（本集群）

| 日期 | 版本 | 备注 |
|------|------|------|
| 2026-05-11 | v1.83.10-stable | 从 `main-stable` 移动 tag 切换到固定 tag（digest 不变） |
| 2026-05-11 | v1.83.14-stable.patch.3 | 首次完整 SOP 升级演练。跨 481 commits，schema migration 全部 additive，滚动升级 ~7min 零停机。`/v1/models` TTFB 从 151s 降至 46s。含 auth bypass / MCP OAuth 安全修复 + 38 模型 cost map 修复 + Bedrock/Gemini/Vertex 多项 bug fix |
| 2026-05-21 | (infra) | CloudFront + VPC Origin 改造：ALB 改为 Internal，流量路径 CF→VPC Origin→ALB。零停机完成。安全组收紧为仅 CF prefix list |
