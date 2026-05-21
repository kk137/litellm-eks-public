# CloudFront + Internal ALB 改造方案

将 LiteLLM 入口从 Internet-facing ALB 改为 CloudFront + VPC Origin + Internal ALB，ALB 不再暴露公网。

## 改造前后对比

```
当前：
  用户 → Route53 (litellm.<YOUR_DOMAIN>) → Internet-facing ALB → Pod

改造后：
  用户 → Route53 → CloudFront → VPC Origin（内网） → Internal ALB → Pod
```

| 维度 | 当前 | 改造后 |
|------|------|--------|
| ALB 类型 | Internet-facing | **Internal** |
| 公网暴露点 | ALB DNS | CloudFront domain |
| TLS 终止 | ALB | CloudFront edge |
| WAF | ALB WAFv2 | CloudFront WAF（边缘拦截） |
| SSE streaming | ✅ | ✅（byte streaming 透传） |
| 安全面 | ALB 直接承受公网流量 | ALB 隐藏在 VPC 内 |

---

## 前置条件

- [x] Route53 管理 DNS（`litellm.<YOUR_DOMAIN>`）
- [ ] ACM 证书（CloudFront 需要 **us-east-1** 区域的证书）
- [ ] VPC 子网 ID（Internal ALB 所在的 private subnet）
- [ ] 安全组 ID（允许 CloudFront VPC Origin 访问 ALB 的 443/80 端口）

---

## 改造步骤

### Step 1：确认 ACM 证书

CloudFront 只能使用 **us-east-1** 区域的 ACM 证书。

```bash
# 查看 us-east-1 的证书
aws acm list-certificates --region us-east-1 \
  --query 'CertificateSummaryList[?contains(DomainName, `<YOUR_DOMAIN>`)].{Domain:DomainName,ARN:CertificateArn,Status:Status}' \
  --output table

# 如果没有，需要申请：
aws acm request-certificate \
  --domain-name "litellm.<YOUR_DOMAIN>" \
  --validation-method DNS \
  --region us-east-1
# 然后在 Route53 添加 CNAME 验证记录
```

### Step 2：ALB 改为 Internal

修改 `07-ingress.yaml`：

```yaml
# Before
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing

# After
annotations:
  alb.ingress.kubernetes.io/scheme: internal
```

```bash
kubectl apply -f 07-ingress.yaml
# ALB Controller 会创建一个新的 Internal ALB
# 记录新 ALB 的 ARN 和 DNS（用于 VPC Origin）
```

⚠️ **注意**：改 scheme 会导致 ALB Controller **删除旧 ALB 并创建新 ALB**（不是原地修改）。在 CloudFront 配置完成前，会有短暂服务中断。

**建议流程**：先不改 ALB，先创建 CloudFront + VPC Origin 指向当前 ALB，DNS 切到 CF 后再改 ALB 为 Internal。

### Step 3：创建 VPC Origin

```bash
# 获取 ALB ARN（改为 Internal 后的）
ALB_ARN=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName, `litellm`)].LoadBalancerArn' --output text)

# 创建 VPC Origin
aws cloudfront create-vpc-origin \
  --vpc-origin-endpoint-config '{
    "Name": "litellm-internal-alb",
    "Arn": "'$ALB_ARN'",
    "HTTPPort": 80,
    "HTTPSPort": 443,
    "OriginProtocolPolicy": "https-only",
    "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
  }' \
  --region us-east-1

# 记录返回的 VpcOriginId
```

### Step 4：创建 CloudFront Distribution

```bash
# Origin Request Policy: 转发所有 header（LiteLLM 需要 Authorization 等）
# Cache Policy: CachingDisabled（LLM API 不缓存）
# Origin Response Timeout: 60s（Claude Opus 首 token 可能 10-30s）

aws cloudfront create-distribution \
  --distribution-config '{
    "CallerReference": "litellm-'$(date +%s)'",
    "Comment": "LiteLLM Proxy - Internal ALB via VPC Origin",
    "Enabled": true,
    "DefaultCacheBehavior": {
      "TargetOriginId": "litellm-vpc-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"]},
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
      "Compress": true
    },
    "Origins": {
      "Quantity": 1,
      "Items": [{
        "Id": "litellm-vpc-origin",
        "DomainName": "<INTERNAL_ALB_DNS>",
        "VpcOriginConfig": {
          "VPCOriginId": "<VPC_ORIGIN_ID>"
        }
      }]
    },
    "Aliases": {"Quantity": 1, "Items": ["litellm.<YOUR_DOMAIN>"]},
    "ViewerCertificate": {
      "ACMCertificateArn": "<ACM_CERT_ARN_US_EAST_1>",
      "SSLSupportMethod": "sni-only",
      "MinimumProtocolVersion": "TLSv1.2_2021"
    }
  }' \
  --region us-east-1

# 记录 CloudFront Domain Name（如 d1234abcdef.cloudfront.net）
```

### Step 5：配置 Origin Response Timeout

```bash
# 默认 30s 对 LLM 不够，需要调到 60s
# 在 Distribution 的 Origin 配置中设置：
#   OriginReadTimeout: 60
#   OriginKeepaliveTimeout: 60

# 通过 update-distribution 修改（或在创建时就指定）
```

