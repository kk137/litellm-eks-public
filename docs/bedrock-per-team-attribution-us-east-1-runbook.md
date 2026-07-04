# Runbook — 把 per-team Bedrock 成本归因推到美东 (us-east-1)

> 目标:把新加坡 (ap-southeast-1) 已验证的 **per-team Bedrock 成本归因**机制复制到 **us-east-1** 生产集群。
> 决策(已拍板):**新建美东独立 exec 角色** `litellm-bedrock-exec-use1`,只信任美东 irsa-role —— CUR 里美东与 SG 的 team 花费分开,SG 侧零改动。
> 机制原理见 [`bedrock-cost-attribution.txt`](../bedrock-cost-attribution.txt)(us-west-2 版)与 memory `project-bedrock-per-team-cost-attribution-sg`(SG IRSA 版)。

---

## 0. 前置事实(2026-07-04 实测,非记忆)

| 维度 | 新加坡 (源,已验证) | 美东 (目标) |
|---|---|---|
| kubectl context | `arn:aws:eks:ap-southeast-1:<ACCOUNT_ID>:cluster/litellm-cluster` | `arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/litellm-cluster` |
| LiteLLM 版本 | v1.84.3 | v1.84.3 ✅ 同 |
| Pod / 滚动策略 | 3 | 3;`maxSurge:0 maxUnavailable:1`(滚动先杀 1,3→2,不中断) |
| IRSA 角色 | `litellm-Cluster-...SaRoleB6A0F44D-K4Bky...` | **`litellm-irsa-role`** |
| Bedrock 区域/前缀 | ap-southeast-1 / `global.` `apac.` | us-east-1 / `us.` `global.` |
| callback 现状 | 已含 `bedrock_team_tag_hook...` | `["prometheus","websearch_interception","s3_v2"]`(**无 hook**) |
| hook 加载 | py 在 `litellm-config` cm、挂 `/app/config`;LiteLLM 加载 config 时把 config 目录入 sys.path → 可 import(**与 `PYTHONPATH=/extra-code` 无关**,那是 agentcore 用的) | 同结构,**无需动 volume/PYTHONPATH** |
| `BEDROCK_EXEC_ROLE_ARN` env | 有 | **无** |
| exec 角色 | `litellm-bedrock-exec`(只信任 SG SaRole) | 本 runbook 新建 `litellm-bedrock-exec-use1` |

**账户 <ACCOUNT_ID>;IAM 全局(无区域);CE/billing 查询走 us-east-1。**

---

## 1. 新建美东独立 exec 角色

```bash
ACCOUNT=<ACCOUNT_ID>
US_IRSA_ARN="arn:aws:iam::${ACCOUNT}:role/litellm-irsa-role"

# 1a. 建角色 — 信任策略只允许美东 irsa-role 做 AssumeRole + TagSession
aws iam create-role \
  --role-name litellm-bedrock-exec-use1 \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"AllowUsEast1IrsaAssume\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": \"${US_IRSA_ARN}\"},
      \"Action\": [\"sts:AssumeRole\", \"sts:TagSession\"]
    }]
  }" \
  --tags Key=Project,Value=litellm Key=ManagedBy,Value=litellm-bedrock-team-tag Key=Region,Value=us-east-1

# 1b. 内联 Bedrock 权限(Invoke + Converse + List/Get,Resource *)
aws iam put-role-policy \
  --role-name litellm-bedrock-exec-use1 \
  --policy-name BedrockInvokePolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }]
  }'
```

> ⚠️ `Converse`/`ConverseStream` 必须包含 —— 美东 websearch_interception 走 converse 路径,SG 旧 exec 角色(2026-06-29 建)只有 Invoke,美东要补齐,否则带 team 的 converse 请求 assume 后调 Bedrock 会 AccessDenied(hook 失败不阻断 → 请求照常走但**零归因**,静默)。

**验证:**
```bash
aws iam get-role --role-name litellm-bedrock-exec-use1 --query 'Role.AssumeRolePolicyDocument'
aws iam get-role-policy --role-name litellm-bedrock-exec-use1 --policy-name BedrockInvokePolicy
```

