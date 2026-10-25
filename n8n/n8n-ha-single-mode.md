# Plano de Implantação — n8n (Single Mode com ALB)

## Visão Geral

Implantação do n8n em modo single (uma instância) na AWS usando ECS com EC2, ALB e RDS PostgreSQL.

- **Região:** `us-east-2` (Ohio)
- **Domínio:** `n8n.joaowillamy.com.br`
- **Implementação:** AWS CLI
- **Modo:** Single instance (sem escalonamento)

## Arquitetura

```
User → Route 53 (n8n.joaowillamy.com.br)
         → ALB n8n-alb (HTTPS 443)
            → Target Group tg-n8n (HTTP 5678)
               → EC2 n8n-ec2 (t3.micro)
                  → ECS Task (n8nio/n8n:latest)
                     → RDS n8n (PostgreSQL)
```

---

## Dados da Conta e Infraestrutura Existente

| Recurso           | Valor                                                              |
|-------------------|--------------------------------------------------------------------|
| Account ID        | `503528589359`                                                     |
| Região            | `us-east-2`                                                        |
| VPC (padrão)      | `vpc-0d23c09c0ea0b3d4b` — `172.31.0.0/16`                         |
| Subnet Zona A     | `subnet-03f065b9968750155` — `172.31.0.0/20` — `us-east-2a`       |
| Subnet Zona B     | `subnet-0740ea16cc283bc25` — `172.31.16.0/20` — `us-east-2b`      |
| Subnet Zona C     | `subnet-09f1f78ee5e0b7dd8` — `172.31.32.0/20` — `us-east-2c`      |
| ACM Cert ARN      | `arn:aws:acm:us-east-2:503528589359:certificate/9584d421-ea6c-49f1-9a4f-021bec3a1bb3` |
| ACM Domínio       | `*.joaowillamy.com.br` — Status: ISSUED                            |
| Route 53 Zone ID  | `Z0828752T799I8L39MU5`                                             |
| Route 53 Domínio  | `joaowillamy.com.br`                                               |
| AMI ECS-Optimized | `ami-02c06286e4c4b347e` — `al2023-ami-ecs-hvm-2023.0.20261019-kernel-6.1-x86_64` — ECS Agent `1.108.0` — Docker `25.0.16` (us-east-2, atualizada em 21/10/2026) |
| IAM Profile ativo | `AccountFullAccessRole` (AdministratorAccess)                      |

---

## Credenciais

- **Arquivo:** `n8n/.env` — já gerado, **não commitar** (adicionado ao `.gitignore`)
- As senhas ficam **exclusivamente** no arquivo `.env`, não neste documento
- Variáveis presentes no `.env`:
  - `DB_POSTGRESDB_PASSWORD` — senha do RDS
  - `N8N_ENCRYPTION_KEY` — chave de encriptação das credenciais do n8n

---

## Recursos a Criar

### Atividade 1 — Security Groups

| Nome      | Associado a | Inbound                                    | Descrição da Regra          |
|-----------|-------------|--------------------------------------------|-----------------------------|
| `n8n-alb` | ALB         | TCP 443 de `0.0.0.0/0`                     | acesso público HTTPS        |
| `n8n-ec2` | EC2 / ECS   | All TCP de SG `n8n-alb`                    | acesso vindo de n8n-alb     |
| `n8n-db`  | RDS         | TCP 5432 de SG `n8n-ec2`                   | acesso vindo de n8n-ec2     |

Todos com Outbound: `All traffic → 0.0.0.0/0`

---

### Atividade 2 — RDS PostgreSQL

| Campo               | Valor                              |
|---------------------|------------------------------------|
| Identificador       | `n8n`                              |
| Engine              | PostgreSQL 16.x                    |
| Instance class      | `db.t3.micro`                      |
| Storage type        | `gp2`                              |
| Storage             | 20 GB                              |
| Multi-AZ            | No                                 |
| Database name       | `n8n`                              |
| Master username     | `n8n`                              |
| Master password     | do `n8n/.env`                      |
| Security Group      | `n8n-db`                           |
| Subnet              | VPC padrão, zona A (`us-east-2a`)  |
| Public access       | No                                 |
| Backup retention    | 0 dias                             |
| Deletion protection | No                                 |

---

### Atividade 3 — Target Group

