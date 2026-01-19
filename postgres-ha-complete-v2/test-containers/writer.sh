#!/bin/bash
export PGPASSWORD=apppass

echo "Starting write workload..."
counter=1
while true; do
  psql -h pg-primary -U appuser -d appdb -c "INSERT INTO sync_test (data) VALUES ('write-$counter-$(date +%s)');" 2>/dev/null && echo "Write $counter OK" || echo "Write $counter FAILED"
  ((counter++))
  sleep 1
done
