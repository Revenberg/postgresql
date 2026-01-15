#!/bin/bash
# Entrypoint script for PostgreSQL primary with replication setup

set -e

# Initialize PostgreSQL if needed
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "Initializing PostgreSQL data directory..."
    initdb --username="$POSTGRES_USER" --pgdata="$PGDATA"
fi

# Add replication authentication to pg_hba.conf
if ! grep -q "replication" "$PGDATA/pg_hba.conf"; then
    echo "Adding replication authentication..."
    echo "host    replication     all     postgres-replica     md5" >> "$PGDATA/pg_hba.conf"
fi

# Start PostgreSQL
exec postgres
