#!/bin/sh
# Creates a hypertable only when the timescaledb extension is available (timescale service).
set -e
if psql -U elefantas -d elefantas -tAc "SELECT 1 FROM pg_available_extensions WHERE name='timescaledb'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -U elefantas -d elefantas <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE TABLE app.metrics (time timestamptz NOT NULL, device int NOT NULL, value double precision);
SELECT create_hypertable('app.metrics', 'time');
INSERT INTO app.metrics
SELECT timestamptz '2026-01-01' + g * interval '1 minute', g % 10, random()
FROM generate_series(1, 100000) g;
SQL
fi
