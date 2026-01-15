#!/usr/bin/env python3
"""
PostgreSQL Database Explorer Web Application
Displays available databases, tables, and their schemas
"""

from flask import Flask, render_template, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor
import os
import time
import sys

app = Flask(__name__)

# Database connection parameters for the primary database
DB_CONFIG = {
    'host': os.environ.get('DB_HOST', 'postgres-node2'),  # Current primary after failover
    'port': int(os.environ.get('DB_PORT', '5432')),
    'user': os.environ.get('DB_USER', 'testadmin'),
    'password': os.environ.get('DB_PASSWORD', 'securepwd123'),
    'database': 'postgres'  # System database to list all databases
}

def wait_for_connection(max_retries=30):
    """Wait for database to be available"""
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(**DB_CONFIG, connect_timeout=3)
            conn.close()
            print(f"✓ Database connection successful on attempt {attempt + 1}")
            return True
        except psycopg2.Error as e:
            print(f"Waiting for database (attempt {attempt + 1}/{max_retries}): {type(e).__name__}")
            time.sleep(1)
    return False

def get_db_connection(database='postgres'):
    """Create a new database connection to specified database"""
    try:
        config = DB_CONFIG.copy()
        config['database'] = database
        conn = psycopg2.connect(**config)
        return conn
    except psycopg2.Error as e:
        print(f"Database connection error to '{database}': {e}")
        return None

def get_databases():
    """Get list of all databases"""
    conn = get_db_connection()
    if not conn:
        return []
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("""
            SELECT datname 
            FROM pg_database 
            WHERE datistemplate = false 
            ORDER BY datname
        """)
        databases = [row['datname'] for row in cur.fetchall()]
        cur.close()
        return databases
    except psycopg2.Error as e:
        print(f"Error fetching databases: {e}")
        return []
    finally:
        conn.close()

def get_tables(database):
    """Get list of tables in a specific database"""
    conn = get_db_connection(database)
    if not conn:
        return []
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("""
            SELECT table_name 
            FROM information_schema.tables 
            WHERE table_schema = 'public'
            ORDER BY table_name
        """)
        tables = [row['table_name'] for row in cur.fetchall()]
        cur.close()
        return tables
    except psycopg2.Error as e:
        print(f"Error fetching tables: {e}")
        return []
    finally:
        conn.close()

def get_table_row_count(database, table):
    """Get row count for a specific table"""
    conn = get_db_connection(database)
    if not conn:
        return 0
    
    try:
        cur = conn.cursor()
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        count = cur.fetchone()[0]
        cur.close()
        return count
    except psycopg2.Error as e:
        print(f"Error fetching row count for table '{table}': {e}")
        return 0
    finally:
        conn.close()

def get_table_schema(database, table):
    """Get schema information for a specific table"""
    conn = get_db_connection(database)
    if not conn:
        return []
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("""
            SELECT column_name, data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = %s
            ORDER BY ordinal_position
        """, (table,))
        columns = cur.fetchall()
        cur.close()
        return columns
    except psycopg2.Error as e:
        print(f"Error fetching table schema: {e}")
        return []
    finally:
        conn.close()

def get_table_data(database, table, limit=50):
    """Get sample data from a table"""
    conn = get_db_connection(database)
    if not conn:
        return []
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(f"SELECT * FROM {table} LIMIT %s", (limit,))
        rows = cur.fetchall()
        cur.close()
        return rows
    except psycopg2.Error as e:
        print(f"Error fetching table data: {e}")
        return []
    finally:
        conn.close()

