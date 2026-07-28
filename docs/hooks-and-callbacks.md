# LiteLLM Hooks & Callbacks 全览

> ConfigMap 里除 `config.yaml` 之外的每个 `.py` 都是一个自定义 hook。本文档说明**有哪些、各自解决什么问题、加载机制、顺序是否重要、怎么加/怎么删、怎么验证生效**。
>
> 适用：`04-configmap.yaml`（本仓库）与线上 `litellm-config` ConfigMap。最后核对：2026-07-28。

---

## 1. 速查表

| # | 名称 | 类型 | 作用 | 何时触发 | 移除条件 |
|---|------|------|------|---------|---------|
| 1 | `litellm_httpx_timeout_patch` | 自定义（导入副作用） | httpx 默认超时 600s → 1200s，绕过 `/v1/messages` 硬超时 | 进程启动时一次 | 升到含 PR #33418 的版本 |
| 2 | `bedrock_team_tag_hook` | 自定义（pre-call） | AssumeRole + STS session tag `team=X`，实现 per-team Bedrock 成本归因 | 每个带 team 的请求 | 长期保留（业务能力） |
| 3 | `codex_additional_tools_flatten` | 自定义（pre-call） | 把 Codex 私有 `additional_tools` 摊平成标准 `tools`，避免 Mantle 400 | 每个 `/v1/responses` 请求 | Codex 或 Mantle 任一侧修好 |
| 4 | `agentcore_websearch` | 自定义（子类覆写） | 把 websearch interception 的后端从 SearXNG 换成 Bedrock AgentCore Web Search | 请求带 web_search 工具时 | 改回 SearXNG 时 |
| 5 | `websearch_interception` | **内置** | 拦截客户端下发的 web_search 工具，代跑 agentic loop（Bedrock Claude 无原生搜索） | 请求带 web_search 工具时 | — |
| 6 | `prometheus` | **内置** | 暴露 `/metrics` 供 Prometheus 抓取 | 每个请求 | — |
| 7 | `s3_v2` | **内置** | 完整请求/响应异步落 S3（含 `error_str`、TTFT、cache 分项） | 每个请求 | — |

**两地差异**：#4 和 #5 互斥（都是 websearch 后端，只能启一个）。
- **us-east-1**：`websearch_interception`（SearXNG，集群内自托管）
- **ap-southeast-1**：`agentcore_websearch`（AWS 托管，跨区打 us-east-1 gateway）

其余 5 个两地一致。

---

## 2. 加载机制（重要）

```yaml
litellm_settings:
  callbacks:
    - "litellm_httpx_timeout_patch.litellm_httpx_timeout_patch_instance"   # <模块名>.<实例名>
    - "prometheus"                                                        # 内置只写名字
```

- **必须用 `callbacks:`，不能用 `success_callback:`** —— 后者不会实例化 handler，`async_pre_call_hook` 永远不被调用。
- **模块解析相对 config 目录**（`/app/config`，即 `--config` 所在目录）。LiteLLM 的 `get_instance_fn` 走这个路径，**不需要动 `PYTHONPATH`**；把 `.py` 作为 ConfigMap 的一个 key 挂进去即可（`04-configmap.yaml` 就是这么做的）。
- **改 ConfigMap 不会自动生效** —— LiteLLM 只在启动时读 config，必须 `kubectl rollout restart deployment/litellm`。

### 顺序重要吗？

| 情况 | 是否重要 |
|------|---------|
| `litellm_httpx_timeout_patch` | **是** —— 必须放**第一位**，它靠导入副作用改全局默认，要在任何 client 被构造前执行 |
| 多个 pre-call hook 之间 | 是 —— 按列表顺序依次改写同一个 `data` dict。当前 3 个 hook 改的字段互不重叠（`aws_*` vs `input`/`tools`），所以实际无冲突，但新增时要检查 |
| 内置 logger（prometheus/s3_v2） | 否 |

---

## 3. 逐个说明

### 3.1 `litellm_httpx_timeout_patch.py` — 超时兜底（临时 workaround）

**问题**：LiteLLM v1.84.3 的 `/v1/messages`（anthropic_messages）路由**丢弃所有超时配置**。`async_anthropic_messages_handler` 调 `.post()` 时不传 `timeout=`，回落到 `http_handler` 的模块级默认值——写死 `COMPLETION_HTTP_FALLBACK_SECONDS = 600.0`。

