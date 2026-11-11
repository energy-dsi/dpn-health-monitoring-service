#!/usr/bin/env bash
#
# Deploy one oauth2-proxy release — the Keycloak gateway in front of a single
# observability UI. Called once per component by
# .pipelines/azure-pipelines/cd-pipelines/oauth2-proxy-cd.yaml.
#
# This lives in a file rather than an inlineScript on purpose: Azure DevOps
# evaluates a block scalar containing ${{ }} expressions as ONE template
# expression, capped at 21000 characters, and this script is well past that.
# Running it via scriptPath sidesteps the limit entirely and makes it testable
# with shellcheck and runnable by hand.
#
# Usage:
#   deploy-oauth2-proxy.sh <environment> <cluster> <component> <sources-dir>
#
set -euo pipefail

ENVIRONMENT="${1:?environment (dev|devtest|test|pdev|ptest|puat) required}"
CLUSTER="${2:?cluster (dpn01|dpn02) required}"
COMPONENT="${3:?component (opensearch|kafka-ui|...) required}"
SOURCES_DIR="${4:?sources directory required}"


if [[ "$ENVIRONMENT" =~ ^(pdev|ptest|puat)$ ]] && [[ "$CLUSTER" == "dpn02" ]]; then
  echo "ERROR: Environment '$ENVIRONMENT' is configured for a single-DPN deployment and does not support cluster '$CLUSTER'."
  exit 1
fi

CONFIG_FILE="$SOURCES_DIR/.pipelines/azure-pipelines/config/$ENVIRONMENT.json"
CONFIG_FILE_CLUSTER="$SOURCES_DIR/.pipelines/azure-pipelines/config/$ENVIRONMENT-$CLUSTER.json"

CHART_DIR="$SOURCES_DIR/charts/oauth2-proxy"
VALUES_FILE="$CHART_DIR/values-$COMPONENT.yaml"

# Release name and the Service it fronts, per UI.
#
# SERVICE_PORT is the browser-facing port on the proxy's
# LoadBalancer, always the port nginx used so bookmarks keep
# working. UPSTREAM_PORT is what the UI itself listens on.
#
# Prometheus and Thanos deliberately have no case here — neither UI needs
# direct browser access; both are consumed through Perses/Grafana
# dashboards instead. Airflow, kafka-ui, and kafka-ui-2 also have no case
# here — all three gateways were removed. Airflow and kafka-ui now handle
# their own login directly; kafka-ui-2 fronted a UI in ns-dpn-01 that this
# repo does not own, so a replacement direct LoadBalancer is out of scope
# here.
#
# UPSTREAM_NS defaults to this namespace; every remaining component's
# upstream lives in it too, now that kafka-ui-2 (the one proxied from
# ns-dpn-01) is gone.
UPSTREAM_NS=""
case "$COMPONENT" in
  opensearch)
    RELEASE_NAME="dpn-oauth2-proxy-osd"
    UPSTREAM_SVC="dpn-opensearch-dashboard-health"
    UPSTREAM_PORT=5601
    SERVICE_PORT=5601
    ;;
  jaeger)
    RELEASE_NAME="dpn-oauth2-proxy-jaeger"
    UPSTREAM_SVC="dpn-jaeger-query-health"
    UPSTREAM_PORT=16686
    SERVICE_PORT=16686
    ;;
  perses)
    RELEASE_NAME="dpn-oauth2-proxy-perses"
    UPSTREAM_SVC="dpn-perses-health"
    UPSTREAM_PORT=8083
    SERVICE_PORT=8083
    ;;
  portal)
    RELEASE_NAME="dpn-oauth2-proxy-portal"
    UPSTREAM_SVC="dpn-portal"
    UPSTREAM_PORT=8000
    SERVICE_PORT=8443
    ;;
  *)
    echo "ERROR: unknown component '$COMPONENT'. Add it to the case statement in this pipeline."
    exit 1
    ;;
esac

echo "CONFIG_FILE=$CONFIG_FILE"
echo "CHART_DIR=$CHART_DIR"
echo "VALUES_FILE=$VALUES_FILE"
echo "RELEASE_NAME=$RELEASE_NAME"

if [ ! -f "$CONFIG_FILE" ]; then
  if [ -f "$CONFIG_FILE_CLUSTER" ]; then
    CONFIG_FILE="$CONFIG_FILE_CLUSTER"
  else
    echo "Config file missing: $CONFIG_FILE"
    exit 1
  fi