def get_actual_primary():
    """Detect which node is actually the primary"""
    print("DEBUG: Detecting actual primary node...", file=sys.stderr)
    sys.stderr.flush()
    
    # Map of all possible primary nodes
    possible_primaries = {
        'node1': ('postgres-node1', '172.18.0.2'),
        'node2': ('postgres-node2', '172.18.0.3'),
        'node3': ('postgres-node3', '172.18.0.6'),
    }
    
    for node_id, (container, ip) in possible_primaries.items():
        try:
            # Try to connect to each node and check if it's in recovery
            test_config = DB_CONFIG.copy()
            test_config['host'] = container
            conn = psycopg2.connect(**test_config, connect_timeout=2)
            cur = conn.cursor()
            cur.execute("SELECT pg_is_in_recovery();")
            is_recovery = cur.fetchone()[0]
            cur.close()
            conn.close()
            
            if not is_recovery:
                # This node is NOT in recovery, so it's the primary
                print(f"DEBUG: PRIMARY FOUND: {node_id} (not in recovery)", file=sys.stderr)
                sys.stderr.flush()
                return {
                    'node_id': node_id,
                    'node_name': container,
                    'client_addr': ip,
                    'role': 'Primary'
                }
        except Exception as e:
            print(f"DEBUG: Could not connect to {node_id}: {str(e)[:50]}", file=sys.stderr)
            sys.stderr.flush()
    
    # Default to node1 if detection fails
    print("DEBUG: Primary detection failed, defaulting to node1", file=sys.stderr)
    sys.stderr.flush()
    return {
        'node_id': 'node1',
        'node_name': 'postgres-node1',
        'client_addr': '172.18.0.2',
        'role': 'Primary'
    }

