#!/usr/bin/env sh
# =============================================================================
# DPN Observability - Dashboard & Index Template Provisioning
#
# Runs once at stack startup (restart: "no").  Five jobs:
#   1. Apply the otel-logs-* index template to OpenSearch so that
#      date_detection is disabled before Data Prepper writes the first doc.
#   2. Delete any pre-existing versions of the DPN saved objects from the
#      .kibana index so the import always writes a clean copy, including any
#      duplicate otel-logs index-pattern that would break time filtering.
#   3. Import the pre-built DPN Pipeline Monitoring dashboard (and all
#      its saved objects) into OpenSearch Dashboards.
#   4. Point Discover's default index pattern at the imported otel-logs-* one.
#   5. Refresh that pattern's field list from the live mapping, so the snapshot
#      baked into the ndjson cannot leave stale/missing fields in the UI.
# =============================================================================
set -e

# OSD stays behind the oauth2-proxy-osd TLS terminator, so internally it still
# listens plain HTTP. OpenSearch (:9200) now serves HTTPS with the security
# plugin enabled.
DASHBOARDS_URL="${DASHBOARDS_URL:-http://dpn-opensearch-dashboards-health:5601}"
OPENSEARCH_URL="${OPENSEARCH_URL:-https://dpn-opensearch-health:9200}"
NDJSON_FILE="${NDJSON_FILE:-/dashboards/log-status-dashboard.ndjson}"
TEMPLATE_FILE="${TEMPLATE_FILE:-/dashboards/otel-logs-index-template.json}"
MAX_WAIT=180

# --- Auth ---------------------------------------------------------------------
# OpenSearch REST (:9200): HTTP Basic as the datawriter service account
# (all_access). Cert SAN doesn't cover the internal hostname, so skip hostname
# verification (-k) — throwaway local-dev certs.
OS_USER="${OS_USER:-datawriter}"
OS_PASS="${OS_PASS:-DpnWriter123!}"
CURL="curl --insecure -u ${OS_USER}:${OS_PASS}"

# OSD (:5601): the security plugin uses proxycache (header) auth. Normally
# oauth2-proxy-osd injects these after a Keycloak login; this init container
# talks to OSD directly, so it presents the same identity headers itself as a
# trusted in-network proxy (admin -> all_access). Values are single tokens, so
# no quoting is needed.
OSD_USER="${OSD_USER:-admin}"
OSD_ROLES="${OSD_ROLES:-dpnadmin}"
# X-Forwarded-For is required too: OSD relays it to OpenSearch, whose proxy
# authenticator only trusts the identity headers when a forwarded-for chain is
# present.
CURL_OSD="curl -H x-forwarded-user:${OSD_USER} -H x-forwarded-groups:${OSD_ROLES} -H X-Forwarded-For:127.0.0.1"

# The otel-logs-* index-pattern shipped in the ndjson - the only one with
# timeFieldName set, so the only one where the time picker filters anything.
LOGS_INDEX_PATTERN_ID="<<your specific value>>"

# -- 1. Wait for OpenSearch ---------------------------------------------------
echo "[1/7] Waiting for OpenSearch at $OPENSEARCH_URL ..."
elapsed=0
until $CURL -sf "$OPENSEARCH_URL/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Timed out waiting for OpenSearch"; exit 1
  fi
done
echo "      OpenSearch is up."

# -- 2. Apply index template --------------------------------------------------
echo "[2/7] Applying otel-logs-* index template ..."
$CURL -sf -X PUT "$OPENSEARCH_URL/_index_template/otel-logs-template" \
  -H "Content-Type: application/json" \
  --data-binary "@${TEMPLATE_FILE}" \
  | grep -q '"acknowledged":true' && echo "      Template applied." \
  || echo "      Template already up-to-date or apply failed (non-fatal)."

# -- 3. Wait for OpenSearch Dashboards ----------------------------------------
echo "[3/7] Waiting for OpenSearch Dashboards at $DASHBOARDS_URL ..."
elapsed=0
until $CURL_OSD -sf -o /dev/null -w "%{http_code}" "$DASHBOARDS_URL/api/status" 2>/dev/null | grep -q "200"; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Timed out waiting for Dashboards"; exit 1
  fi
