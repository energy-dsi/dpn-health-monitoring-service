# Changelog

**Repository:** `dpn-health-monitoring-service`  
**Description:** `Tracks all notable changes, version history, and roadmap toward 1.0.0 following Semantic Versioning.`

<!-- SPDX-License-Identifier: OGL-UK-3.0 -->

--- 

All notable changes to this repository will be documented in this file.

This project follows **Semantic Versioning (SemVer)** ([semver.org](https://semver.org/)), using the format:

`[MAJOR].[MINOR].[PATCH]`
- **MAJOR** (`X.0.0`) – Incompatible API/feature changes that break backward compatibility.
- **MINOR** (`0.X.0`) – Backward-compatible new features, enhancements, or functionality changes.
- **PATCH** (`0.0.X`) – Backward-compatible bug fixes, security updates, or minor corrections.
- **Pre-release versions** – Use suffixes such as `-alpha`, `-beta`, `-rc.1` (e.g., `2.1.0-beta.1`).
- **Build metadata** – If needed, use `+build` (e.g., `2.1.0+20260314`).

---

## How to Update This Changelog

1. When making changes, update this file under the **Unreleased** section.
2. Before a new release, move changes from **Unreleased** to a new dated section with a version number.
3. Follow **Semantic Versioning** rules to categorise changes correctly.
4. If pre-release versions are used, clearly mark them as `-alpha`, `-beta`, or `-rc.X`.

---

## Release 2.0.0 - September 2026

### Added

- DPN Unified portal app component
- CI pipeline for `app/dpn-portal` (`.pipelines/azure-pipelines/ci-pipelines/dpn-portal-ci.yaml`)
- `dpnPortalImageTag` parameter on `monitoring-master-cd.yaml` to deploy dpn portal
- OAuth2 Proxy for Keycloak-based authentication with OpenSearch, Perses, Jaeger, and DPN Portal
- TLS/HTTPS support for the OTel Collector
- TLS on Data Prepper
- Role based access management for DPN UI Components. Two roles defined dpnadmin (edit and view facility) and dpnreader (only view facility). Users need to create user for specific role to access the UI Components.

### Modified

- None

### Removed

- nginx proxy service
---

## Release 1.0.0 - July 2026

- Established initial Health Monitoring project structure, baseline configuration, and repository setup.
- Added OpenTelemetry (OTEL) collector configuration, deployment, and monitoring enhancements.
- Deployed Jaeger service with ingester fixes and ZooKeeper PVC configuration.
- Standardized Kafka and trace encoding to the otlp_proto format.
- Added OpenSearch configuration for monitoring and observability.
- Integrated Prometheus Helm chart with Thanos secret configuration.
- Improved log status and file-scan service dashboards.
- Implemented NGINX for the Health Monitoring service, including image and deployment management.
- Updated Data Prepper service configuration mapping.
- Enhanced heartbeat processing logic and operational functionality.
- Improved resilience and storage configuration

---

## Maintained by the National Energy System Operator (NESO)

Copyright 2026 NESO.  This work is licensed under the Open Government Licence 3.0 (OGL). This work has been developed by NESO using content licensed by the Department for Business and Trade (UK) under the OGL.   
 
Licensed under the Open Government Licence v3.0.

For full licensing terms, [OGL_LICENSE.md](./OGL_LICENSE.md)