def get_replication_stats():
    """Get replication statistics for all nodes"""
    
    print("\n" + "="*80, file=sys.stderr)
    print("DEBUG: get_replication_stats() START", file=sys.stderr)
    print("="*80, file=sys.stderr)
    sys.stderr.flush()
    
    replication_stats = []
    
    # Detect the actual primary node
    primary_info = get_actual_primary()
    
    # Haal alle replication stats van primary
    pg_stats = []
    try:
        print("DEBUG: Connecting to primary...", file=sys.stderr)
        sys.stderr.flush()
        conn = get_db_connection('testdb')
        if conn:
            print("DEBUG: Connected to primary successfully", file=sys.stderr)
            sys.stderr.flush()
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute("""
                SELECT 
                    client_addr,
                    usename,
                    state,
                    sync_state,
                    write_lag,
                    flush_lag,
                    replay_lag,
                    backend_start
                FROM pg_stat_replication
                ORDER BY client_addr
            """)
            pg_stats = cur.fetchall()
            cur.close()
            conn.close()
            
            print(f"DEBUG: Found {len(pg_stats)} replicas in pg_stat_replication", file=sys.stderr)
            sys.stderr.flush()
            for i, stat in enumerate(pg_stats):
                addr = stat.get('client_addr')
                lag = stat.get('write_lag')
                print(f"DEBUG:   [{i}] IP={addr}, state={stat.get('state')}, write_lag={lag}", file=sys.stderr)
                sys.stderr.flush()
    except Exception as e:
        print(f"ERROR: Failed to get pg_stat_replication: {e}", file=sys.stderr)
        sys.stderr.flush()
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        pg_stats = []
    
    # Voeg PRIMARY toe (dynamically detected)
    print(f"DEBUG: Adding {primary_info['node_id']} (PRIMARY)...", file=sys.stderr)
    sys.stderr.flush()
    replication_stats.append({
        'node_id': primary_info['node_id'],
        'node_name': primary_info['node_name'],
        'client_addr': primary_info['client_addr'],
        'usename': 'testadmin',
        'state': 'primary',
        'sync_state': 'N/A',
        'write_lag': 'N/A',
        'flush_lag': 'N/A',
        'replay_lag': 'N/A',
        'backend_start': 'N/A',
        'role': 'Primary',
        'status': 'connected'
    })
    print(f"DEBUG: {primary_info['node_id']} added: role=Primary, address={primary_info['client_addr']}", file=sys.stderr)
    sys.stderr.flush()
    
    # Map van IPs naar node info
    replica_map = {
        '172.18.0.3': {'node_id': 'node2', 'node_name': 'postgres-node2'},
        '172.18.0.4': {'node_id': 'replica1', 'node_name': 'postgres-replica-1'},
        '172.18.0.5': {'node_id': 'replica2', 'node_name': 'postgres-replica-2'},
        '172.18.0.6': {'node_id': 'node3', 'node_name': 'postgres-node3'},
    }
    print(f"DEBUG: Replica map has {len(replica_map)} entries", file=sys.stderr)
    sys.stderr.flush()
    
    # Voeg replicas toe die in pg_stat_replication staan
    print("DEBUG: Processing replicas found in pg_stat_replication...", file=sys.stderr)
    sys.stderr.flush()
    for stat in pg_stats:
        addr = str(stat.get('client_addr', ''))
        print(f"DEBUG:   Checking IP: {addr}", file=sys.stderr)
        sys.stderr.flush()
        
        # Zoek deze IP in de map
        if addr in replica_map:
            info = replica_map[addr]
            write_lag = stat.get('write_lag')
            flush_lag = stat.get('flush_lag')
            replay_lag = stat.get('replay_lag')
            
            print(f"DEBUG:     ✓ MATCH FOUND for {info['node_id']}", file=sys.stderr)
            print(f"DEBUG:       write_lag={write_lag}, flush_lag={flush_lag}, replay_lag={replay_lag}", file=sys.stderr)
            sys.stderr.flush()
            
            replication_stats.append({
                'node_id': info['node_id'],
                'node_name': info['node_name'],
                'client_addr': addr,
                'usename': stat.get('usename', 'testadmin'),
                'state': stat.get('state', 'streaming'),
                'sync_state': stat.get('sync_state', 'async'),
                'write_lag': str(write_lag) if write_lag else 'N/A',
                'flush_lag': str(flush_lag) if flush_lag else 'N/A',
                'replay_lag': str(replay_lag) if replay_lag else 'N/A',
                'backend_start': str(stat.get('backend_start', 'N/A')) if stat.get('backend_start') else 'N/A',
                'role': 'Standby',
                'status': 'connected'
            })
            # Verwijder uit map zodat we later weten welke niet gevonden zijn
            del replica_map[addr]
        else:
            print(f"DEBUG:     - IP not in replica_map", file=sys.stderr)
            sys.stderr.flush()
    
    # Voeg replicas toe die NIET in pg_stat_replication staan (disconnected)
    print(f"DEBUG: Processing disconnected replicas ({len(replica_map)} remaining)...", file=sys.stderr)
    sys.stderr.flush()
    for addr, info in replica_map.items():
        print(f"DEBUG:   Adding disconnected: {info['node_id']} ({addr})", file=sys.stderr)
        sys.stderr.flush()
        replication_stats.append({
            'node_id': info['node_id'],
            'node_name': info['node_name'],
            'client_addr': addr,
            'usename': 'testadmin',
            'state': 'standby',
            'sync_state': 'N/A',
            'write_lag': 'N/A',
            'flush_lag': 'N/A',
            'replay_lag': 'N/A',
            'backend_start': 'N/A',
            'role': 'Standby',
            'status': 'disconnected'
        })
    
    print("="*80, file=sys.stderr)
    print(f"DEBUG: FINAL RESULT: {len(replication_stats)} nodes", file=sys.stderr)
    for stat in replication_stats:
        print(f"DEBUG:   - {stat['node_id']}: role={stat['role']}, addr={stat['client_addr']}, lag={stat['write_lag']}", file=sys.stderr)
    print("="*80 + "\n", file=sys.stderr)
    sys.stderr.flush()
    
    return replication_stats