fi

if [ ! -f "$VALUES_FILE" ]; then
  echo "Values file missing: $VALUES_FILE"
  exit 1
fi

# Reads a key nested one level under a top-level block, e.g.
# `keycloak:` / `  publicUrl:`. Whole-line awk with sub() rather
# than cut -d: — most values here are URLs and would be sliced at
# their scheme or port colon.
read_nested() {
  awk -v blk="^$1:" -v key="$2" '
    $0 ~ blk {inblock=1; next}
    inblock && $0 ~ "^[[:space:]]+"key":" {
      sub("^[[:space:]]*"key":[[:space:]]*",""); gsub(/"/,""); print; exit
    }
    /^[^[:space:]#]/ {inblock=0}
  ' "$3"
}

# Same precedence helm applies with -f: the component values file
# wins, and anything it does not set falls back to the chart's
# own values.yaml. Most components define only what differs — the
# Keycloak block and the shared Secret name live in one place.
read_values() {
  local found
  found="$(read_nested "$1" "$2" "$VALUES_FILE")"
  if [ -z "$found" ]; then
    found="$(read_nested "$1" "$2" "$CHART_DIR/values.yaml")"
  fi
  printf '%s' "$found"
}

# Existing kubernetes.io/tls Secret shared by the health-monitoring
# UIs. Supplies tls.crt + tls.key for the browser AND ca.crt for
# verifying Keycloak, so no separate CA Secret is needed.
TLS_SECRET="$(awk '/^tlsSecretName:/ {sub(/^tlsSecretName:[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$VALUES_FILE")"
TLS_SECRET="${TLS_SECRET:-dpn-health-tls}"

export $(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")

# Only known once the config file is loaded, so it cannot be
# defaulted in the case statement above.
UPSTREAM_NS="${UPSTREAM_NS:-$NAMESPACE}"

echo "RESOURCE_GROUP=$RESOURCE_GROUP"
echo "AKS_CLUSTER=$AKS_CLUSTER"
echo "NAMESPACE=$NAMESPACE"
echo "UPSTREAM_NS=$UPSTREAM_NS"

# Per-cluster LoadBalancer address, optional.
#
# The values files are shared by every cluster, so the address pinned in them
# can only be right for one. dev-dpn01's 10.226.121.10 is not in dev-dpn02's
# 10.226.122.0/27, and Azure rejects an out-of-subnet pin with
# PrivateIPAddressNotInSubnet — the Service sits <pending> and helm --wait times
# out. The config JSON is already per environment AND cluster, so one key there
# beats a values file per component per cluster.
#
# All nine proxies in a namespace share one address, differing only by port, so
# a single key covers every component. Unset means "use the values file", which
# is how dev-dpn01 and the pre-prod environments keep working untouched.
HELM_SET=()
if [ -n "${OBSERVABILITY_LB_IP:-}" ]; then
  echo "OBSERVABILITY_LB_IP=$OBSERVABILITY_LB_IP (overrides service.loadBalancerIP)"
  HELM_SET+=(--set "service.loadBalancerIP=$OBSERVABILITY_LB_IP")
fi

# Per-cluster Key Vault + managed identity, same reasoning as
# OBSERVABILITY_LB_IP above: values.yaml's akv.* block can only be right for
# one cluster, and keyvaultName/userAssignedIdentityID are a matched pair —
# every cluster's own managed identity is granted access to that cluster's
# own vault only, never another cluster's. Mixing them (e.g. dev-dpn02's pod
# using dev-dpn01's vault) does not fail fast: the CSI driver's mount request
# hangs until it times out, which then fails the whole `helm upgrade --wait`
# after several minutes with no indication of the real cause. Both keys come
# from the config JSON so this chart needs no per-cluster values file.
if [ -n "${KEY_VAULT_NAME:-}" ]; then
  echo "KEY_VAULT_NAME=$KEY_VAULT_NAME (overrides akv.keyvaultName)"
  HELM_SET+=(--set "akv.keyvaultName=$KEY_VAULT_NAME")
fi
if [ -n "${AKV_USER_ASSIGNED_IDENTITY_ID:-}" ]; then
  echo "AKV_USER_ASSIGNED_IDENTITY_ID=$AKV_USER_ASSIGNED_IDENTITY_ID (overrides akv.userAssignedIdentityID)"
  HELM_SET+=(--set "akv.userAssignedIdentityID=$AKV_USER_ASSIGNED_IDENTITY_ID")
fi

az aks install-cli --kubelogin-version v0.2.19
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

echo "Checking namespace..."
kubectl get namespace "$NAMESPACE"

echo "========================================"
echo "Ensuring the shared Redis session store"
echo "========================================"

# Every oauth2-proxy release depends on this, so it is ensured on every one
# of the nine component runs rather than as a step only "opensearch" (or any
# other single component) happens to own. helm upgrade --install is
# idempotent: the first run creates it, the other eight are no-ops. It is a
# release of its own — see charts/oauth2-proxy-redis/values.yaml for why it
# must never be tied to a single oauth2-proxy release's lifecycle.
helm upgrade --install dpn-redis-ui-health "$SOURCES_DIR/charts/oauth2-proxy-redis" \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout 2m

if [ "$COMPONENT" = "portal" ]; then
  echo "========================================"
  echo "Deploying dpn-portal (the UI behind this proxy)"
  echo "========================================"

  # Every other component's upstream is deployed by its own existing CD
  # pipeline (jaeger-cd.yaml, opensearch-cd.yaml, ...) well before this script
  # runs. dpn-portal has no such pipeline yet — it is new — so it is deployed
  # here, immediately before the upstream check below would otherwise fail
  # looking for a Service that does not exist.
  #
  # image.repository/image.tag have no default in charts/dpn-portal/values.yaml
  # (see that file): this script cannot know which registry the team publishes
  # app/dpn-portal to, so it fails loudly here rather than guessing wrong.
  #
  # Per-cluster overrides (values-dpn01.yaml / values-dpn02.yaml), same
  # fall-back-to-base-values.yaml precedence as VALUES_FILE/CHART_DIR above.
  PORTAL_CHART_DIR="$SOURCES_DIR/charts/dpn-portal"
  PORTAL_VALUES_FILE="$PORTAL_CHART_DIR/values-$CLUSTER.yaml"
  if [ ! -f "$PORTAL_VALUES_FILE" ]; then
    PORTAL_VALUES_FILE="$PORTAL_CHART_DIR/values.yaml"
  fi
  echo "PORTAL_VALUES_FILE=$PORTAL_VALUES_FILE"

  # PORTAL_VALUES_FILE sets image.repository/image.tag to an explicit "",
  # not an omitted key - an explicit value in a later -f file always wins
  # over --reuse-values, so that alone does not stop this upgrade from
  # blanking out the image dpn-portal-image-cd.yaml already set and tripping
  # the chart's required guard. Reading the currently-deployed values back
  # and re-applying them with --set (which always wins over -f content)
  # is what actually prevents that.
  EXISTING_IMAGE_REPO="$(helm get values dpn-portal -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.image.repository // empty')"
  EXISTING_IMAGE_TAG="$(helm get values dpn-portal -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.image.tag // empty')"

  if [ -z "$EXISTING_IMAGE_REPO" ] || [ -z "$EXISTING_IMAGE_TAG" ]; then
    echo "##vso[task.logissue type=error]dpn-portal has no existing deployed image.repository/image.tag to reuse. Run the DpnPortalImage stage (dpn-portal-image-cd.yaml) at least once for this namespace before this component."
    exit 1
  fi

  echo "Reusing already-deployed image.repository=$EXISTING_IMAGE_REPO image.tag=$EXISTING_IMAGE_TAG"

  helm upgrade --install dpn-portal "$PORTAL_CHART_DIR" \
    --namespace "$NAMESPACE" \
    -f "$PORTAL_VALUES_FILE" \
    --set image.repository="$EXISTING_IMAGE_REPO" \
    --set image.tag="$EXISTING_IMAGE_TAG" \
    --wait \
    --timeout 3m
fi

echo "========================================"
echo "Reading externalUrl from the values file"
echo "========================================"

# awk with sub(), not cut/awk -F':' — the value is a URL and
# would be sliced at its scheme or port colon.
EXTERNAL_URL="$(awk '/^externalUrl:/ {sub(/^externalUrl:[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$VALUES_FILE")"

if [ -z "$EXTERNAL_URL" ]; then
  echo "ERROR: externalUrl is empty in $VALUES_FILE."
  echo "It is the address users browse to — a DNS name covered by the dpn-common"
  echo "certificate, e.g. https://dpn-observability.ns-dpn-health-01.svc.cluster.local:$SERVICE_PORT"
  echo "— and <externalUrl>/oauth2/callback must be a registered redirect URI."
  exit 1
fi

echo "externalUrl = $EXTERNAL_URL"

echo "========================================"
echo "Checking the TLS secret and its keys"
echo "========================================"

# Pre-existing Secret, not created by this chart. Verify the keys
# too, not just its presence: a missing ca.crt would mount fine
# and only surface later as x509 errors on the Keycloak calls.
if ! kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: secret/$TLS_SECRET not found in namespace $NAMESPACE."
  echo "It must be a kubernetes.io/tls Secret holding tls.crt, tls.key and ca.crt."
  exit 1
fi

# Key names contain dots, which jsonpath treats as path separators
# and needs escaping for — jq sidesteps that entirely.
TLS_KEYS="$(kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" -o json | jq -r '.data // {} | keys[]')"

