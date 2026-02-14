#!/usr/bin/env python3
"""
WeSense Zenoh Bridge — P2P Data Receiver

Subscribes to Zenoh, verifies signatures against a trust list,
and writes incoming readings to the local ClickHouse instance.

This is the observer persona's data receiver: it does NOT re-sign readings.
The original ingester's signature is preserved so that observer ClickHouse
contains the same verifiable data as the station's.

Usage:
    python bridge.py
"""

import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone

from wesense_ingester import (
    BufferedClickHouseWriter,
    DeduplicationCache,
    setup_logging,
)
from wesense_ingester.clickhouse.writer import ClickHouseConfig
from wesense_ingester.signing.trust import TrustStore
from wesense_ingester.zenoh.config import ZenohConfig
from wesense_ingester.zenoh.subscriber import ZenohSubscriber

# ── Configuration ─────────────────────────────────────────────────────

STATS_INTERVAL = int(os.getenv("STATS_INTERVAL", "60"))
TRUST_FILE = os.getenv("TRUST_FILE", "data/trust_list.json")
SUBSCRIBE_KEY = os.getenv("ZENOH_SUBSCRIBE_KEY", "wesense/v2/live/**")

# ClickHouse columns (25-column unified schema)
BRIDGE_COLUMNS = [
    "timestamp", "device_id", "data_source", "network_source", "ingestion_node_id",
    "reading_type", "value", "unit",
    "latitude", "longitude", "altitude", "geo_country", "geo_subdivision",
    "board_model", "sensor_model", "deployment_type", "deployment_type_source",
    "transport_type", "deployment_location", "node_name", "node_info", "node_info_url",
    "signature", "ingester_id", "key_version",
]


class ZenohBridge:
    """
    P2P data receiver: subscribe to Zenoh, verify signatures, write to ClickHouse.
    """

    def __init__(self):
        self.logger = setup_logging("zenoh_bridge")
        self.running = True

        # Trust store for signature verification
        self.trust_store = TrustStore(trust_file=TRUST_FILE)
        self.trust_store.load()
        self.logger.info("Trust store loaded from %s", TRUST_FILE)

        # Dedup cache — mesh flooding protection
        self.dedup = DeduplicationCache()

        # ClickHouse writer
        try:
            self.ch_writer = BufferedClickHouseWriter(
                config=ClickHouseConfig.from_env(),
                columns=BRIDGE_COLUMNS,
            )
        except Exception as e:
            self.logger.error("Failed to connect to ClickHouse: %s", e)
            sys.exit(1)

        # Zenoh subscriber
        zenoh_config = ZenohConfig.from_env()
        self.subscriber = ZenohSubscriber(
            config=zenoh_config,
            trust_store=self.trust_store,
            on_reading=self._on_reading,
        )

        # Stats
        self.stats = {
            "received": 0,
            "written": 0,
            "duplicates": 0,
            "unsigned": 0,
        }

    def _on_reading(self, reading_dict, signed_reading):
        """Callback invoked by ZenohSubscriber for each verified reading."""
        self.stats["received"] += 1

        device_id = reading_dict.get("device_id", "")
        reading_type = reading_dict.get("reading_type", "")
        timestamp = reading_dict.get("timestamp", 0)

        # Dedup check
        if self.dedup.is_duplicate(device_id, reading_type, timestamp):
            self.stats["duplicates"] += 1
            return

        # Extract signature fields from the signed_reading envelope (preserve original)
        if signed_reading:
            signature = signed_reading.signature.hex()
            ingester_id = signed_reading.ingester_id
            key_version = signed_reading.key_version
        else:
            # Unsigned reading — still store but flag
            self.stats["unsigned"] += 1
            signature = ""
            ingester_id = ""
            key_version = 0

        # Parse timestamp
        try:
            ts = datetime.fromtimestamp(int(timestamp), tz=timezone.utc)
        except (ValueError, TypeError, OSError):
            self.logger.warning("Invalid timestamp %s from %s", timestamp, device_id)
            return

        value = reading_dict.get("value")
        if value is None:
            return

        try:
            value = float(value)
        except (ValueError, TypeError):
            return

        row = (
            ts,
            device_id,
            reading_dict.get("data_source", ""),
            reading_dict.get("network_source", ""),
            reading_dict.get("ingestion_node_id", ""),
            reading_type,
            value,
            reading_dict.get("unit", ""),
            float(reading_dict["latitude"]) if reading_dict.get("latitude") is not None else None,
            float(reading_dict["longitude"]) if reading_dict.get("longitude") is not None else None,
            float(reading_dict["altitude"]) if reading_dict.get("altitude") is not None else None,
            reading_dict.get("geo_country", ""),
            reading_dict.get("geo_subdivision", ""),
            reading_dict.get("board_model", ""),
            reading_dict.get("sensor_model", ""),
            reading_dict.get("deployment_type", ""),
            reading_dict.get("deployment_type_source", ""),
            reading_dict.get("transport_type", ""),
            reading_dict.get("deployment_location", ""),
            reading_dict.get("node_name"),
            reading_dict.get("node_info"),
            reading_dict.get("node_info_url"),
            signature,
            ingester_id,
            key_version,
        )
        self.ch_writer.add(row)
        self.stats["written"] += 1

    def print_stats(self):
        sub_stats = self.subscriber.stats
        ch_stats = self.ch_writer.get_stats()
        dedup_stats = self.dedup.get_stats()

        self.logger.info(
            "STATS | received=%d | written=%d | duplicates=%d | unsigned=%d | "
            "sub_verified=%d | sub_rejected=%d | ch_written=%d | ch_buffer=%d",
            self.stats["received"],
            self.stats["written"],
            self.stats["duplicates"],
            self.stats["unsigned"],
            sub_stats.get("verified", 0),
            sub_stats.get("rejected", 0),
            ch_stats.get("total_written", 0),
            ch_stats.get("buffer_size", 0),
        )

    def shutdown(self, signum=None, frame=None):
        self.logger.info("Shutting down...")
        self.running = False

        if hasattr(self, 'subscriber'):
            self.subscriber.close()
        if hasattr(self, 'ch_writer'):
            self.ch_writer.close()

        self.logger.info("Shutdown complete")

    def run(self):
        signal.signal(signal.SIGINT, self.shutdown)
        signal.signal(signal.SIGTERM, self.shutdown)

        self.logger.info("=" * 60)
        self.logger.info("WeSense Zenoh Bridge (P2P Data Receiver)")
        self.logger.info("Subscribing to: %s", SUBSCRIBE_KEY)
        self.logger.info("=" * 60)

        self.subscriber.connect()
        self.subscriber.subscribe(SUBSCRIBE_KEY)

        try:
            while self.running:
                time.sleep(STATS_INTERVAL)
                self.print_stats()
        except KeyboardInterrupt:
            self.shutdown()
            sys.exit(0)


def main():
    bridge = ZenohBridge()
    bridge.run()


if __name__ == "__main__":
    main()