done
echo "      Dashboards is up."

# -- 4. Delete existing DPN saved objects (force clean re-import) -------------
echo "[4/7] Deleting existing DPN saved objects ..."
delete_object() {
  TYPE=$1
  ID=$2
  $CURL_OSD -s -o /dev/null -X DELETE \
    "$DASHBOARDS_URL/api/saved_objects/$TYPE/$ID" \
    -H "osd-xsrf: true" \
    -H "kbn-xsrf: true" && echo "      Deleted $TYPE/$ID" || true
}

delete_object "index-pattern"  "$LOGS_INDEX_PATTERN_ID"
# Remove BROKEN duplicate index-patterns over the logs indices - ones with no
# timeFieldName. Such a duplicate is not cosmetic: it is indistinguishable from
# the real one in the picker, and selecting it makes Discover ignore the time
# range entirely (no Time column, no time sort, rows in _doc order), which looks
# like "the date filter is broken".
#
# A duplicate that DOES have a time field is left alone: it works, and in a
# long-lived environment someone may have built saved objects on top of it -
# deleting it would orphan those references.
#
# Metadata is read one object at a time (with _source filtering) rather than
# from a single _find response: the index-pattern "fields" attribute is a huge
# escaped-JSON blob containing braces, so grep-slicing a multi-object response
# by id cannot be done reliably.
$CURL -sf -X POST "$OPENSEARCH_URL/.kibana/_search" \
  -H "Content-Type: application/json" \
  -d '{"size":100,"_source":false,"query":{"term":{"type":"index-pattern"}}}' \
  > /tmp/ip_ids.json || true
for IP_ID in $(grep -o '"_id":"index-pattern:[^"]*"' /tmp/ip_ids.json | sed 's/"_id":"index-pattern://;s/"$//'); do
  # Already deleted above; it is re-imported in step 5.
  if [ "$IP_ID" = "$LOGS_INDEX_PATTERN_ID" ]; then
    continue
  fi
  META=$($CURL -sf "$OPENSEARCH_URL/.kibana/_doc/index-pattern:$IP_ID?_source_includes=index-pattern.title,index-pattern.timeFieldName") || continue
  TITLE=$(echo "$META" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"$//') || true
  case "$TITLE" in
    otel-logs*) ;;
    *) continue ;;
  esac
  if echo "$META" | grep -q '"timeFieldName"'; then
    echo "      Keeping index-pattern/$IP_ID (title: $TITLE) - has a time field"
  else
    $CURL_OSD -s -o /dev/null -X DELETE "$DASHBOARDS_URL/api/saved_objects/index-pattern/$IP_ID" \
      -H "osd-xsrf: true" \
      && echo "      Deleted time-field-less duplicate index-pattern/$IP_ID (title: $TITLE)" || true
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
# DPN Monitoring (current dashboard)
delete_object "visualization"  "dpn3-viz-pipeline-health"
delete_object "dashboard"      "dpn3-dashboard"

# -- 5. Import saved objects --------------------------------------------------
echo "[5/7] Importing DPN Pipeline Monitoring dashboard ..."
$CURL_OSD -sf -X POST "$DASHBOARDS_URL/api/saved_objects/_import?overwrite=true" \
  -H "osd-xsrf: true" \
  -H "kbn-xsrf: true" \
  --form "file=@${NDJSON_FILE}"

