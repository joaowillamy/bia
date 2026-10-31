# Plano de Implantação — n8n (Queue Mode com ALB + Redis)

## Visão Geral

Evolução do n8n de **single mode** para **queue mode**: separação do processo `main`
(recebe webhooks/triggers e serve a UI) dos processos `worker` (executam os workflows),
usando **Redis (ElastiCache)** como message broker.

- **Região:** `us-east-2` (Ohio)
- **Domínio:** `n8n.joaowillamy.com.br`
- **Implementação:** AWS CLI
- **Modo:** Queue (1 main + N workers)
- **Base:** aproveita a infraestrutura já criada no plano `n8n-ha-single-mode.md`

> ⚠️ Este documento **NÃO substitui** o `n8n-ha-single-mode.md`. Ele descreve apenas o que
> precisa ser **adicionado ou alterado** para habilitar o queue mode.

---

## Como funciona o Queue Mode (resumo da doc oficial)

Fluxo (fonte: docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode):

1. O **main** recebe timers e chamadas de webhook e gera (mas não executa) uma execução.
2. Passa o **ID da execução** para o **Redis**, que mantém a fila de execuções pendentes.
3. Um **worker** disponível pega a mensagem do Redis.
4. O worker usa o ID para buscar os dados do workflow no **PostgreSQL**.
5. Ao terminar, o worker grava os resultados no banco e avisa o Redis que terminou.
6. O Redis notifica o main.

**Requisitos obrigatórios da doc:**
- Banco **PostgreSQL** (SQLite não é suportado em modo distribuído). ✅ já temos RDS.
- **Redis** acessível por todas as instâncias (main + workers). ⬅️ **novo: ElastiCache**.
- **`N8N_ENCRYPTION_KEY` idêntica** em main e workers (para ler credenciais do banco). ✅ já no `.env`.
- **`EXECUTIONS_MODE=queue`** no main e em todos os workers.
- Workers **não recebem tráfego HTTP** → não precisam de ALB/Target Group.
- Concurrency recomendada: **≥ 5** por worker (evita exaustão do pool de conexões do banco).

---

## Mapa: o que JÁ existe (single mode) vs. o que FALTA (queue mode)

### ✅ Já criado (plano single mode) — reaproveitar

| Recurso | Nome / ID | Reuso no queue mode |
|---|---|---|
| VPC padrão | `vpc-0d23c09c0ea0b3d4b` | sim |
| Subnets A/B/C | `subnet-03f065b9968750155` / `...0740ea16cc283bc25` / `...09f1f78ee5e0b7dd8` | sim |
| SG ALB | `n8n-alb` (`sg-04b0897b42553bafd`) | sim (sem mudança) |
| SG EC2 | `n8n-ec2` (`sg-04308cfdc4da96c35`) | sim (**+ egress Redis**) |
| SG DB | `n8n-db` (`sg-0374745bf9c9d0c40`) | sim (sem mudança) |
| RDS PostgreSQL | `n8n` | sim (main e workers compartilham) |
| ALB + Listener 443 | `n8n-alb` | sim (só o main fica atrás) |
| Target Group | `tg-n8n` (HTTP:5678 instance) | sim (só o main registra) |
| IAM Role EC2 | `role-ecs-ec2-n8n` | sim |
| ECS Cluster | `cluster-n8n` | sim |
| Launch Template | `lt-n8n-ec2` | **alterar** (tipo de instância / qtd) |
| ASG | `asg-n8n-ec2` | **alterar** (capacidade) |
| Task Definition | `task-def-n8n` | **alterar** (vira a do main + vars de queue) |
| ECS Service | `service-n8n` | **renomear → `service-n8n-main`** (opcional) |
| Route 53 | `n8n.joaowillamy.com.br` → ALB | sim |
| CloudWatch Logs | `/ecs/task-def-n8n` | sim (+ `/ecs/task-def-n8n-worker`) |
| `.env` | `N8N_ENCRYPTION_KEY`, `DB_POSTGRESDB_PASSWORD` | sim (compartilhados) |

### 🟩 A construir (verde no diagrama) + 🟦 ajustes obrigatórios

