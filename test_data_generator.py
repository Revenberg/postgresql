#!/usr/bin/env python3
"""
Test data generator for PostgreSQL
- Finds primary host from operationManagement API
- Creates all necessary tables
- Inserts test data at high speed
"""

import psycopg2
import random
import time
import sys
import requests
from datetime import datetime
import os

# Database connection parameters
DB_CONFIG = {
    'user': os.getenv('DB_USER', 'testadmin'),
    'password': os.getenv('DB_PASSWORD', 'securepwd123'),
    'database': os.getenv('DB_NAME', 'testdb'),
    'port': 5432,
    'host': None  # Will be determined dynamically
}

API_URL = os.getenv('OPERATIONMANAGEMENT_URL', 'http://operationManagement:5001')

def log(message):
    """Log message with timestamp"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)
    sys.stdout.flush()

def debug(message):
    """Log debug message"""
    log(f"  DEBUG: {message}")

def find_primary_host(max_retries=30):
    """Find the primary host from operationManagement API"""
    log("Finding primary host from operationManagement API...")
    log(f"  API URL: {API_URL}/api/operationmanagement/overview")
    
    for attempt in range(max_retries):
        try:
            log(f"  API attempt {attempt + 1}/{max_retries} (timeout: 10s)...")
            response = requests.get(f"{API_URL}/api/operationmanagement/overview", timeout=10)
            if response.status_code == 200:
                data = response.json()
                log(f"  API Response: {str(data)[:200]}")
                # Find the container for this primary
                for node in data.get('nodes', []):
                    if node.get('is_primary') == True:
                        primary_name = node.get('name')
                        host = node.get('container')
                        log(f"✓ Found primary: {primary_name} (container: {host})")
                        return host
                log(f"  No primary node found in response, retrying...")
            else:
                log(f"  API returned {response.status_code}, retrying...")
                log(f"  Response: {response.text[:200]}")
        except requests.exceptions.Timeout as e:
            log(f"  API Timeout error: {type(e).__name__}")
        except requests.exceptions.ConnectionError as e:
            log(f"  API Connection error: {type(e).__name__}: {str(e)[:100]}")
        except Exception as e:
            log(f"  API Exception: {type(e).__name__}: {str(e)[:100]}")
        
        if attempt < max_retries - 1:
            log(f"  Waiting 2 seconds before retry...")
            time.sleep(2)
        else:
            time.sleep(1)
    
    log("✗ Failed to find primary host")
    return None

def create_tables(conn):
    """Create all necessary tables if they don't exist"""
    try:
        cur = conn.cursor()
        
        debug("Creating 'nodes' table if not exists...")
        # Create nodes table
        cur.execute("""
            CREATE TABLE IF NOT EXISTS nodes (
                node_id VARCHAR(50) PRIMARY KEY,
                node_name VARCHAR(255),
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        debug("'nodes' table created/verified")
        
        debug("Creating 'messages' table if not exists...")
        # Create messages table
        cur.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id SERIAL PRIMARY KEY,
                from_node_id VARCHAR(50) NOT NULL,
                to_node_id VARCHAR(50) NOT NULL,
                message_text TEXT,
                rssi INT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (from_node_id) REFERENCES nodes(node_id) ON DELETE CASCADE,
                FOREIGN KEY (to_node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
            )
        """)
        debug("'messages' table created/verified")
        
        debug("Inserting sample nodes...")
        # Insert sample nodes if they don't exist
        cur.execute("INSERT INTO nodes (node_id, node_name) VALUES (%s, %s) ON CONFLICT DO NOTHING", ('NODE001', 'Node 1'))
        cur.execute("INSERT INTO nodes (node_id, node_name) VALUES (%s, %s) ON CONFLICT DO NOTHING", ('NODE002', 'Node 2'))
        cur.execute("INSERT INTO nodes (node_id, node_name) VALUES (%s, %s) ON CONFLICT DO NOTHING", ('NODE003', 'Node 3'))
        
        conn.commit()
        log("✓ Tables created/verified successfully")
        cur.close()
        return True
    except psycopg2.Error as e:
        log(f"✗ Error creating tables: {type(e).__name__}: {str(e)[:200]}")
        return False

