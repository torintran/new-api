#!/usr/bin/env bash
# Cài new-api lên k3s một lần: secret, manifest, chờ pod Ready.
#
# Trên node k3s (hoặc máy đã có KUBECONFIG trỏ vào cluster):
#   bash deploy/k3s/scripts/install.sh
#
# Trước đó, copy app-secrets.env.example và đặt PUBLIC_ORIGIN thật.
# Chạy lại an toàn: secret đã có thì giữ nguyên, không xoay SESSION_SECRET.
# Muốn tạo secret mới khi CHƯA lưu channel key:
#   kubectl -n new-api delete secret new-api-secrets
#
# Biến có thể ghi đè:
#   KUBECTL          lệnh kubectl (mặc định tự tìm kubectl hoặc k3s kubectl)
#   NS               namespace
#   ENV_FILE         file plaintext gitignored
#   ROLLOUT_TIMEOUT  thời gian chờ pod Ready

set -euo pipefail

NS="${NS:-new-api}"
SECRET_NAME="${SECRET_NAME:-new-api-secrets}"
DEPLOY_NAME="${DEPLOY_NAME:-new-api}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
SERVICE_PORT="${SERVICE_PORT:-3000}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
SESSION_SECRET_RAND_BYTES="${SESSION_SECRET_RAND_BYTES:-32}"
SECRET_KEY_SESSION="session-secret"
SECRET_KEY_ORIGIN="public-origin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/overlays/prod"
ENV_FILE="${ENV_FILE:-$ROOT/secrets/app-secrets.env}"

log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

is_placeholder_secret() {
  local value="$1"
  [[ -z "$value" || "$value" == *REPLACE_WITH* || "$value" == *" "* ]]
}

is_valid_origin() {
  local value="$1"
  [[ "$value" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ && "$value" != *example.com* ]]
}

read_env_value() {
  local key="$1" file="$2" line value
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)"
  value="${line#*=}"
  value="${value//$'\r'/}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

pick_kubectl() {
  if [[ -n "${KUBECTL:-}" ]]; then
    # shellcheck disable=SC2206
    KUBECTL_CMD=($KUBECTL)
    return
  fi
  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(kubectl)
    return
  fi
  if command -v k3s >/dev/null 2>&1 && k3s kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(k3s kubectl)
    return
  fi
  if command -v k3s >/dev/null 2>&1 && sudo -n k3s kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(sudo -n k3s kubectl)
    return
  fi
  die "Không nối được cluster. Chạy trên node k3s, hoặc export KUBECONFIG / KUBECTL."
}

k() { "${KUBECTL_CMD[@]}" "$@"; }

require_tools() {
  command -v openssl >/dev/null 2>&1 || die "openssl không có trong PATH"
  command -v grep >/dev/null 2>&1 || die "grep không có trong PATH"
  [[ -d "$OVERLAY" ]] || die "Thiếu overlay: $OVERLAY"
}

require_storage_class() {
  k get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 \
    || die "Thiếu StorageClass ${STORAGE_CLASS}. k3s mặc định có local-path; kiểm tra: kubectl get storageclass"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Thiếu $ENV_FILE — copy từ app-secrets.env.example và đặt PUBLIC_ORIGIN"
  PUBLIC_ORIGIN="$(read_env_value PUBLIC_ORIGIN "$ENV_FILE")"
  PUBLIC_ORIGIN="${PUBLIC_ORIGIN%/}"
  SESSION_SECRET="$(read_env_value SESSION_SECRET "$ENV_FILE")"
  is_valid_origin "$PUBLIC_ORIGIN" \
    || die "PUBLIC_ORIGIN phải là origin HTTPS thật, dạng https://host, không path. Giá trị đọc được: $(printf '%q' "$PUBLIC_ORIGIN"). Sửa $ENV_FILE"
  if is_placeholder_secret "$SESSION_SECRET"; then
    SESSION_SECRET="$(openssl rand -hex "$SESSION_SECRET_RAND_BYTES")"
    umask 077
    cat >"$ENV_FILE" <<EOF
SESSION_SECRET=${SESSION_SECRET}
PUBLIC_ORIGIN=${PUBLIC_ORIGIN}
EOF
    chmod 600 "$ENV_FILE"
    log "Đã sinh SESSION_SECRET và ghi $ENV_FILE"
  else
    log "Dùng SESSION_SECRET có sẵn trong $ENV_FILE"
  fi
}

ensure_secret() {
  k apply -f "$ROOT/base/namespace.yaml"
  if k -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    log "Secret ${NS}/${SECRET_NAME} đã có, giữ nguyên"
    return
  fi
  load_env
  k -n "$NS" create secret generic "$SECRET_NAME" \
    --from-literal="${SECRET_KEY_SESSION}=${SESSION_SECRET}" \
    --from-literal="${SECRET_KEY_ORIGIN}=${PUBLIC_ORIGIN}" \
    --dry-run=client -o yaml \
    | k apply -f -
  log "Đã tạo secret ${NS}/${SECRET_NAME}"
}

apply_manifests() {
  log "Apply $OVERLAY"
  k apply -k "$OVERLAY"
}

wait_ready() {
  if k -n "$NS" rollout status "deploy/${DEPLOY_NAME}" --timeout="$ROLLOUT_TIMEOUT"; then
    return
  fi
  log "Pod chưa Ready. Trạng thái hiện tại:"
  k -n "$NS" get pods,pvc || true
  k -n "$NS" describe "deploy/${DEPLOY_NAME}" || true
  exit 1
}

print_summary() {
  local origin image
  origin="$(k -n "$NS" get secret "$SECRET_NAME" -o "jsonpath={.data['${SECRET_KEY_ORIGIN}']}" | base64 -d)"
  image="$(k -n "$NS" get deploy "$DEPLOY_NAME" -o 'jsonpath={.spec.template.spec.containers[0].image}')"
  k -n "$NS" get pods,pvc
  log ""
  log "Đã cài xong."
  log "Image:    ${image}"
  log "Service:  http://${DEPLOY_NAME}.${NS}.svc.cluster.local:${SERVICE_PORT}"
  log "Console:  ${origin}"
  log "SESSION_SECRET nằm trong ${ENV_FILE} và secret ${NS}/${SECRET_NAME}."
  log "Đừng xoay secret này sau khi đã lưu channel key."
  log ""
  log "Tunnel (Zero Trust → Public Hostname → HTTP):"
  log "  ${DEPLOY_NAME}.${NS}.svc.cluster.local:${SERVICE_PORT}"
  log "Lần đầu mở ${origin} để tạo tài khoản quản trị."
}

pick_kubectl
require_tools
require_storage_class
ensure_secret
apply_manifests
wait_ready
print_summary