| # | Item | Origem | Status |
|---|---|---|---|
| A | **ElastiCache (Redis)** — subnet group + SG + cluster | diagrama (verde) + doc | **novo** |
| B | **SG `n8n-redis`** (inbound 6379 de `n8n-ec2`) | doc (Redis acessível) | **novo** |
| C | **`service-n8n-worker`** (2 tasks, `n8nio/n8n worker`) | diagrama (verde) | **novo** |
| D | **Task Definition `task-def-n8n-worker`** | doc (start workers) | **novo** |
| E | **Capacidade EC2** (t3.micro → **t3.small** para comportar as 3 tasks num só host) | análise de recursos | **alterar** |
| F | **Vars de queue** no main e worker (`EXECUTIONS_MODE`, `QUEUE_BULL_REDIS_*`) | doc | **alterar/novo** |
| G | **Egress 6379** no SG `n8n-ec2` → `n8n-redis` | doc | **alterar** |
| H | Renomear service `service-n8n` → `service-n8n-main` (alinhar diagrama) | diagrama | **opcional** |

---

## ⚠️ Pontos críticos de avaliação (ler antes de implementar)

### 1. Capacidade de EC2 — decisão: 1× t3.small com as 3 tasks
**Decisão do time:** usar **1 única instância `t3.small`** (2 GiB RAM) no cluster, rodando
as **3 tasks juntas** (1 main + 2 workers). Simplicidade acima de tudo, alinhado à filosofia
do projeto.

**Orçamento de memória (t3.small = 2 GiB ≈ 2048 MB):**

| Consumidor | Memória |
|---|---|
| SO + ECS agent + Docker (reserva do host) | ~256–350 MB |
| Task main (`n8n`) — hard limit | **550 MB** |
| Task worker #1 (`n8n-worker`) — hard limit | **512 MB** |
| Task worker #2 (`n8n-worker`) — hard limit | **512 MB** |
| **Total tasks** | **1574 MB** |
| **Folga restante** | ~120–240 MB |

> Os hard limits foram ajustados (main 650 → **550 MB**) para caber as 3 tasks + reserva do
> host dentro de 2 GiB. O n8n consome em média 250–350 MB por processo em operação normal,
> então 550/512 dão margem para picos sem estourar a instância.

**Impactos dessa escolha (trade-offs aceitos):**
- ❌ **Sem isolamento:** se a EC2 falhar, main + workers caem juntos. O ASG reprovisiona a
  instância automaticamente, mas há downtime até o novo host registrar e as tasks subirem.
- ❌ **Sem HA de AZ:** 1 instância = 1 única AZ. (O ALB continua em 2 AZs, mas só há target
  em uma.)
- ✅ **Menor custo:** 1× t3.small em vez de 2.
- ✅ **Simplicidade:** 1 host, placement trivial, fácil de explicar ao aluno.

> **Atenção ao placement do ECS:** com 1 host e 3 tasks (main sem/com porta + 2 workers sem
> porta), não há conflito de porta no host porque os workers **não publicam porta** (bridge,
> sem port mapping) e só o main usa a porta dinâmica do bridge para o Target Group.

### 2. ElastiCache — engine, tipo e modo
- **Engine:** **Valkey** (fork drop-in compatível com Redis OSS, mantido pela Linux
  Foundation). O n8n/BullMQ fala protocolo Redis e funciona sem alterações com Valkey.
  A AWS precifica Valkey **~20% abaixo** do Redis OSS na ElastiCache.
- **Node type:** **`cache.t4g.micro`** (Graviton/ARM). Pela doc de *Supported node types*
  da AWS, tem a **mesma memória (0.50 GiB) e bandwidth** do `cache.t3.micro`, porém é
  **~10–20% mais barato** por ser Graviton. É o menor nó disponível (não existe nada abaixo
  de `.micro` / 0.50 GiB). Valkey é suportado no `t4g.micro` a partir da versão 7.2.