for KEY in tls.crt tls.key ca.crt; do
  if ! printf '%s\n' "$TLS_KEYS" | grep -qx "$KEY"; then
    echo "ERROR: secret/$TLS_SECRET has no '$KEY'. It holds: $(printf '%s ' $TLS_KEYS)"
    echo "tls.crt + tls.key serve the browser; ca.crt verifies Keycloak."
    exit 1
  fi
  echo "secret/$TLS_SECRET has $KEY."
done

echo "========================================"
echo "Checking the Keycloak client secret exists in Key Vault"
echo "========================================"

# Presence check only — the value is never read, never printed,
# and never passed to helm. The pod resolves it itself once the
# CSI driver mirrors it into a Secret, so the credential never
# enters this script's environment or the build log at all.
#
# This checks Key Vault rather than a Kubernetes Secret because
# the Secret the pod reads (<release>-keycloak-akv) is created by
# the CSI driver as a side effect of the pod mounting the
# SecretProviderClass — it does not exist until after this deploy,
# so there is nothing in the cluster yet to check against.
AKV_OBJECT_NAME="$(read_values akv objectName)"
AKV_OBJECT_NAME="${AKV_OBJECT_NAME:-KC-SERVICE-CLIENT-SECRET}"
echo "Key Vault: $KEY_VAULT_NAME, object: $AKV_OBJECT_NAME"