def get_replication_progress():
    """Get WAL replication progress from primary database"""
    try:
        conn = get_db_connection('testdb')
        if not conn:
            return {'progress': 0, 'lag_bytes': 0, 'replica_addr': 'N/A', 'state': 'N/A', 'sync_state': 'N/A', 'replay_lsn': 'N/A'}
    except Exception as e:
        print(f"Error connecting for replication progress: {e}")
        return {'progress': 0, 'lag_bytes': 0, 'replica_addr': 'N/A', 'state': 'N/A', 'sync_state': 'N/A', 'replay_lsn': 'N/A'}
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        # Get current WAL position on primary
        cur.execute("SELECT pg_current_wal_lsn() as lsn;")
        primary_lsn_result = cur.fetchone()
        primary_lsn = primary_lsn_result['lsn'] if primary_lsn_result else None
        print(f"Primary LSN: {primary_lsn}")
        
        # Get all connected replicas
        cur.execute("""
            SELECT 
                client_addr,
                state,
                write_lsn,
                flush_lsn,
                replay_lsn,
                sync_state,
                usename
            FROM pg_stat_replication
            ORDER BY client_addr
        """)
        replicas = cur.fetchall()
        print(f"Found {len(replicas)} connected replicas")
        
        if not replicas or len(replicas) == 0:
            print("⚠ No replicas in pg_stat_replication")
            # Try to check if replicas exist but are not yet connected
            cur.execute("SELECT datname FROM pg_database WHERE datname LIKE 'testdb';")
            db_check = cur.fetchone()
            print(f"testdb exists: {db_check is not None}")
            cur.close()
            return {
                'progress': 0, 
                'lag_bytes': 0, 
                'replica_addr': 'No replicas yet', 
                'state': 'standby', 
                'sync_state': 'async', 
                'replay_lsn': 'N/A'
            }
        
        # Use first replica for progress display
        replica_info = replicas[0]
        print(f"Using replica: {replica_info['client_addr']}, state: {replica_info['state']}")
        
        # Calculate lag in bytes
        if primary_lsn and replica_info['replay_lsn']:
            cur.execute("""
                SELECT 
                    pg_wal_lsn_diff(%s, %s) as lag_bytes
            """, (primary_lsn, replica_info['replay_lsn']))
            lag_result = cur.fetchone()
            lag_bytes = lag_result['lag_bytes'] if lag_result and lag_result['lag_bytes'] else 0
        else:
            lag_bytes = 0
        
        # Estimate progress (assume 1GB is "full")
        total_wal = 1073741824  # 1 GB
        progress = max(0, min(100, int(((total_wal - lag_bytes) / total_wal) * 100))) if lag_bytes < total_wal else 100
        
        cur.close()
        
        return {
            'progress': progress,
            'lag_bytes': int(lag_bytes) if lag_bytes else 0,
            'replica_addr': str(replica_info['client_addr']),
            'state': replica_info['state'],
            'sync_state': replica_info['sync_state'],
            'replay_lsn': str(replica_info['replay_lsn']),
            'user': replica_info['usename']
        }
    except psycopg2.Error as e:
        print(f"Error fetching replication progress: {e}")
        import traceback
        traceback.print_exc()
        return {
            'progress': 0, 
            'lag_bytes': 0, 
            'replica_addr': f'Error: {str(e)[:30]}', 
            'state': 'error', 
            'sync_state': 'N/A', 
            'replay_lsn': 'N/A'
        }
    finally:
        conn.close()

def get_server_info():
    """Get PostgreSQL server information"""
    try:
        conn = get_db_connection('testdb')
        if not conn:
            return {'role': 'Unknown', 'version': 'N/A', 'current_time': 'N/A', 'in_recovery': False}
    except Exception as e:
        return {'role': 'Unknown', 'version': 'N/A', 'current_time': 'N/A', 'in_recovery': False}
    
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        # Get version
        cur.execute("SELECT version();")
        version = cur.fetchone()['version']
        
        # Get recovery status
        cur.execute("SELECT pg_is_in_recovery();")
        in_recovery = cur.fetchone()['pg_is_in_recovery']
        
        # Get current time
        cur.execute("SELECT now() AS current_time;")
        current_time = cur.fetchone()['current_time']
        
        cur.close()
        return {
            'version': version,
            'in_recovery': in_recovery,
            'current_time': str(current_time),
            'role': 'Standby' if in_recovery else 'Primary'
        }
    except psycopg2.Error as e:
        print(f"Error fetching server info: {e}")
        return {'role': 'Unknown', 'version': 'N/A', 'current_time': 'N/A', 'in_recovery': False}
    finally:
        conn.close()