- **Versão Valkey:** 8.x (ou 7.2+). 
- **Cluster mode:** **desabilitado** (n8n/BullMQ espera um único endpoint primário).
- **Nós:** 1 nó (sem réplica) para manter simples — ou 1 primário + 1 réplica se quiser HA.
- **Dimensionamento:** 0.50 GiB é suficiente — a fila guarda apenas **IDs de execução**,
  não os dados do workflow (esses ficam no PostgreSQL). Atenção: TLS e o recurso de search
  exigem reserva de memória maior em nós micro; como TLS fica **desabilitado** no início,
  os 0.50 GiB ficam folgados para o cenário educacional.
- **Encryption in-transit (TLS):** manter **desabilitado** no início. Se habilitar, é preciso
  adicionar `QUEUE_BULL_REDIS_TLS=true` nas tasks (a doc não cita explicitamente, mas é a
  flag suportada pelo n8n para Redis com TLS). **Começar sem TLS** reduz complexidade.
- **AUTH (password):** opcional. Como o Redis fica em subnet privada e só o SG `n8n-ec2`
  acessa, podemos começar **sem password** (igual ao default da doc). Se habilitar,
  guardar em `.env` como `QUEUE_BULL_REDIS_PASSWORD` e injetar no main e workers.

### 3. Inconsistência de versão do PostgreSQL (herdada do plano single)
O plano single mode tem a tabela dizendo **PostgreSQL 16.x** mas a observação final cita
**PostgreSQL 18** (SSL obrigatório). **Confirmar a versão real do RDS `n8n`** antes de
implementar. Não afeta o queue mode em si, mas as vars `DB_POSTGRESDB_SSL_*` devem ser
mantidas idênticas no main e nos workers.

### 4. Multi-main NÃO entra neste plano
A doc descreve multi-main (vários processos `main` para HA), mas é **Enterprise** e foge da
filosofia de simplicidade do projeto. Mantemos **1 único main** (single-main). O diagrama
também mostra apenas um `service-n8n-main`.

### 5. Webhook processors NÃO entram neste plano
A doc descreve processos `webhook` dedicados como camada extra de escala. **Fora de escopo** —
o main continua recebendo os webhooks e delega a execução aos workers via Redis. Isso já é
o ganho principal do queue mode.

---

## Recursos a Criar / Alterar (detalhado)

### Atividade A — Security Group do Redis (`n8n-redis`)

| Campo | Valor |
|---|---|
| Nome | `n8n-redis` |
| VPC | `vpc-0d23c09c0ea0b3d4b` |
| Inbound | TCP **6379** de SG `n8n-ec2` (`sg-04308cfdc4da96c35`) |
| Descrição inbound | `acesso vindo de n8n-ec2` |
| Outbound | `All traffic → 0.0.0.0/0` |

---

### Atividade B — ElastiCache Subnet Group + Cluster Valkey

**Subnet Group `n8n-redis-subnets`:**

| Campo | Valor |
|---|---|
| Nome | `n8n-redis-subnets` |
| Subnets | `subnet-03f065b9968750155` (A) + `subnet-0740ea16cc283bc25` (B) |

**Cluster Valkey `n8n-redis`:**

| Campo | Valor |
|---|---|
| Engine | **Valkey** |
| Versão | 8.x (ou 7.2+) |
| Node type | **`cache.t4g.micro`** (Graviton — mais barato que `t3.micro`) |
| Número de nós | 1 (sem réplica) |
| Cluster mode | **disabled** |
| Subnet group | `n8n-redis-subnets` |
| Security Group | `n8n-redis` |
| Port | 6379 |
| Encryption in-transit (TLS) | **disabled** (início) |
| AUTH token | **disabled** (início) |

> Guardar o **Primary Endpoint** gerado (ex: `n8n-redis.xxxx.use2.cache.amazonaws.com`)
> para injetar em `QUEUE_BULL_REDIS_HOST` no main e nos workers.
> O n8n não distingue Valkey de Redis — as variáveis `QUEUE_BULL_REDIS_*` são as mesmas.

---

### Atividade C — Ajustar SG `n8n-ec2` (egress Redis)

Adicionar regra de **saída** (ou confirmar que o egress `All traffic → 0.0.0.0/0` já cobre):

