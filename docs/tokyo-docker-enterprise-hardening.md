# 东京 Docker 环境企业级改造方案

> 目标：在**保持单机 Docker 简化形态**的前提下，把东京 LiteLLM 环境补齐到企业级要求
> （数据持久 / 实例自愈 / 凭证安全），对标 LiteLLM 官方 CloudFormation（EC2+ASG+RDS）
> 模板与官方 [生产最佳实践](https://docs.litellm.ai/docs/proxy/prod)。
>
> **本文档只描述方案，不含任何真实账号 ID / VPC ID / 域名**（用占位符 `<...>`，
> 执行时从命令查实）。动 live 东京机的每一步都应先备份、可回滚。

## 0. 现状基线（评估结论）

| 项 | 现状 | 企业级判定 |
|---|---|---|
| 计算 | 单台 `r6i.large` EC2，单 AZ（`<AZ_A>`），裸实例无 ASG | 🔴 实例挂=全挂 |
| 数据库 | **EC2 上的 `postgres:16` 容器**，数据在本地 EBS（316 MB / 33 表 / 2267 spendlog） | 🔴 实例销毁=丢数据，无备份 |
| DB 密码 | 明文弱口令（硬编码在 compose / DATABASE_URL，具体值见本地文件） | 🔴 弱口令 |
| 磁盘 | 20 G，**已用 85%** | 🔴 当周宕机风险 |
| 入口 | 端口 4000 只对 CloudFront prefix-list 开放，边缘 WAF/TLS | ✅ 已达标 |
| 凭证 | master/Mantle key 走 Secrets Manager，Bedrock 走 instance-profile IAM | ✅ 已达标 |
| PII | presidio analyzer/anonymizer 脱敏 | ✅ 已达标 |

**改造原则**：保留右列 ✅，只补左列 🔴。**不上 K8s**（那是 us-east-1 EKS 的定位），
单实例 compose 形态不变，把"有状态"和"自愈"两件事交给托管服务。

## 1. 改造目标架构

```
          CloudFront (WAF/TLS, 不变)
                │  (CloudFront managed prefix-list)
                ▼
   ┌─────────  ASG (Min1/Max1, 跨 1a/1c/1d 子网)  ─────────┐
   │  EC2 r6i.large (launch template + user-data 自举)       │
   │    docker compose: litellm + searxng + presidio×2       │
   │    └── DATABASE_URL ──┐  (容器内不再跑 postgres)         │
   └───────────────────────┼─────────────────────────────────┘
                           ▼
            RDS PostgreSQL (Multi-AZ 单实例, db.t4g.micro)
              自动备份 + PITR，密码在 Secrets Manager
```

与官方 CFN 模板的对应：`LiteLLMServerAutoScalingGroup` → 我们的 ASG；
`LiteLLMDB (RDS::DBInstance)` → 我们的 Multi-AZ RDS。我们比官方模板多保留了
CloudFront 入口、Secrets、presidio，并把官方的明文密码/单 AZ/t2.micro 都改强。

## 2. 真实值（执行时查，不入库）

```bash
export REGION=ap-northeast-1
export INSTANCE_ID=<TOKYO_EC2_INSTANCE_ID>        # aws ec2 describe-instances ... Name=litellm-docker
export VPC_ID=<TOKYO_VPC_ID>                       # 该实例的 VpcId
export EC2_SG=<TOKYO_EC2_SG>                        # 该实例的 SecurityGroup
# 三个 AZ 子网（Multi-AZ RDS subnet group 需 ≥2 个不同 AZ）
export SUBNET_A=<SUBNET_AZ_A> SUBNET_C=<SUBNET_AZ_C> SUBNET_D=<SUBNET_AZ_D>
```

---

## 阶段 0 · 紧急止血（与架构无关，建议立即做）

**风险**：磁盘 85%，Postgres 写盘 + Docker 日志会撑爆 → 宕机。

### 0.1 扩 EBS 卷 20G → 50G（在线扩，无需停机）
```bash
VOL=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text)
aws ec2 modify-volume --volume-id $VOL --size 50 --region $REGION
# 等待 optimizing 完成后，在实例上扩文件系统（SSM）：
#   sudo growpart /dev/nvme0n1 1 && sudo xfs_growfs / (或 resize2fs)
```

### 0.2 Docker 日志轮转（防日志撑爆）
在实例 `/etc/docker/daemon.json` 加：
```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
```
`sudo systemctl restart docker` 后重启 compose 生效（已有容器需重建才套用）。

**回滚**：扩盘不可逆但无害；日志配置删文件即恢复。

---

## 阶段 1 · DB 迁 RDS（消除最大硬伤：数据持久）

> 数据仅 316 MB，pg_dump/restore 几分钟完成，停机窗口很短。

### 1.1 DB 密码进 Secrets Manager（替换原明文弱口令）
```bash
NEWPW=$(openssl rand -base64 24 | tr -d '/+=')
aws secretsmanager create-secret --region $REGION \
  --name litellm-docker/db-password --secret-string "$NEWPW"
```

### 1.2 建 RDS（Multi-AZ 单实例）
```bash
# subnet group（≥2 AZ）
aws rds create-db-subnet-group --region $REGION \
  --db-subnet-group-name litellm-tokyo-rds \
  --db-subnet-group-description "litellm tokyo" \
  --subnet-ids $SUBNET_A $SUBNET_C $SUBNET_D

# RDS 安全组：只允许 EC2 SG 访问 5432
RDS_SG=$(aws ec2 create-security-group --region $REGION \
  --group-name litellm-tokyo-rds-sg --description "RDS from litellm EC2" \
  --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region $REGION \
  --group-id $RDS_SG --protocol tcp --port 5432 --source-group $EC2_SG

# 创建实例（Multi-AZ, 加密, 7 天备份, 删除保护）
aws rds create-db-instance --region $REGION \
  --db-instance-identifier litellm-tokyo \
  --engine postgres --engine-version 16 \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --master-username litellm \
  --master-user-password "$NEWPW" \
  --db-name litellm \
  --multi-az \
  --db-subnet-group-name litellm-tokyo-rds \
  --vpc-security-group-ids $RDS_SG \
  --backup-retention-period 7 \
  --no-publicly-accessible \
  --deletion-protection
```

### 1.3 迁移数据（短暂停机）
```bash
# (SSM 在实例上执行)
# a. 停 litellm 容器（停止写入，db 容器保持运行）
docker stop litellm
# b. dump 现有库
docker exec litellm-db pg_dump -U litellm -d litellm -Fc -f /tmp/litellm.dump
docker cp litellm-db:/tmp/litellm.dump /home/ec2-user/litellm/
# c. restore 到 RDS（实例上需有 psql/pg_restore 客户端）
RDS_EP=$(aws rds describe-db-instances --db-instance-identifier litellm-tokyo \
  --region $REGION --query "DBInstances[0].Endpoint.Address" --output text)
PGPASSWORD=$NEWPW pg_restore -h $RDS_EP -U litellm -d litellm --no-owner \
  /home/ec2-user/litellm/litellm.dump
```

### 1.4 切换 compose 指向 RDS
- `docker-compose.yaml`：**删掉 postgres service** 和 `pgdata` volume；litellm 不再 `depends_on postgres`。
- `DATABASE_URL` 改为 `postgresql://litellm:<从secret注入>@<RDS_EP>:5432/litellm`。
- `fetch-secrets.sh`：增加拉 `litellm-docker/db-password`，写进 `.env` 供 compose 注入（**绝不明文进 compose**）。
- `docker compose up -d`，验证 `/health` 返回 db connected。

**回滚**：切回原 compose（postgres service + 旧 DATABASE_URL），本地容器数据未删仍在；
确认 RDS 稳定运行 ≥数日后再删本地 `pgdata`。

---

## 阶段 2 · EC2 进 ASG（消除可用性硬伤：实例自愈）

> 目标 Min1/Max1：实例挂掉 ASG 自动在另一 AZ 拉新台。配合阶段 1 的 RDS，
> 数据不随实例走，新实例自举后接上同一个 RDS 即恢复。

### 2.1 固化"自举"——让新实例能自动起容器栈
当前 compose/config 是手动上传的。进 ASG 前必须让实例**开机即自我组装**：
- 方案 A（推荐）：把 config.yaml / docker-compose.yaml / presidio 配置 / fetch-secrets.sh
  放进 **S3**（或 SSM Parameter），user-data 开机拉取 + `docker compose up -d`。
- 方案 B：做一个预装好的自定义 **AMI**（golden image），user-data 只负责拉 secret + 起栈。

> ⚠️ 这是阶段 2 的真正工作量所在。当前实例是"手工宠物"，ASG 要求"可重建的牲畜"。

### 2.2 Launch Template + ASG
```bash
# 用现有实例的规格做 launch template（含 IAM profile / SG / user-data）
aws ec2 create-launch-template --region $REGION \
  --launch-template-name litellm-tokyo-lt \
  --launch-template-data '{...instanceType:r6i.large, iamInstanceProfile, securityGroupIds, userData(base64)...}'

aws autoscaling create-auto-scaling-group --region $REGION \
  --auto-scaling-group-name litellm-tokyo-asg \
  --launch-template LaunchTemplateName=litellm-tokyo-lt \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier "$SUBNET_A,$SUBNET_C,$SUBNET_D" \
  --health-check-type EC2 --health-check-grace-period 300
```

### 2.3 入口跟随
- CloudFront origin 当前指向固定实例的 public IP/DNS。实例由 ASG 重建后 IP 会变。
  **需要稳定入口**：在 ASG 前挂一个 **ALB**（target group 跟随 ASG），CloudFront origin
  指向 ALB DNS（稳定）。或者用 EIP + lifecycle hook 重绑（较脆，不推荐）。
- 这一步让"自愈"真正闭环；否则实例重建后 CloudFront 仍指旧 IP。

**回滚**：ASG desired 设 0 或删 ASG，手动起回原实例 + 改回 CloudFront origin。

---

## 阶段 3 · 官方生产配置项收尾（低风险，config 层）

对照官方 /prod，补这些（改 `config.yaml` / 环境变量）：
- `export LITELLM_MODE="PRODUCTION"`（关 load_dotenv）
- `general_settings`/`litellm_settings`：`request_timeout`、`set_verbose: False`、`json_logs: true`
- salt key 固定（已加模型，**不可再改**——确认现值已存 Secrets Manager）
- CloudWatch agent + 一条**磁盘/实例健康告警**（补可观测硬伤）

---

## 执行顺序与风险

| 阶段 | 风险 | 停机 | 可独立交付 |
|---|---|---|---|
| 0 止血（扩盘/日志） | 低 | 无 | ✅ 立即可做 |
| 1 DB 迁 RDS | 中（数据迁移） | 几分钟 | ✅ 做完即消除最大硬伤 |
| 2 EC2 进 ASG | 高（要先固化自举 + 加 ALB） | 视情况 | ⚠️ 工作量最大 |
| 3 config 收尾 | 低 | rollout | ✅ |

**建议节奏**：先做阶段 0（本周止血）→ 阶段 1（数据持久，性价比最高）→ 评估是否真需要
阶段 2（用户量不大时，"DB 已托管 + 备份"已覆盖最严重的数据丢失风险；实例自愈的边际
收益要权衡 ASG+ALB 的改造成本）。

## 成本增量（粗估，用户量不大）

- RDS db.t4g.micro Multi-AZ：约两台 micro 的费用（Multi-AZ 翻倍），月级别几十美元
- ALB（若做阶段 2）：固定月费 + LCU
- EBS 扩容 30G gp3：每月数美元
- 阶段 0+1 增量很小；阶段 2 的 ALB 是主要新增固定成本

## 与 us-east-1 EKS 的关系

EKS 那套已是官方 K8s 生产形态（多副本/HPA/Aurora/多 AZ）。东京这套改造后定位为
**"轻量但合规的区域补充"**。若东京无强制本地化/低延迟需求，**最省事的"简化"仍是评估
能否砍掉东京、流量并回 EKS**——维护一套永远比两套省。
