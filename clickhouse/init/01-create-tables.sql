-- WeSense ClickHouse Schema
-- Auto-runs on first container startup via /docker-entrypoint-initdb.d/
--
-- Databases:
--   wesense          - Sensor readings from all ingesters
--   wesense_respiro  - Region boundaries and device-region cache for Respiro maps
--
-- Note: The live database currently uses 'sensormap' for the Respiro tables.
-- This will be renamed to 'wesense_respiro' during migration (Phase 4).

-- =============================================================================
-- Database: wesense — Ingester sensor data
-- =============================================================================

CREATE DATABASE IF NOT EXISTS wesense;

CREATE TABLE IF NOT EXISTS wesense.sensor_readings
(
    `timestamp` DateTime64(3, 'UTC'),
    `device_id` String,
    `data_source` LowCardinality(String),
    `network_source` LowCardinality(String),
    `ingestion_node_id` LowCardinality(String) DEFAULT '',
    `reading_type` LowCardinality(String),
    `value` Float64,
    `unit` LowCardinality(String) DEFAULT '',
    `sample_count` UInt16 DEFAULT 1,
    `sample_interval_avg` UInt16 DEFAULT 300,
    `value_min` Float64 DEFAULT 0,
    `value_max` Float64 DEFAULT 0,
    `latitude` Float64,
    `longitude` Float64,
    `altitude` Nullable(Float32),
    `geo_country` LowCardinality(String),
    `geo_subdivision` LowCardinality(String) DEFAULT '',
    `geo_h3_res8` UInt64 DEFAULT 0,
    `sensor_model` LowCardinality(String) DEFAULT '',
    `board_model` LowCardinality(String) DEFAULT '',
    `calibration_status` LowCardinality(String) DEFAULT 'unknown',
    `data_quality_flag` LowCardinality(String) DEFAULT 'unvalidated',
    `deployment_type` LowCardinality(String) DEFAULT 'unknown',
    `transport_type` LowCardinality(String) DEFAULT 'unknown',
    `location_source` LowCardinality(String) DEFAULT 'unknown',
    `firmware_version` Nullable(String),
    `deployment_location` Nullable(String),
    `node_name` Nullable(String),
    `deployment_type_source` LowCardinality(String) DEFAULT 'unknown',
    `node_info` Nullable(String),
    `node_info_url` Nullable(String)
)
ENGINE = ReplacingMergeTree(timestamp)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (device_id, reading_type, timestamp)
TTL toDateTime(timestamp) + toIntervalYear(3)
SETTINGS index_granularity = 8192;

-- =============================================================================
-- Database: wesense_respiro — Region boundaries for Respiro maps
-- =============================================================================

CREATE DATABASE IF NOT EXISTS wesense_respiro;

-- Region boundaries for point-in-polygon queries
-- Stores administrative boundaries at multiple levels (ADM0-ADM4)
CREATE TABLE IF NOT EXISTS wesense_respiro.region_boundaries
(
    `region_id` String,
    `admin_level` UInt8,
    `name` String,
    `country_code` String,
    `original_id` String,
    `polygon` Array(Array(Tuple(Float64, Float64))),
    `bbox_min_lon` Float64,
    `bbox_max_lon` Float64,
    `bbox_min_lat` Float64,
    `bbox_max_lat` Float64
)
ENGINE = MergeTree
ORDER BY (admin_level, country_code, region_id)
SETTINGS index_granularity = 8192;

-- Cache device locations to regions (updated periodically)
-- Avoids expensive point-in-polygon queries at read time
CREATE TABLE IF NOT EXISTS wesense_respiro.device_region_cache
(
    `device_id` String,
    `latitude` Float64,
    `longitude` Float64,
    `region_adm0_id` String,
    `region_adm1_id` String,
    `region_adm2_id` String,
    `updated_at` DateTime DEFAULT now(),
    `region_adm3_id` String DEFAULT '',
    `region_adm4_id` String DEFAULT ''
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY device_id
SETTINGS index_granularity = 8192;