| Campo | Valor |
|---|---|
| Egress | TCP **6379** para SG `n8n-redis` |

> Se o `n8n-ec2` mantém egress aberto (`0.0.0.0/0`), nenhuma mudança é necessária aqui —
> o inbound do `n8n-redis` já restringe o acesso. **Validar o egress atual.**

---

### Atividade D — Ajustar Capacidade EC2 (ASG + Launch Template)

Conforme **Ponto crítico #1** (1× t3.small com as 3 tasks):

**Launch Template `lt-n8n-ec2` — nova versão:**

| Campo | Antes | Depois |
|---|---|---|
| Instance type | `t3.micro` | **`t3.small`** |
| Demais campos | (mantém AMI, IAM profile, SG `n8n-ec2`, user data) | (iguais) |

**Auto Scaling Group `asg-n8n-ec2` — alterar:**

| Campo | Antes | Depois |
|---|---|---|
| Launch Template versão | `$Latest` | `$Latest` (nova versão) |
| Min / Max / Desired | 1 / 1 / 1 | **1 / 1 / 1** (mantém) |
| Subnets | só A | só A (`subnet-03f065b9968750155`) — mantém |

> Mantém **1 única instância t3.small** na zona A. A única mudança no ASG é apontar para a
> nova versão do Launch Template (t3.small). O ASG continua garantindo reprovisionamento
> automático caso a instância falhe.

---

### Atividade E — Alterar Task Definition do Main (`task-def-n8n`)

Adicionar as variáveis de queue ao container `n8n` existente (nova revisão) **e ajustar a
memória** para caber as 3 tasks no mesmo host:

| Campo | Antes (single) | Depois (queue) |
|---|---|---|
| Memory hard limit | `650` MB | **`550` MB** |
| Memory soft limit | `400` MB | `400` MB (mantém) |

| Variável (nova) | Valor |
|---|---|
| `EXECUTIONS_MODE` | `queue` |
| `QUEUE_BULL_REDIS_HOST` | endpoint do ElastiCache/Valkey `n8n-redis` |
| `QUEUE_BULL_REDIS_PORT` | `6379` |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` |

> Mantém TODAS as variáveis existentes (DB, N8N_HOST, N8N_ENCRYPTION_KEY, SSL, TZ, etc.).
> `N8N_ENCRYPTION_KEY` **deve ser exatamente a mesma** usada no worker.
> Se habilitar AUTH no Valkey: adicionar `QUEUE_BULL_REDIS_PASSWORD` (do `.env`).
> Se habilitar TLS no Valkey: adicionar `QUEUE_BULL_REDIS_TLS=true`.

---

### Atividade F — Criar Task Definition do Worker (`task-def-n8n-worker`)

| Campo | Valor |
|---|---|
| Family | `task-def-n8n-worker` |
| Network mode | `bridge` |
| Launch type | EC2 |
| Task execution role | `ecsTaskExecutionRole` |

**Container `n8n-worker`:**

| Campo | Valor |
|---|---|
| Container name | `n8n-worker` |
| Image | `n8nio/n8n:latest` |
| **Command** | `worker` (equivale a `n8n worker`) |
| Memory hard limit | `512` MB |
| Memory soft limit | `350` MB |
| CPU | `512` units |
| Port mapping | **nenhum** (worker não recebe tráfego) — exceto se usar health check (ver nota) |
| Essential | true |

**Variáveis de ambiente do worker** (todas iguais ao main, exceto as de UI/host):

| Variável | Valor |
|---|---|
| `EXECUTIONS_MODE` | `queue` |
| `QUEUE_BULL_REDIS_HOST` | endpoint do ElastiCache `n8n-redis` |
| `QUEUE_BULL_REDIS_PORT` | `6379` |
| `N8N_ENCRYPTION_KEY` | **mesma** do `.env` (igual ao main) |
| `DB_TYPE` | `postgresdb` |
| `DB_POSTGRESDB_HOST` | endpoint do RDS `n8n` |
| `DB_POSTGRESDB_PORT` | `5432` |
| `DB_POSTGRESDB_DATABASE` | `n8n` |
| `DB_POSTGRESDB_USER` | `n8n` |
| `DB_POSTGRESDB_PASSWORD` | do `.env` |
| `DB_POSTGRESDB_SSL_ENABLED` | `true` |
| `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` | `false` |
| `GENERIC_TIMEZONE` | `America/Sao_Paulo` |
| `TZ` | `America/Sao_Paulo` |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` |

