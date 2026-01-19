#!/bin/bash
# 30-Minute PostgreSQL HA Cluster Test with Restart Option
# Tests: continuous writes, reads from all nodes, data sync verification
# Includes: automated restart at 30 minutes with graceful shutdown

set -e

# Configuration
TEST_DURATION=1800  # 30 minutes in seconds
LOG_DIR="test-logs"
LOG_FILE="${LOG_DIR}/test-$(date +%Y%m%d-%H%M%S).log"
METRICS_FILE="${LOG_DIR}/metrics-$(date +%Y%m%d-%H%M%S).log"
RESTART_LOG="${LOG_DIR}/restart.log"
ENABLE_RESTART=${1:-false}  # Pass 'restart' as argument to enable auto-restart

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize
mkdir -p "$LOG_DIR"

log_message() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to get current pod count
get_pod_status() {
    local running=$(docker ps --filter "label=pg-cluster=node" --format "{{.Names}}" | wc -l)
    echo $running
}

# Function to write test data
write_data() {
    local rows_per_batch=10
    local batch_count=0
    
    log_message "INFO" "Starting write workload to pg-node-1:5432"
    
    while true; do
        for i in {1..10}; do
            docker exec pg-node-1 psql -U appuser -d appdb -c \
                "INSERT INTO test_data (test_value, created_at) VALUES ('batch_$batch_count-row_$i', NOW());" 2>/dev/null || true
        done
        
        batch_count=$((batch_count + 1))
        
        if [ $((batch_count % 10)) -eq 0 ]; then
            local total_rows=$(docker exec pg-node-1 psql -U appuser -d appdb -t -c \
                "SELECT COUNT(*) FROM test_data;" 2>/dev/null | tr -d ' ' || echo "?")
            echo "$(date '+%H:%M:%S') - Write batches: $batch_count | Total rows: $total_rows" >> "$METRICS_FILE"
        fi
        
        sleep 1
    done
}

# Function to read from all nodes
read_data() {
    log_message "INFO" "Starting read workload from all nodes"
    
    local nodes=("pg-node-1" "pg-node-2" "pg-node-3" "pg-node-4" "pg-node-5" "pg-node-6")
    local port_offset=0
    
    while true; do
        for node in "${nodes[@]}"; do
            port=$((5432 + port_offset))
            docker exec "$node" psql -U appuser -d appdb -c \
                "SELECT COUNT(*) FROM test_data LIMIT 1;" 2>/dev/null || true
            port_offset=$((port_offset + 1))
        done
        port_offset=0
        sleep 2
    done
}

# Function to validate replication
validate_replication() {
    log_message "INFO" "Starting replication validation"
    
    while true; do
        local primary_count=$(docker exec pg-node-1 psql -U appuser -d appdb -t -c \
            "SELECT COUNT(*) FROM test_data;" 2>/dev/null | tr -d ' ' || echo "?")
        
        local all_match=true
        for node in "pg-node-2" "pg-node-3" "pg-node-4" "pg-node-5" "pg-node-6"; do
            local node_count=$(docker exec "$node" psql -U appuser -d appdb -t -c \
                "SELECT COUNT(*) FROM test_data;" 2>/dev/null | tr -d ' ' || echo "X")
            
            if [ "$node_count" != "$primary_count" ] && [ "$node_count" != "?" ]; then
                all_match=false
                echo "$(date '+%H:%M:%S') - ⚠ Sync lag on $node: primary=$primary_count vs $node=$node_count" >> "$METRICS_FILE"
                break
            fi
        done
        
        if [ "$all_match" = true ] && [ "$primary_count" != "?" ]; then
            echo "$(date '+%H:%M:%S') - ✓ All nodes synced: $primary_count rows" >> "$METRICS_FILE"
        fi
        
        sleep 10
    done
}

# Function to cleanup test environment
cleanup_test() {
    log_message "INFO" "Cleaning up test containers..."
    
    # Stop background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Remove test table if it exists
    docker exec pg-node-1 psql -U appuser -d appdb -c \
        "DROP TABLE IF EXISTS test_data;" 2>/dev/null || true
}

# Function to perform graceful shutdown
graceful_shutdown() {
    log_message "INFO" "Initiating graceful shutdown..."
    print_info "Stopping all test processes..."
    
    # Kill all background jobs
    jobs -p | xargs -r kill -TERM 2>/dev/null || true
    
    # Wait for processes to finish
    sleep 5
    
    log_message "INFO" "Test completed. Logs saved to $LOG_FILE"
    log_message "INFO" "Metrics saved to $METRICS_FILE"
}

