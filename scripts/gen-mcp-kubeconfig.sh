#!/usr/bin/env bash
# Day 2 — generate a kubeconfig that authenticates as the read-only MCP
# ServiceAccount. The kubernetes-mcp-server is then pointed at this file via
# the KUBECONFIG env var in .mcp.json.
#
# Prereqs:
#   - kubectl is on PATH and current-context already points at the target cluster
#   - infra/k8s/mcp-readonly.yaml has been applied
#
# Usage:
#   bash scripts/gen-mcp-kubeconfig.sh              # writes ~/.kube/mcp-viewer.kubeconfig
#   bash scripts/gen-mcp-kubeconfig.sh /tmp/foo.kc  # custom output path

set -euo pipefail

NAMESPACE="insighthub"
SA="mcp-readonly"
SECRET="mcp-readonly-token"
OUT="${1:-$HOME/.kube/mcp-viewer.kubeconfig}"

echo "→ Using current-context: $(kubectl config current-context)"

CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

if [[ -z "$CLUSTER_CA" ]]; then
  # Some clusters (kind/k3d) inline the CA via certificate-authority file rather
  # than -data. Fall back to reading the file and base64-encoding it.
  CA_FILE=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  if [[ -n "$CA_FILE" && -f "$CA_FILE" ]]; then
    CLUSTER_CA=$(base64 -w0 < "$CA_FILE" 2>/dev/null || base64 < "$CA_FILE" | tr -d '\n')
  fi
fi

echo "→ Fetching token from secret $NAMESPACE/$SECRET …"
TOKEN=$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: token is empty. Did the SA token controller populate the secret yet?" >&2
  echo "       Try: kubectl -n $NAMESPACE describe secret $SECRET" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${CLUSTER_SERVER}
      certificate-authority-data: ${CLUSTER_CA}
contexts:
  - name: mcp-viewer@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      namespace: ${NAMESPACE}
      user: ${SA}
current-context: mcp-viewer@${CLUSTER_NAME}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
EOF

chmod 600 "$OUT"
echo "✓ Wrote $OUT"
echo
echo "Verify (both should pass):"
echo "  kubectl --kubeconfig $OUT get pods -n $NAMESPACE"
echo "  kubectl --kubeconfig $OUT auth can-i delete pods -n $NAMESPACE   # → no"
