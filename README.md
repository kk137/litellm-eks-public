# LiteLLM on Amazon EKS — 生产级部署文档

> 多 LLM 网关：统一代理 AWS Bedrock (Claude)、Google Gemini、OpenAI、Azure OpenAI，  
> 支持 API Key 管理、缓存、限流、可观测性。

## 架构概览

```
                    ┌─────────────────────────────────────────────────┐
                    │                   AWS Cloud                     │
                    │                                                 │
  User ──HTTPS──▶  │  ALB ──▶ EKS (LiteLLM x3) ──▶ Bedrock Claude  │
                    │              │    │                              │
                    │              │    ├──▶ Google Gemini API         │
                    │              │    ├──▶ OpenAI API                │
                    │              │    └──▶ Azure OpenAI API          │
                    │              │                                   │
                    │              ├──▶ ElastiCache Redis (缓存)       │
                    │              └──▶ Aurora PostgreSQL (元数据)      │
                    │                                                 │
                    │  Secrets Manager ◀── External Secrets Operator  │
                    └─────────────────────────────────────────────────┘
```

## 组件清单

| 组件 | 规格 | 用途 |
|------|------|------|
| EKS | K8s 1.35, 3 AZ | 容器编排 |
| 系统节点组 | 2× m7i.large | CoreDNS, kube-proxy 等 |
| 工作负载节点组 | Karpenter 自动扩缩 (Spot + On-Demand) | LiteLLM Pod |
| LiteLLM | 3 副本, `litellm-database:main-stable` | LLM 代理网关 |
| Aurora PostgreSQL | Serverless v2 (0.5–8 ACU) | 用户/Key/用量元数据 |
| ElastiCache Redis | cache.r7g.large × 2, TLS+Auth | 响应缓存 |
| ALB | Internet-facing, HTTPS (ACM), WAFv2 | 入口负载均衡 + 应用层防护 |
| External Secrets Operator | Helm chart | 自动同步 Secrets Manager → K8s Secret |
| AWS LB Controller | Helm chart | 管理 ALB Ingress |

## 前置条件

- AWS CLI v2, `eksctl`, `kubectl`, `helm` 已安装
- 目标账号有足够 IAM 权限（EKS, EC2, RDS, ElastiCache, SecretsManager, IAM, Route53, ACM, ELB）
- 已在 ACM 中申请目标域名的 HTTPS 证书
- 已有 Route53 Hosted Zone 管理目标域名

---

## 部署步骤

### 0. 配置变量

编辑 `deploy.sh` 顶部的变量，替换为你的账号信息：

```bash
ACCOUNT_ID="<你的AWS账号ID>"
REGION="<目标区域>"              # 如 us-east-1
CLUSTER_NAME="litellm-cluster"
DOMAIN="<你的域名>"              # 如 litellm.example.com
HOSTED_ZONE_ID="<Route53 Zone ID>"
```

同时需要修改以下文件中的占位符：

| 文件 | 需替换内容 |
|------|-----------|
| `01-serviceaccount.yaml` | `eks.amazonaws.com/role-arn` 中的账号 ID |
| `07-ingress.yaml` | `certificate-arn` 替换为你的 ACM 证书 ARN |
| `07-ingress.yaml` | `inbound-cidrs` 替换为你的允许访问 CIDR |
| `07-ingress.yaml` | `wafv2-acl-arn` 替换为你的 WAF WebACL ARN |
| `07-ingress.yaml` | `host` 替换为你的域名 |
| `iam-policy.json` | `Resource` 中的账号 ID 和区域 |
| `eksctl-cluster.yaml` | `region`, `availabilityZones` |
| `11-karpenter-nodepool.yaml` | AZ 列表、集群名 |

### 1. 创建 EKS 集群

```bash
eksctl create cluster -f eksctl-cluster.yaml
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
```

预计耗时 ~15 分钟。

### 2. 安装 Karpenter 并创建节点池

