{{/* Common labels on every object */}}
{{- define "vprofile.labels" -}}
app.kubernetes.io/part-of: vprofile
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Fully-qualified image ref. Fails the render (rather than deploying a
     broken :latest) when the pipeline forgets to pass registry/tag. */}}
{{- define "vprofile.image" -}}
{{- $reg := .root.Values.image.registry | required "image.registry is required (--set image.registry=<acct>.dkr.ecr.<region>.amazonaws.com)" -}}
{{- $tag := .root.Values.image.tag      | required "image.tag is required (--set image.tag=<git-sha>-<build>)" -}}
{{- printf "%s/%s:%s" $reg .name $tag -}}
{{- end }}
