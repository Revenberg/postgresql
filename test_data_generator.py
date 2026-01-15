#!/usr/bin/env python3
"""
Test data generator for PostgreSQL
Inserts random entries into the messages table for 5 minutes
"""

import psycopg2
import random
import time
import sys
from datetime import datetime
import os

# Database connection parameters
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'postgres-primary'),
    'port': int(os.getenv('DB_PORT', 5432)),
    'user': os.getenv('DB_USER', 'testadmin'),
    'password': os.getenv('DB_PASSWORD', 'securepwd123'),
    'database': os.getenv('DB_NAME', 'testdb')
}

def log(message):
    """Log message with timestamp"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)
    sys.stdout.flush()

def wait_for_database(max_retries=30):
    """Wait for database to be available"""
    log("Waiting for PostgreSQL database...")
    for attempt in range(max_retries):
        try:
            log(f"  Connection attempt {attempt + 1}/{max_retries}...")
            conn = psycopg2.connect(**DB_CONFIG, connect_timeout=3)
            conn.close()
            log("✓ Database connection successful")
            return True
        except psycopg2.Error as e:
            log(f"  Attempt {attempt + 1} failed: {type(e).__name__}: {str(e)[:100]}")
            time.sleep(1)
    log("✗ Failed to connect to database after multiple attempts")
    return False

def insert_random_message():
    """Insert a random message into the messages table"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()
        
        # Node IDs from init.sql
        node_ids = ['NODE001', 'NODE002', 'NODE003']
        from_node = random.choice(node_ids)
        to_node = random.choice(node_ids)
        
        # Make sure from and to are different
        while to_node == from_node:
            to_node = random.choice(node_ids)
        
        # Random message content
        messages = [
            "Status update from node",
            "Alert: High temperature detected",
            "Battery level low",
            "Sensor reading: 42.5°C",
            "Network quality: excellent",
            "Heartbeat signal",
            "Data sync completed",
            "Waiting for response",
            "Test message from automation",
            "Replication test data"
        ]
        message = random.choice(messages)
        
        # Random RSSI value (-100 to -30)
        rssi = random.randint(-100, -30)
        
        cur.execute("""
            INSERT INTO messages (from_node_id, to_node_id, message_text, rssi)
            VALUES (%s, %s, %s, %s)
        """, (from_node, to_node, message, rssi))
        
        conn.commit()
        cur.close()
        conn.close()
        
        log(f"✓ Inserted message: Node {from_node} → Node {to_node}: '{message}' (RSSI: {rssi})")
        
        return True
    except psycopg2.Error as e:
        log(f"✗ Error inserting message: {type(e).__name__}: {str(e)[:200]}")
        return False
    except Exception as e:
        log(f"✗ Unexpected error: {type(e).__name__}: {str(e)[:200]}")
        return False

def main():
    log("=" * 70)
    log("PostgreSQL Test Data Generator")
    log("=" * 70)
    log(f"Configuration:")
    log(f"  Host: {DB_CONFIG['host']}")
    log(f"  Port: {DB_CONFIG['port']}")
    log(f"  User: {DB_CONFIG['user']}")
    log(f"  Database: {DB_CONFIG['database']}")
    log("")
    
    if not wait_for_database():
        log("✗ FATAL: Failed to connect to database after multiple attempts")
        sys.exit(1)
    
    log("Starting random data insertion for 5 minutes...")
    log("=" * 70)
    
    start_time = time.time()
    duration = 5 * 60  # 5 minutes in seconds
    insert_interval = 2  # Insert every 2 seconds
    inserted_count = 0
    failed_count = 0
    
    try:
        while True:
            elapsed = time.time() - start_time
            
            if elapsed >= duration:
                break
            
            if insert_random_message():
                inserted_count += 1
            else:
                failed_count += 1
            
            time.sleep(insert_interval)
        
        log("=" * 70)
        log(f"✓ Test completed!")
        log(f"  Total inserted: {inserted_count}")
        log(f"  Total failed: {failed_count}")
        log(f"  Duration: {duration // 60} minutes")
        log("=" * 70)
        sys.exit(0)
        
    except KeyboardInterrupt:
        log("")
        log("=" * 70)
        log("✓ Test stopped by user")
        log(f"  Total inserted: {inserted_count}")
        log(f"  Total failed: {failed_count}")
        log("=" * 70)
        sys.exit(0)
    except Exception as e:
        log(f"✗ Fatal error: {type(e).__name__}: {str(e)}")
        log("=" * 70)
        sys.exit(1)

if __name__ == '__main__':
    main()
