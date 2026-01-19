#!/bin/bash
set -e

echo "=================================================="
echo "PostgreSQL Node Registration & Startup"
echo "Container: $(hostname)"
echo "Node Type: ${NODE_TYPE:-backup}"
echo "=================================================="

# Get container name (hostname in Docker)
CONTAINER_NAME=$(hostname)
NODE_NAME="${CONTAINER_NAME#postgres-}"  # Remove 'postgres-' prefix

# Extract IP from hostname resolution or use container IP
# Try to get IP from docker network interface
NODE_IP=$(hostname -I | awk '{print $1}')
if [ -z "$NODE_IP" ]; then
    NODE_IP="127.0.0.1"
fi

# Get node type (backup or replica)
NODE_TYPE="${NODE_TYPE:-backup}"

# Internal port (always 5432 in container)
INTERNAL_PORT=5432

echo "Extracted node info:"
echo "  Name: $NODE_NAME"
echo "  IP: $NODE_IP"
echo "  Type: $NODE_TYPE"
echo "  Port: $INTERNAL_PORT"

# Try to register with operationManagement API (wait for it to be available)
echo ""
echo "Attempting to register with operationManagement API..."

MAX_RETRIES=30
RETRY_COUNT=0
API_URL="http://operationManagement:5001/api/operationmanagement/hosts"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "  [Attempt $((RETRY_COUNT+1))/$MAX_RETRIES] Connecting to $API_URL..."
    
    # Try to register
    RESPONSE=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$NODE_NAME\",
            \"ip\": \"$NODE_IP\",
            \"port\": $INTERNAL_PORT,
            \"type\": \"$NODE_TYPE\"
        }" 2>&1 || echo "")
    
    # Check if response indicates success or node already exists
    if echo "$RESPONSE" | grep -q "success\|already exists"; then
        echo "  ✓ Successfully registered with API (or already registered)"
        echo "    Response: $RESPONSE"
        break
    elif echo "$RESPONSE" | grep -q "Connection refused\|Failed to\|curl:"; then
        # API not ready yet, retry
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "    API not ready, waiting... ($RETRY_COUNT/$MAX_RETRIES)"
            sleep 2
        fi
    else
        # Some response received
        echo "  Response: $RESPONSE"
        if [ ! -z "$RESPONSE" ]; then
            echo "  ✓ Response received from API"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            sleep 2
        fi
    fi
done

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "  ⚠ Could not register with API after $MAX_RETRIES attempts"
    echo "  Continuing anyway - PostgreSQL will start normally"
fi

echo ""
echo "Starting PostgreSQL..."
exec /usr/local/bin/docker-entrypoint.sh "$@"
