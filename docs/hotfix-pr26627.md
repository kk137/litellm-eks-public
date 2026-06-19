# Hotfix: PR #26627 — Bedrock AIP ARN Prompt Cache 修复

## 问题描述

当 LiteLLM 的 `model_list` 中使用 **Application Inference Profile (AIP) ARN** 格式配置 Bedrock 模型时：

```yaml
model: bedrock/arn:aws:bedrock:us-east-1:<ACCOUNT_ID>:application-inference-profile/xxx
```

通过 `/v1/messages` 端点（Claude Code / Anthropic SDK 默认端点）调用时，`cache_control` 指令被**静默丢弃**，导致 Bedrock Prompt Cache 完全失效。

### 影响

- `cache_creation_input_tokens` 和 `cache_read_input_tokens` 全为 0
- 所有输入 token 按 100% 全价计费（丢失 ~90% 的 cache 折扣）
- TTFT（首 token 延迟）增加

### 不影响的场景

- 使用标准 inference profile id（如 `bedrock/us.anthropic.claude-opus-4-6-v1`）→ cache 正常
- 使用 `/v1/chat/completions` 端点 → cache 正常（走不同代码路径）

---

## 根因

**文件**：`litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py`

**第 302 行**：

```python
if cache_control and model and self.is_anthropic_claude_model(model):
```

`is_anthropic_claude_model()` 通过检查 model 字符串中是否包含 `anthropic` + `claude` 来判断。ARN 格式（`arn:aws:bedrock:...application-inference-profile/xxx`）不包含这些子串 → 返回 False → `cache_control` 被丢弃。

---

## 上游状态

