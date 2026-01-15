#!/bin/bash
set -e

# Database connection parameters
DB_HOST="${DB_HOST:-postgres-primary}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-testadmin}"
DB_PASSWORD="${DB_PASSWORD:-securepwd123}"
DB_NAME="${DB_NAME:-testdb}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a /tmp/init.log
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR${NC} $1" | tee -a /tmp/init.log
    exit 1
}

info() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a /tmp/init.log
}

log "========================================"
log "PostgreSQL Database Initializer"
log "========================================"
log "Host: $DB_HOST:$DB_PORT"
log "Database: $DB_NAME"
log "User: $DB_USER"
log ""

# Wait for database to be available
log "Waiting for PostgreSQL to be ready..."
max_attempts=30
attempt=1

while [ $attempt -le $max_attempts ]; do
    if PGPASSWORD=$DB_PASSWORD pg_isready -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME > /dev/null 2>&1; then
        log "✓ PostgreSQL is ready!"
        break
    fi
    info "Attempt $attempt/$max_attempts..."
    attempt=$((attempt + 1))
    sleep 1
done

if [ $attempt -gt $max_attempts ]; then
    error "Failed to connect to PostgreSQL after $max_attempts attempts"
fi

log ""
log "Checking if initialization is needed..."

# Check if tables already exist
tables_exist=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_name IN ('users', 'nodes', 'messages')
" 2>/dev/null || echo "0")

if [ "$tables_exist" = "3" ]; then
    log "✓ All tables already exist - skipping initialization"
    log ""
    
    # Show table statistics
    log "Database Statistics:"
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME << 'QUERY'
        SELECT tablename, 
               (SELECT count(*) FROM users) as users_count,
               (SELECT count(*) FROM nodes) as nodes_count,
               (SELECT count(*) FROM messages) as messages_count
        FROM pg_tables
        WHERE schemaname = 'public'
        LIMIT 1;
QUERY
    
    log ""
    log "========================================"
    log "✓ Initialization skipped - database already initialized"
    log "========================================"
    exit 0
fi

log "✓ Tables do not exist - proceeding with initialization"
log ""
log "Executing init.sql..."

# Execute the init script
if [ ! -f "/init.sql" ]; then
    error "init.sql not found at /init.sql"
fi

PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f /init.sql > /tmp/init_output.log 2>&1

if [ $? -ne 0 ]; then
    error "Failed to execute init.sql"
fi

log "✓ init.sql executed successfully"
log ""
log "Database Statistics After Initialization:"

# Show table statistics
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME << 'QUERY'
    \echo 'Users Table:'
    SELECT 'Total records: ' || count(*) FROM users;
    \echo ''
    \echo 'Nodes Table:'
    SELECT 'Total records: ' || count(*) FROM nodes;
    \echo ''
    \echo 'Messages Table:'
    SELECT 'Total records: ' || count(*) FROM messages;
QUERY

log ""
log "========================================"
log "✓ Database initialization completed successfully!"
log "========================================"
log "Logs saved to: /tmp/init.log"
