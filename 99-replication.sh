#!/bin/bash
# Wait for PostgreSQL to be ready and add replication rules to pg_hba.conf

sleep 2

# Append replication rules to pg_hba.conf
PG_HBA_FILE="/var/lib/postgresql/data/pgdata/pg_hba.conf"

if [ -f "$PG_HBA_FILE" ]; then
    echo "" >> "$PG_HBA_FILE"
    echo "# PostgreSQL Host Based Authentication for Replication" >> "$PG_HBA_FILE"
    echo "host    replication     all     0.0.0.0/0               md5" >> "$PG_HBA_FILE"
    echo "Replication rules added to pg_hba.conf"
    
    # Signal PostgreSQL to reload configuration
    if command -v pg_ctl &> /dev/null; then
        pg_ctl reload -D /var/lib/postgresql/data/pgdata || true
    fi
else
    echo "Warning: pg_hba.conf not found at $PG_HBA_FILE"
fi
