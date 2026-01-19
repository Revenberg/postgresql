#!/bin/bash
echo "Starting read workload..."
while true; do
  for ro in pg-ro1 pg-ro2 pg-ro3; do
    echo "Checking $ro..."
    psql -h $ro -U appuser -d appdb -c "SELECT COUNT(*) FROM sync_test;" 2>/dev/null || echo "Read from $ro failed"
  done
  sleep 2
done
