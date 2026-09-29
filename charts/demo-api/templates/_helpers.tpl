{{- define "demo-api.name" -}}
demo-api
{{- end }}

{{- define "demo-api.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "demo-api.labels" -}}
app.kubernetes.io/name: {{ include "demo-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
