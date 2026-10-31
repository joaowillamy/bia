# Plano de Destruição — n8n (Remover todos os recursos)

## Objetivo

Remover completamente toda a infraestrutura criada para o n8n, sem deixar rastros nem gerar custos.

- **Região:** `us-east-2` (Ohio)
- **Execução:** AWS CLI
- **Ordem:** inversa à criação (dependências respeitadas)

---

## Recursos a Destruir

| Recurso | Nome / ID | Observação |
|---|---|---|
| Route 53 Record | `n8n.joaowillamy.com.br` | A Alias → ALB |
| ECS Service | `service-n8n` | cluster `cluster-n8n` |
| ECS Task Definitions | `task-def-n8n:1`, `task-def-n8n:2` | deregistrar ambas |
| ECS Cluster | `cluster-n8n` | |
| ASG | `asg-n8n-ec2` | termina a EC2 junto |
| Launch Template | `lt-n8n-ec2` (`lt-04ed95b91d85b8dd0`) | |
| ALB Listener | `443` | ARN: `arn:aws:elasticloadbalancing:us-east-2:503528589359:listener/app/n8n-alb/28367c2d21b6b7f5/ae353255e56f0092` |
| ALB | `n8n-alb` | ARN: `arn:aws:elasticloadbalancing:us-east-2:503528589359:loadbalancer/app/n8n-alb/28367c2d21b6b7f5` |
| Target Group | `tg-n8n` | ARN: `arn:aws:elasticloadbalancing:us-east-2:503528589359:targetgroup/tg-n8n/620643b5b1e9658c` |
| RDS | `n8n` | snapshot final: não criar |
| Security Group | `n8n-ec2` (`sg-04308cfdc4da96c35`) | remover regras antes |
| Security Group | `n8n-db` (`sg-0374745bf9c9d0c40`) | remover regras antes |
| Security Group | `n8n-alb` (`sg-04b0897b42553bafd`) | |
| IAM Instance Profile | `role-ecs-ec2-n8n` | remover role antes |
| IAM Role | `role-ecs-ec2-n8n` | desanexar políticas antes |
| CloudWatch Log Group | `/ecs/task-def-n8n` | |

---

## Sequência de Execução

### Passo 1 — Route 53: remover record

```bash
aws route53 change-resource-record-sets \
  --region us-east-1 \
  --hosted-zone-id Z0828752T799I8L39MU5 \
  --change-batch '{
    "Changes": [{
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "n8n.joaowillamy.com.br",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z3AADJGX6KTTL2",
          "DNSName": "n8n-alb-1199562030.us-east-2.elb.amazonaws.com",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'
```

---

### Passo 2 — ECS Service: zerar e deletar

```bash
# Zerar desired count para parar a task
aws ecs update-service \
  --region us-east-2 \
  --cluster cluster-n8n \
  --service service-n8n \
  --desired-count 0

# Aguardar task parar (running=0)
aws ecs wait services-stable \
  --region us-east-2 \
  --cluster cluster-n8n \
  --services service-n8n

# Deletar service
aws ecs delete-service \
  --region us-east-2 \
  --cluster cluster-n8n \
  --service service-n8n \
  --force
```

---

### Passo 3 — ECS Task Definitions: deregistrar

```bash
aws ecs deregister-task-definition \
  --region us-east-2 \
  --task-definition task-def-n8n:1

aws ecs deregister-task-definition \
  --region us-east-2 \
  --task-definition task-def-n8n:2
```

> Task definitions ficam no estado INACTIVE após deregistrar. Para deletar permanentemente:
```bash
aws ecs delete-task-definitions \
  --region us-east-2 \
  --task-definitions task-def-n8n:1 task-def-n8n:2
```

---

### Passo 4 — ASG: deletar (termina a EC2 automaticamente)

```bash
aws autoscaling delete-auto-scaling-group \
  --region us-east-2 \
  --auto-scaling-group-name asg-n8n-ec2 \
  --force-delete
```

> `--force-delete` termina as instâncias em execução antes de deletar o grupo.

---

### Passo 5 — ECS Cluster: deletar

```bash
aws ecs delete-cluster \
  --region us-east-2 \
  --cluster cluster-n8n
```

---

### Passo 6 — Launch Template: deletar

```bash
aws ec2 delete-launch-template \
  --region us-east-2 \
  --launch-template-id lt-04ed95b91d85b8dd0
```

---

### Passo 7 — ALB Listener: deletar

```bash
aws elbv2 delete-listener \
  --region us-east-2 \
  --listener-arn arn:aws:elasticloadbalancing:us-east-2:503528589359:listener/app/n8n-alb/28367c2d21b6b7f5/ae353255e56f0092
```

---

### Passo 8 — ALB: deletar

```bash
aws elbv2 delete-load-balancer \
  --region us-east-2 \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-2:503528589359:loadbalancer/app/n8n-alb/28367c2d21b6b7f5

# Aguardar ALB ser removido
aws elbv2 wait load-balancers-deleted \
  --region us-east-2 \
  --load-balancer-arns arn:aws:elasticloadbalancing:us-east-2:503528589359:loadbalancer/app/n8n-alb/28367c2d21b6b7f5
```

