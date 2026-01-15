#!/bin/bash
#
# Failover script to switch from postgres-primary to postgres-secondary
# Usage: ./failover.sh [--reset-primary] [--force] [--debug]
#

set -e

RESET_PRIMARY=false
FORCE=false
DEBUG=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --reset-primary)
            RESET_PRIMARY=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --debug)
            DEBUG=true
            set -x
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Debug function
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "[DEBUG $(date +'%H:%M:%S')] $@" >&2
    fi
}

echo "========================================"
echo "PostgreSQL Failover: Primary → Secondary"
echo "========================================"
debug "Reset Primary: $RESET_PRIMARY"
debug "Force: $FORCE"
debug "Debug Mode: ON"
echo ""

# Step 1: Check current recovery status
echo "[1/5] Checking current primary status..."
debug "Executing: docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \"SELECT pg_is_in_recovery();\""
if docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();" 2>&1 | grep -q "f"; then
    echo "✓ postgres-primary is confirmed as PRIMARY (not in recovery)"
    debug "postgres-primary recovery status: false (PRIMARY)"
else
    echo "⚠ postgres-primary may already be a replica"
    debug "postgres-primary recovery status: true (REPLICA/STANDBY)"
fi

debug "Executing: docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c \"SELECT pg_is_in_recovery();\""
if docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();" 2>&1 | grep -q "t"; then
    echo "✓ postgres-secondary is confirmed as STANDBY/REPLICA (in recovery)"
    debug "postgres-secondary recovery status: true (STANDBY/REPLICA)"
else
    echo "⚠ postgres-secondary may already be a primary"
    debug "postgres-secondary recovery status: false (PRIMARY)"
    if [ "$FORCE" != "true" ]; then
        echo "Use --force to override"
        debug "Exiting: --force not provided"
        exit 1
    fi
fi

echo ""

# Step 2: Promote secondary to primary
echo "[2/5] Promoting postgres-secondary to PRIMARY..."
debug "Executing: docker exec postgres-secondary pg_ctl promote -D /var/lib/postgresql/data/pgdata"
docker exec postgres-secondary pg_ctl promote -D /var/lib/postgresql/data/pgdata
echo "✓ Promotion command sent"

# Wait for promotion to complete
echo "✓ Waiting for promotion to complete..."
debug "Sleeping 10 seconds for promotion..."
sleep 10

echo ""

# Step 3: Verify secondary is now primary
echo "[3/5] Verifying postgres-secondary is now PRIMARY..."
debug "Executing: docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c \"SELECT pg_is_in_recovery();\""
if docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();" 2>&1 | grep -q "f"; then
    echo "✓ postgres-secondary is now confirmed as PRIMARY"
    debug "Promotion verified: recovery status is false"
else
    echo "❌ Promotion may have failed - check logs:"
    debug "ERROR: Promotion failed - recovery status is still true"
    docker logs postgres-secondary --tail 20
    debug "Exiting with error code 1"
    exit 1
fi

echo ""

# Step 4: Check replication to other replicas
echo "[4/5] Checking replication status from new PRIMARY..."
debug "Querying replication status..."
debug "Executing: docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c \"SELECT client_addr, state, sync_state FROM pg_stat_replication;\""
echo "Replication status:"
docker exec -e PGPASSWORD=securepwd123 postgres-secondary psql -U testadmin -d testdb -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

echo ""

# Step 5: Reset primary as replica (optional)
if [ "$RESET_PRIMARY" = "true" ]; then
    echo "[5/5] Resetting postgres-primary as REPLICA..."
    debug "Reset Primary flag is enabled - proceeding with reset"
    
    cd "$(dirname "$0")"
    debug "Changed directory to: $(pwd)"
    
    echo "Stopping postgres-primary..."
    debug "Executing: docker-compose down postgres-primary"
    docker-compose down postgres-primary
    debug "postgres-primary stopped"
    
    echo "Removing postgres-primary data volume..."
    debug "Executing: docker volume rm postgresql_postgres_primary_data"
    docker volume rm postgresql_postgres_primary_data
    debug "Volume removed"
    
    sleep 3
    debug "Slept 3 seconds"
    
    echo "Starting postgres-primary (will pull basebackup from secondary)..."
    debug "Executing: docker-compose up -d postgres-primary"
    docker-compose up -d postgres-primary
    debug "postgres-primary startup command issued"
    
    echo "Waiting for postgres-primary to initialize as replica..."
    debug "Sleeping 45 seconds for initialization..."
    sleep 45
    debug "Initialization wait complete"
    
    # Verify
    echo "Verifying postgres-primary is now REPLICA..."
    debug "Executing: docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \"SELECT pg_is_in_recovery();\""
    if docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();" 2>&1 | grep -q "t"; then
        echo "✓ postgres-primary is now confirmed as REPLICA"
        debug "postgres-primary verified as REPLICA"
    else
        echo "⚠ postgres-primary verification inconclusive"
        debug "WARNING: postgres-primary recovery status verification inconclusive"
    fi
else
    echo "[5/5] Skipped resetting postgres-primary (use --reset-primary to enable)"
    debug "Reset Primary flag is disabled - skipping reset step"
fi

echo ""
echo "========================================"
echo "Failover Complete!"
echo "========================================"
debug "Failover process completed successfully"
echo ""
echo "NEW TOPOLOGY:"
echo "  postgres-secondary (5435) ← PRIMARY (WAS STANDBY)"
echo "  postgres-primary (5432) ← STANDBY (WAS PRIMARY)"
echo "  postgres-replica-1 (5433) ← STANDBY"
echo "  postgres-replica-2 (5434) ← STANDBY"
echo ""
echo "UPDATE YOUR CONNECTION STRINGS TO:"
echo "  postgresql://testadmin:securepwd123@postgres-secondary:5435/testdb"
echo ""
debug "Use --debug flag to enable verbose output on next run"
