# new-api trên k3s — dùng lại Cloudflare Tunnel sẵn có

Bố cục này bám theo repo `cloudflared` đang chạy và cùng kiểu với `gemini-web2api-go`:

- Kustomize với `base/` + `overlays/prod/`
- Image `ghcr.io/torintran/new-api`, tag đặt trong overlay
- Secret qua **Sealed Secrets** (dùng chung controller đã cài)
- **Không** tạo thêm cloudflared: tunnel hiện tại (namespace `cloudflare`, 2 replica, PDB) đã đủ. Chỉ cần thêm public hostname trỏ vào service của app.

Đây là một replica, SQLite trên PVC. Không kèm PostgreSQL, MySQL hay Redis. Muốn nhiều node thì không dùng bố cục này: SQLite trên `local-path` chỉ mount được một pod.

## Kiến trúc

```text
Internet → Cloudflare Edge → cloudflared (ns cloudflare, ×2) → Service DNS
                                        │
                                        ▼
                        http://new-api.new-api.svc.cluster.local:3000
                                        │
                                        ▼
                        Deployment/new-api (ns new-api, 1 pod)
                                        └── PVC local-path (SQLite + logs)
```

Không có Ingress, không có Traefik, không mở port 80/443 trên VPS.

Database mặc định là `one-api.db` trong `/data` (WORKDIR của image). Log ghi vào `/data/logs`.

## Bố cục repo

```text
deploy/k3s/
├── base/                      # namespace, pvc, deployment, service, networkpolicy
│   └── kustomization.yaml
├── overlays/prod/
│   ├── kustomization.yaml     # pin image
│   └── sealed-app-secrets.yaml # do script sinh ra, commit được
├── scripts/seal-app-secrets.sh
├── scripts/install.sh
├── app-secrets.env.example
└── .gitignore
```

Đường apply production:

```bash
kubectl apply -k deploy/k3s/overlays/prod
```

## Build & push image của bạn (làm một lần)

Workflow `.github/workflows/docker-ghcr.yml` (**Publish Docker image (GHCR)**) build multi-arch (amd64 + arm64) và đẩy lên GHCR của repo đang chạy. Trên fork này đích là `ghcr.io/torintran/new-api`. Không cần Docker trên máy.

Push lên `main` hoặc tag `v*` là workflow chạy. Bấm tay cũng được: **Actions → Publish Docker image (GHCR) → Run workflow**.

Hai mục **Publish Docker image (Multi-arch)** và **Publish Docker image (manual branch)** đẩy lên Docker Hub `calciumion/new-api` và cần secret của project gốc. Không chạy chúng.

Kết quả mong đợi:

```text
ghcr.io/torintran/new-api:v1.0.0        # từ git tag v* mới, do bạn tạo
ghcr.io/torintran/new-api:main          # từ nhánh main
ghcr.io/torintran/new-api:latest        # từ main, hoặc từ tag v*
```

Overlay đang pin `latest`. Tag `v1.0.0` trong ví dụ chỉ là tên tag mới; đừng push lại tag upstream đã có sẵn (ví dụ `v1.0.0-rc.47`) vì Git không tạo lại tag cũ và workflow không chạy.

File workflow phải nằm trên `main` thì nút **Run workflow** mới hiện.

### Bước 1 — bật Actions cho fork

Fork mặc định tắt Actions cho đến khi bạn bật.

GitHub → repo `torintran/new-api` → tab **Actions** → bấm **I understand my workflows, go ahead and enable them**.

Nếu tab đã liệt kê workflow thì Actions đang bật, bỏ qua bước này.

### Bước 2 — trigger build

Commit và push `.github/workflows/docker-ghcr.yml` lên `main` trước. Push đó đã kích hoạt build và ra tag `main` + `latest`.

Muốn thêm một tag bất biến:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Hoặc, khi workflow đã có trên `main`, bấm **Actions → Publish Docker image (GHCR) → Run workflow** trên nhánh `main` (ra tag `main` + `latest`).

Theo dõi ở tab **Actions**. Cả job amd64 và arm64 phải xanh thì manifest `latest` mới có đủ hai kiến trúc. Build xong thì kiểm tra từ máy:

```bash
docker manifest inspect ghcr.io/torintran/new-api:latest
```

Nếu trả về JSON manifest là image đã có. Nếu `denied` thì build chưa xong, hoặc package đang private.