---

### Passo 9 — Target Group: deletar

```bash
aws elbv2 delete-target-group \
  --region us-east-2 \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-2:503528589359:targetgroup/tg-n8n/620643b5b1e9658c
```

---

### Passo 10 — RDS: deletar sem snapshot final

```bash
aws rds delete-db-instance \
  --region us-east-2 \
  --db-instance-identifier n8n \
  --skip-final-snapshot \
  --delete-automated-backups

# Aguardar deleção (pode levar ~5 min)
aws rds wait db-instance-deleted \
  --region us-east-2 \
  --db-instance-identifier n8n
```

---

### Passo 11 — Security Groups: remover regras e deletar

Os SGs têm dependências entre si (inbound rules referenciam outros SGs).
Remover as regras primeiro antes de deletar.

```bash
# Remover inbound de n8n-ec2 (referencia n8n-alb)
aws ec2 revoke-security-group-ingress \
  --region us-east-2 \
  --group-id sg-04308cfdc4da96c35 \
  --protocol tcp --port 0-65535 \
  --source-group sg-04b0897b42553bafd

# Remover inbound de n8n-db (referencia n8n-ec2)
aws ec2 revoke-security-group-ingress \
  --region us-east-2 \
  --group-id sg-0374745bf9c9d0c40 \
  --protocol tcp --port 5432 \
  --source-group sg-04308cfdc4da96c35

# Deletar os 3 SGs
aws ec2 delete-security-group --region us-east-2 --group-id sg-04308cfdc4da96c35
aws ec2 delete-security-group --region us-east-2 --group-id sg-0374745bf9c9d0c40
aws ec2 delete-security-group --region us-east-2 --group-id sg-04b0897b42553bafd
```

---

### Passo 12 — IAM: desanexar políticas, remover role do profile e deletar

```bash
# Desanexar políticas
aws iam detach-role-policy \
  --role-name role-ecs-ec2-n8n \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

aws iam detach-role-policy \
  --role-name role-ecs-ec2-n8n \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Remover role do instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name role-ecs-ec2-n8n \
  --role-name role-ecs-ec2-n8n

# Deletar instance profile
aws iam delete-instance-profile \
  --instance-profile-name role-ecs-ec2-n8n

# Deletar role
aws iam delete-role \
  --role-name role-ecs-ec2-n8n
```

---

### Passo 13 — CloudWatch Log Group: deletar

```bash
aws logs delete-log-group \
  --region us-east-2 \
  --log-group-name /ecs/task-def-n8n
```

---

## Verificação Final

Após executar todos os passos, verificar que não sobrou nada:

```bash
# ECS
aws ecs list-clusters --region us-east-2
aws ecs list-services --region us-east-2 --cluster cluster-n8n 2>/dev/null || echo "cluster nao existe"

# EC2 / ASG / LT
aws autoscaling describe-auto-scaling-groups --region us-east-2 \
  --auto-scaling-group-names asg-n8n-ec2 --query 'AutoScalingGroups[].AutoScalingGroupName'

aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=n8n-ec2" "Name=instance-state-name,Values=running,pending"

# ALB / TG
aws elbv2 describe-load-balancers --region us-east-2 \
  --names n8n-alb --query 'LoadBalancers[].State.Code' 2>/dev/null || echo "alb nao existe"

# RDS
aws rds describe-db-instances --region us-east-2 \
  --db-instance-identifier n8n --query 'DBInstances[].DBInstanceStatus' 2>/dev/null || echo "rds nao existe"

# Security Groups
aws ec2 describe-security-groups --region us-east-2 \
  --filters "Name=group-name,Values=n8n-alb,n8n-ec2,n8n-db" \
  --query 'SecurityGroups[].GroupName'

# IAM
aws iam get-role --role-name role-ecs-ec2-n8n 2>/dev/null || echo "role nao existe"

# Route 53
aws route53 list-resource-record-sets \
  --hosted-zone-id Z0828752T799I8L39MU5 \
  --query "ResourceRecordSets[?Name=='n8n.joaowillamy.com.br.']"

# CloudWatch
aws logs describe-log-groups --region us-east-2 \
  --log-group-name-prefix /ecs/task-def-n8n \
  --query 'logGroups[].logGroupName'
```

---

## Observações

- **Ordem é obrigatória:** SGs só podem ser deletados após o RDS e EC2 serem removidos (dependência de ENI).
- **ALB antes do TG:** o Target Group não pode ser deletado enquanto estiver associado ao ALB.
- **ASG antes do Cluster ECS:** o ASG termina a EC2, que por sua vez desregistra do cluster automaticamente.
- **IAM antes dos SGs:** sem ordem obrigatória entre eles, mas IAM não depende de nenhum outro recurso.
- **Route 53 primeiro:** boa prática remover o DNS antes de derrubar a infra para evitar resolução para endpoint inexistente.
