# oauth2-proxy — Keycloak gateway for the DPN health observability UIs

Puts a Keycloak login in front of the observability UIs reached through
`ns-dpn-health-01`. **This chart replaced the nginx basic-auth proxy
entirely** — `charts/nginx-observability` has been removed, and most of the
UIs it used to multiplex now have their own oauth2-proxy release here.
Airflow is the exception — see the note below the port table — it now
relies on its own login instead.

```
                                        ┌──http──▶ dpn-opensearch-dashboard-health:5601
browser ──https──▶ oauth2-proxy ────────┤
          (internal LB, one port per UI)└──http──▶ … one upstream per release
                        │
                        │ OIDC
                        ▼
              dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local:8443
              (both browser login and token redeem — see below)
```

One release per UI, all sharing one DNS name and the namespace's single static
internal LB address `10.226.121.10`, each keeping the port it had under nginx:

| Component | Port | Upstream | Values file |
| --- | --- | --- | --- |
| `opensearch` | 5601 | `dpn-opensearch-dashboard-health:5601` | `values-opensearch.yaml` |
| `jaeger` | 16686 | `dpn-jaeger-query-health:16686` | `values-jaeger.yaml` |
| `perses` | 8083 | `dpn-perses-health:8083` | `values-perses.yaml` |
| `portal` | 8443 | `dpn-portal:8000` | `values-portal.yaml` |

Prometheus and Thanos deliberately have no gateway here — neither needs a
Keycloak login. Each still publishes directly on the same shared LB address
though, on the port nginx used to serve it (Prometheus `9081`, Thanos
`9091`), via its own component chart rather than this one — see
`charts/prometheus/prometheus-community-values.yaml`'s `extraManifests`
Service and `charts/thanos/values.yaml`'s `query.service`.

**Airflow no longer has an oauth2-proxy gateway here.** Its gateway was
removed; it now relies on its own login (`config/airflow/webserver_config.py`)
instead of the Keycloak gate, and is reached directly through whatever
Service/route its own deployment in `ns-dpn-01` publishes — that is out of
scope for this chart.

**Kafka UI (`dpn-kafka-health-ui`, the health-namespace one) no longer has
an oauth2-proxy gateway here either.** Its gateway was removed; it now
relies on its own native Keycloak OIDC login (`charts/kafka-stack`'s
`kafkaUi.oidcRbac`) instead, and is exposed directly on the same shared LB
address at port `8082` via its own chart rather than this one. Since
oauth2-proxy previously also terminated the browser-facing HTTPS for it,
Kafka UI now terminates TLS itself (`kafkaUi.tls.enabled`, Spring Boot's
`SERVER_SSL_*` reading the same `dpn-health-tls` Secret every other UI in
this namespace uses) — without that, a browser hitting
`https://...:8082` gets a plaintext response back
(`ERR_SSL_PROTOCOL_ERROR`), since Kafka UI's embedded server only ever
spoke plain HTTP.

**`kafka-ui-2` no longer has an oauth2-proxy gateway here either.** It
fronted `dpn-kafka-ui` in `ns-dpn-01` — a UI this repo does not own or
control. Its gateway was removed with no replacement added here; exposing
that UI directly is that UI's own chart/repo's responsibility, not this
one's.

**`portal` is not an nginx migration — it is new.** `dpn-portal` (a tile
landing page linking to the other UIs) and its own oauth2-proxy previously only
ran under `config/docker-compose.observability-full.yml`; it has no prior
cluster port to preserve, which is why 8443 was picked as its external port. `charts/dpn-portal` deploys the page itself; `values-portal.yaml` is its
gateway. `charts/dpn-portal/values.yaml` has no default container image —
set `image.repository` / `image.tag` there to wherever `app/dpn-portal` is
published before the first deploy, or the release fails to render on purpose
rather than pulling a guessed image.

Each values file carries only what differs — name, upstream, port, cookie name.
Everything about Keycloak, TLS and cookie policy is inherited from
`values.yaml`, so there is one place to change the Keycloak address rather than
four.

## The cross-namespace problem

Keycloak lives in `ns-dpn-01`; these pods live in `ns-dpn-health-01`. Two
consequences drive the whole design:

1. **Services** resolve across namespaces only by fully-qualified name, hence
   `https://dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local:8443` rather than
   `https://dpn-keycloak:8443`.
2. **Secrets do not cross namespaces at all.** The Keycloak CA and the client
   secret have to be *copied* into `ns-dpn-health-01`.

Keycloak is also split-horizon in principle — a browser-facing address and an
in-cluster one — but both now resolve to the same name,
`dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local:8443`. That is not a shortcut: it is
the only name the `dpn-common` certificate covers. See the DNS section below.
OIDC discovery is still skipped and each endpoint pinned separately, because
`login_url` is followed by the browser while `redeem_url` / `oidc_jwks_url` are
called by this pod, and those two may need to diverge again later.

`oidc_issuer_url` is the subtle one, and it follows the **internal** URL. The
ns-dpn-01 Keycloak (26.3.2) runs with no `KC_HOSTNAME` set, so under hostname
v2 it derives every URL it advertises — the issuer included — from the `Host`
header of the request it happens to be answering. The request that mints the
token is this pod's redeem call over the in-cluster name, so that is the `iss`
the token carries, even though the user logged in on the public address. It is
never fetched, only string-compared, so pointing it at an address no browser
can resolve is fine.

If `KC_HOSTNAME` is ever pinned on Keycloak, the issuer becomes fixed for every
caller and `keycloak.issuerUrl` must be set to it. The CD pipeline compares the
advertised issuer against the configured one on every deploy and fails with
that exact instruction, so the two cannot drift apart unnoticed.

## What OpenSearch RBAC this does and does not give you

The OpenSearch security plugin is currently **disabled** in this cluster
(`plugins.security.disabled: true`, `DISABLE_SECURITY_DASHBOARDS_PLUGIN=true`),
so this proxy is an **all-or-nothing gate**: a user holding any role in
`keycloak.allowedRoles` gets in and then has full Dashboards access. Per-user
read-only vs admin inside OpenSearch needs the security plugin enabled — a
separate change (node certs, HTTPS on 9200, `securityconfig`, and every writer
switched to authenticated HTTPS). The proxy already forwards
`X-Forwarded-User` / `X-Forwarded-Groups`, so that change needs no edit here.

## Prerequisites — one existing Secret, one synced from Key Vault

**`dpn-health-tls`** already exists in `ns-dpn-health-01` and covers two of the
three needs on its own — it is a `kubernetes.io/tls` Secret holding:

| Key | Used for |
| --- | --- |
| `tls.crt`, `tls.key` | the browser-facing HTTPS listener |
| `ca.crt` | verifying Keycloak on the token-redeem and JWKS calls |