```bash
# 2a. 给 private 子网和集群安全组打 Karpenter 发现标签
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query "Subnets[].SubnetId" --output text --region $REGION)
for subnet in $PRIVATE_SUBNETS; do
  aws ec2 create-tags --resources $subnet --tags Key=karpenter.sh/discovery,Value=$CLUSTER_NAME --region $REGION
done
aws ec2 create-tags --resources $CLUSTER_SG --tags Key=karpenter.sh/discovery,Value=$CLUSTER_NAME --region $REGION

# 2b. 创建 Karpenter Node IAM 角色
aws iam create-role --role-name KarpenterNodeRole-$CLUSTER_NAME \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name KarpenterNodeRole-$CLUSTER_NAME --policy-arn arn:aws:iam::aws:policy/$policy
done
aws iam create-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-$CLUSTER_NAME
aws iam add-role-to-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-$CLUSTER_NAME --role-name KarpenterNodeRole-$CLUSTER_NAME
aws eks create-access-entry --cluster-name $CLUSTER_NAME --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-$CLUSTER_NAME --type EC2_LINUX --region $REGION

# 2c. 创建 Karpenter Controller IAM 角色 (IRSA)
# 参考 iam-policy.json 中的 Karpenter Controller 策略

# 2d. 创建 EC2 Spot Service-Linked Role（首次使用 Spot 时需要）
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com

# 2e. Helm 安装 Karpenter
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.endpoint" --output text)
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.3.0" \
  --namespace kube-system \
  --set "settings.clusterName=$CLUSTER_NAME" \
  --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/KarpenterControllerRole-$CLUSTER_NAME" \
  --wait

# 2f. 应用 NodePool 和 EC2NodeClass
kubectl apply -f 11-karpenter-nodepool.yaml
```

### 3. 创建 ElastiCache Redis

```bash
# 获取 VPC 信息
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

NODE_SG=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
  --query 'SecurityGroups[0].SecurityGroupId' --output text)

# 创建 Redis 安全组（允许 EKS 节点访问 6379）
REDIS_SG=$(aws ec2 create-security-group --group-name litellm-redis-sg \
  --description "LiteLLM Redis" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $REDIS_SG --region $REGION \
  --protocol tcp --port 6379 --source-group $NODE_SG

# 创建子网组
aws elasticache create-cache-subnet-group --region $REGION \
  --cache-subnet-group-name litellm-redis-subnet \
  --cache-subnet-group-description "LiteLLM Redis" \
  --subnet-ids $(echo $PRIVATE_SUBNETS | tr ',' ' ')

# 创建 Redis 集群
REDIS_AUTH_TOKEN=$(openssl rand -hex 20)
aws elasticache create-replication-group --region $REGION \
  --replication-group-id litellm-redis \
  --replication-group-description "LiteLLM Redis" \
  --engine redis --engine-version 7.1 \
  --cache-node-type cache.r7g.large \
  --num-cache-clusters 2 \
  --cache-subnet-group-name litellm-redis-subnet \
  --security-group-ids $REDIS_SG \
  --transit-encryption-enabled \
  --auth-token "$REDIS_AUTH_TOKEN" \
  --at-rest-encryption-enabled \
  --automatic-failover-enabled --multi-az-enabled

# 等待就绪（~10 分钟）
aws elasticache wait replication-group-available \
  --replication-group-id litellm-redis --region $REGION

REDIS_ENDPOINT=$(aws elasticache describe-replication-groups --region $REGION \
  --replication-group-id litellm-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)

echo "Redis: $REDIS_ENDPOINT"
echo "Auth Token: $REDIS_AUTH_TOKEN"
```

### 4. 创建 Aurora PostgreSQL Serverless v2

