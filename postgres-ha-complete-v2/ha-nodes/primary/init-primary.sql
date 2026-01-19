-- Initialize primary database with replication user and test schema
-- Must run commands in correct order since DB might not exist yet

-- First ensure database exists
CREATE DATABASE IF NOT EXISTS appdb;

-- Create replication user (superuser scope)
CREATE ROLE IF NOT EXISTS replicator WITH LOGIN REPLICATION ENCRYPTED PASSWORD 'replpass';
ALTER ROLE replicator VALID UNTIL 'infinity';

-- Now switch to appdb for table creation
\c appdb

CREATE TABLE IF NOT EXISTS test_replication (
    id SERIAL PRIMARY KEY,
    message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    node_id VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS cluster_status (
    node_id VARCHAR(50) PRIMARY KEY,
    role VARCHAR(20),
    status VARCHAR(20),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sync_test (
    id BIGSERIAL PRIMARY KEY,
    data TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

GRANT ALL PRIVILEGES ON DATABASE appdb TO appuser;
GRANT ALL PRIVILEGES ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT USAGE ON SCHEMA public TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
