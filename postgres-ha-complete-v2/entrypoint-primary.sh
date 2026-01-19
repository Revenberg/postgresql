#!/bin/bash
set -e

echo "=== PostgreSQL Primary Node Initialization ==="

# Start PostgreSQL to perform initialization
/usr/local/bin/docker-entrypoint.sh postgres "$@" &
PG_PID=$!

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
for i in {1..60}; do
    if pg_isready -U appuser -d appdb >/dev/null 2>&1; then
        echo "✓ PostgreSQL started"
        break
    fi
    echo "Attempt $i/60..."
    sleep 1
done

# Initialize databases and create replication user
echo "Initializing primary database..."
PGPASSWORD=apppass psql -h localhost -U appuser -d appdb -f /docker-entrypoint-initdb.d/init.sql >/dev/null 2>&1 || true

# Configure pg_hba.conf for replication
echo "Configuring pg_hba.conf for replication..."
PG_DATA="/var/lib/postgresql/data"

# Append replication entries to pg_hba.conf (after existing host entries)
cat >> "$PG_DATA/pg_hba.conf" <<EOF

# Replication connections
host    replication     replicator      0.0.0.0/0               md5
host    replication     replicator      ::/0                    md5
host    all             appuser         0.0.0.0/0               md5
host    all             appuser         ::/0                    md5
EOF

echo "✓ pg_hba.conf updated"

# Reload PostgreSQL configuration
echo "Reloading PostgreSQL configuration..."
PGPASSWORD=apppass psql -h localhost -U appuser -d postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1

echo "✓ Primary initialization complete"

# Wait for primary process to finish
wait $PG_PID