| Campo                  | Valor                   |
|------------------------|-------------------------|
| Nome                   | `tg-n8n`                |
| Tipo                   | `instance`              |
| Protocolo              | HTTP                    |
| Porta                  | 5678                    |
| VPC                    | `vpc-0d23c09c0ea0b3d4b` |
| Health check path      | `/healthz`              |
| Health check protocolo | HTTP                    |
| Health check interval  | 30s                     |
| Healthy threshold      | 2                       |
| Unhealthy threshold    | 3                       |
| Timeout                | 5s                      |
| Deregistration delay   | 30s                     |

---

### Atividade 4 — Application Load Balancer

| Campo          | Valor                                                                                  |
|----------------|----------------------------------------------------------------------------------------|
| Nome           | `n8n-alb`                                                                              |
| Scheme         | `internet-facing`                                                                      |
| IP type        | `ipv4`                                                                                 |
| Subnets        | `subnet-03f065b9968750155` (us-east-2a) + `subnet-0740ea16cc283bc25` (us-east-2b)     |
| Security Group | `n8n-alb`                                                                              |

**Listener:**

| Campo           | Valor                                                                                  |
|-----------------|----------------------------------------------------------------------------------------|
| Porta           | 443                                                                                    |
| Protocolo       | HTTPS                                                                                  |
| Ação            | Forward → `tg-n8n`                                                                     |
| Certificado     | `arn:aws:acm:us-east-2:503528589359:certificate/9584d421-ea6c-49f1-9a4f-021bec3a1bb3` |
| Security Policy | `ELBSecurityPolicy-TLS13-1-2-2021-06`                                                 |

---

### Atividade 5 — IAM Role — EC2 ECS

| Campo        | Valor                                               |
|--------------|-----------------------------------------------------|
| Nome da Role | `role-ecs-ec2-n8n`                                  |
| Tipo         | EC2 Instance Profile                                |
| Políticas    | `AmazonEC2ContainerServiceforEC2Role` (AWS managed) |
|              | `AmazonSSMManagedInstanceCore` (acesso SSM)         |

---

### Atividade 6 — ECS Cluster

| Campo | Valor         |
|-------|---------------|
| Nome  | `cluster-n8n` |
| Tipo  | EC2           |

---

### Atividade 7 — EC2 — ECS Host

| Campo                | Valor                                                                            |
|----------------------|----------------------------------------------------------------------------------|
| Nome (tag)           | `n8n-ec2`                                                                        |
| Tipo                 | `t3.micro`                                                                       |
| AMI                  | `ami-02c06286e4c4b347e` — `al2023-ami-ecs-hvm-2023.0.20261019-kernel-6.1-x86_64` |
| Key pair             | nenhum (acesso via SSM)                                                          |
| IAM Instance Profile | `role-ecs-ec2-n8n`                                                               |
| Security Group       | `n8n-ec2`                                                                        |
| Subnet               | `subnet-03f065b9968750155` (us-east-2a)                                          |
| IP público           | habilitado                                                                       |
| User data            | registrar no cluster `cluster-n8n` via `/etc/ecs/ecs.config`                    |

**User data:**
```bash
#!/bin/bash
echo ECS_CLUSTER=cluster-n8n >> /etc/ecs/ecs.config
```

---

### Atividade 8 — Task Definition

| Campo               | Valor                  |
|---------------------|------------------------|
| Family              | `task-def-n8n`         |
| Network mode        | `bridge`               |
| Launch type         | EC2                    |
| Task role           | —                      |
| Task execution role | `ecsTaskExecutionRole` |

> ⚠️ As configurações de memória e CPU abaixo são definidas **no nível do container**, NÃO na seção de Task size (que é exclusiva do Fargate).

**Container `n8n`:**

| Campo             | Valor                                     |
|-------------------|-------------------------------------------|
| Container name    | `n8n`                                     |
| Image             | `n8nio/n8n:latest`                        |
| Memory hard limit | `650` MB                                  |
| Memory soft limit | `400` MB (reserva)                        |
| CPU               | `1024` units (1 vCPU)                     |
| Port mapping      | container `5678` → host dinâmica (bridge) |
| Essential         | true                                      |

**Variáveis de ambiente do container:**

