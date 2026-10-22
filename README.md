# README

**Repository:** `dpn-health-monitoring-service`

**Description:** `Complete observability infrastructure (logs, traces, and metrics) for the DPN Data Pipelines project.`

<!-- SPDX-License-Identifier: Apache-2.0 AND OGL-UK-3.0 -->

---

## Overview

The DPN Health Monitoring Service provides the observability backend infrastructure — logs, traces, and metrics collection, storage, and visualisation. It is one of several open-source components underpinning DSI's Data Preparation Node (DPN), a framework enabling secure, trusted data-sharing across organisations.

## Configuration & Installation

Detailed configuration and installation instructions for this repository are present in **[dpn-integration-playbook](https://github.com/energy-dsi/dpn-integration-playbook)**

This includes producer/consumer setup, CI/CD pipeline configuration and execution, and deployment validation. Refer to the guide matching your deployment target:

### AWS Deployment

Refer [aws-manual-beta](https://github.com/energy-dsi/dpn-integration-playbook/tree/main/Docs/03-dpn-application-deployment/aws-manual-beta) for AWS specific deployment 

**Note** AWS Manual deployment is an interim solution and GitHub Actions based deployment to replace the manual deployment in future release

### Azure Deployment

Refer [azure-ado-beta](https://github.com/energy-dsi/dpn-integration-playbook/tree/main/Docs/03-dpn-application-deployment/azure-ado-beta) for Azure specific deployment

## Features

The health monitoring service provides a unified observability stack for DPN Data Pipelines, covering:

- **Telemetry ingestion** — OpenTelemetry Collector receiving logs, traces, and metrics over OTLP from DPN applications.
- **Durable transport** — Kafka + Zookeeper buffering telemetry between the collector and downstream processing pipelines.
- **Log processing and storage** — Data Prepper pipelines parsing OTLP logs into OpenSearch for search and analysis.
- **Distributed tracing** — Jaeger Ingester and UI for trace storage and visualisation.
- **Metrics storage** — Prometheus for short-term metrics and Thanos for long-term, highly available metrics storage.
- **Dashboards and visualisation** — Perses and Grafana for unified observability dashboards, alongside OpenSearch Dashboards and Kafka UI.
- **DPN Unified Portal** — a single Keycloak-gated landing page tiling links to every observability UI (Kafka UI, OpenSearch Dashboards, Jaeger, Perses), fronted by its own oauth2-proxy gateway.
- **Kubernetes-native deployment** — Helm charts for every component, with oauth2-proxy gateways terminating HTTPS and enforcing Keycloak login in front of each UI.

## Public Funding Acknowledgment

This repository has been developed with public funding as part of the Data Sharing Infrastructure (DSI), a UK Government initiative.

## License

This repository is licensed under a multi-licence model — see [LICENSE.md](./LICENSE.md) for full terms.

## Security and Responsible Disclosure

We take security seriously. If you believe you have found a security vulnerability in this repository, please follow our responsible disclosure process outlined in [SECURITY.md](./SECURITY.md).

## Contributing

We welcome contributions that align with the Programme's objectives.

## Acknowledgements

This repository has benefited from collaboration with various organisations — see [ACKNOWLEDGEMENTS.md](./ACKNOWLEDGEMENTS.md).

## Support and Contact

For questions, feedback, or support requests:

- Contact the DSI team using [dsi@neso.energy](mailto:dsi@neso.energy)

## Maintained by the National Energy System Operator (NESO)

Copyright 2026 NESO. This work is licensed under the Open Government Licence 3.0 (OGL). This work has been developed by NESO using content licensed by the Department for Business and Trade (UK) under the OGL.

Licensed under the Open Government Licence v3.0.

For full licensing terms, see [OGL_LICENSE.md](./OGL_LICENSE.md).