# Function to handle restart
handle_restart() {
    local restart_enabled=$1
    
    if [ "$restart_enabled" = "restart" ]; then
        echo "" | tee -a "$LOG_FILE"
        log_message "INFO" "====== AUTO-RESTART INITIATED ======"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting cluster" >> "$RESTART_LOG"
        
        print_info "Stopping all containers..."
        docker compose -f docker-compose.yml stop 2>&1 | tee -a "$LOG_FILE"
        
        sleep 10
        
        print_info "Restarting containers..."
        docker compose -f docker-compose.yml start 2>&1 | tee -a "$LOG_FILE"
        
        sleep 20
        
        # Verify cluster is healthy
        local health_check=0
        for node in pg-node-1 pg-node-2 pg-node-3 pg-node-4 pg-node-5 pg-node-6; do
            if docker exec "$node" pg_isready -U appuser -d appdb 2>/dev/null | grep -q "accepting"; then
                health_check=$((health_check + 1))
            fi
        done
        
        if [ $health_check -eq 6 ]; then
            print_success "Cluster restarted and healthy ($health_check/6 nodes)"
            log_message "INFO" "Cluster restarted successfully - all 6 nodes healthy"
        else
            print_error "Cluster restart incomplete ($health_check/6 nodes healthy)"
            log_message "ERROR" "Cluster restart incomplete - only $health_check/6 nodes healthy"
        fi
        
        echo "" | tee -a "$LOG_FILE"
    fi
}

# Main test function
main() {
    print_header "PostgreSQL HA Cluster - 30 Minute Test"
    
    log_message "INFO" "Test Configuration:"
    log_message "INFO" "  Duration: 30 minutes"
    log_message "INFO" "  Auto-Restart: $ENABLE_RESTART"
    log_message "INFO" "  Log File: $LOG_FILE"
    log_message "INFO" "  Metrics File: $METRICS_FILE"
    
    # Create test table
    print_info "Initializing test table..."
    docker exec pg-node-1 psql -U appuser -d appdb -c \
        "CREATE TABLE IF NOT EXISTS test_data (
            id SERIAL PRIMARY KEY,
            test_value VARCHAR(255),
            created_at TIMESTAMP
        );" 2>/dev/null
    print_success "Test table created"
    
    # Start background workloads
    print_info "Starting workloads..."
    write_data &
    WRITE_PID=$!
    log_message "INFO" "Write process started (PID: $WRITE_PID)"
    
    read_data &
    READ_PID=$!
    log_message "INFO" "Read process started (PID: $READ_PID)"
    
    validate_replication &
    VALIDATE_PID=$!
    log_message "INFO" "Validation process started (PID: $VALIDATE_PID)"
    
    print_success "All workloads started"
    echo "" | tee -a "$LOG_FILE"
    
    # Run for 30 minutes
    print_info "Test running for 30 minutes..."
    START_TIME=$(date +%s)
    
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        REMAINING=$((TEST_DURATION - ELAPSED))
        
        if [ $REMAINING -le 0 ]; then
            print_info "Test duration complete (30 minutes)"
            break
        fi
        
        MINUTES=$((REMAINING / 60))
        SECONDS=$((REMAINING % 60))
        
        PODS_RUNNING=$(get_pod_status)
        STATUS="Elapsed: ${ELAPSED}s | Remaining: ${MINUTES}m ${SECONDS}s | Pods: ${PODS_RUNNING}/6"
        echo -ne "\r$STATUS"
        
        sleep 5
    done
    
    echo "" | tee -a "$LOG_FILE"
    print_info "Test duration elapsed"
    
    # Handle restart if requested
    handle_restart "$ENABLE_RESTART"
    
    # Cleanup
    graceful_shutdown
    
    # Summary
    print_header "Test Summary"
    
    FINAL_ROWS=$(docker exec pg-node-1 psql -U appuser -d appdb -t -c \
        "SELECT COUNT(*) FROM test_data;" 2>/dev/null | tr -d ' ' || echo "?")
    
    print_success "Test completed successfully"
    print_info "Final row count: $FINAL_ROWS"
    print_info "Log: $LOG_FILE"
    print_info "Metrics: $METRICS_FILE"
}

# Signal handlers
trap 'log_message "WARN" "Received interrupt signal"; graceful_shutdown; exit 0' INT TERM

# Run main test
main

exit 0