---

## 2. 给美东 `litellm-irsa-role` 加 AssumeRole 权限

```bash
aws iam put-role-policy \
  --role-name litellm-irsa-role \
  --policy-name StsAssumeBedrockExecUse1 \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"sts:AssumeRole\", \"sts:TagSession\"],
      \"Resource\": \"arn:aws:iam::${ACCOUNT}:role/litellm-bedrock-exec-use1\"
    }]
  }"
```

**验证(两向都要对得上):**
```bash
aws iam get-role-policy --role-name litellm-irsa-role --policy-name StsAssumeBedrockExecUse1
```

---

## 3. 装 hook + callback 进 `litellm-config` cm(美东,一次性)

> 美东 hook py 与 config.yaml 同 cm、同挂 `/app/config` → 无需动 volume/PYTHONPATH。
> **用 SG bug-027 已修版**(不靠 `startswith('bedrock/')` 检测;对所有 team 请求注入,无 team 透传)。**不要**用 `bedrock-cost-attribution.txt` 里 us-west-2 的旧版。
> cm 只能整 key 重写,所以一步做完:导出两个 key → 在 config.yaml 的 `callbacks:` 追加 hook → 带两个 key 一起 apply。**只追加一行,绝不用 SG 的 config.yaml 覆盖**(区域/前缀/S3 全不同)。

```bash
US=arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/litellm-cluster
SG=arn:aws:eks:ap-southeast-1:<ACCOUNT_ID>:cluster/litellm-cluster

# 3a. 从 SG 现网导出已修版 hook,从美东现网导出 config.yaml
kubectl --context=$SG get configmap litellm-config -n litellm \
  -o jsonpath='{.data.bedrock_team_tag_hook\.py}' > /tmp/bedrock_team_tag_hook.py
kubectl --context=$US get configmap litellm-config -n litellm \
  -o jsonpath='{.data.config\.yaml}' > /tmp/us-config.yaml

# 3b. 在 callbacks: 段追加 hook(放最前,确保 pre_call 注入先于其它 callback,与 SG 一致)
python3 - <<'PY'
p = "/tmp/us-config.yaml"
s = open(p).read()
needle = '  callbacks:\n    - "prometheus"'
assert needle in s, "callbacks 段结构变了,手工确认后再改"
s = s.replace(needle,
    '  callbacks:\n    - "bedrock_team_tag_hook.bedrock_team_tag_hook_instance"\n    - "prometheus"')
open(p,"w").write(s)
print("patched")
PY

# 3c. 带 config.yaml + hook py 两个 key 一起 apply
kubectl --context=$US create configmap litellm-config -n litellm \
  --from-file=config.yaml=/tmp/us-config.yaml \
  --from-file=bedrock_team_tag_hook.py=/tmp/bedrock_team_tag_hook.py \
  --dry-run=client -o yaml | kubectl --context=$US apply -f -

# 3d. 确认两个 key 都在,且 config.yaml 里有 hook callback
kubectl --context=$US get configmap litellm-config -n litellm \
  -o jsonpath='{.data}' | python3 -c "import json,sys; print(list(json.load(sys.stdin).keys()))"
# 期望: ['bedrock_team_tag_hook.py', 'config.yaml']
kubectl --context=$US get configmap litellm-config -n litellm \
  -o jsonpath='{.data.config\.yaml}' | grep -c bedrock_team_tag_hook   # 期望 >=1
```

---

## 4. deployment 加 `BEDROCK_EXEC_ROLE_ARN` env → 触发滚动重启

```bash
US=arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/litellm-cluster
kubectl --context=$US set env deployment/litellm -n litellm \
  BEDROCK_EXEC_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/litellm-bedrock-exec-use1

kubectl --context=$US rollout status deployment/litellm -n litellm --timeout=5m
```

