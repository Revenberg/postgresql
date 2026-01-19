#!/bin/bash
set -e

# Database connection parameters
DB_USER="${DB_USER:-testadmin}"
DB_PASSWORD="${DB_PASSWORD:-securepwd123}"
DB_NAME="${DB_NAME:-testdb}"

# API and node configuration
API_URL="${API_URL:-http://operationManagement:5001}"
NODES="${NODES:-node1 node2 node3}"
NODE_PORTS="${NODE_PORTS:-5432 5435 5436}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a /tmp/init.log
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR${NC} $1" | tee -a /tmp/init.log
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING${NC} $1" | tee -a /tmp/init.log
}

info() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a /tmp/init.log
}

# Function to find primary node using operationManagement API status endpoint
# Returns: "container_name:port"
# Outputs logging to stderr so it doesn't interfere with the return value
find_primary_node() {
    local max_retries=30
    local retry=1
    local response
    local primary_node
    
    {
        info "Calling operationManagement status endpoint to get primary database..."
    } >&2
    
    while [ $retry -le $max_retries ]; do
        # Call the operationManagement status endpoint
        response=$(curl -s -w "\n%{http_code}" \
            -X GET \
            "$API_URL/api/operationmanagement/status" \
            -H "Content-Type: application/json" \
            2>/dev/null)
        
        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | head -n-1)
        
        if [ "$http_code" = "200" ]; then
            # Parse the response to find the primary node
            # The status endpoint returns nodes as an object (dict), not an array
            # Example: {"nodes": {"node1": {...}, "node2": {"is_primary": true, ...}, ...}}
            primary_node=$(echo "$body" | jq -r '.nodes | to_entries[] | select(.value.is_primary == true) | .key' 2>/dev/null | head -1)
            
            if [ -n "$primary_node" ] && [ "$primary_node" != "null" ]; then
                # Get the node's container and port from the status response
                local node_container=$(echo "$body" | jq -r ".nodes.\"$primary_node\".container" 2>/dev/null)
                local node_port=$(echo "$body" | jq -r ".nodes.\"$primary_node\".port // 5432" 2>/dev/null)
                
                if [ -n "$node_container" ] && [ "$node_container" != "null" ]; then
                    # Use container name and port from API (works within Docker network)
                    {
                        log "✓ Found primary node from API: $primary_node (container: $node_container, port: $node_port)"
                    } >&2
                    # Return only the connection string to stdout
                    echo "$node_container:$node_port"
                    return 0
                fi
            else
                {
                    info "No primary node found yet, retrying... (attempt $retry/$max_retries)"
                } >&2
            fi
        else
            {
                info "API call failed with status $http_code, retrying... (attempt $retry/$max_retries)"
            } >&2
        fi
        
        retry=$((retry + 1))
        sleep 2
    done
    
    # Fallback: try direct connection to known nodes
    {
        warn "Could not get primary from API, falling back to direct connection..."
    } >&2
    local node_ips="172.18.0.2 172.18.0.3 172.18.0.6"
    local ports="5432 5432 5432"
    local node_names="node1 node2 node3"
    local ip
    local port
    local name
    local i=0
    
    for ip in $node_ips; do
        port=$(echo $ports | cut -d' ' -f$((i+1)))
        name=$(echo $node_names | cut -d' ' -f$((i+1)))
        i=$((i+1))
        
        {
            info "Testing $ip:$port ($name)..."
        } >&2
        
        # Try to connect to this node using IP address
        if PGPASSWORD=$DB_PASSWORD timeout 5 pg_isready -h $ip -p $port -U $DB_USER > /dev/null 2>&1; then
            {
                log "✓ Found working node via direct connection: $ip ($node_names node)"
            } >&2
            echo "$ip:$port"
            return 0
        fi
    done
    
    # Last resort fallback
    {
        warn "Could not connect to any node, using final fallback (postgres-node2:5432)"
    } >&2
    echo "postgres-node2:5432"
}

log "========================================"
log "PostgreSQL Database Initializer"
log "========================================"
log "Database: $DB_NAME"
log "User: $DB_USER"
log "Using operationManagement API: $API_URL"
log ""

# Find the primary node using operationManagement API
# Returns "container_name:port"
PRIMARY_NODE_INFO=$(find_primary_node)
DB_HOST="${PRIMARY_NODE_INFO%:*}"
DB_PORT="${PRIMARY_NODE_INFO##*:}"

log "Connecting to primary: $DB_HOST:$DB_PORT (resolved via operationManagement API)"
log ""