Because `ca.crt` rides along, no separate CA Secret has to be copied out of
ns-dpn-01. This assumes the DPN CA that signed `dpn-health-tls` also signed
Keycloak's certificate — if it did not, the proxy logs `x509: certificate
signed by unknown authority` and the CA needs splitting back out. The chart
never creates or modifies this Secret; the pipeline only verifies all three
keys are present, since a missing `ca.crt` mounts perfectly happily and fails
much later.

**The Keycloak client credential** for `dpn-service-client` is synced from
Azure Key Vault by `templates/secretproviderclass.yaml`, via the Secrets
Store CSI driver / provider-azure add-on already running on this cluster —
the same mechanism already in use for `dpn-keycloak-kv-secrets` and
`federator-client-kv-secrets` in `ns-dpn-01`
(`kubectl get secretproviderclass -n ns-dpn-01 -o yaml` to see them live).

Each release renders its own `SecretProviderClass` (named
`<release>-kv-secrets`) that pulls `akv.objectName` (default
`KC-SERVICE-CLIENT-SECRET`) from `akv.keyvaultName` and mirrors it, via
`secretObjects`, into a Secret named by the `oauth2-proxy.akvSecretName`
helper (`<release>-keycloak-akv`) under the key `client-secret` —
`templates/deployment.yaml` reads that Secret through `secretKeyRef`, exactly
as it read the old hand-made Secret. Auth to Key Vault uses this cluster's
existing VM-managed identity — `akv.tenantId` and
`akv.userAssignedIdentityID` in `values.yaml` default to it; override them
per environment only if a different cluster/vault pair uses a different
tenant or identity.

**The CSI driver only mirrors the value into that Secret while some pod has
the `SecretProviderClass` mounted as a volume** — that mount is what triggers
the sync, not an independent poller. `templates/deployment.yaml` mounts it at
`/mnt/secrets-store` for exactly this reason; the pod never reads that mount
path directly, only the mirrored Secret via `OAUTH2_PROXY_CLIENT_SECRET`.

Nothing here is created by hand, and the credential never passes through the
pipeline at all — no `--set`, no secret pipeline variable, nothing to mask in
a build log.

| Secret | Owner | Contents | Ongoing effort |
| --- | --- | --- | --- |
| `dpn-health-tls` | pre-existing | `tls.crt`, `tls.key`, `ca.crt` | none |
| `<release>-keycloak-akv` | CSI driver, from Key Vault | `client-secret` | none — rotate in Key Vault |
| `<release>-cookie` | this chart | `cookie-secret` | none, ever |

**`cookie-secret`** is the AES key for the session cookie. Nothing outside the
pod uses it, so any 32 random characters will do and the chart makes its own in
a Secret of its own. On upgrades it is read back with `lookup`, so a deploy
never mints a new key and logs everyone out. Delete that Secret to rotate.

## Prerequisites — the shared Redis session store

Every release sets `session_store_type = "redis"` (see `sessionStore` in
`values.yaml`) rather than storing the token bundle in the browser cookie.
Without this, the cookie has to hold the full `id_token` / `access_token` /
`refresh_token` set — and this realm's tokens carry an audience claim plus a
multivalued `roles` claim on top of the defaults — which risks `HTTP 431
Request Header Too Large` on some browsers or intermediate proxies. The
docker-compose stack hits the same problem and solves it the same way with its
own `redis` service.

`charts/oauth2-proxy-redis` deploys the store, released as `dpn-redis-ui-health`
— **on its own**, not owned by any of the four oauth2-proxy releases:

```bash
helm upgrade --install dpn-redis-ui-health charts/oauth2-proxy-redis \
  -n ns-dpn-health-01
```

The CD pipeline does this automatically, once, before every component's own
deploy (`helm upgrade --install` is idempotent, so running it four times is a
no-op after the first). It is deliberately not folded into any one release: a
shared dependency tied to one release's lifecycle gets deleted the moment
that release does, taking every other release's sessions with it.

No persistence is configured — a Redis restart logs everyone out, same as the
docker-compose service, and is judged an acceptable trade against running a
stateful workload for what is disposable session cache.

## Prerequisites — DNS, and why the URLs are cluster names

Every browser-facing URL here is a `*.svc.cluster.local` name. That looks wrong
at first glance and is deliberate.

The `dpn-health-tls` certificate is `CN=dpn-common`, issued by `dpn-root`, and
its **only** SANs are:

```
DNS:*.ns-dpn-01.svc.cluster.local
DNS:*.ns-dpn-health-01.svc.cluster.local
```

There is no IP SAN. When a URL's host is an IP literal, TLS verification
consults `iPAddress` SANs *only* and ignores every `DNS:` entry — a wildcard
can never match an IP. So browsing to `https://10.226.121.10:5601` fails with
`ERR_CERT_COMMON_NAME_INVALID` no matter how thoroughly the CA is trusted;
that error is a **name** failure, not a trust failure. Choosing names the
certificate already covers avoids reissuing it at all, and decouples the URLs
from an address that could change.

**This requires client-side DNS.** Browsers never use kube-dns, so the names
must be published in VNet / corporate DNS:

| Name | Resolves to | Serves |
| --- | --- | --- |
| `dpn-observability.ns-dpn-health-01.svc.cluster.local` | `10.226.121.10` | all four proxied UIs, one port each |
| `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local` | `10.226.121.13` | the Keycloak login redirect |

An Azure Private DNS zone for `svc.cluster.local` linked to the VNet, with those
two A records, is the usual way. Pods are unaffected — they resolve through
kube-dns and continue to get ClusterIPs for these names, which is what they
want for the token-redeem and JWKS calls.

If the LoadBalancer address ever changes, one DNS record changes with it. The
four `externalUrl` values and the four Keycloak redirect URIs do not — which
is the whole reason for doing it this way rather than embedding the IP.