# -- 6. Point Discover's default index pattern at the logs pattern ------------
# Discover opens on defaultIndex when no pattern is chosen. If that default is a
# pattern without a time field (e.g. an otel-metrics-*/otel-traces-* one made by
# hand), the time picker silently does nothing.
#
# LOGS_INDEX_PATTERN_ID is created by the import in step 5 - the ndjson ships in
# the same ConfigMap as this script, so the two cannot drift. Confirm it landed
# anyway, so a wrong id points Discover at nothing instead of failing silently.
#
# Two more Advanced Settings are applied here for the Log View panel. Both are
# per-environment saved objects in .kibana, NOT yml keys, so an environment that
# never had them set behaves differently from one that did:
#
#   dateFormat:tz        Unset means "Browser", so the log table renders in the
#                        viewer's local timezone while every other panel is UTC.
#   discover:sampleSize  OSD defaults to 500 rows. A saved-search panel fetches
#                        the newest N rows in range and stops, so the log view
#                        looks like it is "missing data" when it is just capped.
#                        10000 is the ceiling - OpenSearch refuses a deeper page
#                        (index.max_result_window), so a larger value only errors.
echo ""
echo "[6/7] Applying Advanced Settings (defaultRoute, defaultIndex, dateFormat:tz, sampleSize) ..."
if $CURL_OSD -sf -o /dev/null "$DASHBOARDS_URL/api/saved_objects/index-pattern/$LOGS_INDEX_PATTERN_ID" \
     -H "osd-xsrf: true"; then
  # defaultRoute: OSD lands on /app/opensearch_dashboards_overview when
  # unset, which 404s as "Application Not Found" if that app isn't
  # registered in this build/config - point it at the dashboards list
  # instead, same as the docker-compose reference's opensearch-init did
  # via a raw .kibana config doc write.
  $CURL_OSD -sf -o /dev/null -X POST "$DASHBOARDS_URL/api/opensearch-dashboards/settings" \
    -H "osd-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "{\"changes\":{\"defaultRoute\":\"/app/dashboards\",\"defaultIndex\":\"${LOGS_INDEX_PATTERN_ID}\",\"dateFormat:tz\":\"UTC\",\"discover:sampleSize\":10000}}" \
    && echo "      Advanced Settings applied (UTC, 10000 rows)." \
    || echo "      WARNING: settings API rejected the change (non-fatal)."
else
  echo "      WARNING: index-pattern/$LOGS_INDEX_PATTERN_ID not found after import."
  echo "               Default index pattern left unchanged - check that"
  echo "               LOGS_INDEX_PATTERN_ID matches the id in $NDJSON_FILE."
fi

# -- 7. Refresh the index-pattern field list -----------------------------------
# The ndjson carries a baked "fields" snapshot, which goes stale as soon as the
# Data Prepper pipeline adds or drops a field. Stale entries are not cosmetic:
# fields that no longer exist still show up in the filter bar and always match
# 0 docs, new fields (e.g. log._stage) cannot be filtered or added as columns,
# and a field wrongly marked aggregatable gets a sort control that errors with
# "Text fields are not optimised for ... field data".
#
# Re-reading the live mapping here makes the list correct in every environment,
# whatever the ndjson happens to contain. Non-destructive and idempotent.
echo ""
echo "[7/7] Refreshing otel-logs-* field list from the live mapping ..."
FIELDS=$($CURL_OSD -sf "$DASHBOARDS_URL/api/index_patterns/_fields_for_wildcard?pattern=otel-logs-*&meta_fields=_source&meta_fields=_id&meta_fields=_type&meta_fields=_index&meta_fields=_score") || FIELDS=""
if [ -n "$FIELDS" ]; then
  # Turn {"fields":[...]} into the escaped-string form the saved object stores.
  ESCAPED=$(printf '%s' "$FIELDS" \
    | sed 's/^{"fields"://; s/}$//' \
    | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"attributes":{"title":"otel-logs-*","timeFieldName":"@timestamp","fields":"%s"}}' "$ESCAPED" \
    | $CURL_OSD -sf -o /dev/null -X PUT "$DASHBOARDS_URL/api/saved_objects/index-pattern/$LOGS_INDEX_PATTERN_ID" \
        -H "osd-xsrf: true" \
        -H "Content-Type: application/json" \
        --data-binary @- \
    && echo "      Field list refreshed." \
    || echo "      WARNING: field list refresh rejected (non-fatal; use Stack Management > Refresh field list)."
else
  echo "      WARNING: could not read live fields (non-fatal; ndjson snapshot left in place)."
fi

echo ""
echo "Provisioning complete."
echo "  Dashboard 1: $DASHBOARDS_URL/app/dashboards#/view/dpn-dashboard-pipeline-monitoring"
echo "  Dashboard 2: $DASHBOARDS_URL/app/dashboards#/view/dpn2-dashboard"
