# velociraptor-agent

[Velociraptor](https://github.com/Velocidex/velociraptor) DFIR agent for Kubernetes and Docker
hosts: a multi-arch image, a Helm chart (one agent per node), a Kubernetes artifact pack and a
`kubectl` plugin to attach a throw-away agent to a running pod.

Companion of [velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker) (server
image) and [velociraptor-helm](https://github.com/MaximeWewer/velociraptor-helm) (server chart).

## Why an agent is not hardened like the server

A forensic agent only sees what its namespaces and privileges show it. The server image is
distroless, rootless, with a read-only rootfs because it needs nothing from the host; an agent
built the same way would see an empty filesystem and its own process. Here the hardening is:
minimal image, read-only host mount, targeted capabilities instead of `privileged`, a dedicated
namespace, egress to the frontend only.

| Placement | Sees | Provided |
|-----------|------|----------|
| **DaemonSet** (default) | the node and every pod on it | `chart/` |
| **Ephemeral container** (`kubectl debug`) | one pod, without restarting it | `kubectl-velociraptor` |
| **Docker host** (compose) | the host and every container | `docker/` |
| Sidecar | one pod, only with `shareProcessNamespace`; must be there *before* the incident | not provided (see [Limitations](#limitations)) |

## Image

```
ghcr.io/maximewewer/velociraptor-agent:0.77.4          # amd64 + arm64, no shell
ghcr.io/maximewewer/velociraptor-agent:0.77.4-debug    # + busybox
```

- Base `gcr.io/distroless/base-debian13`. The upstream `linux-amd64` / `linux-arm64` binaries
  are dynamically linked and need **GLIBC 2.38**: debian12 (2.36) does not work, and there is no
  static musl build for arm64. The weekly update workflow fails if a release needs a newer glibc.
- Runs as root on purpose (reading the host needs it); the chart drops what is not needed.
- `ARG VELO_VERSION` in the `Dockerfile` is the single source of truth; per-arch sha256 are
  pinned and verified at build.

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t velociraptor-agent:dev .
docker build --target debug -t velociraptor-agent:dev-debug .
```

## Quick start (with the velociraptor chart)

The server chart exports the client config (CA, enrollment nonce, server URLs) into a Secret
`<release>-velociraptor-client-<org>`. Secrets can not be mounted across namespaces: install the
agent in the server namespace, or replicate the Secret (reflector, External Secrets...).

```bash
NS=velociraptor
kubectl create ns $NS
kubectl label ns $NS pod-security.kubernetes.io/enforce=privileged

# 1. Agent: DaemonSet + the artifact pack ConfigMap for the server.
helm install agent oci://ghcr.io/maximewewer/charts/velociraptor-agent --devel -n $NS \
  --set clientConfig.existingSecret=velo-velociraptor-client-root \
  --set identity.clusterName=prod-eu1

# 2. Server: export the client config, load the Kubernetes artifacts.
helm install velo oci://ghcr.io/maximewewer/charts/velociraptor --devel -n $NS \
  --set clientConfig.export.enabled=true \
  --set customArtifacts.enabled=true \
  --set 'customArtifacts.existingConfigMaps[0]=agent-velociraptor-agent-artifacts'
```

`--devel`: chart versions carry the release date (`0.77.4-25-11-2026`), a semver pre-release.

Agents enroll with the **node name** as hostname. Then, in the GUI:

- *Server Events* → add `Server.Kubernetes.AutoLabel`;
- *Client Events* → add `Kubernetes.Agent.Identity` (or list it in the server config
  `Frontend.default_client_monitoring_artifacts`).

Clients get labels `k8s`, `k8s-daemonset`, `k8s-cluster-prod-eu1`, `k8s-node-<node>` (+
`identity.extraLabels`): hunt a cluster or a node with a label filter.

## How the DaemonSet sees the node

| Mechanism | Effect |
|-----------|--------|
| `hostPID` | every host and container process (`pslist`, `/proc/<pid>/…`) |
| `hostNetwork` (also shares UTS) | client hostname = node name, stable across rollouts; `Linux.Network.*` show host sockets. NetworkPolicy does not apply: filter at node level, or `hostNetwork=false` + `networkPolicy.enabled` |
| host `/` at `/host`, read-only, `HostToContainer` | node filesystem, including container rootfs mounted later |
| `--remap` | the `file` / `auto` accessors see `/host` as `/`: **built-in `Linux.*` artifacts analyse the node unchanged** (Linux.Sys.Users, Linux.Syslog.*, Linux.Search.FileFinder…). `/proc` stays the agent's procfs, other accessors are shadowed |
| writeback on a `hostPath` (`/var/lib/velociraptor-agent/<namespace>-<fullname>`) | one client ID per node and release, kept across restarts and upgrades (no duplicate clients; two releases, e.g. one per org, never share an identity) |
| `tolerations: [{operator: Exists}]`, `nodeSelector: kubernetes.io/os=linux` | every Linux node, tainted or not (control plane included) |

The client config is never modified: a `yq` init container deep-merges the chart overlay
(writeback path, local buffer, optional `server_urls` / `Client` extras) into an in-memory volume.

### Reading files inside containers

`/proc/<pid>/root` is the merged view of a container's filesystem (no overlayfs layer walking).
**Velociraptor's `file` accessor resolves that magic link to the agent's own `/`** and silently
reads the wrong file (`stat` works, `read_file` returns empty). Read with the `raw_file`
accessor, which lets the kernel resolve it; `raw_file` does not glob, so list with `file` and
read with `raw_file`. The `Linux.Kubernetes.*` artifacts do this, and glob with
`nosymlink=TRUE`: a symlink inside a container (`/tmp/x -> /`) resolves from the agent's root,
so following it would collect host files labelled as container evidence.

### Security profiles (`profile`)

| | `restricted` (default) | `full` |
|-|------------------------|--------|
| User | root | root |
| Capabilities | `DAC_READ_SEARCH` (read any file), `SYS_PTRACE` (`/proc/<pid>/root`, `mem`, `environ` of other users) — all others dropped | privileged |
| Rootfs / escalation | read-only / `allowPrivilegeEscalation: false` | read-only |
| seccomp / AppArmor | `RuntimeDefault` / `Unconfined` (the runtime's default AppArmor profile denies ptrace-read of processes outside the container) | — |
| For | file and process forensics, hunting, pod logs | eBPF event artifacts, raw devices (`raw_ext4`, imaging), memory of protected processes, active response (with `hostRoot.readOnly=false`) |

## Kubernetes artifacts

Shipped in `chart/files/artifacts/`, rendered into the `<release>-velociraptor-agent-artifacts`
ConfigMap (`serverArtifacts.namespace` = the server namespace). No Kubernetes API access needed:
everything is resolved from the node. The server reads that directory at startup only (and
`artifact_set()` does not override artifacts loaded from it): after a chart upgrade that changes
artifacts, restart the server pod.

| Artifact | Type | What |
|----------|------|------|
| `Linux.Kubernetes.Pods` | CLIENT | pod / namespace / container / image ↔ container ID ↔ PIDs, from `/proc/<pid>/cgroup` (cgroup v1/v2, systemd/cgroupfs) and the runtime's OCI bundle (containerd, CRI-O). In an ephemeral agent: the target's processes |
| `Linux.Kubernetes.Container.Collect` | CLIENT | globs evaluated **inside** matching containers (`/etc/passwd`, shell histories, `/tmp`, `/dev/shm`… by default), uploaded via `/proc/<pid>/root` + `raw_file`. Symlinks skipped (an absolute link would resolve against the host) |
| `Linux.Kubernetes.PodLogs` | CLIENT | kubelet container logs `/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log*`, rotated and of exited/restarted containers |
| `Kubernetes.Agent.Identity` | CLIENT_EVENT | mode, cluster, node, target pod (from `VELOCIRAPTOR_K8S_*` env) at start then daily |
| `Server.Kubernetes.AutoLabel` | SERVER_EVENT | turns identity events into client labels |
| `Server.Kubernetes.CleanupEphemeral` | SERVER | deletes `k8s-ephemeral` clients not seen for `MaxAgeHours` (dry run by default) |

## Ephemeral agent: one pod, no restart

A sidecar added after an incident restarts the pod: memory, processes and the ephemeral
filesystem are gone. An ephemeral container attaches to the running pod instead.

```bash
install -m 0755 kubectl-velociraptor ~/.local/bin/      # kubectl plugin
kubectl velociraptor debug suspicious-pod -n shop --target app \
  --config-secret velociraptor/velo-velociraptor-client-root --cluster prod-eu1
# ... collect Linux.Kubernetes.Container.Collect on client "suspicious-pod" ...
kubectl velociraptor cleanup -n shop                     # copied config Secret
```

- Shares the PID namespace of `--target`; hostname = pod name; labels `k8s-ephemeral`,
  `k8s-ns-<ns>`, `k8s-pod-<pod>`.
- The config goes in `VELOCIRAPTOR_LITERAL_CONFIG` from a Secret (ephemeral containers can not
  mount new volumes); copied into the pod namespace when it lives elsewhere.
- `--profile restricted` (default: `SYS_PTRACE` + `DAC_READ_SEARCH`) is refused by Pod Security
  `baseline`/`restricted` namespaces; `--profile minimal` adds no capability (reads processes of
  the same uid only).
- An ephemeral container can not be removed: it runs until the pod dies. Run
  `Server.Kubernetes.CleanupEphemeral` **after** the pod is gone: a deleted client whose agent
  still runs enrolls again.
- Needs kubectl >= 1.32 (`kubectl debug --custom`).
- The ephemeral container keeps the runtime's default AppArmor profile (Pod Security forbids
  `Unconfined` below `privileged`): it can read a target confined by the same profile — the
  usual case — but not one running with a custom AppArmor profile.

## Docker host (no Kubernetes)

```bash
cd docker
cp /path/to/client.config.yaml .        # never commit it
docker compose up -d
```

Same model as the DaemonSet: `pid`/`network`/`uts: host`, host `/` read-only at `/host` with the
same `remap.yaml` (kept in sync with the chart by CI), read-only rootfs, `DAC_READ_SEARCH` +
`SYS_PTRACE`, identity in a named volume.

## Security model

A DaemonSet with `hostPID` and the host root mounted is **remote root read access to every
node, driven by the Velociraptor server**: whoever controls the server (or an API client with
collection rights) controls the cluster. Treat the server, its GUI and its API certificates
accordingly.

- Install in a dedicated namespace; only that namespace gets Pod Security `privileged`.
- Keep `profile: restricted` and `hostRoot.readOnly: true` unless you need active response.
- Restrict egress to the frontend (`hostNetwork=false` + `networkPolicy`, or node firewall).
- No service account token is mounted; the agent never calls the Kubernetes API.
- Expect detections: "Pod created with hostPID", CIS 5.2.x (privileged / hostPID / hostNetwork)
  — add a scoped exception for this namespace.
- The client config holds no private key (each agent generates its own into the writeback), but
  its nonce lets anyone enroll a client: keep it in a Secret, rotate it if leaked.

## Limitations

- Kubernetes >= 1.30 (`appArmorProfile` field).
- **GKE Autopilot / EKS Fargate**: no privileged DaemonSet. A sidecar mode is not provided: it
  only sees its pod, must be deployed before the incident, and multiplies clients per rollout.
- Container metadata comes from containerd / CRI-O bundles; other runtimes only get pod UID +
  container ID from the cgroup.
- Images are built and smoke-tested on amd64 and arm64 (native runners); the end-to-end test
  runs on amd64 kind.

## Development

```bash
helm lint chart --set clientConfig.existingSecret=x
velociraptor artifacts verify chart/files/artifacts/*.yaml
kind create cluster --name chart-testing && ./ci/e2e.sh chart-testing
```

`ci/e2e.sh`: server + DaemonSet on kind, enrollment, stable client ID across a rollout,
`Linux.Kubernetes.Pods` / `Container.Collect` (sha256 of a file written in a pod) /
`PodLogs`, auto-labels, ephemeral agent without pod restart.

Workflows: `update-versions` (weekly: Velociraptor release → Dockerfile, per-arch sha256, chart,
references; PR) → `release-image` (multi-arch push, native smoke tests, SBOM, GitHub release) →
`release-helm` (OCI chart once the image exists). `test-chart` on every PR.