```bash
# RDS 安全组
RDS_SG=$(aws ec2 create-security-group --group-name litellm-rds-sg \
  --description "LiteLLM RDS" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --region $REGION \
  --protocol tcp --port 5432 --source-group $NODE_SG

# 子网组
aws rds create-db-subnet-group --region $REGION \
  --db-subnet-group-name litellm-rds-subnet \
  --db-subnet-group-description "LiteLLM RDS" \
  --subnet-ids $(echo $PRIVATE_SUBNETS | tr ',' ' ')

# Aurora 集群
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
aws rds create-db-cluster --region $REGION \
  --db-cluster-identifier litellm-db \
  --engine aurora-postgresql --engine-version 16.4 \
  --master-username litellm_admin \
  --master-user-password "$DB_PASSWORD" \
  --db-subnet-group-name litellm-rds-subnet \
  --vpc-security-group-ids $RDS_SG \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=8 \
  --storage-encrypted --database-name litellm

# Serverless v2 实例
aws rds create-db-instance --region $REGION \
  --db-instance-identifier litellm-db-instance-1 \
  --db-cluster-identifier litellm-db \
  --engine aurora-postgresql --db-instance-class db.serverless

# 等待就绪（~10 分钟）
aws rds wait db-instance-available \
  --db-instance-identifier litellm-db-instance-1 --region $REGION

RDS_ENDPOINT=$(aws rds describe-db-clusters --region $REGION \
  --db-cluster-identifier litellm-db \
  --query 'DBClusters[0].Endpoint' --output text)

DATABASE_URL="postgresql://litellm_admin:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/litellm"
echo "Aurora: $RDS_ENDPOINT"
```

### 5. 写入 Secrets Manager

```bash
MASTER_KEY=$(openssl rand -hex 32)
SALT_KEY=$(openssl rand -hex 16)

# 必需密钥
aws secretsmanager create-secret --name litellm/master-key   --secret-string "$MASTER_KEY"     --region $REGION
aws secretsmanager create-secret --name litellm/salt-key     --secret-string "$SALT_KEY"        --region $REGION
aws secretsmanager create-secret --name litellm/database-url --secret-string "$DATABASE_URL"    --region $REGION
aws secretsmanager create-secret --name litellm/redis-host   --secret-string "$REDIS_ENDPOINT"  --region $REGION
aws secretsmanager create-secret --name litellm/redis-password --secret-string "$REDIS_AUTH_TOKEN" --region $REGION

# 可选密钥（先用占位符，后续替换真实值）
aws secretsmanager create-secret --name litellm/azure-api-key  --secret-string "PLACEHOLDER" --region $REGION
aws secretsmanager create-secret --name litellm/azure-api-base --secret-string "PLACEHOLDER" --region $REGION
aws secretsmanager create-secret --name litellm/gemini-api-key --secret-string "PLACEHOLDER" --region $REGION
aws secretsmanager create-secret --name litellm/openai-api-key --secret-string "PLACEHOLDER" --region $REGION

echo "Master Key: sk-$MASTER_KEY"
```

> ⚠️ 记录 `MASTER_KEY`，这是调用 LiteLLM API 的认证密钥。

### 6. 安装 Helm 组件

```bash
# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Metrics Server（HPA 依赖）
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### 7. 创建 IRSA Role

```bash
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')

# 创建信任策略
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:litellm:litellm-sa",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role --role-name litellm-irsa-role \
  --assume-role-policy-document file:///tmp/trust-policy.json

# 附加权限策略（Bedrock + SecretsManager + CloudWatch）
aws iam put-role-policy --role-name litellm-irsa-role \
  --policy-name litellm-policy --policy-document file://iam-policy.json