于是 `router_settings.timeout`、`litellm_settings.request_timeout`、per-model `timeout`、`stream_timeout` **四个配置对该路由全部无效**。非流式请求被硬顶在 600s（httpx 的 read timeout 对非流式是总时长上限）；流式不受影响（read timeout 按 chunk 间隔算）。

**修法**：导入时 rebind `http_handler._DEFAULT_TIMEOUT` 为 `httpx.Timeout(timeout=1200, connect=5)`。`get_async_httpx_client()` 构造并缓存 client 时读这个模块全局，patch 在任何请求之前跑，所以覆盖全部 client。类本身是空的 `CustomLogger` 子类，只为让 `callbacks:` 有个实例可挂，**per-request 零开销**。

**为什么不用 `LITELLM_WORKER_STARTUP_HOOKS`**：那条路走裸 `importlib`，依赖 `sys.path`，还得改 `PYTHONPATH`。`callbacks:` 相对 config 目录解析，更省事。

**参数**：秒数读 env `LITELLM_HTTPX_DEFAULT_TIMEOUT`，默认 1200（对齐 ALB idle timeout 1200s——再大也没用，ALB 会先断）。`connect` 单独钉 5s，避免连不上也要等 20 分钟才报错。

**边界**：`_DEFAULT_TIMEOUT` 是全代理共享的，所以这是**全局抬高上限**而非只修那一条路由。只抬高、不缩短，显式传 `timeout=` 的路由（chat/completions、responses）不受影响。`pass_through_endpoints.py` 显式传 `params={"timeout": 600}`，**passthrough 路由仍是 600s 上限**，本 patch 管不到。

**上游**：issue #26752 / #30836，修复 PR #33418（2026-07-15 merged），最早出现在 v1.94.0-rc.1。**1.84–1.93 全部 stable 都没 backport**，所以只能自己 patch。升级后删掉本文件 + `callbacks:` 那一行，然后改用真正的 config 字段。

---

### 3.2 `bedrock_team_tag_hook.py` — per-team 成本归因

**目的**：把 Bedrock 花费按 team 拆分到 Cost Explorer / CUR。

**机制**（AWS IAM principal-based cost attribution，2026-04 GA）：
```
litellm-sa (IRSA) --AssumeRole + TagSession(team=X)--> bedrock-exec role
  --> Bedrock InvokeModel 以 assumed-role/bedrock-exec/litellm-<team> 身份执行
  --> CUR 里 iamPrincipal/team = X
```

在 `async_pre_call_hook` 里按 `user_api_key_dict.team_alias` AssumeRole，把临时凭证塞进 `data["aws_access_key_id"]` 等字段。

**要点**：
- 需要 env `BEDROCK_EXEC_ROLE_ARN`，**没设就整体空转**（`if not EXEC_ROLE_ARN: return data`）。光挂 hook 不给 env 等于没开。
- **没有 team_alias 的请求原样放过**，落在 pod 自己的 IRSA principal 名下，不会失败。
- per-team 凭证缓存 55 分钟（临时凭证有效 1 小时，提前刷新），避免打爆 STS（AssumeRole 约 500/s/account）。
- 对非 Bedrock 后端也会注入 `aws_*`，但那些 provider 直接忽略，安全。原因：pre-call 阶段 `data["model"]` 还是公开的 `model_name`（如 `bedrock-nova-pro`），`custom_llm_provider` 未解析，这里判断不出是不是 bedrock。
- AssumeRole 失败只 warn 不抛，**绝不因为归因失败而弄挂请求**。
- 美东用独立 exec 角色（含 Converse 权限）；详见 [bedrock-per-team-attribution-us-east-1-runbook.md](bedrock-per-team-attribution-us-east-1-runbook.md)。

---

### 3.3 `codex_additional_tools_flatten.py` — Codex 兼容

**问题**：新版 Codex（≥26.707「Responses Lite」序列化）把工具列表塞进一个非标准 input item：

```json
{"type": "additional_tools", "role": "developer", "tools": [...]}
```

Bedrock Mantle 的 Responses API 只认标准 OpenAI schema，直接 `400 validation_error: Invalid 'input': value did not match any expected variant`（Codex issue #32086）。

