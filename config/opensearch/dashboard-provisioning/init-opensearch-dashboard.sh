#!/usr/bin/env sh
# =============================================================================
# DPN Observability - Dashboard & Index Template Provisioning
#
# Runs once at stack startup (restart: "no").  Three jobs:
#   1. Apply the otel-logs-* index template to OpenSearch so that
#      date_detection is disabled before Data Prepper writes the first doc.
#   2. Delete any pre-existing versions of the DPN saved objects from the
#      .kibana index so the import always writes a clean copy.
#   3. Import the pre-built DPN Pipeline Monitoring dashboard (and all
#      its saved objects) into OpenSearch Dashboards.
# =============================================================================
set -e

DASHBOARDS_URL="${DASHBOARDS_URL:-http://dpn-opensearch-dashboards-health:5601}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://dpn-opensearch-health:9200}"
NDJSON_FILE="${NDJSON_FILE:-/dashboards/log-status-dashboard.ndjson}"
TEMPLATE_FILE="${TEMPLATE_FILE:-/dashboards/otel-logs-index-template.json}"
MAX_WAIT=180

# -- 1. Wait for OpenSearch ---------------------------------------------------
echo "[1/5] Waiting for OpenSearch at $OPENSEARCH_URL ..."
elapsed=0
until curl -sf "$OPENSEARCH_URL/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Timed out waiting for OpenSearch"; exit 1
  fi
done
echo "      OpenSearch is up."

# -- 2. Apply index template --------------------------------------------------
echo "[2/5] Applying otel-logs-* index template ..."
curl -sf -X PUT "$OPENSEARCH_URL/_index_template/otel-logs-template" \
  -H "Content-Type: application/json" \
  --data-binary "@${TEMPLATE_FILE}" \
  | grep -q '"acknowledged":true' && echo "      Template applied." \
  || echo "      Template already up-to-date or apply failed (non-fatal)."

# -- 3. Wait for OpenSearch Dashboards ----------------------------------------
echo "[3/5] Waiting for OpenSearch Dashboards at $DASHBOARDS_URL ..."
elapsed=0
until curl -sf -o /dev/null -w "%{http_code}" "$DASHBOARDS_URL/api/status" 2>/dev/null | grep -q "200"; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Timed out waiting for Dashboards"; exit 1
  fi
done
echo "      Dashboards is up."

# -- 4. Delete existing DPN saved objects (force clean re-import) -------------
echo "[4/5] Deleting existing DPN saved objects ..."
delete_object() {
  TYPE=$1
  ID=$2
  curl -s -o /dev/null -X DELETE \
    "$DASHBOARDS_URL/api/saved_objects/$TYPE/$ID" \
    -H "osd-xsrf: true" \
    -H "kbn-xsrf: true" && echo "      Deleted $TYPE/$ID" || true
}

delete_object "index-pattern"  "<<your specific value>>"
# Remove any stale index-pattern whose title is exactly "otel-logs*" (missing the dash)
# left over from a previous bad import. Iterate all index-patterns and delete exact-title matches.
curl -sf "$DASHBOARDS_URL/api/saved_objects/_find?type=index-pattern&per_page=100" \
  -H "osd-xsrf: true" > /tmp/ip_list.json || true
for STALE_ID in $(grep -o '"id":"[^"]*","type":"index-pattern"' /tmp/ip_list.json | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//'); do
  TITLE=$(grep -o "\"id\":\"$STALE_ID\"[^}]*\"title\":\"[^\"]*\"" /tmp/ip_list.json | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"//') || true
  if [ "$TITLE" = "otel-logs*" ]; then
    curl -s -o /dev/null -X DELETE "$DASHBOARDS_URL/api/saved_objects/index-pattern/$STALE_ID" \
      -H "osd-xsrf: true" && echo "      Deleted stale index-pattern/$STALE_ID (title: otel-logs*)" || true
  fi
done
delete_object "visualization"  "dpn-viz-component-health"
delete_object "visualization"  "dpn-viz-pipeline-status"
delete_object "visualization"  "dpn-viz-all-logs"
delete_object "visualization"  "dpn-viz-trace-ids"
delete_object "search"         "dpn-search-pipeline-history"
delete_object "search"         "dpn-search-filtered-logs"
delete_object "search"         "dpn-search-trace-pivot"
delete_object "search"         "dpn-search-pipeline-failures"
delete_object "dashboard"      "dpn-dashboard-pipeline-monitoring"
# DPN Pipeline Monitoring 2
delete_object "visualization"  "dpn2-viz-component-health"
delete_object "visualization"  "dpn2-viz-pipeline-health"
delete_object "visualization"  "dpn2-viz-all-logs"
delete_object "visualization"  "dpn2-viz-trace-ids"
delete_object "visualization"  "dpn2-viz-failure-count"
delete_object "dashboard"      "dpn2-dashboard"

# -- 5. Import saved objects --------------------------------------------------
echo "[5/5] Importing DPN Pipeline Monitoring dashboard ..."
curl -sf -X POST "$DASHBOARDS_URL/api/saved_objects/_import?overwrite=true" \
  -H "osd-xsrf: true" \
  -H "kbn-xsrf: true" \
  --form "file=@${NDJSON_FILE}"

echo ""
echo "Provisioning complete."
echo "  Dashboard 1: $DASHBOARDS_URL/app/dashboards#/view/dpn-dashboard-pipeline-monitoring"
echo "  Dashboard 2: $DASHBOARDS_URL/app/dashboards#/view/dpn2-dashboard"