> **Concurrency:** definir `worker --concurrency=5` (ou via var). Default é 10; a doc
> recomenda ≥ 5. Com 2 workers × concurrency, atenção ao pool de conexões do RDS t3.micro.
> **Health check (opcional):** setar `QUEUE_HEALTH_CHECK_ACTIVE=true` expõe `/healthz` na
> porta 5678 do worker; permite health check do ECS. Como o worker não entra no ALB, é
> opcional — pode-se usar health check de container (`curl localhost:5678/healthz`).
> **NÃO definir** `N8N_HOST`, `N8N_PROTOCOL`, `WEBHOOK_URL`, `N8N_PROXY_HOPS` no worker
> (são do main/UI).

---

### Atividade G — Criar ECS Service do Worker (`service-n8n-worker`)

| Campo | Valor |
|---|---|
| Nome | `service-n8n-worker` |
| Cluster | `cluster-n8n` |
| Task Definition | `task-def-n8n-worker` |
| Launch type | EC2 |
| Desired count | **2** |
| Deployment type | Rolling Update |
| Minimum healthy percent | 50% |
| Maximum percent | 100% |
| Load balancer | **nenhum** (worker não recebe tráfego HTTP) |
| AZ Rebalancing | desativado |

---

### Atividade H — (Opcional) Renomear `service-n8n` → `service-n8n-main`

O diagrama mostra `service-n8n-main`. O ECS **não permite renomear** um service — seria
preciso criar `service-n8n-main` e deletar `service-n8n`. **Avaliar se vale o esforço**:
- Se for só estética do diagrama → **manter `service-n8n`** e anotar o apelido "main".
- Se quiser aderência total ao diagrama → recriar como `service-n8n-main` (reusando
  `task-def-n8n`, ALB e Target Group `tg-n8n`).

> **Recomendação:** manter `service-n8n` para não recriar o service que já serve a UI;
> documentar que `service-n8n` == "main". Decisão do time.

---

## Sequência de Execução

```
A → Criar SG n8n-redis (inbound 6379 de n8n-ec2)
B → Criar ElastiCache Subnet Group + Cluster Redis (n8n-redis) → anotar endpoint
C → Validar/ajustar egress do SG n8n-ec2 (6379 → n8n-redis)
D → Nova versão do Launch Template (t3.small) + ASG mantém 1/1/1 na zona A
    → aguardar a instância registrar no cluster-n8n
E → Nova revisão da Task Definition do main (task-def-n8n) com vars de queue + memória 550 MB
    → forçar novo deployment do service-n8n (main) com EXECUTIONS_MODE=queue
F → Criar Task Definition do worker (task-def-n8n-worker)
G → Criar ECS Service do worker (service-n8n-worker, desired=2)
H → (opcional) renomear service para service-n8n-main
Validação
```

> **Ordem importa:** o Redis (A+B) precisa existir ANTES de o main entrar em queue mode (E),
> senão o main não inicia. E a capacidade EC2 (D, t3.small) precisa estar pronta antes de
> subir os workers (G), senão as tasks ficam `PENDING` por falta de recursos no host.

---

## Validação

1. **Redis acessível:** da EC2 (via SSM), `redis-cli -h <endpoint> -p 6379 ping` → `PONG`.
2. **Main em queue mode:** logs do container main (`/ecs/task-def-n8n`) mostram conexão ao
   Redis e mensagem de modo `queue` (sem erros de "ECONNREFUSED" ao Redis).
3. **Workers ativos:** logs `/ecs/task-def-n8n-worker` mostram `n8n worker is now ready` e
   `Start job: ...` quando um workflow roda.
4. **UI → Settings → Workers:** (Enterprise) mostraria os workers; na community, validar via
   logs/execuções.
