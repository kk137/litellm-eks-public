#!/bin/bash
set -euo pipefail

ACCOUNT_ID="<YOUR_ACCOUNT_ID>"
REGION="us-east-1"
CLUSTER_NAME="litellm-cluster"
DOMAIN="<YOUR_DOMAIN>"
HOSTED_ZONE_ID="<YOUR_HOSTED_ZONE_ID>"

echo "============================================"
echo "LiteLLM EKS 全栈部署脚本"
echo "Account: $ACCOUNT_ID | Region: $REGION"
echo "============================================"

# ============================================================
# Phase 1: 创建 EKS 集群
# ============================================================
echo ""
echo ">>> Phase 1: 创建 EKS 集群 (K8s 1.35)..."
eksctl create cluster -f eksctl-cluster.yaml

echo ">>> 更新 kubeconfig..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# ============================================================
# Phase 2: 创建 Secrets Manager 密钥
# ============================================================
echo ""
echo ">>> Phase 2: 创建 Secrets Manager 密钥..."
echo "请手动设置以下密钥值（替换 YOUR_* 占位符）:"

MASTER_KEY=$(openssl rand -hex 32)
SALT_KEY=$(openssl rand -hex 16)

aws secretsmanager create-secret --name litellm/master-key \
  --secret-string "$MASTER_KEY" --region $REGION 2>/dev/null || \
  aws secretsmanager put-secret-value --secret-id litellm/master-key \
  --secret-string "$MASTER_KEY" --region $REGION

aws secretsmanager create-secret --name litellm/salt-key \
  --secret-string "$SALT_KEY" --region $REGION 2>/dev/null || \
  aws secretsmanager put-secret-value --secret-id litellm/salt-key \
  --secret-string "$SALT_KEY" --region $REGION

echo "  ✅ master-key 和 salt-key 已自动生成"
echo ""
echo "  ⚠️  以下密钥稍后手动创建（不影响部署流程）:"
echo "  aws secretsmanager create-secret --name litellm/azure-api-key --secret-string 'YOUR_AZURE_KEY' --region $REGION"
echo "  aws secretsmanager create-secret --name litellm/azure-api-base --secret-string 'https://YOUR_ENDPOINT.openai.azure.com' --region $REGION"
echo "  aws secretsmanager create-secret --name litellm/gemini-api-key --secret-string 'YOUR_GEMINI_KEY' --region $REGION"
echo "  aws secretsmanager create-secret --name litellm/openai-api-key --secret-string 'YOUR_OPENAI_KEY' --region $REGION"
echo ""
# 先创建占位密钥，避免 ExternalSecret 同步失败
for SECRET_NAME in litellm/azure-api-key litellm/azure-api-base litellm/gemini-api-key litellm/openai-api-key; do
  aws secretsmanager create-secret --name "$SECRET_NAME" \
    --secret-string "PLACEHOLDER_REPLACE_ME" --region $REGION 2>/dev/null || true
done
echo "  ✅ 占位密钥已创建，部署后替换真实值即可"

# ============================================================
# Phase 3: 部署 ElastiCache Redis
# ============================================================
echo ""
echo ">>> Phase 3: 部署 ElastiCache Redis..."

# 获取 VPC 和私有子网
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
NODE_SG=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
  --query 'SecurityGroups[0].SecurityGroupId' --output text)