### Bước 3 — cho k3s pull được image

Package mới trên GHCR mặc định **private** → pod sẽ `ImagePullBackOff`.

**Cách 1 (khuyến nghị)** — để public: GitHub → **Packages** → `new-api` → **Package settings** → **Change visibility** → **Public**. Image chỉ chứa binary app, không có secret.

**Cách 2** — giữ private, tạo pull secret:

```bash
kubectl -n new-api create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=torintran \
  --docker-password='<PAT có read:packages>'
```

Rồi thêm vào `base/deployment.yaml`, dưới `spec.template.spec`:

```yaml
      imagePullSecrets:
        - name: ghcr-pull
```

### Build local (dự phòng)

Nếu không dùng CI:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u torintran --password-stdin

docker buildx create --use --name new-api 2>/dev/null || true
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/torintran/new-api:v1.0.0 \
  --push .
```

PAT cần scope `write:packages` + `read:packages`.

Deployment hiện dùng `imagePullPolicy: Always` với tag `latest`, nên lần deploy sau vẫn kéo lại image khi tag không đổi. Nếu sau này bạn pin tag bất biến và đổi policy thành `IfNotPresent`, mỗi lần build lại phải dùng tag mới (ví dụ `v1.0.0-2`), vì policy đó không kéo lại tag cũ.

### Kiểm tra trước khi deploy

```bash
docker manifest inspect ghcr.io/torintran/new-api:latest > /dev/null && echo "image OK"
```

## 0. Yêu cầu

- k3s đang chạy, `kubectl` hoạt động.
- **Sealed Secrets controller** đã cài (`kubectl get pods -n kube-system -l name=sealed-secrets-controller`).
- `kubeseal` trong PATH nếu dùng Sealed Secret.
- Tunnel trong Zero Trust đang **Healthy**.
- StorageClass `local-path`.

Kiểm tra:

```bash
kubectl get nodes -o wide
kubectl get storageclass
kubectl get pods -n cloudflare
```

## 1. Tạo secret cho app

Secret có hai khóa:

| Khóa | Env trong pod | Việc của nó |
|---|---|---|
| `session-secret` | `SESSION_SECRET` | Session và, khi không set riêng, `CRYPTO_SECRET` để mã hoá channel key |
| `public-origin` | `SESSION_COOKIE_TRUSTED_URL` | Origin HTTPS đúng của console |

`SESSION_COOKIE_SECURE=true` đã gắn trong Deployment. App từ chối boot nếu origin không phải `https://host` không path.

Không xoay `SESSION_SECRET` sau khi đã lưu channel. Key đã mã hoá trong SQLite sẽ không đọc lại được.

### Cách A — Sealed Secret

```bash
cp deploy/k3s/app-secrets.env.example deploy/k3s/secrets/app-secrets.env
```

Sửa `PUBLIC_ORIGIN` thành hostname thật, ví dụ `https://api.example.com`. Sinh secret:

```bash
openssl rand -hex 32
```

Điền vào `SESSION_SECRET`, rồi:

```bash
bash deploy/k3s/scripts/seal-app-secrets.sh
kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml
```

File sealed là ciphertext, commit được. Plaintext nằm trong `deploy/k3s/secrets/` và đã gitignore. File sealed không nằm trong `kustomization.yaml`.

### Cách B — script cài một lần

Điền `PUBLIC_ORIGIN` trong `deploy/k3s/secrets/app-secrets.env`. Nếu `SESSION_SECRET` còn placeholder, script tự sinh.

```bash
bash deploy/k3s/scripts/install.sh
```

Script tạo secret nếu chưa có, apply overlay, và chờ pod Ready. Chạy lại không xoay secret đang có trong cluster.

### Cách C — kubectl create secret

```bash
kubectl create namespace new-api

kubectl -n new-api create secret generic new-api-secrets \
  --from-literal=session-secret="$(openssl rand -hex 32)" \
  --from-literal=public-origin='https://api.example.com'
```

## 2. Deploy

Nếu không dùng `install.sh`:

```bash
kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml   # nếu dùng cách A
kubectl apply -k deploy/k3s/overlays/prod
```

Theo dõi:

```bash
kubectl -n new-api get pods,pvc
kubectl -n new-api rollout status deploy/new-api --timeout=300s
kubectl -n new-api logs deploy/new-api --tail=100
```

