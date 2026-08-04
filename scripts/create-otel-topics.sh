#!/bin/bash

# ==============================================================================
# OpenTelemetry Kafka Topics Creation Script
# ==============================================================================
# This script creates the required Kafka topics for OpenTelemetry telemetry data
# 
# Topics created:
# - otel-traces: Distributed traces
# - otel-metrics: Metrics data
# - otel-logs: Application logs
#
# Usage:
#   ./create-otel-topics.sh
#
# Prerequisites:
#   - Kafka container (dpn-kafka) must be running
#   - Docker must be installed and accessible
# ==============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KAFKA_CONTAINER="dpn-kafka-health"
BOOTSTRAP_SERVER="localhost:9092"
PARTITIONS=3
REPLICATION_FACTOR=1

# Topics to create
TOPICS=("otel-traces" "otel-metrics" "otel-logs")

echo -e "${BLUE}===================================================================${NC}"
echo -e "${BLUE}  OpenTelemetry Kafka Topics Creation${NC}"
echo -e "${BLUE}===================================================================${NC}"
echo ""

# Check if Kafka container is running
echo -e "${YELLOW}Checking if Kafka container is running...${NC}"
if ! docker ps --format '{{.Names}}' | grep -q "^${KAFKA_CONTAINER}$"; then
    echo -e "${RED}ERROR: Kafka container '${KAFKA_CONTAINER}' is not running!${NC}"
    echo -e "${YELLOW}Please start Kafka first:${NC}"
    echo -e "  docker-compose -f docker-compose.otel.yml up -d dpn-kafka"
    exit 1
fi
echo -e "${GREEN}✓ Kafka container is running${NC}"
echo ""

# Wait for Kafka to be ready
echo -e "${YELLOW}Waiting for Kafka to be ready...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker exec ${KAFKA_CONTAINER} kafka-broker-api-versions --bootstrap-server ${BOOTSTRAP_SERVER} &> /dev/null; then
        echo -e "${GREEN}✓ Kafka is ready${NC}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -e "${YELLOW}  Waiting... (${RETRY_COUNT}/${MAX_RETRIES})${NC}"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}ERROR: Kafka did not become ready in time${NC}"
    exit 1
fi
echo ""

# Create topics
echo -e "${BLUE}Creating OpenTelemetry topics...${NC}"
echo ""

for TOPIC in "${TOPICS[@]}"; do
    echo -e "${YELLOW}Creating topic: ${TOPIC}${NC}"
    
    # Check if topic already exists
    if docker exec ${KAFKA_CONTAINER} kafka-topics --list --bootstrap-server ${BOOTSTRAP_SERVER} 2>/dev/null | grep -q "^${TOPIC}$"; then
        echo -e "${YELLOW}  ⚠ Topic '${TOPIC}' already exists, skipping...${NC}"
    else
        # Create the topic
        if docker exec ${KAFKA_CONTAINER} kafka-topics \
            --create \
            --topic ${TOPIC} \
            --bootstrap-server ${BOOTSTRAP_SERVER} \
            --partitions ${PARTITIONS} \
            --replication-factor ${REPLICATION_FACTOR} 2>&1; then
            echo -e "${GREEN}  ✓ Topic '${TOPIC}' created successfully${NC}"
        else
            echo -e "${RED}  ✗ Failed to create topic '${TOPIC}'${NC}"
            exit 1
        fi
    fi
    echo ""
done

# Verify topics
echo -e "${BLUE}Verifying created topics...${NC}"
echo ""
echo -e "${YELLOW}All Kafka topics:${NC}"
docker exec ${KAFKA_CONTAINER} kafka-topics --list --bootstrap-server ${BOOTSTRAP_SERVER} | grep "^otel-" || true
echo ""

# Display topic details
echo -e "${BLUE}Topic Details:${NC}"
for TOPIC in "${TOPICS[@]}"; do
    echo -e "${YELLOW}Topic: ${TOPIC}${NC}"
    docker exec ${KAFKA_CONTAINER} kafka-topics \
        --describe \
        --topic ${TOPIC} \
        --bootstrap-server ${BOOTSTRAP_SERVER} 2>/dev/null || echo "  Topic not found"
    echo ""
done

echo -e "${GREEN}===================================================================${NC}"
echo -e "${GREEN}  ✓ OpenTelemetry topics created successfully!${NC}"
echo -e "${GREEN}===================================================================${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo -e "  1. Open Kafka UI: ${YELLOW}http://localhost:8080${NC}"
echo -e "  2. Click on 'Topics' to view the created topics"
echo -e "  3. Start sending telemetry data from your applications"
echo -e "  4. View messages in Kafka UI as they arrive"
echo ""
echo -e "${BLUE}Topics created:${NC}"
for TOPIC in "${TOPICS[@]}"; do
    echo -e "  • ${GREEN}${TOPIC}${NC} (${PARTITIONS} partitions, replication factor ${REPLICATION_FACTOR})"
done
echo ""

# Made with Bob