**修法**：pre-call 时把每个 `additional_tools` item 的 `tools` 合并到顶层 `data["tools"]`，并把该 item 从 `data["input"]` 里删掉。已验证 Mantle 接受这些工具放在标准 `tools` 字段里（含 Codex 的 `custom`/`namespace` 类型）。

**⚠️ 踩过的坑（代码里有注释）**：`found`（见到过 item 吗）必须和 `extra_tools`（item 里有工具吗）**分开记**。Codex 后续轮次会重发一个 `tools` 为**空列表**的 `additional_tools` item（工具在前面轮次已建立）。那个空 item 依然是 Mantle 拒绝的非标准变体，**即使没东西可合并也必须删**。早先版本只看 `extra_tools` 就跳过，导致每个后续轮次都 400。

**作用域**：只处理 `call_type == "aresponses"` 且 input 里真有 `additional_tools` 的请求，其余原样返回。整体 try/except——改写失败就放原始 data 过去，不丢请求。

---

### 3.4 `agentcore_websearch.py` — 托管搜索后端（仅 SG）

继承内置的 `WebSearchInterceptionLogger`，**只覆写 `_execute_search`**，把后端从 SearXNG 换成 Bedrock AgentCore Web Search（MCP + SigV4）。agentic loop / 消息拼接 / 流式 / citation 块全部复用父类——不 fork、不改 LiteLLM 源码、客户端零改动。

**为什么不用 `search_provider` 配置**：LiteLLM 的 `search_provider` 是闭合枚举（perplexity/tavily/searxng…共 17 个），不含 AgentCore，也没有自定义注册口。覆写 `_execute_search` 是绕过限制最轻的路径。

**⚠️ 版本脆弱点**：依赖父类的"私有"方法 `_execute_search(query)`，其返回签名跨版本会变——
- v1.84.x（当前）：`-> str`（纯文本，无原生 citation 块）
- main 较新版本：`-> (str, SearchResponse)`

本实现针对 **1.84.3**。**升级 LiteLLM 时必须回归这个签名**（`inspect.signature` 检查）。

**env**（值见部署文件，不在本文档）：`AGENTCORE_WS_REGION`（钉 `us-east-1`——AgentCore Web Search 只在美东，跨区调用时 SigV4 的 region 必须是 us-east-1 而不是 pod 所在区）、`AGENTCORE_WS_MCP_URL`、`AGENTCORE_WS_TOOL_NAME`、`AGENTCORE_WS_MAX_RESULTS`（默认 10）。IRSA 需要 `bedrock-agentcore:InvokeGateway`。

详见 [agentcore-websearch-runbook.md](agentcore-websearch-runbook.md)；后端效果对比见 [search-backend-benchmark.md](search-backend-benchmark.md)。

---

### 3.5 内置三个

**`websearch_interception`** — Bedrock 上的 Claude **没有原生 web search**（Bedrock Web Grounding 只支持 Nova），所以客户端下发 `web_search` 工具时由网关拦下来、自己跑 agentic loop 去搜、把结果拼回消息。配套 `websearch_interception_params.search_tool_name` 指向 `search_tools:` 里声明的后端。

> ⚠️ 这个拦截**必须非流式**才能截住 `tool_use`，是长请求容易撞超时的根源之一。客户端若 `deny WebSearch`，不下发工具 → 不触发拦截 → 恢复流式。

**`prometheus`** — 暴露 `/metrics`。见 [monitoring-logging-audit-guide.md](monitoring-logging-audit-guide.md)。

**`s3_v2`** — 完整请求/响应异步批量落 S3（不阻塞）。**排查超时的唯一真源**：pod 日志和 SpendLogs 都看不到 `error_str`，只有 S3 日志有；另外独有 TTFT（`completionStartTime`）、cache 分项、`model_parameters`（stream 标志、tools）。配 `s3_callback_params`。查询方法见 [monitoring-logging-audit-guide.md](monitoring-logging-audit-guide.md)。

---

## 4. 新增一个 hook

1. 写 `.py`，导出一个模块级实例：
   ```python
   from litellm.integrations.custom_logger import CustomLogger

   class MyHook(CustomLogger):
       async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
           return data   # 改写 data 后返回

   my_hook_instance = MyHook()
   ```
   **务必**：作用域收窄（只处理该管的 `call_type`）、整体 try/except 后放原始 data 过去、失败只 warn 不抛。