# ⚠️ 重要：Bedrock foundation-model ARN 不含账号 ID，需额外添加
aws iam put-role-policy --role-name litellm-irsa-role \
  --policy-name litellm-bedrock-models \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": ["arn:aws:bedrock:*::foundation-model/*"]
    }]
  }'
```

### 8. 部署 K8s 资源

```bash
kubectl apply -f 00-namespace.yaml

# ⚠️ 关键：放宽 PodSecurity 到 baseline（LiteLLM 镜像需要 root 运行 Prisma）
kubectl label ns litellm \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline --overwrite

kubectl apply -f 01-serviceaccount.yaml
kubectl apply -f 02-secretstore.yaml
kubectl apply -f 03-externalsecret.yaml
kubectl apply -f 04-configmap.yaml
kubectl apply -f 05-deployment.yaml
kubectl apply -f 06-service.yaml
kubectl apply -f 07-ingress.yaml
kubectl apply -f 08-hpa.yaml
kubectl apply -f 09-pdb.yaml
kubectl apply -f 10-networkpolicy.yaml

# 等待就绪
kubectl rollout status deployment/litellm -n litellm --timeout=300s
```

### 9. 配置 Route53 DNS

```bash
ALB_DNS=$(kubectl get ingress litellm -n litellm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

ALB_ZONE=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" --output text)

aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$DOMAIN\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"$ALB_ZONE\",
          \"DNSName\": \"dualstack.$ALB_DNS\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }"
```

### 10. 验证

```bash
# 健康检查
curl -sk https://$DOMAIN/health/readiness

# 期望输出：{"status":"connected","db":"connected","cache":"redis",...}

# 调用 Claude
curl -sk https://$DOMAIN/v1/chat/completions \
  -H "Authorization: Bearer sk-$MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3-5-sonnet",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## 文件清单

```
litellm-eks/
├── deploy.sh                    # 一键部署脚本（包含所有步骤）
├── eksctl-cluster.yaml          # EKS 集群定义
├── iam-policy.json              # IRSA IAM 权限策略
├── 00-namespace.yaml            # Namespace
├── 01-serviceaccount.yaml       # ServiceAccount (IRSA)
├── 02-secretstore.yaml          # ESO SecretStore
├── 03-externalsecret.yaml       # ESO ExternalSecret (9 个密钥)
├── 04-configmap.yaml            # LiteLLM 配置（模型列表、路由、缓存）
├── 05-deployment.yaml           # Deployment (3 副本, 反亲和, 探针)
├── 06-service.yaml              # ClusterIP Service
├── 07-ingress.yaml              # ALB Ingress (HTTPS, CIDR 限制)
├── 08-hpa.yaml                  # HPA (CPU 65% / Memory 75%, 3-20 副本)
├── 09-pdb.yaml                  # PDB (最少 2 可用)
├── 10-networkpolicy.yaml        # NetworkPolicy (零信任)
└── 11-karpenter-nodepool.yaml   # Karpenter v1.3.0 NodePool + EC2NodeClass
```

---

## 踩坑记录 & 注意事项

### 🔴 必须注意

| # | 问题 | 解决方案 |
|---|------|---------|
| 1 | **Prisma query engine 权限** — LiteLLM 镜像在构建时以 root 安装 Prisma binary 到 `/root/.cache/prisma-python/`，`runAsUser: 1000` 无法访问 | 使用 `litellm-database` 镜像 + PodSecurity 设为 `baseline` + 不设 `runAsUser`（以 root 运行） |
| 2 | **Bedrock foundation-model ARN** — 格式为 `arn:aws:bedrock:*::foundation-model/*`（无账号 ID，双冒号） | IAM 策略中 Resource 不能包含账号 ID |
| 3 | **NetworkPolicy 阻断 ALB→Pod** — ALB 通过 VPC IP 直连 Pod（target-type: ip），不经过 kube-system namespace | ingress 规则需添加 `ipBlock: <VPC CIDR>` |
| 4 | **NetworkPolicy 阻断 Pod→ElastiCache/RDS** — Redis/RDS 在 VPC 内但不在 K8s namespace 中 | egress 规则用 `ipBlock: <VPC CIDR>` 而非 `namespaceSelector` |
| 5 | **`--detailed_debug False` 参数** — LiteLLM 不支持此 CLI 参数，会导致启动崩溃 | 不要添加此参数 |
| 6 | **ALB access_logs 注解** — 如果指定的 S3 bucket 不存在，ALB Controller 会 reconcile 失败 | 要么先创建 bucket，要么不加 access_logs 注解 |
| 7 | **Karpenter v1.3.0 API 变更** — `nodeClassRef.apiVersion` 字段已移除，`consolidationPolicy` 值 `WhenUnderutilized` 改为 `WhenEmptyOrUnderutilized` | 使用 `nodeClassRef.group: karpenter.k8s.aws` 替代；EC2NodeClass 必须包含 `amiSelectorTerms` |
| 8 | **Karpenter Spot 首次使用** — 缺少 EC2 Spot Service-Linked Role 导致 `AuthFailure.ServiceLinkedRoleCreationNotPermitted` | 需先执行 `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com` |
| 9 | **Karpenter 子网/安全组发现** — NodeClaim 创建失败，找不到子网或安全组 | 必须给 private 子网和集群安全组打 `karpenter.sh/discovery=<cluster-name>` 标签 |

---

## WAF 配置

ALB 已关联 WAFv2 WebACL，提供三层应用层防护：

| 规则 | 模式 | 说明 |
|------|------|------|
| AWS Managed Core Rule Set | Count（仅记录） | SQL 注入、XSS、路径遍历等 OWASP Top 10 |
| AWS Managed Known Bad Inputs | Count（仅记录） | 已知恶意请求模式 |
| Rate Limit 1000/5min | Block（拦截） | 单 IP 每 5 分钟超 1000 次请求则拦截 |

**创建 WAF WebACL**：

```bash
# 创建 WAFv2 WebACL（Core Rule Set Count + Known Bad Inputs Count + Rate Limit Block）
aws wafv2 create-web-acl \
  --name litellm-waf \
  --scope REGIONAL \
  --default-action Allow={} \
  --rules '[
    {"Name":"AWS-AWSManagedRulesCommonRuleSet","Priority":1,"OverrideAction":{"Count":{}},"Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"CommonRuleSet"}},
    {"Name":"AWS-AWSManagedRulesKnownBadInputsRuleSet","Priority":2,"OverrideAction":{"Count":{}},"Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesKnownBadInputsRuleSet"}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"KnownBadInputs"}},
    {"Name":"RateLimit-1000-per-IP","Priority":3,"Action":{"Block":{}},"Statement":{"RateBasedStatement":{"Limit":1000,"EvaluationWindowSec":300,"AggregateKeyType":"IP"}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"RateLimit"}}
  ]' \
  --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=litellm-waf \
  --tags Key=Project,Value=litellm \
  --region us-east-1
```

将返回的 ARN 填入 `07-ingress.yaml` 的 `wafv2-acl-arn` 注解，然后 `kubectl apply`。

**观察与切换**：在 CloudWatch 中观察 `CommonRuleSet` 和 `KnownBadInputs` 指标，确认无误报后将 Count 切换为 Block。
| 7 | **Rolling Update 限制** — hard podAntiAffinity + 节点数 = 副本数时，无法滚动更新（没有空闲节点放新 Pod） | 更新时先 `kubectl scale deployment/litellm --replicas=0 -n litellm` 再 `scale --replicas=3`，或增加节点数到 > 副本数 |

### 🟡 建议

| 项目 | 说明 |
|------|------|
| **镜像版本** | 生产环境建议锁定具体版本（如 `v1.81.14`）而非 `main-stable` |
| **Claude 模型** | Claude 3.5 Sonnet v2 已标记 Legacy，建议使用 Claude Sonnet 4 |
| **LITELLM_MIGRATION_DIR** | 设为 `/tmp/migrations`，避免写入只读的 site-packages 目录 |
| **HOME 环境变量** | 设为 `/tmp`，确保 Prisma CLI 的缓存写入可写目录 |

---

## 模型配置

在 `04-configmap.yaml` 中配置模型列表。当前支持：

### AWS Bedrock Claude 模型（IRSA 认证，无需 API Key）

| 模型别名 | Bedrock 模型 ID | 说明 |
|----------|----------------|------|
| `claude-sonnet-4.6` | `bedrock/us.anthropic.claude-sonnet-4-6` | Claude Sonnet 4.6（最新） |
| `claude-sonnet-4.5` | `bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Claude Sonnet 4.5 |
| `claude-sonnet-4` | `bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0` | Claude Sonnet 4 |
| `claude-opus-4.6` | `bedrock/us.anthropic.claude-opus-4-6-v1` | Claude Opus 4.6 |
| `claude-opus-4.5` | `bedrock/us.anthropic.claude-opus-4-5-20251101-v1:0` | Claude Opus 4.5 |
| `claude-haiku-4.5` | `bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 |
| `claude-3.5-haiku` | `bedrock/us.anthropic.claude-3-5-haiku-20241022-v1:0` | Claude 3.5 Haiku |

### AWS Bedrock Nova 模型（IRSA 认证）

| 模型别名 | Bedrock 模型 ID | 说明 |
|----------|----------------|------|
| `nova-premier` | `bedrock/us.amazon.nova-premier-v1:0` | Nova Premier |
| `nova-pro` | `bedrock/us.amazon.nova-pro-v1:0` | Nova Pro |
| `nova-lite` | `bedrock/us.amazon.nova-lite-v1:0` | Nova Lite |
| `nova-micro` | `bedrock/us.amazon.nova-micro-v1:0` | Nova Micro |

### 其他 LLM 提供商（需 API Key）

| 模型别名 | 实际模型 | Provider | 认证方式 |
|----------|---------|----------|---------|
| `gpt-4o` | Azure GPT-4o | Azure OpenAI | `AZURE_API_KEY` + `AZURE_API_BASE` |
| `gemini-2.0-flash` | Gemini 2.0 Flash | Google | `GEMINI_API_KEY` |
| `gemini-2.5-pro` | Gemini 2.5 Pro Preview | Google | `GEMINI_API_KEY` |
| `gpt-4o-openai` | GPT-4o | OpenAI | `OPENAI_API_KEY` |
| `o3-mini` | o3-mini | OpenAI | `OPENAI_API_KEY` |

添加新模型只需编辑 ConfigMap 并重启 Pod：

```bash
kubectl edit configmap litellm-config -n litellm
kubectl rollout restart deployment/litellm -n litellm
```

---

## 运维命令

```bash
# 查看 Pod 状态
kubectl get pods -n litellm

# 查看日志
kubectl logs -n litellm -l app=litellm --tail=100

# 健康检查
curl -sk https://$DOMAIN/health/readiness

# 更新部署（滚动更新，零停机）
kubectl apply -f 05-deployment.yaml
kubectl rollout restart deployment/litellm -n litellm
# 注意：如果工作节点数 = 副本数（无空闲节点），hard podAntiAffinity 会导致
# 滚动更新卡住，此时需要 scale 0→3 或增加节点

# 更新 API Key
aws secretsmanager put-secret-value --secret-id litellm/openai-api-key \
  --secret-string "sk-your-real-key" --region $REGION
# ESO 每小时自动同步，或手动触发：
kubectl delete secret litellm-secrets -n litellm
# ExternalSecret 会自动重建

# 查看 HPA 状态
kubectl get hpa -n litellm

# 查看 ALB 状态
kubectl get ingress -n litellm
```

---

## 清理

```bash
# 删除 K8s 资源
kubectl delete -f 07-ingress.yaml
kubectl delete -f 05-deployment.yaml
kubectl delete ns litellm

# 删除 ElastiCache
aws elasticache delete-replication-group --replication-group-id litellm-redis \
  --no-final-snapshot-identifier --region $REGION

# 删除 Aurora
aws rds delete-db-instance --db-instance-identifier litellm-db-instance-1 \
  --skip-final-snapshot --region $REGION
aws rds delete-db-cluster --db-cluster-identifier litellm-db \
  --skip-final-snapshot --region $REGION

# 删除 Secrets Manager
for s in master-key salt-key database-url redis-host redis-password \
         azure-api-key azure-api-base gemini-api-key openai-api-key; do
  aws secretsmanager delete-secret --secret-id "litellm/$s" \
    --force-delete-without-recovery --region $REGION
done

# 删除 IAM Role
aws iam delete-role-policy --role-name litellm-irsa-role --policy-name litellm-policy
aws iam delete-role-policy --role-name litellm-irsa-role --policy-name litellm-bedrock-models
aws iam delete-role --role-name litellm-irsa-role

# 删除 EKS 集群
eksctl delete cluster --name $CLUSTER_NAME --region $REGION

# 删除 Route53 记录（手动在控制台或 CLI）
# 删除安全组（VPC 删除后自动清理）
```