### Step 6：Route53 DNS 切换

```bash
# 获取 CloudFront domain
CF_DOMAIN="d1234abcdef.cloudfront.net"

# 获取 Hosted Zone ID
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "<YOUR_DOMAIN>" \
  --query 'HostedZones[0].Id' --output text)

# 切换 DNS：从 ALB → CloudFront
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "litellm.<YOUR_DOMAIN>",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "'$CF_DOMAIN'",
          "EvaluateTargetHealth": false
        }
      }
    }]
  }'
```

`Z2FDTNDATAQYW2` 是 CloudFront 的固定 Hosted Zone ID（所有 CF Distribution 通用）。

### Step 7：WAF 迁移（可选）

```bash
# 当前 WAF 关联在 ALB 上
# 如果要改为 CloudFront WAF（边缘拦截更优）：

# 1. 创建 CloudFront 用的 WAF WebACL（必须在 us-east-1）
# 2. 关联到 Distribution
# 3. 移除 ALB 上的 WAF 关联

# 或者保留 ALB WAF 也行（两层 WAF 不冲突，但没必要）
```

### Step 8：验证

```bash
# 1. DNS 解析确认
dig litellm.<YOUR_DOMAIN>
# 应该返回 CloudFront IP（不是 ALB IP）

# 2. 健康检查
curl -s https://litellm.<YOUR_DOMAIN>/health/liveliness
# 返回 "I'm alive!"

# 3. SSE Streaming 验证
curl -sN https://litellm.<YOUR_DOMAIN>/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_LITELLM_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-haiku45","messages":[{"role":"user","content":"count 1 to 5"}],"stream":true}'
# 应逐 token 流式返回，不 buffer

# 4. 确认 ALB 不再公网可达
nslookup <old-alb-dns>
# Internal ALB 应该只返回私有 IP（10.x.x.x）
curl -sk https://<old-alb-dns>/health/liveliness
# 应超时或拒绝（从公网访问不到）

# 5. CloudFront 响应头确认
curl -sI https://litellm.<YOUR_DOMAIN>/health/liveliness | grep -i "x-cache\|via\|server"
# 应看到 x-cache: Miss from cloudfront / via: ... CloudFront
```

---

## 零停机切换顺序（推荐）

避免服务中断的正确顺序：

```
1. 创建 ACM 证书（us-east-1）并完成 DNS 验证
   ↓ 等证书 ISSUED（通常 5-30 分钟）
2. 保持 ALB 为 Internet-facing（不改）
3. 创建 CloudFront Distribution
   - Origin 先直接指向当前 Internet-facing ALB（普通 HTTPS origin，不用 VPC Origin）
   - 配好 Alias + ACM 证书
   ↓ 等 Distribution Deployed（通常 5-15 分钟）
4. Route53 DNS 切到 CloudFront
   ↓ 等 DNS 传播（TTL 时间，通常 60s-300s）
5. 确认流量已经走 CloudFront（看 x-cache header）
6. 此时：用户 → CloudFront → Internet-facing ALB（中间状态，已安全）
7. 改 ALB 为 Internal + 创建 VPC Origin
8. 更新 CloudFront Origin 从 HTTPS origin 改为 VPC Origin
9. 验证全链路正常
10. 删除旧的 Internet-facing ALB 安全组入站规则（或 ALB Controller 自动处理）
```

这样**全程不断服务**。

---

## 回滚方案

如果改造出问题：

```bash
# 快速回滚：DNS 切回 ALB
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "litellm.<YOUR_DOMAIN>",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "<ALB_HOSTED_ZONE_ID>",
          "DNSName": "<ALB_DNS>",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

# 如果 ALB 已改为 Internal，需要改回 Internet-facing：
# 修改 07-ingress.yaml scheme → internet-facing
# kubectl apply -f 07-ingress.yaml
```

---

## 成本影响

| 项 | 改造前 | 改造后 |
|----|--------|--------|
| ALB | ~$30/月（Internet-facing） | ~$30/月（Internal，价格相同） |
| CloudFront | $0 | **< $1/月**（当前流量） |
| WAF | ALB WAFv2 ~$5/月 | 同（保留 ALB WAF 或迁到 CF） |
| **总增量** | — | **< $1/月** |

---

## 涉及的项目文件改动

| 文件 | 改动 |
|------|------|
| `07-ingress.yaml` | annotation `scheme: internal` |
| `README.md` | 架构图更新（加 CloudFront 层） |
| `OPERATIONS.md` | 新增 CloudFront 运维章节 |
| `deploy.sh` | 可选：加 CloudFront 创建步骤 |

---

## 执行前 Checklist

```
[ ] ACM 证书已在 us-east-1 申请并 ISSUED
[ ] 确认当前 ALB 的安全组 / subnet 信息
[ ] 选定执行时间窗口（建议非高峰）
[ ] 备份当前 Route53 记录
[ ] 备份 07-ingress.yaml
[ ] 通知相关使用方（短暂 DNS 切换期可能有 1-2 次请求失败）
```

---

## 参考

- `litellm-on-eks-guide/docs/10-cloudfront.md` — guide 的 CloudFront 配置步骤
- `CDN-ACCELERATION-ANALYSIS.md` — 加速效果分析文档
- AWS 文档：[CloudFront VPC Origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
