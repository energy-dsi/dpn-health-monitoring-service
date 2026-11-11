# OpenTelemetry Collector Helm Chart

This Helm chart deploys the OpenTelemetry Collector with secret redaction capabilities to the `ns-dpn-health-01` namespace.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Kafka cluster accessible at `dpn-kafka-health.kafka.svc.cluster.local:9092`
- A `kubernetes.io/tls` Secret named by `tls.secretName` (default `dpn-health-tls`)
  already present in `namespace`, holding `tls.crt` + `tls.key`. This chart does
  not create it — it is the same Secret the oauth2-proxy releases consume. Its
  certificate must carry the collector's Service names as SANs
  (`dpn-otel-collector` and `dpn-otel-collector.<namespace>.svc.cluster.local`),
  otherwise producers that verify the hostname will reject the handshake.

## Installation

### Install to the default namespace (ns-dpn-health-01)

```bash
helm install otel-collector ./charts/otel-collector
```

### Install with custom namespace

```bash
helm install otel-collector ./charts/otel-collector \
  --set namespace=my-custom-namespace
```

### Install with custom cluster name

```bash
helm install otel-collector ./charts/otel-collector \
  --set clusterName=my-cluster-name
```

## Configuration

### Key Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace for deployment | `ns-dpn-health-01` |
| `clusterName` | Cluster name for resource attributes | `dpn-cluster` |
| `replicaCount` | Number of replicas | `3` |
| `image.repository` | Container image repository | `otel/opentelemetry-collector-contrib` |
| `image.tag` | Container image tag | `0.95.0` |
| `autoscaling.enabled` | Enable horizontal pod autoscaling | `true` |
| `autoscaling.minReplicas` | Minimum number of replicas | `3` |
| `autoscaling.maxReplicas` | Maximum number of replicas | `10` |
| `tls.enabled` | Serve the OTLP receivers over TLS | `true` |
| `tls.secretName` | Existing `kubernetes.io/tls` Secret with the serving cert | `dpn-health-tls` |
| `tls.mountPath` | Where that Secret is mounted in the container | `/tls` |
| `tls.certFile` / `tls.keyFile` | Keys read from the Secret | `tls.crt` / `tls.key` |
| `tls.minVersion` | Minimum TLS version accepted | `"1.2"` |
| `keycloak.enabled` | Require a Keycloak Bearer token on OTLP/HTTP (`:4318`) calls only | `true` |
| `keycloak.issuerUrl` | Keycloak realm the token's `iss`/signature is checked against | `.../realms/dpn-realm` |
| `keycloak.audience` | Keycloak client id the token's `aud` claim must contain | `dpn-service-client` |
| `keycloak.issuerCaFile` | CA file (inside `tls.mountPath`) used to verify Keycloak's own TLS cert | `ca.crt` |

### OTLP over TLS

`tls.enabled` only ever applies to the **OTLP/HTTP receiver (`:4318`)** — the
gRPC receiver (`:4317`) is always plaintext regardless of this flag, see
"Why :4317 (gRPC) is always plaintext" below. The HTTP receiver terminates TLS
itself — there is no ingress controller or sidecar in front of the collector.
This is **server-side TLS only**: no `client_ca_file` is configured, so
producers do not need a client certificate.

Producers do have to change, though — a plaintext exporter against a TLS
listener fails the handshake rather than downgrading:

```bash
# OTLP/HTTP
OTEL_EXPORTER_OTLP_ENDPOINT=https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/dpn-ca.crt
```

To roll back to plaintext ingestion:

```bash
helm upgrade otel-collector ./charts/otel-collector --set tls.enabled=false
```

`tls.enabled` also puts the `:13133` health endpoint on HTTPS, and
`templates/deployment.yaml` forces `scheme: HTTPS` onto both probes from the same
flag. The scheme is patched onto the merged probe map in the template rather than
defaulted in `values.yaml`, because all nine `values-<env>[-<cluster>].yaml`
files override those probe maps — a values-level default would be one forgotten
file away from a CrashLooping environment. kubelet does not verify the
certificate on an HTTPS probe, so nothing else is needed.

### Keycloak authentication (OIDC)