| Variável                 | Valor                               |
|--------------------------|-------------------------------------|
| `DB_TYPE`                | `postgresdb`                        |
| `DB_POSTGRESDB_HOST`     | endpoint do RDS `n8n` (pós criação) |
| `DB_POSTGRESDB_PORT`     | `5432`                              |
| `DB_POSTGRESDB_DATABASE` | `n8n`                               |
| `DB_POSTGRESDB_USER`     | `n8n`                               |
| `DB_POSTGRESDB_PASSWORD` | do `n8n/.env`                       |
| `N8N_HOST`               | `n8n.joaowillamy.com.br`            |
| `N8N_PORT`               | `5678`                              |
| `N8N_PROTOCOL`           | `https`                             |
| `N8N_EDITOR_BASE_URL`    | `https://n8n.joaowillamy.com.br`    |
| `WEBHOOK_URL`            | `https://n8n.joaowillamy.com.br`    |
| `N8N_PROXY_HOPS`         | `1`                                 |
| `N8N_ENCRYPTION_KEY`     | do `n8n/.env`                       |
| `GENERIC_TIMEZONE`       | `America/Sao_Paulo`                 |
| `TZ`                     | `America/Sao_Paulo`                 |

---

### Atividade 9 — ECS Service

| Campo                     | Valor          |
|---------------------------|----------------|
| Nome                      | `service-n8n`  |
| Cluster                   | `cluster-n8n`  |
| Task Definition           | `task-def-n8n` |
| Launch type               | EC2            |
| Desired count             | 1              |
| Deployment type           | Rolling Update |
| Minimum healthy percent   | 50%            |
| Maximum percent           | 100%           |
| AZ Rebalancing            | desativado     |
| Load balancer             | `n8n-alb`      |
| Container → porta         | `n8n:5678`     |
| Target Group              | `tg-n8n`       |
| Health check grace period | 60s            |

---

### Atividade 10 — Route 53

| Campo   | Valor                                  |
|---------|----------------------------------------|
| Zone ID | `Z0828752T799I8L39MU5`                 |
| Nome    | `n8n.joaowillamy.com.br`               |
| Tipo    | `A` — Alias                            |
| Alvo    | DNS do ALB `n8n-alb` (pós criação)     |

---

## Sequência de Execução

```
Atividade 1 → Criar Security Groups (n8n-alb, n8n-ec2, n8n-db)
Atividade 2 → Criar RDS PostgreSQL (n8n)
Atividade 3 → Criar Target Group (tg-n8n) — tipo instance, HTTP:5678, deregistration delay: 30s
Atividade 4 → Criar ALB (n8n-alb) + Listener 443
Atividade 5 → Criar IAM Role (role-ecs-ec2-n8n) + Instance Profile
Atividade 6 → Criar ECS Cluster (cluster-n8n)
Atividade 7 → Criar EC2 (n8n-ec2) registrada no cluster
Atividade 8 → Criar Task Definition (task-def-n8n)
Atividade 9 → Criar ECS Service (service-n8n)
Atividade 10 → Criar Record Route 53 (n8n.joaowillamy.com.br → n8n-alb)
Atividade 11 → Validação
```

---

## Validação

1. Acessar `https://n8n.joaowillamy.com.br`
2. Verificar tela de setup do n8n (criação do owner account)
3. Confirmar criação automática das tabelas no PostgreSQL
4. Testar criação de um workflow básico
5. Verificar health check do Target Group como `healthy` no console

---

## Observações Técnicas

- **`N8N_PROXY_HOPS=1`** é obrigatório pois o n8n fica atrás do ALB (reverse proxy). Sem isso o n8n não consegue determinar o IP real do cliente.
- **`N8N_ENCRYPTION_KEY`** deve ser fixado e guardado. Se o container reiniciar sem essa chave, as credenciais salvas nos workflows ficam inacessíveis.
- **Listener apenas 443:** quem acessar `http://n8n.joaowillamy.com.br` receberá erro de conexão (sem redirect). Adicionar listener 80 com redirect para 443 é opcional.
- **Memory hard limit 650 MB / soft limit 400 MB:** o n8n consome em média 250–350 MB em operação normal. O hard limit de 650 MB dá margem para picos sem comprometer o host t3.micro (1 GB RAM).
- **Port mapping dinâmico (bridge):** o ECS escolhe a porta do host automaticamente. O Target Group do tipo `instance` resolve isso corretamente via registro automático do Service.
