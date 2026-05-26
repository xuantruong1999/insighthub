# Day 2 — Debug session: docker MCP server không connect

**Ngày:** 2026-05-26
**Branch:** `feature/day-two`
**Servers:** filesystem, docker, prometheus, kubernetes, postgres (5 total)

## Triệu chứng

Sau khi scaffold `.mcp.json` với 5 servers và set 4 env vars (`INSIGHTHUB_ROOT`,
`PROMETHEUS_URL`, `KUBECONFIG`, `DATABASE_URL`), chạy `claude mcp list`:

```
filesystem: ... - ✓ Connected
docker:     npx -y docker-mcp-server@2.1.1 - ✗ Failed to connect
prometheus: ... - ✓ Connected
kubernetes: ... - ✓ Connected
postgres:   ... - ✓ Connected
```

4/5 server connect; chỉ `docker` fail. Cluster `kind-insighthub` đã chạy, RBAC
read-only đã apply, kubeconfig sinh ra OK — vậy fail này **không** liên quan
quyền hoặc env, mà ở chính server entry.

## Bước 1 — Khoanh vùng (filesystem MCP equivalent)

Đọc `.mcp.json` để confirm command đang chạy:

```json
"docker": {
  "command": "npx",
  "args": ["-y", "docker-mcp-server@2.1.1"]
}
```

Chạy thủ công để xem stderr:

```bash
$ npx -y docker-mcp-server@2.1.1 --help
Usage: docker-mcp-server [options]
MCP server for Docker container execution
Options:
  -p, --port <port>       Port to listen on (default: "30000")
  -t, --token <token>     Bearer token for authentication ...
```

**Root cause:** package `docker-mcp-server@2.1.1` là **HTTP server** (listen
port + bearer token), không phải **stdio** MCP. Claude Code spawn nó qua stdio
→ handshake không match → server exit → "Failed to connect".

Đây là lỗi chọn package, không phải lỗi cấu hình.

## Bước 2 — Tìm alternative (docker MCP equivalent)

`docker mcp` CLI đã có sẵn từ Docker Desktop:

```bash
$ docker mcp version
v0.13.0

$ docker mcp catalog show docker-mcp | grep -i "^docker:"
docker: Use the Docker CLI.

$ docker mcp server enable docker
$ docker mcp gateway run --dry-run
- Reading configuration...
- Listing MCP tools...
> Initialized in 19.4ms
Dry run mode enabled, not starting the server.
```

Docker MCP Toolkit gateway: stdio by default, integrated với Docker Desktop,
catalog-managed. Đây mới là entry chuẩn.

## Bước 3 — Fix

Sửa `.mcp.json`:

```diff
 "docker": {
-  "command": "npx",
-  "args": ["-y", "docker-mcp-server@2.1.1"]
+  "command": "docker",
+  "args": ["mcp", "gateway", "run", "--servers", "docker"]
 }
```

Re-verify:

```
$ claude mcp list | grep -E "^(filesystem|docker|prometheus|kubernetes|postgres):"
filesystem: ... - ✓ Connected
docker:     docker mcp gateway run --servers docker - ✓ Connected
prometheus: ... - ✓ Connected
kubernetes: ... - ✓ Connected
postgres:   ... - ✓ Connected
```

5/5 ✓ Connected.

## Verification — least-privilege ServiceAccount (kubernetes MCP)

Cluster kind-insighthub, namespace `insighthub`, SA `mcp-readonly`:

```
$ kubectl auth can-i get pods    --as=system:serviceaccount:insighthub:mcp-readonly
yes
$ kubectl auth can-i delete pods --as=system:serviceaccount:insighthub:mcp-readonly
no
$ kubectl auth can-i create deployments --as=system:serviceaccount:insighthub:mcp-readonly
no
```

Kubeconfig sinh ra ở `~/.kube/mcp-viewer.kubeconfig`, dùng SA token thay vì
admin cert → `kubernetes-mcp-server --read-only` chạy với blast radius = 0.

## Lessons

1. **`✗ Failed to connect` trong `claude mcp list` không phân biệt được lý do
   thật (auth, env, package sai loại). Phải chạy command thủ công để đọc stderr.**
2. **Tên package nghe giống không có nghĩa là đúng loại transport.**
   `docker-mcp-server` (npm) ≠ Docker MCP Toolkit. Luôn check `--help` /
   docs trước khi pin.
3. **Docker MCP Toolkit (`docker mcp gateway run`)** là entry chính thức từ
   Docker Inc — catalog-managed, secret-managed, ưu tiên nó hơn các package
   community.
4. **RBAC là rào chắn cuối cùng.** Kể cả khi MCP server bị inject prompt yêu cầu
   `kubectl delete pod`, API server reject vì SA không có verb `delete`.
   `--read-only` của `kubernetes-mcp-server` là defense-in-depth, không phải
   defense duy nhất.

## Artifacts đã tạo trong session

- `.mcp.json` — 5 servers, versions pinned (`docker mcp` CLI v0.13.0 đi kèm
  Docker Desktop; không pin được qua npm)
- `infra/k8s/mcp-readonly.yaml` — SA + ClusterRole (get/list/watch) + binding + token
- `scripts/gen-mcp-kubeconfig.sh` — sinh kubeconfig dùng SA token
- `.env` — INSIGHTHUB_ROOT, PROMETHEUS_URL, KUBECONFIG, DATABASE_URL (gitignored)
