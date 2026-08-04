# ==============================================================================
# OpenTelemetry Kafka Topics Creation Script (PowerShell)
# ==============================================================================
# This script creates the required Kafka topics for OpenTelemetry telemetry data
# 
# Topics created:
# - otel-traces: Distributed traces
# - otel-metrics: Metrics data
# - otel-logs: Application logs
#
# Usage:
#   .\create-otel-topics.ps1
#
# Prerequisites:
#   - Kafka container (dpn-kafka) must be running
#   - Docker must be installed and accessible
# ==============================================================================

# Configuration
$KAFKA_CONTAINER = "dpn-kafka-health"
$BOOTSTRAP_SERVER = "localhost:9092"
$PARTITIONS = 3
$REPLICATION_FACTOR = 1

# Topics to create
$TOPICS = @("otel-traces", "otel-metrics", "otel-logs")

Write-Host "===================================================================" -ForegroundColor Blue
Write-Host "  OpenTelemetry Kafka Topics Creation" -ForegroundColor Blue
Write-Host "===================================================================" -ForegroundColor Blue
Write-Host ""

# Check if Kafka container is running
Write-Host "Checking if Kafka container is running..." -ForegroundColor Yellow
$kafkaRunning = docker ps --format "{{.Names}}" | Select-String -Pattern "^$KAFKA_CONTAINER$"
if (-not $kafkaRunning) {
    Write-Host "ERROR: Kafka container '$KAFKA_CONTAINER' is not running!" -ForegroundColor Red
    Write-Host "Please start Kafka first:" -ForegroundColor Yellow
    Write-Host "  docker-compose -f docker-compose.otel.yml up -d dpn-kafka"
    exit 1
}
Write-Host "✓ Kafka container is running" -ForegroundColor Green
Write-Host ""

# Wait for Kafka to be ready
Write-Host "Waiting for Kafka to be ready..." -ForegroundColor Yellow
$MAX_RETRIES = 30
$RETRY_COUNT = 0
$kafkaReady = $false

while ($RETRY_COUNT -lt $MAX_RETRIES) {
    try {
        $result = docker exec $KAFKA_CONTAINER kafka-broker-api-versions --bootstrap-server $BOOTSTRAP_SERVER 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Kafka is ready" -ForegroundColor Green
            $kafkaReady = $true
            break
        }
    }
    catch {
        # Continue waiting
    }
    
    $RETRY_COUNT++
    Write-Host "  Waiting... ($RETRY_COUNT/$MAX_RETRIES)" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

if (-not $kafkaReady) {
    Write-Host "ERROR: Kafka did not become ready in time" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Create topics
Write-Host "Creating OpenTelemetry topics..." -ForegroundColor Blue
Write-Host ""

foreach ($TOPIC in $TOPICS) {
    Write-Host "Creating topic: $TOPIC" -ForegroundColor Yellow
    
    # Check if topic already exists
    $existingTopics = docker exec $KAFKA_CONTAINER kafka-topics --list --bootstrap-server $BOOTSTRAP_SERVER 2>$null
    if ($existingTopics -match "^$TOPIC$") {
        Write-Host "  ⚠ Topic '$TOPIC' already exists, skipping..." -ForegroundColor Yellow
    }
    else {
        # Create the topic
        $createResult = docker exec $KAFKA_CONTAINER kafka-topics `
            --create `
            --topic $TOPIC `
            --bootstrap-server $BOOTSTRAP_SERVER `
            --partitions $PARTITIONS `
            --replication-factor $REPLICATION_FACTOR 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Topic '$TOPIC' created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  ✗ Failed to create topic '$TOPIC'" -ForegroundColor Red
            Write-Host "  Error: $createResult" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host ""
}

# Verify topics
Write-Host "Verifying created topics..." -ForegroundColor Blue
Write-Host ""
Write-Host "All OpenTelemetry topics:" -ForegroundColor Yellow
$allTopics = docker exec $KAFKA_CONTAINER kafka-topics --list --bootstrap-server $BOOTSTRAP_SERVER 2>$null
$otelTopics = $allTopics | Select-String -Pattern "^otel-"
$otelTopics | ForEach-Object { Write-Host "  • $_" -ForegroundColor Green }
Write-Host ""

# Display topic details
Write-Host "Topic Details:" -ForegroundColor Blue
foreach ($TOPIC in $TOPICS) {
    Write-Host "Topic: $TOPIC" -ForegroundColor Yellow
    $details = docker exec $KAFKA_CONTAINER kafka-topics `
        --describe `
        --topic $TOPIC `
        --bootstrap-server $BOOTSTRAP_SERVER 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host $details
    }
    else {
        Write-Host "  Topic not found" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "===================================================================" -ForegroundColor Green
Write-Host "  ✓ OpenTelemetry topics created successfully!" -ForegroundColor Green
Write-Host "===================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Blue
Write-Host "  1. Open Kafka UI: " -NoNewline
Write-Host "http://localhost:8080" -ForegroundColor Yellow
Write-Host "  2. Click on 'Topics' to view the created topics"
Write-Host "  3. Start sending telemetry data from your applications"
Write-Host "  4. View messages in Kafka UI as they arrive"
Write-Host ""
Write-Host "Topics created:" -ForegroundColor Blue
foreach ($TOPIC in $TOPICS) {
    Write-Host "  • $TOPIC" -NoNewline -ForegroundColor Green
    Write-Host " ($PARTITIONS partitions, replication factor $REPLICATION_FACTOR)"
}
Write-Host ""

# Made with Bob