# Redis 安全组
REDIS_SG=$(aws ec2 create-security-group --group-name litellm-redis-sg \
  --description "LiteLLM Redis SG" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $REDIS_SG --region $REGION \
  --protocol tcp --port 6379 --source-group $NODE_SG

# Redis 子网组
aws elasticache create-cache-subnet-group --region $REGION \
  --cache-subnet-group-name litellm-redis-subnet \
  --cache-subnet-group-description "LiteLLM Redis subnets" \
  --subnet-ids $(echo $PRIVATE_SUBNETS | tr ',' ' ')

# Redis 集群 (单节点 cache.r7g.large，加密+auth)
REDIS_AUTH_TOKEN=$(openssl rand -hex 20)
aws elasticache create-replication-group --region $REGION \
  --replication-group-id litellm-redis \
  --replication-group-description "LiteLLM Redis cache" \
  --engine redis \
  --engine-version 7.1 \
  --cache-node-type cache.r7g.large \
  --num-cache-clusters 2 \
  --cache-subnet-group-name litellm-redis-subnet \
  --security-group-ids $REDIS_SG \
  --transit-encryption-enabled \
  --auth-token "$REDIS_AUTH_TOKEN" \
  --at-rest-encryption-enabled \
  --automatic-failover-enabled \
  --multi-az-enabled \
  --tags Key=Project,Value=litellm

echo "  ⏳ 等待 Redis 创建完成..."
aws elasticache wait replication-group-available \
  --replication-group-id litellm-redis --region $REGION

REDIS_ENDPOINT=$(aws elasticache describe-replication-groups --region $REGION \
  --replication-group-id litellm-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)

# 存储 Redis 连接信息到 Secrets Manager
aws secretsmanager create-secret --name litellm/redis-host \
  --secret-string "$REDIS_ENDPOINT" --region $REGION 2>/dev/null || \
  aws secretsmanager put-secret-value --secret-id litellm/redis-host \
  --secret-string "$REDIS_ENDPOINT" --region $REGION

aws secretsmanager create-secret --name litellm/redis-password \
  --secret-string "$REDIS_AUTH_TOKEN" --region $REGION 2>/dev/null || \
  aws secretsmanager put-secret-value --secret-id litellm/redis-password \
  --secret-string "$REDIS_AUTH_TOKEN" --region $REGION

echo "  ✅ Redis: $REDIS_ENDPOINT"

# ============================================================
# Phase 4: 部署 Aurora PostgreSQL Serverless v2
# ============================================================
echo ""
echo ">>> Phase 4: 部署 Aurora PostgreSQL Serverless v2..."

# RDS 安全组
RDS_SG=$(aws ec2 create-security-group --group-name litellm-rds-sg \
  --description "LiteLLM RDS SG" --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --region $REGION \
  --protocol tcp --port 5432 --source-group $NODE_SG

# RDS 子网组
aws rds create-db-subnet-group --region $REGION \
  --db-subnet-group-name litellm-rds-subnet \
  --db-subnet-group-description "LiteLLM RDS subnets" \
  --subnet-ids $(echo $PRIVATE_SUBNETS | tr ',' ' ')

# Aurora 集群
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
aws rds create-db-cluster --region $REGION \
  --db-cluster-identifier litellm-db \
  --engine aurora-postgresql \
  --engine-version 16.4 \
  --master-username litellm_admin \
  --master-user-password "$DB_PASSWORD" \
  --db-subnet-group-name litellm-rds-subnet \
  --vpc-security-group-ids $RDS_SG \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=8 \
  --storage-encrypted \
  --database-name litellm \
  --tags Key=Project,Value=litellm

# Aurora Serverless v2 实例
aws rds create-db-instance --region $REGION \
  --db-instance-identifier litellm-db-instance-1 \
  --db-cluster-identifier litellm-db \
  --engine aurora-postgresql \
  --db-instance-class db.serverless

echo "  ⏳ 等待 Aurora 创建完成..."
aws rds wait db-instance-available \
  --db-instance-identifier litellm-db-instance-1 --region $REGION

RDS_ENDPOINT=$(aws rds describe-db-clusters --region $REGION \
  --db-cluster-identifier litellm-db \
  --query 'DBClusters[0].Endpoint' --output text)

DATABASE_URL="postgresql://litellm_admin:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/litellm"

aws secretsmanager create-secret --name litellm/database-url \
  --secret-string "$DATABASE_URL" --region $REGION 2>/dev/null || \
  aws secretsmanager put-secret-value --secret-id litellm/database-url \
  --secret-string "$DATABASE_URL" --region $REGION

echo "  ✅ Aurora: $RDS_ENDPOINT"

# ============================================================
# Phase 5: 安装 K8s 组件
# ============================================================
echo ""
echo ">>> Phase 5: 安装 AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo ">>> 安装 External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

echo ">>> 安装 Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# ============================================================
# Phase 6: 创建 IRSA Role
# ============================================================
echo ""
echo ">>> Phase 6: 创建 IRSA IAM Role..."
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')

cat > /tmp/litellm-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
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
    }
  ]
}
EOF

aws iam create-role --role-name litellm-irsa-role \
  --assume-role-policy-document file:///tmp/litellm-trust-policy.json 2>/dev/null || true

aws iam put-role-policy --role-name litellm-irsa-role \
  --policy-name litellm-policy \
  --policy-document file://iam-policy.json

echo "  ✅ IRSA Role 已创建"

# ============================================================
# Phase 7: 部署 LiteLLM K8s 资源
# ============================================================
echo ""
echo ">>> Phase 7: 部署 LiteLLM K8s 资源..."
kubectl apply -f 00-namespace.yaml
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

echo "  ⏳ 等待 Deployment 就绪..."
kubectl rollout status deployment/litellm -n litellm --timeout=300s

# ============================================================
# Phase 8: 配置 Route53 DNS
# ============================================================
echo ""
echo ">>> Phase 8: 配置 Route53 DNS..."
ALB_DNS=$(kubectl get ingress litellm -n litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

ALB_HOSTED_ZONE=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" --output text)

cat > /tmp/r53-record.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DOMAIN",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "$ALB_HOSTED_ZONE",
        "DNSName": "dualstack.$ALB_DNS",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file:///tmp/r53-record.json

echo "  ✅ DNS: $DOMAIN -> $ALB_DNS"

# ============================================================
# Phase 9: 验证
# ============================================================
echo ""
echo "============================================"
echo "🎉 部署完成！"
echo "============================================"
echo ""
echo "端点: https://$DOMAIN"
echo "健康检查: https://$DOMAIN/health/readiness"
echo ""
echo "测试命令:"
echo "  curl -H 'Authorization: Bearer sk-$MASTER_KEY' https://$DOMAIN/v1/chat/completions \\"
echo "    -d '{\"model\": \"claude-3-5-sonnet\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
echo ""
echo "查看状态:"
echo "  kubectl get pods -n litellm"
echo "  kubectl get ingress -n litellm"
echo "  kubectl logs -n litellm -l app=litellm --tail=50"
