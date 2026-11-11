# GitHub Actions CD

These workflows are self-contained and runnable directly from this repo — `workflow_dispatch` from the Actions tab, no dependency on any other repo.

- `dpn-gha-health-monitoring-cd-install.yaml` — the orchestrator; calls the 10 per-chart workflows below (local `uses: ./.github/workflows/...` reusable-workflow calls) plus `dpn-gha-validate.yaml` as a shared validation step.
- `dpn-gha-kafka-cd.yaml`, `dpn-gha-opensearch-cd.yaml`, `dpn-gha-prometheus-cd.yaml`, `dpn-gha-thanos-cd.yaml`, `dpn-gha-data-prepper-cd.yaml`, `dpn-gha-jaeger-cd.yaml`, `dpn-gha-perses-cd.yaml`, `dpn-gha-otel-cd.yaml`, `dpn-gha-portal-cd.yaml`, `dpn-gha-oauth2-proxy-cd.yaml` — per-chart installers, each independently dispatchable too.
- `dpn-gha-uninstall-health-monitoring.yaml`, `dpn-gha-rollback-health-monitoring.yaml` — standalone teardown/rollback, reverse dependency order.
- `dpn-gha-validate.yaml` — shared `workflow_call` validation step, copied in from `dpn-containerised-deployment-service` since the orchestrator depends on it locally.

## One-time setup required (not a workflow change)

- **GitHub Environments** named `<environment>-<cluster>` for each target (e.g. `dev-dpn01`, `test-dpn02`).
- **Repository or Environment secrets**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` (Azure OIDC federated identity).
- **AWS path**: relies on OIDC role-chaining into the shared hub role, then your account's `oidc_github_runner_admin` role — no AWS secret needed, but that role/trust must exist.
- **Self-hosted runner**: workflows target `runs-on: [self-hosted, vmss]` — register a runner with that label, or change `runs-on` to a pool you control.
- **Per-environment config**: `.github/config/{aws,azure}/<environment>-<cluster>.json` already has real target values — update if pointing at different infrastructure.

Nothing in the workflow logic itself needs editing to run these — these are environment/credential setup steps, same as any GitHub Actions deployment pipeline.