def wait_for_database(max_retries=30):
    """Wait for database to be available"""
    log(f"Waiting for PostgreSQL database at {DB_CONFIG['host']}...")
    for attempt in range(max_retries):
        try:
            log(f"  Connection attempt {attempt + 1}/{max_retries}...")
            conn = psycopg2.connect(**DB_CONFIG, connect_timeout=3)
            conn.close()
            log("✓ Database connection successful")
            return True
        except psycopg2.Error as e:
            log(f"  Attempt {attempt + 1} failed: {type(e).__name__}: {str(e)[:150]}")
            time.sleep(1)
    log("✗ Failed to connect to database after multiple attempts")
    return False

def insert_random_message():
    """Insert a random message into the messages table"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()
        
        # Node IDs
        node_ids = ['NODE001', 'NODE002', 'NODE003']
        from_node = random.choice(node_ids)
        to_node = random.choice(node_ids)
        
        # Make sure from and to are different
        while to_node == from_node:
            to_node = random.choice(node_ids)
        
        # Random message content
        messages = [
            "Status update", "Alert: High temperature", "Battery low", "Sensor reading",
            "Network quality excellent", "Heartbeat signal", "Data sync completed",
            "Waiting for response", "Test message", "Replication data"
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
        return True
    except psycopg2.Error:
        return False

def main():
    log("=" * 70)
    log("PostgreSQL Test Data Generator")
    log("=" * 70)
    
    # Find primary host
    primary_host = find_primary_host()
    if not primary_host:
        log("✗ FATAL: Could not find primary host")
        sys.exit(1)
    
    DB_CONFIG['host'] = primary_host
    
    log(f"Configuration:")
    log(f"  Host: {DB_CONFIG['host']}")
    log(f"  Port: {DB_CONFIG['port']}")
    log(f"  User: {DB_CONFIG['user']}")
    log(f"  Database: {DB_CONFIG['database']}")
    log("")
    
    if not wait_for_database():
        log("✗ FATAL: Failed to connect to database")
        sys.exit(1)
    
    # Create tables
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        if not create_tables(conn):
            log("✗ FATAL: Failed to create tables")
            sys.exit(1)
        conn.close()
    except psycopg2.Error as e:
        log(f"✗ FATAL: {e}")
        sys.exit(1)
    
    log("Starting high-speed data insertion (10 records/second)...")
    log("=" * 70)
    
    start_time = time.time()
    duration = 5 * 60  # 5 minutes
    insert_interval = 0.1  # 10 inserts per second
    inserted_count = 0
    failed_count = 0
    last_progress_report = start_time
    
    try:
        while True:
            elapsed = time.time() - start_time
            
            if elapsed >= duration:
                break
            
            if insert_random_message():
                inserted_count += 1
            else:
                failed_count += 1
            
            # Progress report every 10 seconds
            now = time.time()
            if now - last_progress_report >= 10:
                rate = inserted_count / (now - start_time) if (now - start_time) > 0 else 0
                remaining = duration - elapsed
                log(f"Progress: {inserted_count} inserted, {failed_count} failed, {rate:.1f} records/sec, {remaining:.0f}s remaining")
                last_progress_report = now
            
            time.sleep(insert_interval)
        
        log("=" * 70)
        log(f"✓ Test completed!")
        log(f"  Total inserted: {inserted_count}")
        log(f"  Total failed: {failed_count}")
        log(f"  Duration: {duration // 60} minutes")
        log(f"  Speed: {inserted_count / duration:.1f} records/second")
        log("=" * 70)
        sys.exit(0)
        
    except KeyboardInterrupt:
        log("")
        log("=" * 70)
        log("✓ Test stopped by user")
        log(f"  Total inserted: {inserted_count}")
        log(f"  Total failed: {failed_count}")
        log(f"  Speed: {inserted_count / (time.time() - start_time):.1f} records/second")
        log("=" * 70)
        sys.exit(0)
    except Exception as e:
        log(f"✗ Fatal error: {type(e).__name__}: {str(e)}")
        log("=" * 70)
        sys.exit(1)

if __name__ == '__main__':
    main()