# Debug: Check if host is reachable via DNS
log "DEBUG: Testing DNS resolution for $DB_HOST..."
if nslookup $DB_HOST > /dev/null 2>&1; then
    log "✓ Host $DB_HOST is resolvable via DNS"
    local resolved_ip=$(nslookup $DB_HOST | grep -A1 "Name:" | grep "Address:" | awk '{print $NF}' | head -1)
    [ -n "$resolved_ip" ] && log "  Resolved IP: $resolved_ip"
else
    warn "WARNING: Could not resolve $DB_HOST via DNS, will use as-is"
fi

# Wait for database to be available (connect to postgres database first)
log "Waiting for PostgreSQL to be ready..."
max_attempts=60
attempt=1

while [ $attempt -le $max_attempts ]; do
    # Try pg_isready without -v option (not supported in all versions)
    pg_isready_output=$(PGPASSWORD=$DB_PASSWORD pg_isready -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres 2>&1)
    pg_isready_result=$?
    
    if [ $pg_isready_result -eq 0 ]; then
        log "✓ PostgreSQL is ready!"
        log "  Output: $pg_isready_output"
        break
    else
        # Log the pg_isready output for debugging
        info "Attempt $attempt/$max_attempts - Waiting for $DB_HOST:$DB_PORT..."
        info "  pg_isready exit code: $pg_isready_result"
        info "  Output: $pg_isready_output"
        
        # Show status codes meaning:
        # 0 = accepting connections
        # 1 = rejecting connections
        # 2 = no attempt was made (server not running?)
        # 3 = no attempt was made (invalid parameters?)
        case $pg_isready_result in
            1) info "  (Rejecting connections - server may still be starting)" ;;
            2) info "  (Server not running or not responding)" ;;
            3) info "  (Invalid parameters)" ;;
        esac
    fi
    
    attempt=$((attempt + 1))
    sleep 2
done

if [ $attempt -gt $max_attempts ]; then
    error "Failed to connect to PostgreSQL after $max_attempts attempts"
    error "Last pg_isready output: $pg_isready_output"
fi

# Create testdb database if it doesn't exist
log "Creating database $DB_NAME if it doesn't exist..."
log "DEBUG: Executing CREATE DATABASE command..."

create_db_output=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres -c "CREATE DATABASE $DB_NAME;" 2>&1)
create_db_result=$?

if [ $create_db_result -eq 0 ]; then
    log "✓ Database $DB_NAME created successfully"
elif echo "$create_db_output" | grep -q "already exists"; then
    log "✓ Database $DB_NAME already exists"
else
    warn "Database creation result - exit code: $create_db_result"
    warn "Output: $create_db_output"
fi

log ""
log "Checking if initialization is needed..."

# Check if tables already exist
tables_exist=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_name IN ('users', 'nodes', 'messages')
" 2>/dev/null || echo "0")

if [ "$tables_exist" = "3" ]; then
    log "✓ All tables already exist - skipping initialization"
    log ""
    
    # Show table statistics
    log "Database Statistics:"
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME << 'QUERY'
        SELECT tablename, 
               (SELECT count(*) FROM users) as users_count,
               (SELECT count(*) FROM nodes) as nodes_count,
               (SELECT count(*) FROM messages) as messages_count
        FROM pg_tables
        WHERE schemaname = 'public'
        LIMIT 1;
QUERY
    
    log ""
    log "========================================"
    log "✓ Initialization skipped - database already initialized"
    log "========================================"
    exit 0
fi

log "✓ Tables do not exist - proceeding with initialization"
log ""
log "Executing init.sql..."

# Execute the init script
if [ ! -f "/init.sql" ]; then
    error "init.sql not found at /init.sql"
fi

PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f /init.sql > /tmp/init_output.log 2>&1

if [ $? -ne 0 ]; then
    error "Failed to execute init.sql"
fi

log "✓ init.sql executed successfully"
log ""
log "Database Statistics After Initialization:"

# Show table statistics
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME << 'QUERY'
    \echo 'Users Table:'
    SELECT 'Total records: ' || count(*) FROM users;
    \echo ''
    \echo 'Nodes Table:'
    SELECT 'Total records: ' || count(*) FROM nodes;
    \echo ''
    \echo 'Messages Table:'
    SELECT 'Total records: ' || count(*) FROM messages;
QUERY

log ""
log "========================================"
log "✓ Database initialization completed successfully!"
log "========================================"
log "Logs saved to: /tmp/init.log"
