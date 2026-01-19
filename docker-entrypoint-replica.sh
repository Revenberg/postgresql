#!/bin/bash
set -e

PGDATA="/var/lib/postgresql/data"
RECOVERY_SIGNAL="$PGDATA/standby.signal"
POSTGRESQL_CONF="$PGDATA/postgresql.conf"

# Get node type from environment variable (default to 'backup' for backward compatibility)
NODE_TYPE="${NODE_TYPE:-backup}"
HOSTNAME=$(hostname)

echo "=================================================="
echo "PostgreSQL Streaming Replication Entrypoint (Replica)"
echo "Container: $HOSTNAME"
echo "Node Type: $NODE_TYPE"
echo "PGDATA: $PGDATA"
echo "=================================================="

# Function to check if PostgreSQL cluster exists
cluster_exists() {
    [ -f "$PGDATA/PG_VERSION" ]
}

# Function to clean cluster
clean_cluster() {
    echo "🔄 Resetting PostgreSQL cluster..."
    if [ -d "$PGDATA" ]; then
        rm -rf "$PGDATA"/*
        echo "✓ Cluster data removed"
    fi
}

# Function to try to find primary node
find_primary() {
    local primary_candidates=("postgres-node2" "postgres-node1" "postgres-node3")
    for candidate in "${primary_candidates[@]}"; do
        # Simple pg_isready check
        if timeout 2 pg_isready -h "$candidate" -p 5432 -U "$POSTGRES_USER" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Step 1: Initialize cluster or copy from primary
echo "Step 1: Initializing cluster..."

if cluster_exists; then
    echo "✓ PostgreSQL cluster exists locally"
else
    echo "ℹ No local cluster found"
    
    # First time startup: try brief check for running primary
    PRIMARY=$(find_primary)
    if [ -n "$PRIMARY" ]; then
        echo "✓ Found primary: $PRIMARY - attempting pg_basebackup..."
        
        mkdir -p ~/.postgresql
        echo "$PRIMARY:5432:*:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.postgresql/pgpass
        chmod 600 ~/.postgresql/pgpass
        
        if pg_basebackup -h "$PRIMARY" -D "$PGDATA" -U "$POSTGRES_USER" -v -P -W 2>&1 | tee /tmp/basebackup.log; then
            echo "✓ Base backup successful"
        else
            echo "⚠ Base backup failed - fresh initialization"
            clean_cluster
            /usr/local/bin/docker-entrypoint.sh postgres --initialize-only > /tmp/pg_init.log 2>&1 || true
        fi
    else
        echo "ℹ No primary found - fresh initialization as read-only replica"
        /usr/local/bin/docker-entrypoint.sh postgres --initialize-only > /tmp/pg_init.log 2>&1 || true
    fi
fi

# Step 2: Configure streaming replication parameters
echo "Step 2: Configuring replication settings..."

# Backup original postgresql.conf if exists
if [ -f "$POSTGRESQL_CONF" ]; then
    cp "$POSTGRESQL_CONF" "$POSTGRESQL_CONF.orig"
fi

# Append replication settings
cat >> "$POSTGRESQL_CONF" << 'EOF'

# ===== STREAMING REPLICATION SETTINGS =====
# WAL configuration
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 1GB

# Standby settings
hot_standby = on
hot_standby_feedback = on
max_standby_streaming_delay = 300s

# Recovery settings
recovery_target_timeline = 'latest'
EOF

echo "✓ Replication settings configured"

# Step 3: Configure node mode (replica = locked standby)
echo "Step 3: Configuring replica mode..."

if [ "$NODE_TYPE" = "replica" ]; then
    echo "   This is a REPLICA node (locked standby, cannot be promoted)"
    touch "$RECOVERY_SIGNAL"
    chmod 600 "$RECOVERY_SIGNAL"
    
    # Create recovery.conf
    cat > "$PGDATA/recovery.conf" << EOF
standby_mode = on
primary_conninfo = 'host=postgres-node2 port=5432 user=$POSTGRES_USER password=$POSTGRES_PASSWORD application_name=$HOSTNAME'
recovery_target_timeline = 'latest'
EOF
    chmod 600 "$PGDATA/recovery.conf"
    echo "✓ REPLICA mode: locked as standby"
else
    echo "   This is a BACKUP REPLICA node"
    rm -f "$RECOVERY_SIGNAL"
    rm -f "$PGDATA/recovery.conf"
fi

# Step 4: Start PostgreSQL
echo "Step 4: Starting PostgreSQL in streaming replication mode..."
exec /usr/local/bin/docker-entrypoint.sh postgres
    echo "  Status: REPLICA (standby locked, cannot be promoted)"
else
    echo "✓ PostgreSQL BACKUP node is ready"
    echo "  Status: BACKUP (can be promoted to PRIMARY)"
fi
echo "  Hostname: $(hostname)"
echo "  User: $POSTGRES_USER"
echo "  Port: 5432"
echo "=================================================="
echo ""

# Keep the process running
wait $PG_PID
