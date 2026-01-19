#!/bin/bash
export PGPASSWORD=apppass

echo "=== Starting Cluster Validation ==="
while true; do
  clear
  echo "=== Cluster Sync Status $(date) ==="
  echo ""
  echo "Primary (pg-primary:5432):"
  psql -h pg-primary -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  echo "Backup1 (pg-backup1:5433):"
  psql -h pg-backup1 -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  echo "Backup2 (pg-backup2:5434):"
  psql -h pg-backup2 -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  echo "RO1 (pg-ro1:5440):"
  psql -h pg-ro1 -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  echo "RO2 (pg-ro2:5441):"
  psql -h pg-ro2 -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  echo "RO3 (pg-ro3:5442):"
  psql -h pg-ro3 -U appuser -d appdb -t -c "SELECT COUNT(*) as rows FROM sync_test;" 2>/dev/null || echo "Unavailable"
  echo ""
  sleep 10
done
