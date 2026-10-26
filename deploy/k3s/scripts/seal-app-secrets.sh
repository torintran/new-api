#!/usr/bin/env bash
set -euo pipefail

# Mã hoá SESSION_SECRET + PUBLIC_ORIGIN thành SealedSecret (ciphertext an toàn để commit).
# Dùng chung Sealed Secrets controller với repo cloudflared của bạn.
#
# Cách dùng:
#   ./deploy/k3s/scripts/seal-app-secrets.sh
#   ./deploy/k3s/scripts/seal-app-secrets.sh /path/to/app-secrets.env
#
# Nguồn plaintext : deploy/k3s/secrets/app-secrets.env  (gitignored)
# Đích ciphertext : deploy/k3s/overlays/prod/sealed-app-secrets.yaml
#
# Sau khi seal, apply riêng file ciphertext:
#   kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml
# (không nằm trong kustomization để 'kubectl apply -k' vẫn chạy được trước lần seal đầu)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-new-api}"
NAME="${NAME:-new-api-secrets}"
SRC="${1:-$ROOT/secrets/app-secrets.env}"
OUT="${OUT:-$ROOT/overlays/prod/sealed-app-secrets.yaml}"

command -v kubeseal >/dev/null 2>&1 || { echo "kubeseal không có trong PATH"; exit 1; }
command -v kubectl  >/dev/null 2>&1 || { echo "kubectl không có trong PATH"; exit 1; }
[ -f "$SRC" ] || { echo "Thiếu $SRC — copy từ app-secrets.env.example"; exit 1; }

set -a
# shellcheck disable=SC1090
. "$SRC"
set +a

: "${SESSION_SECRET:?SESSION_SECRET rỗng}"
: "${PUBLIC_ORIGIN:?PUBLIC_ORIGIN rỗng}"

if [[ "$SESSION_SECRET" == *REPLACE_WITH* || "$SESSION_SECRET" == *" "* ]]; then
  echo "SESSION_SECRET vẫn là placeholder"
  exit 1
fi
if [[ ! "$PUBLIC_ORIGIN" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ || "$PUBLIC_ORIGIN" == *example.com* ]]; then
  echo "PUBLIC_ORIGIN phải là origin HTTPS thật, dạng https://host, không path"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
umask 077

kubectl create secret generic "$NAME" \
  --namespace "$NS" \
  --from-literal=session-secret="$SESSION_SECRET" \
  --from-literal=public-origin="$PUBLIC_ORIGIN" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets-controller \
    --format yaml \
> "$OUT"

chmod 644 "$OUT"
echo "Đã ghi $OUT"
echo "Apply: kubectl apply -f $OUT"
