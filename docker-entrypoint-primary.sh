#!/bin/bash
set -e

# Start PostgreSQL in the background
/usr/local/bin/docker-entrypoint.sh postgres &
PG_PID=$!

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to start..."
for i in {1..60}; do
    if pg_isready -U postgres > /dev/null 2>&1; then
        echo "✓ PostgreSQL is ready!"
        sleep 1  # Give it another second to fully initialize
        break
    fi
    if [ $i -eq 60 ]; then
        echo "✗ PostgreSQL failed to start after 60 seconds"
        kill $PG_PID
        exit 1
    fi
    sleep 1
done

# Add replication rules to pg_hba.conf
PG_HBA_FILE="/var/lib/postgresql/data/pgdata/pg_hba.conf"

if [ -f "$PG_HBA_FILE" ]; then
    echo "Adding replication rules to pg_hba.conf..."
    
    # Append replication rules to pg_hba.conf
    cat >> "$PG_HBA_FILE" << 'EOF'

# PostgreSQL Host Based Authentication for Replication
host    replication     all     0.0.0.0/0               md5
EOF
    
    echo "✓ Replication rules added to pg_hba.conf"
    
    # Reload PostgreSQL configuration
    kill -HUP $PG_PID || true
    sleep 1
    echo "✓ PostgreSQL configuration reloaded"
else
    echo "⚠ Warning: pg_hba.conf not found at $PG_HBA_FILE"
fi

# Keep the PostgreSQL process running
wait $PG_PID
