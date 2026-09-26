# GitHub Actions deployment reference

Reference copy of this component's GitHub Actions deployment tooling, sourced from `dpn-containerised-deployment-service` (branch `feature/merge-azure-aws`, where this component's directory is named `dpn-health-monitoring`) on 2026-09-22. Replaces a previous, incorrectly-shaped copy of this folder.

**This is a reference copy, not a runnable pipeline from this location, and does not affect the existing Azure DevOps pipelines under `.pipelines/azure-pipelines/`.** These files use GitHub Actions' `uses: ./.github/workflows/...` reusable-workflow syntax internally (`dpn-gha-health-monitoring-cd-install.yaml` calls the 10 per-chart workflows below) — that syntax only resolves against a repo's own `.github/workflows/`, so as laid out here it is not executable even in principle, purely a reference/traceability copy. The actual GitHub Actions CD pipeline still runs centrally from `dpn-containerised-deployment-service`, which checks out this repo's charts directly.

- `actions/cloud-login/` — the shared composite action every workflow here uses to authenticate to whichever cloud (azure/aws/gcp) is selected at dispatch time
- `config/{aws,azure}/*.json` — per-environment config, one set per cloud (shared across all DPN components deployed to that environment; each workflow reads only the keys it needs)
- `workflows/dpn-gha-health-monitoring-cd-install.yaml` — the top-level orchestrator, calls the 10 per-chart workflows below in sequence
- `workflows/dpn-gha-kafka-cd.yaml`, `dpn-gha-opensearch-cd.yaml`, `dpn-gha-prometheus-cd.yaml`, `dpn-gha-thanos-cd.yaml`, `dpn-gha-data-prepper-cd.yaml`, `dpn-gha-jaeger-cd.yaml`, `dpn-gha-perses-cd.yaml`, `dpn-gha-otel-cd.yaml`, `dpn-gha-portal-cd.yaml`, `dpn-gha-oauth2-proxy-cd.yaml` — the per-chart installers, each independently dispatchable in the source repo too
- All workflows handle all three clouds via their own `cloud` input (not three separate files).

The Helm values for this repo's charts on AWS and Azure now live where they belong — alongside each chart, under `charts/<chart-name>/values/<cloud>/<environment>-<cluster>.yaml` (e.g. `charts/kafka-stack/values/aws/dev-dpn01.yaml`) — not in this folder. This mirrors the `values/{aws,azure,gcp}/<environment>-<cluster>.yaml` folder structure used in the source repo `dpn-containerised-deployment-service`. GCP is deliberately excluded for now. `oauth2-proxy-redis` has no per-cloud values at all, for any cloud — just one shared `values.yaml`. This sits alongside, and does not touch, the existing flat `values-<environment>-<cluster>.yaml` files used by the Azure DevOps pipelines.

No standalone uninstall or rollback workflow exists for any of these — a few sub-workflows have embedded self-healing `helm uninstall ... || true` retries and, for prometheus/thanos/perses only, embedded auto-rollback-to-last-revision, but these are automatic recovery steps inside the install workflow itself, not separate pipelines.
