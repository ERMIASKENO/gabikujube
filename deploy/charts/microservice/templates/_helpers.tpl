{{- define "ms.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ms.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ms.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ms.labels" -}}
{{ include "ms.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | trunc 63 | quote }}
app.kubernetes.io/part-of: shopsphere
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* repo:tag@digest - readable tag, immutable digest */}}
{{- define "ms.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- if .Values.image.tag }}{{ $repo }}:{{ .Values.image.tag }}@{{ .Values.image.digest }}{{ else }}{{ $repo }}@{{ .Values.image.digest }}{{ end -}}
{{- else -}}
{{ $repo }}:{{ required "image.tag or image.digest is required" .Values.image.tag }}
{{- end -}}
{{- end -}}

{{/* Services that back this workload, depending on the delivery strategy */}}
{{- define "ms.backendServices" -}}
{{- $n := include "ms.name" . -}}
{{- if eq .Values.rollout.strategy "canary" -}}
{{ $n }},{{ $n }}-stable,{{ $n }}-canary
{{- else if eq .Values.rollout.strategy "blueGreen" -}}
{{ $n }},{{ $n }}-stable,{{ $n }}-preview
{{- else -}}
{{ $n }}
{{- end -}}
{{- end -}}

{{- define "ms.workloadKind" -}}
{{- if eq .Values.rollout.strategy "rolling" -}}Deployment{{- else -}}Rollout{{- end -}}
{{- end -}}

{{- define "ms.workloadApiVersion" -}}
{{- if eq .Values.rollout.strategy "rolling" -}}apps/v1{{- else -}}argoproj.io/v1alpha1{{- end -}}
{{- end -}}