| 项 | 链接 |
|---|---|
| Issue | [BerriAI/litellm#26625](https://github.com/BerriAI/litellm/issues/26625) |
| PR | [BerriAI/litellm#26627](https://github.com/BerriAI/litellm/pull/26627) |
| 状态 | **OPEN**（截至 2026-05-12 未合并） |

---

## Hotfix 实现

### 原理

在容器启动时，用 Python 修改 LiteLLM 库文件中的判断条件，增加对 ARN 格式的识别。容器每次重启都会重新 patch（幂等）。

### 代码变更

**Before**（第 302 行）：
```python
if cache_control and model and self.is_anthropic_claude_model(model):
```

**After**：
```python
if (cache_control and model and (self.is_anthropic_claude_model(model) or ("arn:" in model.lower() and "bedrock" in model.lower()))):
```

### 逻辑解读

```
原来：model 必须被识别为 Claude → 才保留 cache_control
新增：OR model 字符串包含 "arn:" 且包含 "bedrock" → 也保留 cache_control
```

这样 AIP ARN 格式的 model 也能通过判断，cache_control 被保留并透传到 Bedrock。

---

## 部署方式（kubectl YAML）

在 `05-deployment.yaml` 的 container spec 中加 `command` 和 `args` override：

```yaml
containers:
  - name: litellm
    image: ghcr.io/berriai/litellm-database:v1.83.14-stable.patch.3
    command: ["/bin/sh", "-c"]
    args:
      - |
        python3 -c "
        target='/app/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py'
        with open(target) as f: content = f.read()
        old='if cache_control and model and self.is_anthropic_claude_model(model):'
        new='if (cache_control and model and (self.is_anthropic_claude_model(model) or (\"arn:\" in model.lower() and \"bedrock\" in model.lower()))):'
        if old in content:
            content = content.replace(old, new)
            with open(target, 'w') as f: f.write(content)
            print('[hotfix] PR#26627 applied')
        else:
            print('[hotfix] already patched or target not found')
        "
        exec litellm --config /app/config/config.yaml --port 4000 --num_workers 2
```

**注意**：加了 `command` 后，原来的 `args` 会被覆盖。确保 `exec litellm` 的参数和原 deployment 一致。

### 部署方式（Helm values.yaml）

```yaml
command:
  - /bin/sh
  - -c
  - |
    python3 -c "
    target='/app/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py'
    with open(target) as f: content = f.read()
    old='if cache_control and model and self.is_anthropic_claude_model(model):'
    new='if (cache_control and model and (self.is_anthropic_claude_model(model) or (\"arn:\" in model.lower() and \"bedrock\" in model.lower()))):'
    if old in content:
        content = content.replace(old, new)
        with open(target, 'w') as f: f.write(content)
        print('[hotfix] PR#26627 applied')
    else:
        print('[hotfix] already patched or target not found')
    "
    exec litellm --config /app/proxy_config.yaml --port 4000 --num_workers 4
```

---

## 验证方法

### 1. 确认 patch 已生效

```bash
kubectl exec -n litellm deploy/litellm -- python3 -c "
import os
target = '/app/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py'
with open(target) as f:
    content = f.read()
if 'arn:' in content and 'bedrock' in content:
    print('Hotfix ACTIVE')
else:
    print('Hotfix NOT applied')
"
```

### 2. 确认 pod 日志有 hotfix 消息

```bash
kubectl logs -n litellm deploy/litellm --tail=20 | grep hotfix
# 期望看到: [hotfix] PR#26627 applied
```

### 3. Unit test 级验证（在 pod 内）

```bash
kubectl exec -n litellm deploy/litellm -- python3 -c "
def is_anthropic_claude_model(model):
    return 'anthropic' in model.lower() and 'claude' in model.lower()

tests = [
    'bedrock/us.anthropic.claude-opus-4-6-v1',
    'bedrock/arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-a-opus',
    'openai/gpt-4o',
]
for m in tests:
    old = is_anthropic_claude_model(m)
    new = old or ('arn:' in m.lower() and 'bedrock' in m.lower())
    print(f'{\"KEEP\" if new else \"DROP\"} cache_control for: {m}')
"
```

期望输出：
```
KEEP cache_control for: bedrock/us.anthropic.claude-opus-4-6-v1
KEEP cache_control for: bedrock/arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-a-opus
DROP cache_control for: openai/gpt-4o
```

### 4. 端到端验证（需要真实 AIP ARN）

```bash
# 需要先在 model_list 里配一个 AIP ARN 模型 + 对应的 AKSK
# 然后发 /v1/messages 请求：
curl -s https://<endpoint>/v1/messages \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "<aip-model-name>",
    "max_tokens": 50,
    "system": [{"type":"text","text":"<长 system prompt ≥1024 tokens>","cache_control":{"type":"ephemeral"}}],
    "messages": [{"role":"user","content":"hello"}]
  }'

# 验证响应 usage 中：
#   cache_creation_input_tokens > 0（第一次）
#   cache_read_input_tokens > 0（第二次同 prefix）
```

---

## 实测记录（2026-05-12）

在 litellm-cluster (us-east-1) 上完成了验证：

| Step | 动作 | 结果 |
|------|------|------|
| 1 | kubectl exec + python patch 单个 pod | ✅ 第 302 行正确修改 |
| 2 | kill -HUP reload workers | ✅ 新代码生效 |
| 3 | 标准 model id 请求正常 | ✅ 不影响现有功能 |
| 4 | Unit test: AIP ARN old=DROP new=KEEP | ✅ 修复确认 |
| 5 | 清理（delete patched pod） | ✅ 环境恢复 |

### 踩坑记录

| 问题 | 原因 | 解决 |
|------|------|------|
| sed 在 JSON patch 中转义失败 | shell/JSON/Python 三层转义 | 改用 python -c 做替换 |
| patch 文件后进程未读取新代码 | Python 模块已加载到内存 | kill -HUP 或重启容器 |
| kill 1 导致容器重建丢失 patch | K8s 容器 restart = 从镜像重建 | 必须用 command override（每次启动都 patch）|

---

## 何时启用

**当你满足以下全部条件时才需要启用此 hotfix**：

1. ✅ 使用 Application Inference Profile ARN 作为 model id（用于 AWS 原生分账）
2. ✅ 客户端走 `/v1/messages` 端点（Claude Code / Anthropic SDK）
3. ✅ PR #26627 尚未合入 LiteLLM 发布的 stable 版本

**当前状态（2026-05-12）**：我们使用标准 inference profile id，**不需要启用此 hotfix**。

---

## 何时移除

```
PR #26627 合入 LiteLLM main
    ↓
BerriAI 发布新 stable release（含此修复）
    ↓
你升级 LiteLLM image tag 到该版本
    ↓
确认 transformation.py 第 302 行已包含 ARN 判断
    ↓
去掉 05-deployment.yaml 中的 command/args override
    ↓
kubectl apply + rollout
    ↓
验证 AIP ARN 模型的 cache 仍然正常工作
```

### 验证是否可以移除

```bash
# 查新版本的代码是否已包含修复
kubectl exec -n litellm deploy/litellm -- grep -c "arn:" \
  /app/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py
# 如果返回 > 0，说明官方已修复，可以移除 hotfix
```

---

## 关联文档

- [OPERATIONS.md 4.1](./OPERATIONS.md) — 已知问题记录
- [PR #26627](https://github.com/BerriAI/litellm/pull/26627) — Upstream PR
- [参考 guide 18-operations.md](./litellm-on-eks-guide/docs/18-operations.md) — 原始 hotfix 方案参考
