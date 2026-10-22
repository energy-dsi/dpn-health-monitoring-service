{{/*
Browser-facing base URL of this proxy, without a trailing slash.
Everything the browser is redirected to (redirect_url, whitelist_domains) is
derived from this, so it must match exactly what users type in the address bar
— including the port.
*/}}
{{- define "oauth2-proxy.externalUrl" -}}
{{- required "externalUrl is required: the browser-facing URL of this proxy, e.g. https://10.0.0.10:5601 (see charts/oauth2-proxy/README.md)" .Values.externalUrl | trimSuffix "/" -}}
{{- end -}}

{{/*
Name of the chart-managed Secret holding the generated cookie-secret. It is
deliberately NOT .Values.secret.name: that one is the Secret carrying the
Keycloak client credential, which this chart never creates, modifies or owns
— see templates/secret.yaml.
*/}}
{{- define "oauth2-proxy.cookieSecretName" -}}
{{- default (printf "%s-cookie" .Values.name) .Values.secret.cookieName -}}
{{- end -}}

{{/*
Name of the Secret the CSI driver mirrors the Key Vault client credential
into — see templates/secretproviderclass.yaml. This chart never creates,
modifies or owns it either: the CSI driver does, as a side effect of the
Deployment mounting the SecretProviderClass.

Fixed/shared across every oauth2-proxy instance (jaeger/osd/perses/portal) —
they all authenticate as the same dpn-service-client, so each instance's own
SecretProviderClass mirrors the identical Key Vault value into ONE shared
Secret rather than each keeping its own copy. Whichever instances are
running keep this Secret's CSI sync alive between them; this only requires
at least one of them to have its SecretProviderClass volume mounted, which
every instance already does independently.

kafka-stack's kafka-ui-oidc-rbac SecretProviderClass (see
charts/kafka-stack/templates/kafka-ui-oidc-rbac-secretproviderclass.yaml)
targets this exact same Secret name too. Since Kafka UI runs in the Kafka
stage, well before this chart's OAuth2Proxy stage in
monitoring-master-cd.yaml, that is what actually creates
dpn-keycloak-shared-akv first on a brand new environment — by the time any
oauth2-proxy release here deploys, the Secret already exists.
*/}}
{{- define "oauth2-proxy.akvSecretName" -}}
dpn-keycloak-shared-akv
{{- end -}}

{{/*
host[:port] of externalUrl — oauth2-proxy's whitelist_domains takes a bare
host:port, not a URL.
*/}}
{{- define "oauth2-proxy.externalHost" -}}
{{- include "oauth2-proxy.externalUrl" . | trimPrefix "https://" | trimPrefix "http://" -}}
{{- end -}}

{{/*
Browser-facing Keycloak base URL — where the user is sent to log in. This is
the address of Keycloak's own LoadBalancer Service, NOT its in-cluster name:
the browser cannot resolve *.svc.cluster.local.

This is deliberately NOT the same thing as the token issuer; see
oauth2-proxy.issuerUrl below.
*/}}
{{- define "oauth2-proxy.keycloakPublicUrl" -}}
{{- required "keycloak.publicUrl is required: the browser-facing Keycloak base URL, e.g. https://10.226.121.13:8443 (see charts/oauth2-proxy/README.md)" .Values.keycloak.publicUrl | trimSuffix "/" -}}
{{- end -}}

{{/*
host[:port] of the browser-facing Keycloak URL, in the same bare host:port form
whitelist_domains takes. Needed because logging out chains
/oauth2/sign_out?rd=<Keycloak end-session URL>, and that rd points at a
DIFFERENT host from this proxy — see whitelist_domains in configmap.yaml.
*/}}
{{- define "oauth2-proxy.keycloakPublicHost" -}}
{{- include "oauth2-proxy.keycloakPublicUrl" . | trimPrefix "https://" | trimPrefix "http://" -}}
{{- end -}}

{{/*
In-cluster Keycloak base URL, used for the server-to-server calls only (token
redeem, JWKS, userinfo). Keycloak lives in ns-dpn-01 while these pods live in
ns-dpn-health-01, so this MUST be the fully-qualified cross-namespace name —
a bare `dpn-keycloak` would only resolve inside ns-dpn-01.
*/}}
{{- define "oauth2-proxy.keycloakInternalUrl" -}}
{{- .Values.keycloak.internalUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "oauth2-proxy.realmUrl" -}}
{{- printf "%s/realms/%s" (include "oauth2-proxy.keycloakPublicUrl" .) .Values.keycloak.realm -}}
{{- end -}}

{{- define "oauth2-proxy.internalRealmUrl" -}}
{{- printf "%s/realms/%s" (include "oauth2-proxy.keycloakInternalUrl" .) .Values.keycloak.realm -}}
{{- end -}}

{{/*
The issuer oauth2-proxy validates the `iss` claim against — a string
comparison, never fetched, because discovery is skipped.

It is NOT publicUrl. The ns-dpn-01 Keycloak (26.x) runs with no KC_HOSTNAME
set, so under hostname v2 it derives every advertised URL from the Host header
of the request it is answering. The request that mints the token is THIS pod's
token-redeem call, made over the in-cluster name — so the `iss` stamped into
the token is the INTERNAL URL, even though the user logged in on the public
one. Hence the default below.

Set keycloak.issuerUrl explicitly only if KC_HOSTNAME is later pinned on
Keycloak: the issuer then becomes fixed regardless of caller, and this must
change to match publicUrl or every login fails on issuer mismatch. The CD
pipeline compares the two and fails with that instruction.
*/}}
{{- define "oauth2-proxy.issuerUrl" -}}
{{- default (include "oauth2-proxy.keycloakInternalUrl" .) .Values.keycloak.issuerUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "oauth2-proxy.issuerRealmUrl" -}}
{{- printf "%s/realms/%s" (include "oauth2-proxy.issuerUrl" .) .Values.keycloak.realm -}}
{{- end -}}
