#!/bin/bash
set -e

PGDATA="/var/lib/postgresql/data"
RECOVERY_SIGNAL="$PGDATA/standby.signal"
NODE_TYPE="${NODE_TYPE:-backup}"

echo "============================================================"
echo "PostgreSQL Node Startup"
echo "Node Type: $NODE_TYPE"
echo "Container: $(hostname)"
echo "============================================================"

# Create PGDATA if needed
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

# Configure standby.signal for non-primary nodes
if [ "$NODE_TYPE" = "replica" ]; then
    echo "Setting up as REPLICA (read-only standby)..."
    # Touch standby.signal ONLY if dir is empty (fresh init)
    if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
        touch "$RECOVERY_SIGNAL"
        chmod 600 "$RECOVERY_SIGNAL"
    fi
fi

echo "Starting PostgreSQL..."
exec /usr/local/bin/docker-entrypoint.sh postgres