The CD pipeline **cannot verify any of this**. It resolves through kube-dns
like any other pod, so a successful lookup there says nothing about a client
machine. It prints the requirement and moves on.

## Prerequisites — Keycloak realm

All four releases share the single `dpn-service-client` client in the
`dpn-realm` realm, so the client needs **every** callback registered on
it — Keycloak matches redirect URIs exactly, and a missing one fails that UI's
login with `invalid_redirect_uri`. The realm JSON in this repo lists only the
docker-compose callbacks (`https://localhost:5601/oauth2/callback`), so add
these before the first login attempt:

| Valid redirect URI | Web origin |
| --- | --- |
| `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:5601/oauth2/callback` | `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:5601` |
| `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:16686/oauth2/callback` | `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:16686` |
| `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8083/oauth2/callback` | `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8083` |
| `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8443/oauth2/callback` | `https://dpn-observability.ns-dpn-health-01.svc.cluster.local:8443` |

That realm name comes from `config/keycloak/dpn-realm.json`, which is the
docker-compose realm — if the ns-dpn-01 Keycloak serves a different one, set
`keycloak.realm` in the values file. The pipeline fails with that hint when the
realm's discovery endpoint 404s.

The realm must also keep the `realm-roles-claim` protocol mapper that puts
realm roles into a `roles` claim — `allowed_groups` reads that claim, and there
is no `groups` client scope in this realm.

## The two URLs, and where each comes from

**`externalUrl` — pinned in each component values file.** The namespace has one
static internal LB address, `10.226.121.10`, which the retired nginx Service
used to hold on its own. Kubernetes lets several Services share an address but
never a port, so all four proxies pin the same `service.loadBalancerIP` and
each takes the single port its UI already used. Existing bookmarks keep working
— only the scheme changes (`http` → `https`) and the login changes from basic
auth to Keycloak.

**`keycloak.publicUrl` — a DNS name, in `values.yaml`.** It is
`https://dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local:8443`, and only `login_url`
is built from it. It cannot be derived from discovery: an unpinned Keycloak
answers every probe with the hostname the probe itself used, so asking over the
in-cluster name only ever returns the in-cluster name. The pipeline verifies
what it finds in the values file instead — it fails if the advertised issuer
stops matching `issuerUrl`, and warns if `publicUrl` does not answer.

Keycloak's own LoadBalancer is what that name must resolve to for clients:

```bash
kubectl get svc -n ns-dpn-01 | grep -i keycloak
# dpn-keycloak             ClusterIP      10.0.30.93     <none>          8443/TCP
# dpn-keycloak-service-lb  LoadBalancer   10.0.207.148   10.226.121.13   8443:32425/TCP
```

**`keycloak.issuerUrl` — empty, meaning "same as `internalUrl`".** See the
split-horizon note above; change it only alongside a `KC_HOSTNAME` change on
Keycloak itself.

## Deploy order

**The nginx release must be uninstalled first.** Its chart has been deleted
from this repo, but that alone changes nothing in the cluster — the live
`dpn-nginx-observability` release still holds every one of these ports on
`10.226.121.10`, and Azure rejects any Service claiming an address and port
that is already taken. The pipeline detects this and fails with the reason
rather than letting Azure reject the Service.

```bash
# 1. release the ports — one time, and every UI is offline until step 3
helm uninstall dpn-nginx-observability -n ns-dpn-health-01

# 2. the shared session store — one release, not owned by any UI's proxy
helm upgrade --install dpn-redis-ui-health charts/oauth2-proxy-redis \
  -n ns-dpn-health-01

# 2b. portal's own UI, only needed for the new `portal` component
helm upgrade --install dpn-portal charts/dpn-portal \
  -n ns-dpn-health-01

# 3. one release per UI. Nothing is passed in: every URL is in the values
#    files, and the client secret is read from the Secret by the pod itself
for c in opensearch jaeger perses portal; do
  helm upgrade --install "dpn-oauth2-proxy-$c" charts/oauth2-proxy \
    -n ns-dpn-health-01 -f "charts/oauth2-proxy/values-$c.yaml"
done
```

The release name for OpenSearch Dashboards is `dpn-oauth2-proxy-osd`, not
`-opensearch`, so adjust that one if you run the loop verbatim.