if ! az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$AKV_OBJECT_NAME" >/dev/null 2>&1; then
  echo "ERROR: secret '$AKV_OBJECT_NAME' not found in Key Vault '$KEY_VAULT_NAME'."
  echo ""
  echo "It must hold the dpn-service-client credential from the Keycloak realm."
  echo "Create it once per environment:"
  echo ""
  echo "  az keyvault secret set --vault-name $KEY_VAULT_NAME \\"
  echo "    --name $AKV_OBJECT_NAME --value '<dpn-service-client secret>'"
  exit 1
fi

echo "Key Vault secret '$AKV_OBJECT_NAME' exists."

echo "========================================"
echo "Checking the upstream UI Service exists"
echo "========================================"

kubectl get svc "$UPSTREAM_SVC" -n "$UPSTREAM_NS"

# Two separate things to prove, and conflating them is a trap.
#
# 1. The Service publishes the port upstream.url connects to. That is the
#    SERVICE port — .spec.ports[].port — never the target port.
if ! kubectl get svc "$UPSTREAM_SVC" -n "$UPSTREAM_NS" -o json \
     | jq -e --arg p "$UPSTREAM_PORT" '[(.spec.ports // [])[].port | tostring] | index($p)' >/dev/null; then
  echo "ERROR: svc/$UPSTREAM_SVC in $UPSTREAM_NS does not publish port $UPSTREAM_PORT."
  echo "It publishes:"
  kubectl get svc "$UPSTREAM_SVC" -n "$UPSTREAM_NS" -o jsonpath='{range .spec.ports[*]}  {.name} {.port} -> {.targetPort}{"\n"}{end}' || true
  echo ""
  echo "upstream.url in $VALUES_FILE and UPSTREAM_PORT in this script must both"
  echo "use the Service port."
  exit 1
fi

