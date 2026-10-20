#!/bin/bash

# =============================================================================
# Script de Deploy/Rollback ECS - Projeto BIA
# =============================================================================
# Uso:
#   ./scripts/ecs-deploy.sh deploy    - Build, push ECR e deploy no ECS
#   ./scripts/ecs-deploy.sh list      - Lista revisions da task definition
#   ./scripts/ecs-deploy.sh rollback  - Rollback interativo para uma revision
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Configurações — ajuste conforme o ambiente
# -----------------------------------------------------------------------------
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"           # Trocar para "service-bia-alb" quando necessário
TASK_FAMILY="task-def-bia-alb"      # Trocar para "task-def-bia-alb" quando necessário
ECR_REGISTRY="503528589359.dkr.ecr.us-east-2.amazonaws.com"
ECR_REPO="bia"
REGION="us-east-2"
AWS_PROFILE=""                  # Deixar vazio para usar a role da instância EC2

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------

# Monta o prefixo de comandos AWS CLI (com ou sem profile)
aws_cmd() {
  if [ -n "$AWS_PROFILE" ]; then
    aws --profile "$AWS_PROFILE" --region "$REGION" "$@"
  else
    aws --region "$REGION" "$@"
  fi
}

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
success() { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
error()   { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; }

# Verifica dependências necessárias
check_deps() {
  local missing=()
  for cmd in aws docker git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    error "Dependências faltando: ${missing[*]}"
    exit 1
  fi
}

# Extrai o short hash da imageUri (última parte após ":")
extract_hash() {
  local image_uri="$1"
  echo "$image_uri" | rev | cut -d: -f1 | rev
}

# -----------------------------------------------------------------------------
# Comando: list
# Lista todas as revisions ativas da task definition com o hash do commit
# -----------------------------------------------------------------------------
cmd_list() {
  log "Buscando revisions da task definition: $TASK_FAMILY"
  echo ""

  # Busca ARNs de todas as revisions ativas
  local arns
  arns=$(aws_cmd ecs list-task-definitions \
    --family-prefix "$TASK_FAMILY" \
    --status ACTIVE \
    --sort DESC \
    --query "taskDefinitionArns[]" \
    --output json)

  if [ "$(echo "$arns" | jq 'length')" -eq 0 ]; then
    error "Nenhuma revision encontrada para a família: $TASK_FAMILY"
    exit 1
  fi

  # Descobre qual revision o service está usando atualmente
  local current_revision
  current_revision=$(aws_cmd ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query "services[0].taskDefinition" \
    --output text | rev | cut -d: -f1 | rev)

  printf "%-10s %-15s %-50s %s\n" "REVISION" "COMMIT HASH" "IMAGEM" "STATUS"
  printf "%-10s %-15s %-50s %s\n" "--------" "-----------" "------" "------"

  echo "$arns" | jq -r '.[]' | while read -r arn; do
    local revision
    revision=$(echo "$arn" | rev | cut -d: -f1 | rev)

    local image_uri
    image_uri=$(aws_cmd ecs describe-task-definition \
      --task-definition "$arn" \
      --query "taskDefinition.containerDefinitions[0].image" \
      --output text)

    local commit_hash
    commit_hash=$(extract_hash "$image_uri")

    local status=""
    if [ "$revision" = "$current_revision" ]; then
      status="← ATUAL"
    fi

    printf "%-10s %-15s %-50s %s\n" "$revision" "$commit_hash" "$image_uri" "$status"
  done

  echo ""
}

# -----------------------------------------------------------------------------
# Comando: deploy
# Build da imagem, push para ECR, nova task definition e update do service
# -----------------------------------------------------------------------------
cmd_deploy() {
  check_deps

  # Pega o short commit hash do git local
  local commit_hash
  commit_hash=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || git rev-parse --short HEAD)
  log "Commit hash: $commit_hash"

  local image_uri="$ECR_REGISTRY/$ECR_REPO:$commit_hash"
  local image_uri_latest="$ECR_REGISTRY/$ECR_REPO:latest"
  local dockerfile_dir
  dockerfile_dir="$(cd "$(dirname "$0")" && pwd)"

  # 1. Login no ECR
  log "Fazendo login no ECR..."
  aws_cmd ecr get-login-password | docker login \
    --username AWS \
    --password-stdin "$ECR_REGISTRY"
  success "Login no ECR realizado"

  # 2. Build da imagem
  log "Fazendo build da imagem: $image_uri"
  docker build -t "$image_uri" -t "$image_uri_latest" "$dockerfile_dir"
  success "Build concluído"

  # 3. Push para o ECR
  log "Fazendo push para o ECR..."
  docker push "$image_uri"
  docker push "$image_uri_latest"
  success "Push concluído: $image_uri"

  # 4. Pega a task definition atual como base
  log "Buscando task definition atual: $TASK_FAMILY"
  local task_def_json
  task_def_json=$(aws_cmd ecs describe-task-definition \
    --task-definition "$TASK_FAMILY" \
    --query "taskDefinition" \
    --output json)

  # 5. Gera novo JSON substituindo apenas o imageUri do container
  log "Gerando nova revision da task definition com imagem: $image_uri"
  local new_task_def
  new_task_def=$(echo "$task_def_json" | jq \
    --arg IMAGE "$image_uri" \
    'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
     .containerDefinitions[0].image = $IMAGE')

  # 6. Registra nova revision
  local new_task_def_arn
  new_task_def_arn=$(aws_cmd ecs register-task-definition \
    --cli-input-json "$new_task_def" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)
  success "Nova task definition registrada: $new_task_def_arn"

  # 7. Atualiza o service
  log "Atualizando service $SERVICE no cluster $CLUSTER..."
  aws_cmd ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$new_task_def_arn" \
    --output json > /dev/null
  success "Service atualizado"

  # 8. Aguarda estabilização
  log "Aguardando service estabilizar (pode levar alguns minutos)..."
  aws_cmd ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE"
  success "Deploy concluído! Commit $commit_hash está no ar."
}

# -----------------------------------------------------------------------------
# Comando: rollback
# Lista versões disponíveis e permite escolher para qual reverter
# -----------------------------------------------------------------------------
cmd_rollback() {
  log "Iniciando rollback interativo..."
  echo ""

  # Mostra as versões disponíveis
  cmd_list

  # Pede a revision desejada
  read -r -p "Digite o número da REVISION para fazer rollback (ou ENTER para cancelar): " chosen_revision

  if [ -z "$chosen_revision" ]; then
    log "Rollback cancelado."
    exit 0
  fi

  # Valida se é um número
  if ! [[ "$chosen_revision" =~ ^[0-9]+$ ]]; then
    error "Revision inválida: '$chosen_revision'. Deve ser um número."
    exit 1
  fi

  local target_task_def="$TASK_FAMILY:$chosen_revision"

  # Confirma que a revision existe
  log "Verificando revision $target_task_def..."
  local task_def_status
  task_def_status=$(aws_cmd ecs describe-task-definition \
    --task-definition "$target_task_def" \
    --query "taskDefinition.status" \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$task_def_status" = "NOT_FOUND" ] || [ "$task_def_status" = "INACTIVE" ]; then
    error "Revision $chosen_revision não encontrada ou está inativa."
    exit 1
  fi

  # Confirmação final
  local image_uri
  image_uri=$(aws_cmd ecs describe-task-definition \
    --task-definition "$target_task_def" \
    --query "taskDefinition.containerDefinitions[0].image" \
    --output text)
  local commit_hash
  commit_hash=$(extract_hash "$image_uri")

  echo ""
  log "Você está prestes a fazer rollback para:"
  log "  Revision : $chosen_revision"
  log "  Commit   : $commit_hash"
  log "  Imagem   : $image_uri"
  echo ""
  read -r -p "Confirmar rollback? (s/N): " confirm

  if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    log "Rollback cancelado."
    exit 0
  fi

  # Atualiza o service para a revision escolhida
  log "Aplicando rollback para revision $chosen_revision..."
  aws_cmd ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$target_task_def" \
    --output json > /dev/null
  success "Service atualizado para revision $chosen_revision"

  # Aguarda estabilização
  log "Aguardando service estabilizar..."
  aws_cmd ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE"
  success "Rollback concluído! Commit $commit_hash está no ar."
}

# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------
main() {
  local command="${1:-}"

  case "$command" in
    deploy)
      cmd_deploy
      ;;
    list)
      cmd_list
      ;;
    rollback)
      cmd_rollback
      ;;
    *)
      echo ""
      echo "Uso: $(basename "$0") <comando>"
      echo ""
      echo "Comandos disponíveis:"
      echo "  deploy    Build da imagem, push para ECR e deploy no ECS"
      echo "  list      Lista revisions da task definition com hash do commit"
      echo "  rollback  Rollback interativo para uma revision anterior"
      echo ""
      echo "Variáveis configuráveis no topo do script:"
      echo "  CLUSTER      = $CLUSTER"
      echo "  SERVICE      = $SERVICE"
      echo "  TASK_FAMILY  = $TASK_FAMILY"
      echo "  REGION       = $REGION"
      echo ""
      exit 1
      ;;
  esac
}

main "$@"
