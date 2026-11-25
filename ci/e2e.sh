#!/usr/bin/env bash
# End-to-end test on a kind cluster (current kubectl context):
#   server (velociraptor chart, OCI) + agent DaemonSet (this chart, locally built image)
#   -> enrollment, stable client ID across a rollout, Kubernetes artifacts (pods mapping,
#      container file collection, pod logs), auto-labels, ephemeral agent (kubectl plugin).
# Usage: ci/e2e.sh [kind-cluster-name]
set -euo pipefail

KIND_CLUSTER="${1:-chart-testing}"
NS=velociraptor
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

log() { echo "::group::$*" >&2; }
end() { echo "::endgroup::" >&2; }
fail() { echo "::error::$*" >&2; kubectl -n "$NS" get pods -o wide >&2 || true; \
         kubectl -n "$NS" logs ds/agent-velociraptor-agent -c velociraptor --tail=50 >&2 || true; exit 1; }
retry() { local n=$1; shift; for _ in $(seq "$n"); do "$@" && return 0; sleep 5; done; return 1; }

log "Build agent image"
docker build -q -t velociraptor-agent:ci "$ROOT" >/dev/null
kind load docker-image velociraptor-agent:ci --name "$KIND_CLUSTER"
docker create --name velo-bin velociraptor-agent:ci >/dev/null
docker cp velo-bin:/velociraptor "$WORK/velociraptor"; docker rm velo-bin >/dev/null
end

log "Install agent + server"
kubectl create ns "$NS"
kubectl label ns "$NS" pod-security.kubernetes.io/enforce=privileged
helm install agent "$ROOT/chart" -n "$NS" \
  --set image.registry= --set image.repository=velociraptor-agent --set image.tag=ci \
  --set clientConfig.existingSecret=velo-velociraptor-client-root \
  --set identity.clusterName=ci --set 'identity.extraLabels[0]=e2e'
cat > "$WORK/server.yaml" <<'EOF'
frontend:
  service:
    type: ClusterIP
clientConfig:
  export:
    enabled: true
customArtifacts:
  enabled: true
  existingConfigMaps: [agent-velociraptor-agent-artifacts]
apiClients:
  - name: e2e
    roles: [administrator, api]
EOF
helm install velo oci://ghcr.io/maximewewer/charts/velociraptor --devel -n "$NS" \
  -f "$WORK/server.yaml" --wait --timeout 600s
kubectl -n "$NS" wait --for=create secret/velo-velociraptor-client-root --timeout=300s
kubectl -n "$NS" wait --for=create secret/velo-velociraptor-api-e2e --timeout=300s
kubectl -n "$NS" rollout status ds/agent-velociraptor-agent --timeout=300s || fail "agent not ready"
end

log "API access"
kubectl -n "$NS" get secret velo-velociraptor-api-e2e -o jsonpath='{.data.api\.config\.yaml}' \
  | base64 -d | sed 's/^api_connection_string: .*/api_connection_string: 127.0.0.1:18001/' > "$WORK/api.yaml"
kubectl -n "$NS" port-forward pod/velo-velociraptor-0 18001:8001 >/dev/null 2>&1 &
PF_PID=$!
vq() { "$WORK/velociraptor" --nobanner --api_config "$WORK/api.yaml" query --format=jsonl "$@"; }
retry 24 vq "SELECT 1 FROM scope()" >/dev/null || fail "API unreachable"
end

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
client_of() { vq --env "H=$1" "SELECT client_id FROM clients() WHERE os_info.hostname = H" | jq -r .client_id | head -1; }
enrolled() { [ -n "$(client_of "$1")" ]; }

log "Enrollment (hostname = node name)"
retry 24 enrolled "$NODE" || fail "no client with hostname $NODE"
CID="$(client_of "$NODE")"; echo "client $CID" >&2
end

# collect <client> <artifact> [params json] -> result rows (jsonl)
collect() {
  local params="${3:-}"; [ -n "$params" ] || params='{}'
  vq --env "C=$1" --env "A=$2" --env "P=$params" "
    LET F <= collect_client(client_id=C, artifacts=A, env=parse_json(data=P), timeout=240)
    LET W <= SELECT * FROM watch_monitoring(artifact='System.Flow.Completion') WHERE FlowId = F.flow_id LIMIT 1
    SELECT * FROM source(client_id=C, flow_id=F.flow_id, artifact=A)"
}

