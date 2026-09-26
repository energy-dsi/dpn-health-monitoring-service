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

### OTLP over TLS

The OTLP receivers terminate TLS themselves — there is no ingress controller or
sidecar in front of the collector. This is **server-side TLS only**: no
`client_ca_file` is configured, so producers do not need a client certificate.

Producers do have to change, though — a plaintext exporter against a TLS
listener fails the handshake rather than downgrading:

```bash
# OTLP/HTTP
OTEL_EXPORTER_OTLP_ENDPOINT=https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/dpn-ca.crt
```

For gRPC, use a TLS-enabled channel (in the Python SDK: `OTLPSpanExporter(...,
insecure=False, credentials=...)`) rather than the default insecure one.

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
uptime — and never customer telemetry, which only ever traverses the TLS OTLP
receivers.

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

- **OTLP gRPC** (TLS): `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317`
- **OTLP HTTP** (TLS): `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318`
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

The gRPC equivalent has no such courtesy message: a plaintext gRPC client just
fails to dial and times out.

### Producer gets "x509: certificate signed by unknown authority"

The producer reached the TLS listener but does not trust the DPN CA. Point it at
the CA bundle (`OTEL_EXPORTER_OTLP_CERTIFICATE`, or the SDK's credentials
argument for gRPC). If instead the error names the hostname —
`certificate is valid for ... not <host>` — the cert in `tls.secretName` is
missing that SAN; see Prerequisites.

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