Kỳ vọng: pod `1/1 Running`, PVC `Bound`. Lần boot đầu app tự migrate SQLite.

## 3. Thêm public hostname vào tunnel hiện có

Zero Trust → **Networks** → **Tunnels** → tunnel của bạn → **Public Hostname** → **Add a public hostname**:

| Field | Value |
|---|---|
| Subdomain | phần host bạn đã ghi trong `PUBLIC_ORIGIN` |
| Domain | domain của bạn |
| Path | để trống |
| Type | `HTTP` |
| URL | `new-api.new-api.svc.cluster.local:3000` |

`PUBLIC_ORIGIN` phải trùng origin trình duyệt thấy, ví dụ hostname `api` + domain `example.com` thì origin là `https://api.example.com`.

Hostname được quản lý trong dashboard, không cần sửa manifest, không cần restart cloudflared. Dùng chung tunnel với các app khác. Xoay token tunnel không đụng tới secret của new-api.

Nếu sau này bật default-deny ingress cho namespace `new-api`, phải cho phép ingress từ namespace `cloudflare` vào port 3000.

## 4. Cấu hình Cloudflare

Không bật Access cho cả hostname. Console và API dùng chung host; Access chặn luôn client gọi `/v1`.

- Cache Rule: **Bypass** cho hostname này. Cache làm hỏng streaming.
- **Bot Fight Mode**: tắt cho hostname này.
- **Under Attack Mode**: tắt.
- SSL/TLS: `Full` (origin trong cluster là HTTP), bật Always Use HTTPS, Minimum TLS 1.2.
- WebSocket: hostname kiểu HTTP của tunnel cho phép upgrade. Realtime dùng `GET /v1/realtime` và `GET /v1/responses`.

Request không stream mà quá khoảng 100 giây không có byte đầu thì Cloudflare trả **524**. Chat dài nên bật `stream: true`.

## 5. Test

Mở `PUBLIC_ORIGIN` và hoàn thành wizard tạo tài khoản quản trị.

Trong console: thêm channel, bật model, tạo API key. Rồi:

```bash
curl -fsS https://api.example.com/api/status

curl -fsS https://api.example.com/v1/models \
  -H "Authorization: Bearer $NEW_API_KEY"
```

Streaming:

```bash
curl -N https://api.example.com/v1/chat/completions \
  -H "Authorization: Bearer $NEW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-enabled-model",
    "stream": true,
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

Thấy `data: {...}` từng đoạn là ổn.

## 6. Vận hành

```bash
kubectl -n new-api logs -f deploy/new-api
kubectl -n cloudflare logs -l app.kubernetes.io/name=cloudflared --tail=50

kubectl -n new-api rollout restart deploy/new-api
```

### Nâng cấp image

Sửa `overlays/prod/kustomization.yaml`, đổi `newTag`, rồi:

```bash
kubectl apply -k deploy/k3s/overlays/prod
kubectl -n new-api rollout status deploy/new-api
```

Một replica và strategy `Recreate`: pod cũ tắt rồi pod mới mới lên. Có khoảng ngắt ngắn.

### Backup

`local-path` trên single-node là hostPath:

```bash
PV=$(kubectl -n new-api get pvc new-api-data -o jsonpath='{.spec.volumeName}')
HOSTPATH=$(kubectl get pv "$PV" -o jsonpath='{.spec.hostPath.path}')
sudo tar czf /root/new-api-$(date +%F-%H%M).tgz -C "$HOSTPATH" .
```

Giữ `deploy/k3s/secrets/app-secrets.env` cùng bản backup. Mất `SESSION_SECRET` thì channel key trong database không giải mã được.

Restore:

```bash
kubectl -n new-api scale deploy/new-api --replicas=0
# giải nén vào đúng HOSTPATH, giữ nguyên SESSION_SECRET
kubectl -n new-api scale deploy/new-api --replicas=1
```

### Xoá

```bash
kubectl delete -k deploy/k3s/overlays/prod
kubectl -n new-api delete secret new-api-secrets
kubectl delete namespace new-api
```

Xoá namespace là xoá PVC. Backup trước.

## 7. Troubleshooting

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| Pod `Init:CrashLoopBackOff` | Init container không chown được volume | `kubectl -n new-api logs pod/... -c fix-data-permissions` |
| `unable to open database file` | Volume thuộc root, app chạy uid 65532 | Init container phải chown `/data` |
| `CreateContainerConfigError` | Thiếu Secret `new-api-secrets` | Tạo secret trước khi apply Deployment |
| Boot chết vì `SESSION_COOKIE_TRUSTED_URL` | Origin sai, có path, hoặc không phải https | Sửa `public-origin` cho đúng `https://host` rồi restart |
| Secret không xuất hiện sau SealedSecret | Seal bằng key của cluster khác | `kubeseal --fetch-cert` từ cluster này rồi seal lại |
| Cloudflare 502 | cloudflared không tới được service | Kiểm tra URL hostname, pod Ready |
| Cloudflare 524 | Origin không trả byte đầu trong ~100s | Dùng `stream: true` |
| Cookie đăng nhập không giữ | `PUBLIC_ORIGIN` khác hostname trình duyệt | Hai giá trị phải trùng |
| `ImagePullBackOff` | Tag không có, hoặc GHCR private | `docker manifest inspect`; package public hoặc `imagePullSecrets` |
| Pod OOMKilled | Request lớn, nhiều stream | Tăng memory limit trong Deployment |
| PVC Pending | Thiếu StorageClass `local-path` | `kubectl get sc` |
| Cảnh báo `TRUSTED_PROXIES` lúc boot | Chưa set biến, app tin RFC1918 | Đúng với cloudflared trong cluster. Đừng đặt `none` nếu cần IP client |
| `dial tcp 10.43.x.x:8083: connect: connection refused` khi test kênh | NetworkPolicy của pod `new-api` chặn Service IP | Mục dưới. Pod curl không mang label app không chứng minh pod app đi được |

