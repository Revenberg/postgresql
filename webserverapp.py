#!/usr/bin/env python3
"""
PostgreSQL Database Explorer Web Application
Uses operationManagement API instead of direct database connections
"""

from flask import Flask, render_template, jsonify, request
import requests
import os
import time
import sys

app = Flask(__name__)

# API endpoint for operationManagement service
API_URL = os.environ.get('OPERATIONMANAGEMENT_SERVICE_URL', 'http://operationManagement:5001')

def wait_for_api(max_retries=30):
    """Wait for operationManagement API to be available"""
    for attempt in range(max_retries):
        try:
            response = requests.get(f"{API_URL}/api/operationmanagement/overview", timeout=3)
            if response.status_code == 200:
                print(f"✓ API connection successful on attempt {attempt + 1}")
                return True
        except requests.RequestException as e:
            print(f"Waiting for API (attempt {attempt + 1}/{max_retries}): {type(e).__name__}")
        time.sleep(1)
    return False

def get_cluster_overview():
    """Get cluster overview from API"""
    try:
        response = requests.get(f"{API_URL}/api/operationmanagement/overview", timeout=5)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"Error fetching cluster overview: {e}")
        return None

def get_node_list():
    """Get list of all nodes from API"""
    data = get_cluster_overview()
    if not data or 'nodes' not in data:
        return []
    return data['nodes']

def get_primary_node():
    """Get primary node information from API"""
    data = get_cluster_overview()
    if not data:
        return None
    
    for node in data.get('nodes', []):
        if node.get('is_primary'):
            return node
    return None

@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({'status': 'healthy'}), 200

@app.route('/')
def index():
    """Main dashboard page"""
    overview = get_cluster_overview()
    nodes = get_node_list()
    primary = get_primary_node()
    
    return render_template('dashboard.html', 
                          cluster=overview,
                          nodes=nodes,
                          primary=primary)

@app.route('/api/cluster/status')
def api_cluster_status():
    """Get cluster status as JSON"""
    overview = get_cluster_overview()
    if not overview:
        return jsonify({'error': 'Unable to reach operationManagement API'}), 503
    
    return jsonify({
        'cluster_status': overview.get('cluster_status', 'unknown'),
        'primary_node': overview.get('primary_node'),
        'timestamp': overview.get('timestamp'),
        'node_count': len(overview.get('nodes', [])),
        'standby_count': len([n for n in overview.get('nodes', []) if not n.get('is_primary')]),
        'replica_count': len([n for n in overview.get('nodes', []) if n.get('is_replica')]),
    })

@app.route('/api/nodes')
def api_nodes():
    """Get all nodes as JSON"""
    nodes = get_node_list()
    if not nodes:
        return jsonify({'error': 'Unable to reach operationManagement API'}), 503
    
    return jsonify({'nodes': nodes})

@app.route('/api/nodes/<node_name>')
def api_node_detail(node_name):
    """Get specific node details"""
    nodes = get_node_list()
    for node in nodes:
        if node.get('name') == node_name or node.get('container') == node_name:
            return jsonify(node)
    
    return jsonify({'error': 'Node not found'}), 404

@app.route('/api/promote/<node_name>', methods=['POST'])
def api_promote_node(node_name):
    """Promote a standby node to primary via API"""
    try:
        response = requests.post(
            f"{API_URL}/api/operationmanagement/promote/{node_name}",
            timeout=120
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/api/demote/<node_name>', methods=['POST'])
def api_demote_node(node_name):
    """Demote a primary node to standby via API"""
    try:
        response = requests.post(
            f"{API_URL}/api/operationmanagement/demote/{node_name}",
            timeout=120
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/clusters')
def clusters():
    """Cluster management page"""
    try:
        response = requests.get(
            f"{API_URL}/api/operationmanagement/db-clusters",
            timeout=5
        )
        clusters_data = response.json() if response.status_code == 200 else {'clusters': []}
    except requests.RequestException:
        clusters_data = {'clusters': []}
    
    try:
        response = requests.get(
            f"{API_URL}/api/operationmanagement/nodes",
            timeout=5
        )
        nodes_data = response.json() if response.status_code == 200 else {'nodes': []}
    except requests.RequestException:
        nodes_data = {'nodes': []}
    
    return render_template('clusters.html', clusters=clusters_data.get('clusters', []), nodes=nodes_data.get('nodes', []))

@app.route('/api/clusters')
def api_get_clusters():
    """Get all clusters as JSON"""
    try:
        response = requests.get(
            f"{API_URL}/api/operationmanagement/db-clusters",
            timeout=5
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/api/clusters', methods=['POST'])
def api_create_cluster():
    """Create a new cluster"""
    try:
        data = request.get_json() or {}
        response = requests.post(
            f"{API_URL}/api/operationmanagement/db-clusters",
            json=data,
            timeout=30
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/api/clusters/<cluster_name>/nodes', methods=['POST'])
def api_add_node_to_cluster(cluster_name):
    """Add a node to a cluster"""
    try:
        data = request.get_json() or {}
        response = requests.post(
            f"{API_URL}/api/operationmanagement/db-clusters/{cluster_name}/nodes",
            json=data,
            timeout=30
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/api/clusters/<cluster_name>/nodes/<node_name>', methods=['DELETE'])
def api_remove_node_from_cluster(cluster_name, node_name):
    """Remove a node from a cluster"""
    try:
        response = requests.delete(
            f"{API_URL}/api/operationmanagement/db-clusters/{cluster_name}/nodes/{node_name}",
            timeout=30
        )
        response.raise_for_status()
        return jsonify(response.json())
    except requests.RequestException as e:
        return jsonify({'error': str(e)}), 502

@app.route('/api/health')
def api_health():
    """Health check endpoint"""
    overview = get_cluster_overview()
    if overview:
        return jsonify({'status': 'healthy', 'api': 'connected'})
    return jsonify({'status': 'unhealthy', 'api': 'disconnected'}), 503

@app.before_request
def startup_checks():
    """Run startup checks on first request"""
    if not hasattr(app, 'startup_done'):
        print("Starting up PostgreSQL Explorer Web Application")
        print(f"API URL: {API_URL}")
        
        if wait_for_api():
            app.startup_done = True
            print("✓ Application ready")
        else:
            print("✗ Failed to connect to operationManagement API")
            # Continue anyway, user will see error in UI

if __name__ == '__main__':
    print("PostgreSQL Explorer Web Application")
    print(f"operationManagement API: {API_URL}")
    print("\nStarting Flask app...")
    app.run(host='0.0.0.0', port=5000, debug=False)
