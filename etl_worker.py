#!/usr/bin/env python3
"""A small ETL worker used to demonstrate logging and failure handling."""
import argparse
import logging
import sys
import time
from pathlib import Path

LOG_DIR = Path("/var/log/etl")
LOG_FILE = LOG_DIR / "pipeline.log"


class UTCFormatter(logging.Formatter):
    """Format every record with an explicit UTC timestamp."""
    converter = time.gmtime


def configure_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    formatter = UTCFormatter(
        fmt="%(asctime)sZ | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers.clear()

    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setFormatter(formatter)
    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(formatter)
    root.addHandler(file_handler)
    root.addHandler(stdout_handler)


def run_etl(fail: bool = False, empty: bool = False) -> int:
    log = logging.getLogger("etl")
    log.info("ETL pipeline started")
    log.info("Extracting source data")
    time.sleep(0.5)

    if fail:
        try:
            raise ConnectionError(
                "could not connect to database: connection timed out"
            )
        except ConnectionError:
            log.exception("ERROR: source database connection failed")
            return 1

    log.info("Transforming records")
    time.sleep(0.5)

    if empty:
        log.warning("0 rows loaded")
        log.info("ETL pipeline finished with zero rows")
        return 0

    loaded_rows = 1250
    log.info("Loading %d rows into destination", loaded_rows)
    log.info("ETL pipeline completed successfully")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Demo ETL worker")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--fail", action="store_true",
                       help="simulate a database connection failure")
    group.add_argument("--empty", action="store_true",
                       help="simulate a successful run that loads zero rows")
    args = parser.parse_args()

    try:
        configure_logging()
    except PermissionError as exc:
        print(f"Cannot write {LOG_FILE}: {exc}", file=sys.stderr)
        return 2

    return run_etl(fail=args.fail, empty=args.empty)


if __name__ == "__main__":
    raise SystemExit(main())
