# OpenTelemetry Collector Helm Chart

This Helm chart deploys the OpenTelemetry Collector with secret redaction capabilities to the `ns-dpn-health-01` namespace.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Kafka cluster accessible at `dpn-kafka-health.kafka.svc.cluster.local:9092`

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

- **OTLP gRPC**: `otel-collector.ns-dpn-health-01.svc.cluster.local:4317`
- **OTLP HTTP**: `otel-collector.ns-dpn-health-01.svc.cluster.local:4318`
- **Metrics**: `otel-collector.ns-dpn-health-01.svc.cluster.local:8888`
- **Health Check**: `otel-collector.ns-dpn-health-01.svc.cluster.local:13133`

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