def get_replica_server_info():
    """Get PostgreSQL replica and secondary server information"""
    replicas_info = []
    
    # Define servers to monitor: node1, node2, node3
    servers_config = [
        {'name': 'postgres-node1', 'port': 5432, 'role': 'Primary', 'display_port': '5432'},
        {'name': 'postgres-node2', 'port': 5432, 'role': 'Standby', 'display_port': '5435'},
        {'name': 'postgres-node3', 'port': 5432, 'role': 'Standby', 'display_port': '5436'},
    ]
    
    # Try to connect to each server
    for server_config in servers_config:
        replica_name = server_config['name']
        server_role = server_config['role']
        try:
            replica_config = {
                'host': replica_name,
                'port': 5432,
                'user': 'testadmin',
                'password': 'securepwd123',
                'database': 'testdb',
                'connect_timeout': 3
            }
            replica_conn = psycopg2.connect(**replica_config)
            cur = replica_conn.cursor(cursor_factory=RealDictCursor)
            
            # Get replica server info
            cur.execute("""
                SELECT 
                    version() as version,
                    pg_is_in_recovery() as in_recovery,
                    NOW() as current_time
            """)
            info = cur.fetchone()
            
            # Get row counts for replica - try to fetch from tables
            row_counts = {'users': 0, 'nodes': 0, 'messages': 0}
            try:
                # Query each table individually to better handle errors
                cur.execute("SELECT COUNT(*) as cnt FROM users;")
                result = cur.fetchone()
                row_counts['users'] = result['cnt'] if result else 0
                
                cur.execute("SELECT COUNT(*) as cnt FROM nodes;")
                result = cur.fetchone()
                row_counts['nodes'] = result['cnt'] if result else 0
                
                cur.execute("SELECT COUNT(*) as cnt FROM messages;")
                result = cur.fetchone()
                row_counts['messages'] = result['cnt'] if result else 0
                
                print(f"✓ {replica_name} row counts: users={row_counts['users']}, nodes={row_counts['nodes']}, messages={row_counts['messages']}")
            except Exception as e:
                print(f"⚠ {replica_name} - Error fetching row counts: {e}")
                # Keep row_counts as zeros but still show as connected
            
            cur.close()
            replica_conn.close()
            
            # Extract version number
            version_str = info['version'] if info else 'Unknown'
            version_match = version_str.split()[1] if info else 'N/A'
            
            # Determine actual role
            if server_role == 'Standby':
                role_display = 'Standby' if (info and info['in_recovery']) else 'Primary'
            else:
                role_display = 'Primary' if (info and not info['in_recovery']) else 'Standby'
            
            replicas_info.append({
                'name': replica_name,
                'version': version_match,
                'role': role_display,
                'server_role': server_role,
                'current_time': info['current_time'].strftime('%Y-%m-%d %H:%M:%S') if info else 'N/A',
                'status': 'connected',
                'row_counts': row_counts
            })
        except psycopg2.Error as e:
            replicas_info.append({
                'name': replica_name,
                'version': 'N/A',
                'role': 'Unknown',
                'current_time': 'N/A',
                'status': f'disconnected ({type(e).__name__})',
                'row_counts': {'users': 0, 'nodes': 0, 'messages': 0}
            })
        except Exception as e:
            replicas_info.append({
                'name': replica_name,
                'version': 'N/A',
                'role': 'Unknown',
                'current_time': 'N/A',
                'status': f'error ({type(e).__name__})',
                'row_counts': {'users': 0, 'nodes': 0, 'messages': 0}
            })
    
    return replicas_info

