#!/usr/bin/env sh
# =============================================================================
# DPN Observability - OpenSearch Alerting Provisioning
#
# Reads configuration from environment variables (set via .env file):
#   ALERT_EMAIL        - recipient email address
#   SMTP_HOST          - SMTP server hostname
#   SMTP_PORT          - SMTP server port (default 465)
#   SMTP_FROM          - sender email address
#   SMTP_USER          - SMTP username (optional)
#   SMTP_PASS          - SMTP password (optional)
#   ALERT_SEVERITIES   - comma-separated severity levels e.g. ERROR,FATAL
#
# Creates:
#   1. An SMTP email account in OpenSearch alerting
#   2. An email destination pointing to ALERT_EMAIL
#   3. A monitor that queries otel-logs-* on the configured schedule
#   4. A trigger that fires when any matching severity log appears
#   5. An email action that sends the alert
# =============================================================================
set -e

OPENSEARCH_URL="${OPENSEARCH_URL:-http://dpn-opensearch-health:9200}"
ALERT_EMAIL="${ALERT_EMAIL:-alerts@example.com}"
SMTP_HOST="${SMTP_HOST:-smtp.example.com}"
SMTP_PORT="${SMTP_PORT:-465}"
SMTP_FROM="${SMTP_FROM:-opensearch-alerts@example.com}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
# Default: ERROR and FATAL only. Override in .env e.g. ALERT_SEVERITIES=ERROR,WARN,FATAL
ALERT_SEVERITIES="${ALERT_SEVERITIES:-ERROR,FATAL}"
MAX_WAIT=180

# Convert comma-separated ALERT_SEVERITIES into a JSON array e.g. ["ERROR","FATAL"]
SEVERITIES_JSON=$(echo "$ALERT_SEVERITIES" | \
  awk -F',' '{for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i<NF?",":"")}' | \
  sed 's/^/[/;s/$/]/')
echo "      Alert severities: $SEVERITIES_JSON"

# -- 1. Wait for OpenSearch ---------------------------------------------------
echo "[1/4] Waiting for OpenSearch at $OPENSEARCH_URL ..."
elapsed=0
until curl -sf "$OPENSEARCH_URL/_cluster/health" | grep -qE '"status":"(green|yellow)"'; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Timed out waiting for OpenSearch"; exit 1
  fi
done
echo "      OpenSearch is up."

# -- 2. Register SMTP email account -------------------------------------------
echo "[2/4] Registering SMTP account ..."

# Build optional auth fields only if SMTP_USER is provided
if [ -n "$SMTP_USER" ]; then
  AUTH_FIELDS=",\"username\": \"$SMTP_USER\", \"password\": \"$SMTP_PASS\""
else
  AUTH_FIELDS=""
fi

curl -sf -X POST "$OPENSEARCH_URL/_plugins/_alerting/destinations/email_accounts" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"dpn-smtp-account\",
    \"email\": \"$SMTP_FROM\",
    \"host\": \"$SMTP_HOST\",
    \"port\": $SMTP_PORT,
    \"method\": \"ssl\"
    $AUTH_FIELDS
  }" > /dev/null \
  && echo "      SMTP account registered." \
  || echo "      SMTP account already exists (non-fatal)."

# -- 3. Create or reuse email destination -------------------------------------
echo "[3/4] Registering email destination ..."

DEST_ID=$(curl -sf "$OPENSEARCH_URL/_plugins/_alerting/destinations" \
  -H "Content-Type: application/json" \
  | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//') || true

if [ -z "$DEST_ID" ]; then
  DEST_RESPONSE=$(curl -sf -X POST "$OPENSEARCH_URL/_plugins/_alerting/destinations" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"dpn-email-alert\",
      \"type\": \"email\",
      \"email\": {
        \"email_account_id\": \"dpn-smtp-account\",
        \"recipients\": [
          { \"type\": \"email\", \"email\": \"$ALERT_EMAIL\" }
        ]
      }
    }")
  DEST_ID=$(echo "$DEST_RESPONSE" | grep -o '"_id":"[^"]*"' | sed 's/"_id":"//;s/"//')
  echo "      Destination created: $DEST_ID"