# 2. Something ready is actually behind it. Deliberately NOT matched on a port
#    number: an endpoint carries the TARGET port, which differs from the
#    Service port wherever targetPort is remapped — dpn-kafka-health-ui
#    publishes 8082 and targets 8080, so a port comparison here would reject a
#    perfectly healthy backend.
#
#    EndpointSlices rather than Endpoints: the v1 Endpoints API is deprecated
#    from Kubernetes 1.33 and this cluster already warns about it. An endpoint
#    with no conditions block counts as ready, which is what absent means.
READY_COUNT="$(kubectl get endpointslices -n "$UPSTREAM_NS" \
  -l "kubernetes.io/service-name=$UPSTREAM_SVC" -o json 2>/dev/null \
  | jq '[.items[]?.endpoints[]? | select((.conditions.ready // true) == true)] | length' || echo 0)"

if [ "${READY_COUNT:-0}" -lt 1 ]; then
  echo "ERROR: svc/$UPSTREAM_SVC in $UPSTREAM_NS has no ready backends."
  kubectl get endpointslices -n "$UPSTREAM_NS" -l "kubernetes.io/service-name=$UPSTREAM_SVC" -o wide || true
  kubectl get pods -n "$UPSTREAM_NS" -o wide || true
  exit 1
fi

echo "svc/$UPSTREAM_SVC publishes $UPSTREAM_PORT with $READY_COUNT ready backend(s)."

echo "========================================"
echo "Checking the LB port is free"
echo "========================================"
# The address to test for conflicts is the PINNED service.loadBalancerIP, not
# anything parsed out of externalUrl. externalUrl is now a DNS name — it has to
# be, because the dpn-common certificate carries only *.svc.cluster.local
# wildcards and an IP literal can never match a DNS SAN — so stripping the host
# out of it yields a hostname that matches no Service's ingress IP, and the
# conflict query below would find nothing and pass every time.
# The override wins here too, or this would test the wrong cluster's address
# for conflicts — finding nothing and passing unconditionally.
LB_HOST="${OBSERVABILITY_LB_IP:-$(read_values service loadBalancerIP)}"

if [ -z "$LB_HOST" ]; then
  echo "service.loadBalancerIP is not pinned; skipping the port-conflict check."
  echo "Azure will assign an address and reject the Service itself if the port is taken."