2. 作为一个 key 加到 `04-configmap.yaml` 的 `data:` 下（YAML block scalar，缩进 4 空格）。
3. 在 `config.yaml` 的 `callbacks:` 里加 `"<模块名>.<实例名>"`。注意位置（见 §2 顺序表）。
4. 部署（**不要裸 `kubectl apply` 本仓库的 04**，含占位符）：
   ```bash
   # 导出 live → 本地改 → patch 回去
   kubectl get cm litellm-config -n litellm -o json > /tmp/cm-backup.json
   kubectl create configmap litellm-config -n litellm \
     --from-file=config.yaml=config-new.yaml \
     --from-file=<每个现有 .py 都要重列，否则会丢> \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl rollout restart deployment/litellm -n litellm
   ```
   > `kubectl create configmap --from-file` 是**全量替换**，漏列任何一个现有 key 都会把它删掉。改完先 diff live vs 预期确认字节一致再 rollout。

5. **改完 live 一定同步回本仓库** `04-configmap.yaml` —— 否则下次用 `render-and-apply.sh` 重部会丢。

SG 侧走 CDK：改 `model-config-builder.ts` 的 `callbacks` 列表 + `cluster-stack.ts` 的 `configData`，不要手工 patch（会被下次 deploy 覆盖）。

---

## 5. 验证 hook 真的生效

```bash
# 1) ConfigMap 里 key 齐不齐
kubectl get cm litellm-config -n litellm -o json | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)['data']))"

# 2) 启动日志里有没有加载/执行痕迹（每个 worker 一行）
kubectl logs -n litellm -l app=litellm --tail=3000 | grep -i "httpx timeout patch"
# 3 pod × --num_workers 2 = 应有 6 行

# 3) pre-call hook 是否被调用（这些 hook 都打了 info 日志）
kubectl logs -n litellm -l app=litellm --since=10m | grep -E "BedrockTeamTagHook|CodexAdditionalToolsFlatten"

# 4) 有没有加载失败
kubectl logs -n litellm -l app=litellm --tail=3000 | grep -iE "traceback|ImportError|ModuleNotFound"
```

### ⚠️ 不要用 `kubectl exec python3` 验证导入副作用类的 patch

```bash
# ❌ 永远打印未 patch 的值 —— 这是假阴性
kubectl exec <pod> -- python3 -c "from litellm.llms.custom_httpx import http_handler as h; print(h._DEFAULT_TIMEOUT)"
```
`exec` 起的是**新 python 进程**，不走 LiteLLM 的 callbacks 加载流程。唯一凭据是上面第 2 条的启动日志。

### 回归清单（改任何 hook 后都跑）

- 6 个 Claude 模型走 `/v1/messages`（含 `[1m]` 变体）
- `/v1/chat/completions`（sonnet + grok）
- `/v1/responses`（gpt-5.5、gpt-5.6-luna）—— 覆盖 Codex hook 路径
- 流式 SSE 一次
- 带 `web_search` 工具的请求一次 —— 覆盖 websearch 路径
- pod `RESTARTS` 应为 0

镜像里**没有 curl**，但有 python + requests：
```bash
kubectl exec -n litellm <pod> -- python3 -c "
import os,requests
H={'Authorization':'Bearer '+os.environ['LITELLM_MASTER_KEY']}
r=requests.post('http://localhost:4000/v1/messages',headers=H,
  json={'model':'claude-opus-5','max_tokens':16,'messages':[{'role':'user','content':'say ok'}]},timeout=120)
print(r.status_code)"
```
（用 `os.environ` 取 key，不要在命令行里写明文。）

---

## 6. 相关文档

- [operations.md](operations.md) — 升级 / 回滚 / 已知问题
- [monitoring-logging-audit-guide.md](monitoring-logging-audit-guide.md) — S3 日志字段与查询
- [bedrock-per-team-attribution-us-east-1-runbook.md](bedrock-per-team-attribution-us-east-1-runbook.md) — hook #2 的完整落地步骤
- [agentcore-websearch-runbook.md](agentcore-websearch-runbook.md) — hook #4 的完整落地步骤
- [gateway-alternatives-evaluation.md](gateway-alternatives-evaluation.md) §5 — hook #1 那个超时缺陷的四网关横向对比