@app.route('/')
def index():
    """Home page showing database overview"""
    try:
        databases = get_databases()
        server_info = get_server_info()
        replica_info = get_replica_server_info()
        replication_stats = get_replication_stats()
        replication_progress = get_replication_progress()
        
        # Get row counts for primary tables
        primary_row_counts = {
            'users': None,
            'nodes': None,
            'messages': None
        }
        try:
            for table in primary_row_counts.keys():
                try:
                    primary_row_counts[table] = get_table_row_count('testdb', table)
                except Exception as e:
                    print(f"Error getting row count for {table}: {e}")
                    primary_row_counts[table] = None
        except Exception as e:
            print(f"Error fetching primary row counts: {e}")
        
        db_info = []
        try:
            for db in databases:
                tables = get_tables(db)
                table_details = []
                for table in tables:
                    try:
                        row_count = get_table_row_count(db, table)
                        table_details.append({
                            'name': table,
                            'row_count': row_count
                        })
                    except Exception as e:
                        print(f"Error getting row count for {db}.{table}: {e}")
                        table_details.append({
                            'name': table,
                            'row_count': None
                        })
                db_info.append({
                    'name': db,
                    'table_count': len(table_details),
                    'tables': table_details
                })
        except Exception as e:
            print(f"Error fetching database info: {e}")
        
        return render_template('index.html', 
                             databases=db_info,
                             server_info=server_info,
                             primary_row_counts=primary_row_counts,
                             replica_info=replica_info,
                             replication_stats=replication_stats,
                             replication_progress=replication_progress)
    except Exception as e:
        print(f"Fatal error in index route: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/databases')
def api_databases():
    """API endpoint to get all databases"""
    databases = get_databases()
    return jsonify({'databases': databases})

@app.route('/api/database/<database>/tables')
def api_tables(database):
    """API endpoint to get tables in a database"""
    tables = get_tables(database)
    table_details = []
    for table in tables:
        row_count = get_table_row_count(database, table)
        table_details.append({
            'name': table,
            'row_count': row_count
        })
    return jsonify({'database': database, 'tables': table_details})

@app.route('/api/database/<database>/table/<table>/schema')
def api_table_schema(database, table):
    """API endpoint to get table schema"""
    schema = get_table_schema(database, table)
    return jsonify({'database': database, 'table': table, 'columns': schema})

@app.route('/api/database/<database>/table/<table>/data')
def api_table_data(database, table):
    """API endpoint to get sample table data"""
    data = get_table_data(database, table)
    return jsonify({'database': database, 'table': table, 'rows': data})

@app.route('/health')
def health():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        if conn:
            conn.close()
            return jsonify({'status': 'healthy', 'database': 'connected'}), 200
    except Exception as e:
        print(f"Health check error: {e}")
    return jsonify({'status': 'unhealthy', 'database': 'disconnected'}), 500

@app.route('/api/replication/stats')
def api_replication_stats():
    """API endpoint to get replication statistics"""
    stats = get_replication_stats()
    return jsonify({'replication_stats': stats})

@app.route('/api/server/info')
def api_server_info():
    """API endpoint to get server information"""
    info = get_server_info()
    return jsonify(info)

@app.route('/api/nodes/status')
def api_nodes_status():
    """API endpoint to get status of all nodes (node1, node2, node3)"""
    nodes_status = get_replica_server_info()
    return jsonify({'nodes': nodes_status})

@app.route('/api/nodes/replication')
def api_nodes_replication():
    """API endpoint to get replication details between nodes"""
    stats = get_replication_stats()
    progress = get_replication_progress()
    return jsonify({
        'replication_stats': stats,
        'replication_progress': progress
    })

if __name__ == '__main__':
    print("\n" + "="*60)
    print("PostgreSQL Database Explorer - Starting")
    print("="*60)
    print(f"Connecting to: {DB_CONFIG['host']}:{DB_CONFIG['port']}")
    
    if wait_for_connection():
        print("Starting Flask server on 0.0.0.0:5000")
        print("="*60 + "\n")
        app.run(host='0.0.0.0', port=5000, debug=False)
    else:
        print("❌ Failed to connect to database after multiple attempts")
        exit(1)