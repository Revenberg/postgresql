#!/bin/bash
set -e

echo "=== PostgreSQL Read-Only Replica Initialization ==="
echo "Waiting for primary to accept connections..."

counter=0
while ! PGPASSWORD=replpass psql -h pg-node-1 -U replicator -d appdb -c "SELECT 1" >/dev/null 2>&1; do
    counter=$((counter + 1))
    if [ $counter -gt 60 ]; then
        echo "ERROR: Primary did not become available after 60 retries"
        exit 1
    fi
    echo "Attempt $counter/60: Waiting for primary..."
    sleep 2
done

echo "✓ Primary is ready!"
echo "Creating base backup..."

rm -rf /var/lib/postgresql/data/*

if PGPASSWORD=replpass pg_basebackup -h pg-node-1 -D /var/lib/postgresql/data -U replicator -v -P -R; then
    echo "✓ Base backup completed successfully"
else
    echo "ERROR: Base backup failed"
    exit 1
fi

echo "Starting PostgreSQL as read-only replica..."
exec /usr/local/bin/docker-entrypoint.sh postgres -c hot_standby=on -c listen_addresses="*" -c log_statement=all
