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

{{/* Name of the Secret holding MYSQL_ROOT_PASSWORD — either the one the user
     brought, or the one this chart creates. Both db01 and app01 read the same
     Secret so there is exactly one source of truth for the credential. */}}
{{- define "vprofile.dbSecretName" -}}
{{- if .Values.db.existingSecret -}}
{{- .Values.db.existingSecret -}}
{{- else -}}
db01-credentials
{{- end -}}
{{- end }}

{{/* Refuse to render when neither option is set, instead of shipping an empty
     password that fails later as an opaque "Access denied" from MySQL. */}}
{{- define "vprofile.requireDbSecret" -}}
{{- if and (not .Values.db.existingSecret) (not .Values.db.rootPassword) -}}
{{- fail "db credentials missing: set db.existingSecret (preferred) or --set db.rootPassword=... at install time" -}}
{{- end -}}
{{- end }}

{{/* Container securityContext. Every container gets the common hardening;
     `extra` carries the per-component parts (runAsUser, capability exceptions).
     Usage: {{- include "vprofile.containerSecurity" (dict "root" . "extra" .Values.securityContext.app) | nindent 10 }} */}}
{{- define "vprofile.containerSecurity" -}}
allowPrivilegeEscalation: {{ .root.Values.security.common.allowPrivilegeEscalation }}
seccompProfile:
  type: {{ .root.Values.security.common.seccompProfile.type }}
capabilities:
  drop:
    - ALL
{{- with .add }}
  add:
{{- range . }}
    - {{ . }}
{{- end }}
{{- end }}
{{- with .extra }}
{{ toYaml . }}
{{- end }}
{{- end }}