Or run `oauth2-proxy-cd.yaml` once per component — it does steps 2 and 2b
itself (step 2 on every run, harmlessly, since `helm upgrade --install` is
idempotent; step 2b only when `component: portal`). The master pipeline
chains all four in order for the same reason the loop is sequential: Azure
reconciles a shared LoadBalancer address unreliably when several Services
mutate it at once.

## Adding another UI

1. Copy any `values-<component>.yaml` and change the five things that vary:
   `name`, `upstream.url`, `externalUrl`, `cookie.name` and `service.port`.
   Leave the Keycloak block out — it is inherited.
2. Add a branch to the `case` statement in
   `.pipelines/azure-pipelines/cd-pipelines/oauth2-proxy-cd.yaml` with the
   release name, upstream Service, upstream port and published port. Set
   `UPSTREAM_NS` if the UI lives outside `ns-dpn-health-01`.
3. Add the component to that file's `component` parameter list, and a chained
   `template:` block in the `OAuth2Proxy` stage of `monitoring-master-cd.yaml`.
4. Register `<externalUrl>/oauth2/callback` as a redirect URI, and
   `<externalUrl>` as a web origin, on the `oauth2-proxy` Keycloak client.

No Secret to create — each release renders its own `SecretProviderClass`
pulling the same `KC-SERVICE-CLIENT-SECRET` object from Key Vault.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `invalid_redirect_uri` from Keycloak | `<externalUrl>/oauth2/callback` not registered on the client |
| Login loops back to the login page | `oidc_issuer_url` (i.e. `keycloak.issuerUrl`, defaulting to `internalUrl`) does not match the token `iss` claim — usually because `KC_HOSTNAME` was pinned on Keycloak after this was configured |
| Browser hangs or "site cannot be reached" on the Keycloak redirect | Client DNS does not resolve `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local` to `10.226.121.13`. Browsers do not use kube-dns |
| `ERR_CERT_COMMON_NAME_INVALID` in the browser | The URL used an IP, or a name outside the certificate wildcards. An IP literal is matched only against `iPAddress` SANs, never a DNS wildcard — trusting the CA does not fix it |
| `x509: certificate signed by unknown authority` in proxy logs | `ca.crt` in `dpn-health-tls` is not the CA that signed Keycloak's cert |
| `x509: certificate is valid for <x>, not dpn-keycloak.ns-dpn-01...` | Keycloak's cert has no SAN for its in-cluster name — add the SAN, or set `keycloak.insecureSkipVerify: true` |
| `invalid_scope` | A scope was requested that the realm does not define; keep `keycloak.scope` pinned |
| 403 after a successful Keycloak login | The user holds none of `keycloak.allowedRoles`, or the `roles` claim mapper is missing |
| Pod `Running` but never `Ready`, probes log `connection refused` | Something is probing the plain-HTTP port. oauth2-proxy binds **only** the TLS listener once `tls_cert_file` is set, so probes must use `port: 4443` with `scheme: HTTPS` |
| Pod will not start, cookie secret error | Cookie secret is neither 16/24/32 raw bytes nor base64 decoding to that |
| `CreateContainerConfigError` on the pod | The `<release>-keycloak-akv` Secret has no `client-secret` key yet — check the pod's `keycloak-secrets-store` CSI volume mount events and that `akv.objectName` exists in the vault under `akv.keyvaultName` |
| Pod stuck in `ContainerCreating`, event `FailedMount` on `keycloak-secrets-store` | The CSI driver could not reach Key Vault or the object — check `akv.tenantId` / `akv.userAssignedIdentityID` / `akv.keyvaultName` / `akv.objectName`, and that the managed identity has `get` permission on that secret |
| Everyone logged out after a deploy | `cookie-secret` was regenerated — the Secret was deleted, or `lookup` could not read it back |
| `HTTP 431 Request Header Too Large` | `dpn-redis-ui-health` is not reachable — check `session_store_type` rendered into the ConfigMap and that the Redis Service resolves. Without Redis, the token bundle falls back to living entirely in the cookie |
| `dpn-oauth2-proxy-portal` Helm install fails to render | `image.repository` / `image.tag` are unset in `charts/dpn-portal/values.yaml` — set them to wherever `app/dpn-portal` is published before deploying that component |
