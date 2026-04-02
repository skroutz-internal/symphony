{{- define "symphony.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "symphony.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "symphony.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "symphony.workerFullname" -}}
{{- printf "%s-worker" (include "symphony.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "symphony.workersServiceName" -}}
{{- printf "%s-workers" (include "symphony.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "symphony.workerHost" -}}
{{- $root := .root -}}
{{- $ordinal := .ordinal -}}
{{- printf "%s-%d.%s.%s.svc.cluster.local" (include "symphony.workerFullname" $root) $ordinal (include "symphony.workersServiceName" $root) $root.Release.Namespace -}}
{{- end -}}

{{- define "symphony.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "symphony.labels" -}}
helm.sh/chart: {{ include "symphony.chart" . }}
app.kubernetes.io/name: {{ include "symphony.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "symphony.selectorLabels" -}}
app.kubernetes.io/name: {{ include "symphony.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "symphony.serverSelectorLabels" -}}
{{ include "symphony.selectorLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "symphony.workerSelectorLabels" -}}
{{ include "symphony.selectorLabels" . }}
app.kubernetes.io/component: worker
{{- end -}}

{{- define "symphony.serviceAccountName" -}}
default
{{- end -}}

{{- define "symphony.modelSecretName" -}}
{{- if .Values.secrets.model.secretName -}}
{{- .Values.secrets.model.secretName -}}
{{- else if .Values.secrets.model.create -}}
{{- printf "%s-model" (include "symphony.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "symphony.githubTokenSecretName" -}}
{{- if .Values.secrets.githubToken.secretName -}}
{{- .Values.secrets.githubToken.secretName -}}
{{- else if .Values.secrets.githubToken.create -}}
{{- printf "%s-github-token" (include "symphony.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "symphony.githubAppSecretName" -}}
{{- if .Values.secrets.githubApp.secretName -}}
{{- .Values.secrets.githubApp.secretName -}}
{{- else if .Values.secrets.githubApp.create -}}
{{- printf "%s-github-app" (include "symphony.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "symphony.workerSshSecretName" -}}
{{- if .Values.secrets.workerSsh.secretName -}}
{{- .Values.secrets.workerSsh.secretName -}}
{{- else if .Values.secrets.workerSsh.create -}}
{{- printf "%s-worker-ssh" (include "symphony.fullname" .) -}}
{{- end -}}
{{- end -}}
