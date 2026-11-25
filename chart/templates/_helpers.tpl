{{- define "velociraptor-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "velociraptor-agent.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "velociraptor-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "velociraptor-agent.labels" -}}
helm.sh/chart: {{ include "velociraptor-agent.chart" . }}
{{ include "velociraptor-agent.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: agent
{{- end }}

{{- define "velociraptor-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "velociraptor-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "velociraptor-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "velociraptor-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "velociraptor-agent.image" -}}
{{- $ref := .Values.image.repository -}}
{{- with .Values.image.registry }}{{ $ref = printf "%s/%s" . $ref }}{{ end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $ref .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/* Secret holding the base client config. */}}
{{- define "velociraptor-agent.configSecretName" -}}
{{- if .Values.clientConfig.existingSecret -}}
{{- .Values.clientConfig.existingSecret -}}
{{- else if .Values.clientConfig.inline -}}
{{- printf "%s-client-config" (include "velociraptor-agent.fullname" .) -}}
{{- else -}}
{{- fail "velociraptor-agent: set clientConfig.existingSecret (e.g. the Secret exported by the velociraptor chart, clientConfig.export.enabled=true) or clientConfig.inline" -}}
{{- end -}}
{{- end }}

{{/* Host directory of the identity (writeback.type=hostPath): one per release. */}}
{{- define "velociraptor-agent.writebackHostPath" -}}
{{- .Values.writeback.hostPath | default (printf "/var/lib/velociraptor-agent/%s-%s" .Release.Namespace (include "velociraptor-agent.fullname" .)) -}}
{{- end }}

{{/* Where the agent keeps its identity + local buffer (in the container). */}}
{{- define "velociraptor-agent.stateDir" -}}/var/lib/velociraptor{{- end }}

{{/* Overlay deep-merged onto the base client config by the config-merge init container. */}}
{{- define "velociraptor-agent.overlay" -}}
{{- $state := include "velociraptor-agent.stateDir" . -}}
{{- $client := dict
      "writeback_linux" (printf "%s/velociraptor.writeback.yaml" $state)
      "local_buffer" (dict
          "filename_linux" (printf "%s/buffer.bin" $state)
          "disk_size" (int64 .Values.writeback.localBufferDiskSize)) -}}
{{- with .Values.clientConfig.serverUrls }}{{ $_ := set $client "server_urls" . }}{{ end -}}
{{- $client = mergeOverwrite (deepCopy .Values.clientConfig.extra) $client -}}
{{- toYaml (dict "Client" $client) -}}
{{- end }}

{{/* velociraptor --remap file: host root seen as "/" for the file/auto accessors. */}}
{{- define "velociraptor-agent.remap" -}}
{{- if and .Values.remap.enabled (not .Values.hostRoot.enabled) -}}
{{- fail "velociraptor-agent: remap.enabled needs hostRoot.enabled (the remap points the file accessor at the host root mount)" -}}
{{- end -}}
{{- $root := .Values.hostRoot.mountPath -}}
{{- $r := list (dict "type" "permissions" "permissions" .Values.remap.permissions) -}}
{{- range list "file" "auto" }}
{{- $r = append $r (dict "type" "mount" "from" (dict "accessor" "file" "prefix" $root) "on" (dict "accessor" . "prefix" "/" "path_type" "linux")) -}}
{{- end }}
{{- /* /proc stays the agent's own procfs: same PID namespace as the host (hostPID), and
       /proc/<pid>/root of host-mounted procfs is not readable through the remapped path. */ -}}
{{- range list "file" "auto" }}
{{- $r = append $r (dict "type" "mount" "from" (dict "accessor" "file" "prefix" "/proc") "on" (dict "accessor" . "prefix" "/proc" "path_type" "linux")) -}}
{{- end }}
{{- range .Values.remap.shadowAccessors }}
{{- $r = append $r (dict "type" "shadow" "from" (dict "accessor" .) "on" (dict "accessor" .)) -}}
{{- end }}
{{- toYaml (dict "remappings" $r) -}}
{{- end }}

{{/* Container securityContext from the profile. */}}
{{- define "velociraptor-agent.securityContext" -}}
{{- if .Values.securityContextOverride -}}
{{- toYaml .Values.securityContextOverride -}}
{{- else if eq .Values.profile "full" -}}
runAsUser: 0
runAsGroup: 0
privileged: true
readOnlyRootFilesystem: true
{{- else if eq .Values.profile "restricted" -}}
runAsUser: 0
runAsGroup: 0
runAsNonRoot: false
privileged: false
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
  add: ["DAC_READ_SEARCH", "SYS_PTRACE"]
seccompProfile:
  type: RuntimeDefault
appArmorProfile:
  type: Unconfined
{{- else -}}
{{- fail (printf "velociraptor-agent: profile must be restricted or full (got %q)" .Values.profile) -}}
{{- end -}}
{{- end }}

{{/* Security context of the config-merge init container (no host access needed). */}}
{{- define "velociraptor-agent.initSecurityContext" -}}
runAsUser: 65532
runAsGroup: 65532
runAsNonRoot: true
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "velociraptor-agent.artifactsConfigMapName" -}}
{{- .Values.serverArtifacts.name | default (printf "%s-artifacts" (include "velociraptor-agent.fullname" .)) -}}
{{- end }}