log "Victim pod"
kubectl create ns victim
kubectl -n victim run app --image=busybox:1.37 --restart=Never -- \
  sh -c 'echo E2E-EVIDENCE > /tmp/evidence; ln -s / /tmp/escape; echo started; sleep 3600'
kubectl -n victim wait --for=condition=Ready pod/app --timeout=180s
WANT="$(printf 'E2E-EVIDENCE\n' | sha256sum | awk '{print $1}')"
end

log "Linux.Kubernetes.Pods"
collect "$CID" Linux.Kubernetes.Pods '{"NamespaceRegex":"^victim$"}' | tee "$WORK/pods.jsonl" >&2
jq -e 'select(.Pod=="app" and .Container=="app" and .Runtime=="containerd")' "$WORK/pods.jsonl" >/dev/null \
  || fail "victim pod not mapped"
end

log "Linux.Kubernetes.Container.Collect"
collect "$CID" Linux.Kubernetes.Container.Collect '{"NamespaceRegex":"^victim$"}' > "$WORK/files.jsonl"
jq -c '{ContainerPath, Sha: .Upload.sha256}' "$WORK/files.jsonl" >&2
jq -e --arg w "$WANT" 'select(.ContainerPath=="/tmp/evidence" and .Upload.sha256==$w)' "$WORK/files.jsonl" >/dev/null \
  || fail "/tmp/evidence not collected from the container"
if jq -e 'select(.ContainerPath | startswith("/tmp/escape"))' "$WORK/files.jsonl" >/dev/null; then
  fail "followed a symlink out of the container (/tmp/escape -> /)"
fi
end

log "Linux.Kubernetes.PodLogs"
collect "$CID" Linux.Kubernetes.PodLogs '{"NamespaceRegex":"^victim$"}' > "$WORK/logs.jsonl"
jq -e 'select(.Pod=="app" and .Container=="app")' "$WORK/logs.jsonl" >/dev/null || fail "pod logs not found"
end

log "Auto-labels"
vq "SELECT add_server_monitoring(artifact='Server.Kubernetes.AutoLabel') AS s,
           add_client_monitoring(artifact='Kubernetes.Agent.Identity') AS c FROM scope()" >/dev/null
has_labels() { vq --env "C=$CID" "SELECT labels FROM clients(client_id=C)" | jq -e \
  --arg n "k8s-node-$NODE" '.labels | index("k8s-daemonset") and index("k8s-cluster-ci") and index($n) and index("e2e")' >/dev/null; }
retry 36 has_labels || fail "labels not applied"
end

log "Stable identity across a rollout"
kubectl -n "$NS" rollout restart ds/agent-velociraptor-agent
kubectl -n "$NS" rollout status ds/agent-velociraptor-agent --timeout=300s
[ "$(vq "SELECT count() AS n FROM clients() WHERE os_info.hostname = '$NODE' GROUP BY 1" | jq -r .n)" = "1" ] \
  || fail "rollout enrolled a duplicate client"
end

log "Ephemeral agent (kubectl velociraptor debug)"
"$ROOT/kubectl-velociraptor" debug app -n victim --config-secret "$NS/velo-velociraptor-client-root" \
  --image velociraptor-agent:ci --cluster ci
retry 36 enrolled app || fail "ephemeral agent did not enroll"
ECID="$(client_of app)"
[ "$(kubectl -n victim get pod app -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ] \
  || fail "target pod restarted"
collect "$ECID" Linux.Kubernetes.Container.Collect > "$WORK/eph.jsonl"
jq -e --arg w "$WANT" 'select(.Pod=="app" and .ContainerPath=="/tmp/evidence" and .Upload.sha256==$w)' \
  "$WORK/eph.jsonl" >/dev/null || fail "ephemeral collection failed"
"$ROOT/kubectl-velociraptor" cleanup -n victim
end

echo "e2e OK" >&2