else
  echo "      Destination already exists: $DEST_ID"
fi

# -- 4. Create failure monitor ------------------------------------------------
echo "[4/4] Creating failure log monitor ..."

# Delete existing monitor with same name to allow clean re-provisioning
EXISTING_MONITOR=$(curl -sf -X POST "$OPENSEARCH_URL/_plugins/_alerting/monitors/_search" \
  -H "Content-Type: application/json" \
  -d '{"query":{"term":{"monitor.name":"dpn-failure-log-monitor"}}}' \
  | grep -o '"_id":"[^"]*"' | head -1 | sed 's/"_id":"//;s/"//') || true

if [ -n "$EXISTING_MONITOR" ]; then
  curl -sf -X DELETE "$OPENSEARCH_URL/_plugins/_alerting/monitors/$EXISTING_MONITOR" > /dev/null
  echo "      Deleted existing monitor: $EXISTING_MONITOR"
fi

curl -sf -X POST "$OPENSEARCH_URL/_plugins/_alerting/monitors" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"monitor\",
    \"name\": \"dpn-failure-log-monitor\",
    \"monitor_type\": \"query_level_monitor\",
    \"enabled\": true,
    \"schedule\": {
      \"period\": { \"interval\": 1, \"unit\": \"MINUTES\" }
    },
    \"inputs\": [
      {
        \"search\": {
          \"indices\": [\"otel-logs-*\"],
          \"query\": {
            \"size\": 5,
            \"query\": {
              \"bool\": {
                \"must\": [
                  {
                    \"terms\": {
                      \"resourceLogs.scopeLogs.logRecords.severityText\": $SEVERITIES_JSON
                    }
                  },
                  {
                    \"range\": {
                      \"@timestamp\": { \"gte\": \"now-1m\" }
                    }
                  }
                ]
              }
            }
          }
        }
      }
    ],
    \"triggers\": [
      {
        \"query_level_trigger\": {
          \"id\": \"dpn-failure-trigger\",
          \"name\": \"Failure logs detected\",
          \"severity\": \"1\",
          \"condition\": {
            \"script\": {
              \"source\": \"ctx.results[0].hits.total.value > 0\",
              \"lang\": \"painless\"
            }
          },
          \"actions\": [
            {
              \"name\": \"Send email alert\",
              \"destination_id\": \"$DEST_ID\",
              \"subject_template\": {
                \"source\": \"[DPN ALERT] Failure logs detected in {{ctx.monitor.name}}\",
                \"lang\": \"mustache\"
              },
              \"message_template\": {
                \"source\": \"Monitor: {{ctx.monitor.name}}\nAlert time: {{ctx.periodEnd}}\nSeverities watched: $ALERT_SEVERITIES\nFailure count (last 1 min): {{ctx.results.0.hits.total.value}}\n\nSample log messages:\n{{#ctx.results.0.hits.hits}}  - [{{_source.resourceLogs.0.scopeLogs.0.logRecords.0.severityText}}] {{_source.resourceLogs.0.scopeLogs.0.logRecords.0.body.stringValue}}\n{{/ctx.results.0.hits.hits}}\nView dashboard: http://localhost:5601/app/dashboards#/view/dpn-dashboard-pipeline-monitoring\",
                \"lang\": \"mustache\"
              }
            }
          ]
        }
      }
    ]
  }"

echo ""
echo "Alerting provisioning complete."
echo "  Monitor:     dpn-failure-log-monitor (runs every 1 minute)"
echo "  Severities:  $ALERT_SEVERITIES"
echo "  Alert email: $ALERT_EMAIL"
echo "  SMTP:        $SMTP_FROM -> $SMTP_HOST:$SMTP_PORT"
echo "  Manage:      http://localhost:5601/app/alerting"
