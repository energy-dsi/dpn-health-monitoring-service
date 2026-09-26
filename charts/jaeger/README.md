# Custom Jaeger Helm Chart

This chart deploys Jaeger as three separate components:

- `dpn-jaeger-collector`
- `dpn-jaeger-query`
- `dpn-jaeger-ingester`

## Usage

Copy `charts/jaeger` into your repository, then run:

```bash
helm lint ./charts/jaeger
helm template dpn-jaeger ./charts/jaeger
helm upgrade --install dpn-jaeger ./charts/jaeger -n ns-dpn-health-01
```

## Expected pods

```text
dpn-jaeger-collector-xxxxx   1/1 Running
dpn-jaeger-query-xxxxx       1/1 Running
dpn-jaeger-ingester-xxxxx    1/1 Running
```

## Notes

- The chart includes AKS Gatekeeper-compatible container security context.
- It assumes Kafka is reachable at `dpn-kafka.ns-dpn-health-01.svc.cluster.local:9092`.
- It assumes OpenSearch is reachable at `dpn-opensearch.ns-dpn-health-01.svc.cluster.local:9200`.