else
  
  CONFLICT="$(kubectl get svc -n "$NAMESPACE" -o json \
    | jq -r --arg ip "$LB_HOST" --arg port "$SERVICE_PORT" --arg self "$RELEASE_NAME" '
        .items[]
        | select(.metadata.name != $self)
        | select(((.status.loadBalancer.ingress // [])[0].ip == $ip)
                 or ((.spec.loadBalancerIP // "") == $ip))
        | select([(.spec.ports // [])[].port | tostring] | index($port))
        | .metadata.name')"
  
  if [ -n "$CONFLICT" ]; then
    echo "ERROR: another Service already publishes $LB_HOST:$SERVICE_PORT —"
    echo "  $CONFLICT"
    echo ""
    echo "If that is dpn-nginx-observability-health, it is the retired basic-auth"
    echo "proxy still holding the port. Its chart has been removed from this repo,"
    echo "but the release is still live in the cluster — remove it once, and every"
    echo "port it held becomes available to these proxies:"
    echo ""
    echo "  helm uninstall dpn-nginx-observability -n $NAMESPACE"
    echo ""
    echo "If it is another oauth2-proxy release, two components have been given the"
    echo "same service.port — check the values files."
    exit 1
  fi
  echo "$LB_HOST:$SERVICE_PORT is free."
fi

echo "========================================"
echo "Verifying the Keycloak URLs (cross-namespace)"
echo "========================================"

KEYCLOAK_PUBLIC_URL="$(read_values keycloak publicUrl)"
KEYCLOAK_INTERNAL_URL="$(read_values keycloak internalUrl)"
KEYCLOAK_ISSUER_URL="$(read_values keycloak issuerUrl)"
REALM="$(read_values keycloak realm)"

KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443}"
REALM="${REALM:-dpn-realm}"
# Empty issuerUrl means "same as internalUrl", matching the chart
# default in templates/_helpers.tpl.
KEYCLOAK_ISSUER_URL="${KEYCLOAK_ISSUER_URL:-$KEYCLOAK_INTERNAL_URL}"

echo "publicUrl   = $KEYCLOAK_PUBLIC_URL (browser login)"
echo "internalUrl = $KEYCLOAK_INTERNAL_URL (token redeem, JWKS)"
echo "issuer      = $KEYCLOAK_ISSUER_URL (expected in the token's iss claim)"

if [ -z "$KEYCLOAK_PUBLIC_URL" ]; then
  echo "ERROR: keycloak.publicUrl is empty in $VALUES_FILE."
  echo "It is the address the browser is redirected to for login, so it must be"
  echo "Keycloak's own LoadBalancer, not its ClusterIP Service. Find it with:"
  echo "  kubectl get svc -n ns-dpn-01 | grep -i keycloak"
  exit 1
fi

# A *.svc.cluster.local name here is deliberate, not a mistake, but it is only
# correct if corporate/VNet DNS publishes it — kube-dns is invisible to a
# browser. The names are used because the dpn-common certificate carries
# *.ns-dpn-01.svc.cluster.local and *.ns-dpn-health-01.svc.cluster.local as
# SANs and nothing else: browsing by IP fails hostname verification outright,
# since an IP literal is matched only against iPAddress SANs and never against
# a DNS wildcard.
#
# This cannot be verified from here — the agent resolves through kube-dns like
# any other pod, so the name resolving in THIS check says nothing about whether
# a user's laptop can resolve it. Hence a warning, not a failure.
case "$KEYCLOAK_PUBLIC_URL" in
  *svc.cluster.local*)
    echo "NOTE: keycloak.publicUrl is an in-cluster name ($KEYCLOAK_PUBLIC_URL)."
    echo "That is intended — it matches the certificate's wildcard SAN — but it"
    echo "ONLY works if VNet DNS resolves that name to Keycloak's LoadBalancer."
    echo "Browsers do not use kube-dns. Confirm from a client machine with:"
    echo "  nslookup ${KEYCLOAK_PUBLIC_URL#https://}"
    ;;
esac

# Keycloak lives in ns-dpn-01, these pods in ns-dpn-health-01.
# This proves the fully-qualified Service name resolves and
# answers from THIS namespace, and reads back the issuer it
# advertises to a caller using that name.
#
# That issuer is the one that matters: Keycloak 26 runs here with
# no KC_HOSTNAME, so under hostname v2 it derives every advertised
# URL from the Host header of the request it is answering. The
# request that mints the token is oauth2-proxy's redeem call over
# the in-cluster name, so the `iss` claim in the token will be
# whatever this probe — which uses the same name — reports.
#
# -k here only checks reachability; the proxy itself verifies the
# certificate against the CA in secret/$TLS_SECRET.
kubectl delete pod oauth2-proxy-keycloak-test -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=60s

WELL_KNOWN="$(kubectl run oauth2-proxy-keycloak-test -n "$NAMESPACE" \
  --image=curlimages/curl:8.8.0 \
  --restart=Never \
  --rm \
  --attach \
  --quiet \
  --command -- sh -c \
  "curl -sSk --max-time 15 $KEYCLOAK_INTERNAL_URL/realms/$REALM/.well-known/openid-configuration" || true)"

ADVERTISED_ISSUER="$(printf '%s' "$WELL_KNOWN" | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p')"

if [ -z "$ADVERTISED_ISSUER" ]; then
  echo "ERROR: could not read the issuer from"
  echo "  $KEYCLOAK_INTERNAL_URL/realms/$REALM/.well-known/openid-configuration"
  echo ""
  echo "Response was:"
  echo "$WELL_KNOWN"
  echo ""
  echo "Either Keycloak is not reachable from $NAMESPACE, or realm '$REALM' does"
  echo "not exist on it — that realm name comes from dpn-authentication-service's"
  echo "charts/keycloak/dpn-realm.json, imported by its realm-import Job. Set"
  echo "keycloak.realm in $VALUES_FILE to whatever the ns-dpn-01 Keycloak actually serves."
  exit 1
fi

EXPECTED_ISSUER="$KEYCLOAK_ISSUER_URL/realms/$REALM"

echo "Keycloak advertises: $ADVERTISED_ISSUER"
echo "This release expects: $EXPECTED_ISSUER"

if [ "$ADVERTISED_ISSUER" != "$EXPECTED_ISSUER" ]; then
  echo "ERROR: Keycloak's issuer does not match the one this release would"
  echo "validate tokens against. oauth2-proxy compares oidc_issuer_url with the"
  echo "token's iss claim, so a mismatch sends every login back to the login page."
  echo ""
  echo "If the advertised issuer is now a fixed browser-facing URL, KC_HOSTNAME"
  echo "has been pinned on the ns-dpn-01 Keycloak since this was configured. Set"
  echo "keycloak.issuerUrl in $VALUES_FILE to:"
  echo "  ${ADVERTISED_ISSUER%/realms/$REALM}"
  echo "and re-run."
  exit 1
fi

echo "Issuer matches."

# Best effort: confirm the browser-facing address answers at all,
# so a typo in publicUrl surfaces here rather than as a dead
# redirect at first login. A warning, not a failure — hairpinning
# into an internal Azure LoadBalancer from inside the cluster can
# fail even when browsers reach it perfectly well.
kubectl delete pod oauth2-proxy-keycloak-public-test -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=60s

PUBLIC_CODE="$(kubectl run oauth2-proxy-keycloak-public-test -n "$NAMESPACE" \
  --image=curlimages/curl:8.8.0 \
  --restart=Never \
  --rm \
  --attach \
  --quiet \
  --command -- sh -c \
  "curl -sSk -o /dev/null -w '%{http_code}' --max-time 15 $KEYCLOAK_PUBLIC_URL/realms/$REALM/.well-known/openid-configuration" 2>/dev/null || true)"

case "$PUBLIC_CODE" in
  *200*)
    echo "keycloak.publicUrl answers on the realm endpoint."
    ;;
  *)
    echo "##vso[task.logissue type=warning]keycloak.publicUrl ($KEYCLOAK_PUBLIC_URL) did not answer from inside the cluster (HTTP '$PUBLIC_CODE'). That may just be LoadBalancer hairpinning, but confirm a browser can open $KEYCLOAK_PUBLIC_URL/realms/$REALM/.well-known/openid-configuration before announcing the URL — login_url points there."
    ;;
esac

echo "========================================"
echo "Linting oauth2-proxy chart"
echo "========================================"

# Every Keycloak URL now lives in the values file — they cannot be
# derived from discovery while Keycloak answers with whatever
# hostname it was called by. The step above is what keeps them
# honest: it fails the deploy if the issuer stops matching.
helm lint "$CHART_DIR" -f "$VALUES_FILE"

echo "========================================"
echo "Rendering oauth2-proxy chart"
echo "========================================"

# The rendered Secret carries only the generated cookie value, so
# there is no hand-supplied credential anywhere in this output.
# It still stays in /tmp with only its `kind:` lines echoed —
# a session key is not something to print into a build log
# either.
helm template "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  ${HELM_SET[@]+"${HELM_SET[@]}"} \
  > /tmp/oauth2-proxy-rendered.yaml

grep "^kind:" /tmp/oauth2-proxy-rendered.yaml || true

echo "========================================"
echo "Deploying oauth2-proxy"
echo "========================================"

# No adoption step. The chart no longer renders a Secret of that
# name, so the hand-made one is simply left alone — which is the
# whole point of moving it out of the release.

# Deliberately NOT --atomic. On failure it uninstalls the whole
# release, which deleted the very pods, Services and events
# needed to work out why the deploy failed — and, while the
# client-secret Secret was still part of the release, deleted
# that too, so the next run reported a missing credential
# instead of the real fault.
#
# Nothing here deletes anything now. A failed deploy leaves the
# broken resources in place and prints their state below.
if ! helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
     --namespace "$NAMESPACE" \
     -f "$VALUES_FILE" \
     ${HELM_SET[@]+"${HELM_SET[@]}"} \
     --wait \
     --timeout 5m; then

  echo "========================================"
  echo "Deploy failed — diagnostics"
  echo "========================================"

  # Every line is best-effort: this block runs precisely when
  # things are broken, so a failing lookup must not mask the
  # output of the ones that would have worked.
  echo "--- pods ---"
  kubectl get pods -n "$NAMESPACE" -l app="$RELEASE_NAME" -o wide || true

  echo "--- describe ---"
  kubectl describe pods -n "$NAMESPACE" -l app="$RELEASE_NAME" || true

  echo "--- logs (current) ---"
  kubectl logs -n "$NAMESPACE" -l app="$RELEASE_NAME" --tail=100 --all-containers || true

  echo "--- logs (previous container, if it restarted) ---"
  kubectl logs -n "$NAMESPACE" -l app="$RELEASE_NAME" --tail=100 --all-containers --previous || true

  echo "--- service ---"
  kubectl describe svc "$RELEASE_NAME" -n "$NAMESPACE" || true

  echo "--- events ---"
  kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp | tail -40 || true

  echo ""
  echo "The release was NOT rolled back — everything above is still in the"
  echo "cluster to inspect. Fix the cause and re-run; helm upgrade is"
  echo "idempotent, and secret/${RELEASE_NAME}-keycloak-akv is untouched"
  echo "either way — it is synced from Key Vault by the CSI driver, not"
  echo "owned by this release."
  exit 1
fi

kubectl rollout status deployment/"$RELEASE_NAME" \
  -n "$NAMESPACE" \
  --timeout=300s

echo "========================================"
echo "oauth2-proxy resources"
echo "========================================"

kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -l app="$RELEASE_NAME"

echo "========================================"
echo "Verifying the LoadBalancer address matches externalUrl"
echo "========================================"

LB_IP="$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

echo "oauth2-proxy internal LB IP: ${LB_IP:-<pending>}"

# Two different things to confirm, and only one of them is visible from here.
#
# The Service getting the address it was pinned to IS checkable. Whether
# externalUrl's DNS name resolves to that address is NOT: it is a corporate /
# VNet DNS record, and this agent resolves through kube-dns like any other pod,
# so a lookup here would prove nothing about a user's laptop. That half is
# printed as a reminder rather than tested.
EXTERNAL_HOST="$(echo "$EXTERNAL_URL" | sed 's#^https\?://##; s#:.*##')"

if [ -n "$LB_IP" ]; then
  if [ -z "$LB_HOST" ]; then
    echo "Service was assigned $LB_IP (service.loadBalancerIP is not pinned)."
  elif [ "$LB_IP" = "$LB_HOST" ]; then
    echo "Service has its pinned address $LB_IP."
  else
    echo "##vso[task.logissue type=warning]Service was assigned $LB_IP but service.loadBalancerIP pins $LB_HOST. Azure did not honour the pin, so DNS for $EXTERNAL_HOST now points at the wrong address."
  fi

  echo ""
  echo "Before anyone can log in, both of these must hold:"
  echo "  1. DNS resolves $EXTERNAL_HOST to $LB_IP for CLIENT machines."
  echo "     Browsers do not use kube-dns; this needs a VNet/private DNS record."
  echo "  2. $EXTERNAL_URL/oauth2/callback is a registered redirect URI on the"
  echo "     oauth2-proxy Keycloak client — Keycloak matches it exactly."
else
  echo "##vso[task.logissue type=warning]LB IP not assigned yet. Re-run once Azure assigns it, then point DNS for $EXTERNAL_HOST at the assigned address."
fi

echo "========================================"
echo "Testing the proxy responds and demands a login"
echo "========================================"

kubectl delete pod oauth2-proxy-curl-test -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=60s

# Both requests go to the TLS listener, which is the only one
# oauth2-proxy binds at all. -k because the serving certificate
# is issued for the browser-facing address, not the Service name.
#   /ping  -> 200, the unauthenticated health endpoint
#   /      -> 302, an unauthenticated request must be bounced to
#             Keycloak and must never return the UI
kubectl run oauth2-proxy-curl-test -n "$NAMESPACE" \
  --image=curlimages/curl:8.8.0 \
  --restart=Never \
  --rm \
  --attach \
  --command -- sh -c \
  "echo -n 'ping (expect 200): '; curl -sSk -o /dev/null -w '%{http_code}\n' --max-time 10 https://$RELEASE_NAME:${SERVICE_PORT}/ping || true; \
   echo -n 'root (expect 302): '; curl -sSk -o /dev/null -w '%{http_code}\n' --max-time 10 https://$RELEASE_NAME:${SERVICE_PORT}/ || true"

echo "========================================"
echo "Recent events"
echo "========================================"

kubectl get events -n "$NAMESPACE" \
  --sort-by=.metadata.creationTimestamp | grep -i oauth2 | tail -30 || true

echo "oauth2-proxy deployment completed."