### Kênh trong cluster: connection refused tới gemini-web2api

Base URL đúng là `http://gemini-web2api.gemini.svc.cluster.local:8083`, không thêm `/v1`. Log test kênh dạng:

```text
Post "http://gemini-web2api.gemini.svc.cluster.local:8083/v1/chat/completions": dial tcp 10.43.95.20:8083: connect: connection refused
```

DNS đã ra ClusterIP. `connection refused` là RST ở TCP, không phải sai key. `new-api-egress` chỉ cho dải `10.43.0.0/16` mở cổng 53, và rule Internet loại cả `10.0.0.0/8`. Trên k3s, gói bị policy chặn trả RST.

Pod `curl` tạo bằng `kubectl run` không có label `app.kubernetes.io/name: new-api`, nên policy không áp vào nó. `curl` ra HTTP 200 không có nghĩa pod new-api nối được.

Kiểm tra:

```bash
kubectl -n gemini get endpoints gemini-web2api -o wide
kubectl get networkpolicy -n new-api
```

Endpoints phải có IP pod. Policy `new-api-egress` phải cho TCP `8083` tới `10.43.0.0/16` và namespace `gemini`.

Áp manifest đã sửa rồi test lại kênh trong console, model `gemini-3.6-flash`:

```bash
kubectl apply -k deploy/k3s/overlays/prod
```

Lần thất bại sau đó, nếu còn, log sẽ là lỗi key, model hoặc cookie, không còn `connection refused`.

## 8. Checklist

- [ ] `PUBLIC_ORIGIN` là origin HTTPS thật, trùng hostname tunnel.
- [ ] `SESSION_SECRET` đã lưu ngoài git và nằm trong bản backup.
- [ ] Sealed secret đã commit nếu dùng cách A; plaintext `.env` không commit.
- [ ] Không bật Cloudflare Access trên cả hostname.
- [ ] Cache bypass, tắt Bot Fight Mode.
- [ ] Container nonroot, read-only root FS, drop ALL caps.
- [ ] NetworkPolicy chặn egress private/link-local.
- [ ] Vẫn một replica.
- [ ] Image `ghcr.io/torintran/new-api:latest` đã push, package public hoặc đã có `ghcr-pull`.

## 9. Tóm tắt

```bash
# 0. Image: Actions → Publish Docker image (GHCR) → Run workflow trên main
#    rồi để package public, hoặc tạo ghcr-pull (mục Build & push)

cp deploy/k3s/app-secrets.env.example deploy/k3s/secrets/app-secrets.env
# sửa PUBLIC_ORIGIN, điền SESSION_SECRET=$(openssl rand -hex 32)

bash deploy/k3s/scripts/install.sh

# Zero Trust: public hostname HTTP
#   https://api.example.com → new-api.new-api.svc.cluster.local:3000
```