> `set env` 会改 pod template → 自动滚动。`maxSurge:0 maxUnavailable:1`:一次杀 1 个(3→2 服务不中断),起新的读到新 cm+env。**cm 变更不会自动重启 pod**,但本步的 env 变更会,所以第 3 步的 cm 改动也在这次滚动里一并生效。

---

## 5. 验证归因链(激活即时可测 CloudTrail;账单侧 24–48h)

```bash
US=arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/litellm-cluster

# 5a. hook 是否 fire(INFO 日志)—— 需有带 team 的 key 打一次 bedrock 请求
kubectl --context=$US logs -n litellm -l app=litellm --since=10m --tail=500 \
  | grep "BedrockTeamTagHook.pre_call"
# 期望看到 team_alias=<你的team> 且非 None

# 5b. CloudTrail 确认 AssumeRole 带 team tag(即时,权威)
aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time "$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --query 'Events[*].CloudTrailEvent' --output json \
  | python3 -c "import json,sys;[print(json.loads(r).get('requestParameters',{}).get('roleSessionName'), json.loads(r).get('requestParameters',{}).get('tags')) for r in json.load(sys.stdin) if 'litellm-bedrock-exec-use1' in json.loads(r).get('requestParameters',{}).get('roleArn','')]"
# 期望: litellm-<team> [{'key':'team','value':'<team>'}]

# 5c. 账单侧(等 24–48h)—— 按 team 分组的 Bedrock 花费
aws ce get-cost-and-usage --region us-east-1 \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock Service"]}}' \
  --group-by Type=TAG,Key=iamPrincipal/team
```

> **`iamPrincipal/team` tag 已在 2026-07-01 全账户激活**(SG 那次做的,IAM 全局共享),美东无需再激活 cost allocation tag。CUR export `litellm-cur2-iam-principal` 已 HEALTHY。
> ⚠️ SERVICE 名是 **"Amazon Bedrock Service"**(带 Service),不是 "Amazon Bedrock"。

---

## 6. 留存配置(防漂移)

美东集群独立管理(非 IaC / 非 Helm),`litellm-config` 是裸 `kubectl apply`,手改不会被覆盖但也无声明式真源。为防漂移:
- 本 runbook 即美东这套改动的权威记录(角色 `litellm-bedrock-exec-use1` + irsa 内联策略 `StsAssumeBedrockExecUse1` + hook cm key + callback + `BEDROCK_EXEC_ROLE_ARN` env)。
- hook 源码以 SG 现网导出为准(bug-027 已修版),重装时按第 3 步重新从集群导出,不要从旧文件恢复。
- 若日后美东改为声明式管理,把上述 4 处一并纳入。

---

## 回滚

| 步骤 | 回滚 |
|---|---|
| 4. env | `kubectl set env deployment/litellm -n litellm BEDROCK_EXEC_ROLE_ARN-`(减号删除)→ hook 见空 ARN 直接透传,归因停,请求正常 |
| 3. callback / cm key | 重 apply 去掉 callback 行的 config.yaml(hook py key 无害留着,没被 callback 引用就是死代码) |
| 1/2. IAM | `delete-role-policy` + `delete-role`(先解绑内联策略) |

**最安全的紧急回滚**:只删第 4 步的 env(一条命令),hook 立即空转透传,不必碰 cm/IAM。

---

## 风险小结

| 风险 | 级别 | 缓解 |
|---|---|---|
| Pod 滚动重启 | 🟡 中 | `maxSurge:0/maxUnavailable:1`,3→2 不中断;建议低峰执行 |
| Converse 权限漏配 → 静默零归因 | 🟡 中 | 第 1b 步已含 Converse;第 5a/5b 验证 fire |
| 误用旧版 hook(bug-027) | 🟡 中 | 强制从 SG 现网导出,不用 .txt 旧版 |
| 误覆盖美东 config.yaml 为 SG 版 | 🟡 中 | 第 3 步只在现网 config 上追加一行,不整份替换 |
| 破坏 SG | 🟢 零 | 独立角色,SG 资源全不碰 |
| 配置漂移 | 🟡 中 | 第 6 步同步回 CDK |