5. **Teste funcional:** criar um workflow com trigger manual/webhook e confirmar que a
   **execução aparece como feita por um worker** (ID de worker nos logs de execução).
6. **ALB saudável:** Target Group `tg-n8n` com o main `healthy` (inalterado do single mode).
7. **Escala:** com 1 host t3.small, o teto é ~2 workers (orçamento de memória). Para escalar
   além disso, subir o tipo da instância (t3.medium) ou adicionar um 2º host no ASG — anotar
   como evolução futura. **Não** subir `desired` dos workers acima de 2 sem aumentar o host.

---

## Observações Técnicas

- **Encryption key compartilhada é obrigatória:** se o worker usar uma `N8N_ENCRYPTION_KEY`
  diferente do main, ele **não consegue descriptografar as credenciais** salvas no banco e
  os workflows com credenciais falham. Usar a MESMA do `.env` em ambos.
- **Workers fora do ALB:** não criar Target Group nem listener para os workers. Eles só
  conversam com Redis (6379) e RDS (5432).
- **Pool de conexões do RDS:** 2 workers × concurrency alta pode esgotar conexões do
  PostgreSQL t3.micro. Começar com `concurrency=5` e monitorar. A doc alerta exatamente
  sobre isso ("concurrency baixa com muitos workers esgota o pool").
- **Binary data em queue mode:** a doc avisa que **filesystem não é suportado** para binary
  data em queue mode. Se workflows precisarem persistir binários, usar **S3** via external
  storage (`N8N_DEFAULT_BINARY_DATA_MODE=s3`). **Fora de escopo inicial** — anotar como
  evolução futura se necessário.
- **Redis sem persistência:** ElastiCache Redis padrão mantém a fila em memória. Se o nó
  reiniciar, execuções enfileiradas e ainda não processadas podem ser perdidas. Para o
  contexto educacional é aceitável; HA real exigiria réplica + Multi-AZ (fora de escopo).
- **Graceful shutdown:** `N8N_GRACEFUL_SHUTDOWN_TIMEOUT=30` dá 30s para o worker terminar
  jobs em andamento antes de ser derrubado num deploy/rolling update.
- **Custo adicional vs. single mode:** mesma quantidade de EC2 (1 instância, apenas
  t3.small em vez de t3.micro) +
  ElastiCache **Valkey `cache.t4g.micro`** (Graviton + Valkey = opção mais econômica;
  elegível ao free tier de 12 meses em nós micro). Para estimativas de fatura, consultar
  o AWS Pricing Calculator.

---

## Resumo da avaliação (resposta à pergunta "falta algo?")

**O verde do diagrama está correto, mas incompleto.** Os itens em verde (service-n8n-worker,
conexões worker→cache/RDS, main→cache) estão certos. Porém, para o queue mode funcionar de
verdade, o plano precisa cobrir **5 itens que o diagrama não mostra**:

1. ✅ **ElastiCache em si** (o diagrama mostra o ícone, mas não há plano de criação) —
   **Atividade A/B** (Valkey em `cache.t4g.micro`, a opção mais barata).
2. ✅ **SG dedicado `n8n-redis`** (inbound 6379) — **Atividade A**.
3. ✅ **Capacidade EC2 insuficiente** — 1× t3.micro não comporta main + 2 workers →
   subir o tipo para **1× t3.small** (2 GiB) e rodar as 3 tasks no mesmo host, com os hard
   limits ajustados (main 550 + worker 512 + worker 512) — **Atividade D/E**. **Este é o
   gap mais importante.**
4. ✅ **Variáveis de queue** (`EXECUTIONS_MODE`, `QUEUE_BULL_REDIS_*`) no main E nos workers,
   com **encryption key compartilhada** — **Atividades E/F**.
5. ✅ **Task Definition do worker** com `command: worker` e sem vars de UI/host — **Atividade F**.

Itens conscientemente **fora de escopo** (alinhado à simplicidade do projeto): multi-main
(Enterprise), webhook processors dedicados, S3 para binary data, TLS/AUTH no Redis.