With `keycloak.enabled` (default `true`), the OTLP/HTTP receiver (`:4318`)
rejects any call that doesn't carry a valid Keycloak-issued Bearer access
token — TLS alone is no longer enough to be accepted there, only to reach the
receiver in the first place. This is enforced via the `oidcauthextension`
(`extensions.oidc` in [otel-collector-config.yaml](otel-collector-config.yaml)),
wired onto the HTTP OTLP protocol only, via `auth: {authenticator: oidc}`.
**The gRPC receiver (`:4317`) is untouched by this flag** and stays
TLS-trusted-client-only, same as before — if your producers export over
gRPC, this whole section doesn't affect them; switch to OTLP/HTTP if you want
them to require a Keycloak token too.

`keycloak.enabled` **requires** `tls.enabled`: the extension's
`issuer_ca_path` reuses the `ca.crt` already carried by the `tls.secretName`
Secret to verify Keycloak's own certificate (the same CA
[oauth2-proxy](../oauth2-proxy) trusts Keycloak with) — there is no separate
CA Secret to mount. `helm template`/`helm upgrade` fails outright if you set
`keycloak.enabled=true` with `tls.enabled=false`.

Producers exporting over OTLP/HTTP must send a Keycloak client-credentials
access token for `keycloak.audience` on every export, as an
`Authorization: Bearer <token>` header. This is the same token-fetch flow
`utils/kafka_security.py`'s `SASL_SSL`+`OAUTHBEARER` mode
already performs for Kafka in `dpn-data-pipelines`, but against a different
client: the collector's default `keycloak.audience` is `dpn-service-client`
(the same client [oauth2-proxy](../oauth2-proxy) authenticates browser logins
as — see its `values.yaml`'s `keycloak.clientId`), deliberately kept separate
from `dpn-kafka-client` (Kafka-only, per `dpn-data-pipelines`'
`.docs/kafka-auth-modes.md`) rather than widening that client's scope.

This means `dpn-service-client`'s credential (client id + secret) is **not**
already sitting in producer/consumer/adaptor/schema_mapper pods the way
`dpn-kafka-client`'s is — each pod emitting OTLP telemetry needs that
credential distributed to it (e.g. via the same AKV/Secrets-Store-CSI pattern
`charts/oauth2-proxy/values.yaml`'s `akv:` block already uses to pull this
client's secret) before it can attach a Bearer token to its exports.

**The Keycloak side needs a one-time change first**: `dpn-service-client`'s
client-credentials access tokens must carry `dpn-service-client` in their
`aud` claim (add an Audience protocol mapper on that client if its tokens
currently only carry Keycloak's default `["account"]`) — otherwise the
extension rejects every otherwise-valid token with an audience mismatch.

To roll back to TLS-trusted-client-only (no token check):

```bash
helm upgrade otel-collector ./charts/otel-collector --set keycloak.enabled=false
```

#### Troubleshooting

**`401 Unauthenticated`** — no token was sent, or it doesn't validate. Confirm
the producer is attaching a bearer token at all, then check the collector
logs for the specific OIDC rejection reason (expired token, wrong issuer,
wrong audience).

**`oidc: audience mismatch` (or a token accepted here that gets rejected
elsewhere)** — the presented token's `aud` claim doesn't contain
`keycloak.audience`. Check the Audience protocol mapper on the Keycloak
client named there.

**Collector fails to start on this version, complaining about `issuer_ca_path`
or a TLS handshake to Keycloak** — `dpn-health-tls` doesn't carry a `ca.crt`
that signed Keycloak's certificate, or `keycloak.issuerCaFile` points at the
wrong key. Confirm with `kubectl get secret dpn-health-tls -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -issuer`.

### Why :4317 (gRPC) is always plaintext

A deliberate choice, not a limitation: the gRPC OTLP receiver has no `tls:`
block and no `auth:` block at all, unconditionally, regardless of
`tls.enabled` or `keycloak.enabled`. gRPC producers connect insecure
(`grpc.insecure_channel(...)` / `OTLPSpanExporter(..., insecure=True)`) and
need no CA and no Bearer token. If you need TLS and/or a Keycloak token
enforced, export over OTLP/HTTP (`:4318`) instead.

### Why :8888 is still plaintext

Not a choice — **collector 0.95.0 cannot serve it over TLS.**
`service.telemetry.metrics` accepts only `level` and `address`; adding a `tls:`
key fails config validation outright:

```
$ otelcol-contrib validate --config=file:/etc/otelcol/config.yaml
Error: 'service.telemetry.metrics' has invalid keys: tls
```

Revisit when `image.tag` moves past 0.95.0. In the meantime the exposure is
limited to the collector's own self-metrics — queue depth, refused-record counts,
uptime — and never customer telemetry, which only ever traverses the OTLP/HTTP
receiver when `tls.enabled`.

### Secret Redaction

The collector includes a redaction processor that automatically masks sensitive information in logs. See [SECRET_REDACTION.md](../../docs/SECRET_REDACTION.md) for details.

## Upgrading

```bash
helm upgrade otel-collector ./charts/otel-collector
```

## Uninstalling

```bash
helm uninstall otel-collector
```

This will remove all resources created by the chart, including the namespace resources.

## Verifying the Installation

Check the deployment status:

```bash
kubectl get pods -n ns-dpn-health-01 -l app.kubernetes.io/name=otel-collector
```

Check the service:

```bash
kubectl get svc -n ns-dpn-health-01 -l app.kubernetes.io/name=otel-collector
```

View logs:

```bash
kubectl logs -n ns-dpn-health-01 -l app.kubernetes.io/name=otel-collector --tail=100
```

## Endpoints

The collector exposes the following endpoints:

- **OTLP gRPC** (always plaintext, no auth): `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317`
- **OTLP HTTP** (TLS + Keycloak, when enabled): `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318`
- **Health Check** (TLS): `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:13133/healthz`
- **Metrics** (plain HTTP — see below): `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:8888`

## Kafka Topics

The collector exports telemetry data to the following Kafka topics:

- `otel-metrics` - Metrics data
- `otel-logs` - Logs data (with secret redaction)
- `otel-traces` - Traces data (sampled at 10%)

## Monitoring

The collector exposes Prometheus metrics on port 8888. The deployment includes annotations for automatic Prometheus scraping:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8888"
prometheus.io/path: "/metrics"
```

## High Availability

The chart is configured for high availability:

- **Multiple Replicas**: 3 replicas by default
- **Pod Disruption Budget**: Ensures at least 2 pods are available during disruptions
- **Horizontal Pod Autoscaling**: Automatically scales between 3-10 replicas based on CPU/memory
- **Anti-Affinity**: Prefers to schedule pods on different nodes

## Troubleshooting

### Pods not starting

Check pod events:
```bash
kubectl describe pod -n ns-dpn-health-01 -l app.kubernetes.io/name=otel-collector
```

### Producer gets HTTP 400 "Client sent an HTTP request to an HTTPS server."

The producer is still exporting plaintext to the TLS-enabled OTLP/HTTP
receiver. Go's TLS server answers a plaintext request with exactly that
message, so a 400 carrying it means the listener is healthy and the *client*
needs `https://`. Nothing is dropped silently — but nothing is ingested either.

This only applies to `:4318`. `:4317` (gRPC) has no TLS listener to hit in the
first place — a plaintext gRPC client dials it successfully.

### Producer gets "x509: certificate signed by unknown authority"

The producer reached the OTLP/HTTP (`:4318`) TLS listener but does not trust
the DPN CA. Point it at the CA bundle (`OTEL_EXPORTER_OTLP_CERTIFICATE`). If
instead the error names the hostname — `certificate is valid for ... not
<host>` — the cert in `tls.secretName` is missing that SAN; see Prerequisites.
Not applicable to `:4317` (gRPC), which has no TLS to verify.

### Connection issues to Kafka

Verify Kafka connectivity:
```bash
kubectl exec -n ns-dpn-health-01 -it <otel-collector-pod> -- sh
# Inside the pod
nc -zv dpn-kafka-health.kafka.svc.cluster.local 9092
```

### Secret redaction not working

Check the collector logs for redaction processor errors:
```bash
kubectl logs -n ns-dpn-health-01 -l app.kubernetes.io/name=otel-collector | grep redaction
```

## Support

For issues and questions, please refer to:
- [Architecture Documentation](../../docs/ARCHITECTURE.md)
- [Troubleshooting Guide](../../docs/TROUBLESHOOTING.md)
- [Secret Redaction Guide](../../docs/SECRET_REDACTION.md)