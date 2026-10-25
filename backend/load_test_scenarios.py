"""Interactively apply mobile flood-routing test scenarios to MongoDB."""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv
from pymongo import MongoClient, UpdateOne


DB_DIRECTORY = Path(__file__).resolve().parent

# Input coordinates are stored as (latitude, longitude); GeoJSON stores
# coordinates in the opposite order: [longitude, latitude].
CAMERAS = (
    ("CCTV 1", 8.500839971893368, 124.62804753089578),
    ("CCTV 2", 8.495803648115317, 124.62539004380038),
    ("CCTV 3", 8.492091924806873, 124.65385142528442),
    ("CCTV 4", 8.496395789841635, 124.64138659683796),
    ("CCTV 5", 8.484534494949672, 124.65709620343732),
)

WATER_LEVEL_METERS = {
    "safe": 0.05,
    "alert": 0.20,
    "danger": 0.50,
}

SCENARIOS = (
    ("Set 1", ("alert", "safe", "alert", "safe", "safe")),
    ("Set 2", ("danger", "alert", "danger", "alert", "safe")),
    ("Set 3", ("danger", "danger", "danger", "danger", "safe")),
)
NORMAL_STATUSES = ("safe",) * len(CAMERAS)


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _scenario_updates(statuses: tuple[str, ...], timestamp: str) -> list[UpdateOne]:
    updates = []
    for (label, latitude, longitude), status in zip(CAMERAS, statuses, strict=True):
        water_level = WATER_LEVEL_METERS[status]
        point = {
            "type": "Point",
            "coordinates": [longitude, latitude],
        }
        updates.append(
            UpdateOne(
                {"location.type": "Point", "location.coordinates": point["coordinates"]},
                {
                    "$set": {
                        "location": point,
                        "status": status,
                        "water_level": water_level,
                        "timestamp": timestamp,
                        "last_evaluation": {
                            "status": status,
                            "water_level": water_level,
                            "captured_at": timestamp,
                            "source": "load_test_scenarios.py",
                        },
                    },
                    "$setOnInsert": {"location_label": label},
                },
                upsert=True,
            )
        )
    return updates


def _upload_scenario(collection, name: str, statuses: tuple[str, ...]) -> None:
    timestamp = _timestamp()
    result = collection.bulk_write(_scenario_updates(statuses, timestamp))
    print(
        f"{name} uploaded at {timestamp}: "
        f"{result.matched_count} updated, "
        f"{len(result.upserted_ids)} inserted."
    )


def _prompt_for_scenario() -> str:
    print("\nChoose the next action:")
    for index, (name, statuses) in enumerate(SCENARIOS, start=1):
        summary = ", ".join(
            f"{camera[0]}={status.upper()}"
            for camera, status in zip(CAMERAS, statuses, strict=True)
        )
        print(f"  {index}. {name}: {summary}")
    return input("Enter 1, 2, 3, or END to restore all sensors to normal: ").strip()


def main() -> None:
    load_dotenv(DB_DIRECTORY / ".env")
    uri = os.environ.get("MONGODB_URI")
    if not uri:
        raise RuntimeError(
            "MONGODB_URI is missing; set it in backend/.env or the environment"
        )

    database_name = os.environ.get("MONGODB_DB", "CCTVs")
    collection_name = os.environ.get("MONGODB_COLLECTION", "cctv data")

    with MongoClient(uri, serverSelectionTimeoutMS=10000) as client:
        client.admin.command("ping")
        collection = client[database_name][collection_name]
        print(
            f"Connected to database '{database_name}', collection "
            f"'{collection_name}'. Existing camera configuration is preserved."
        )

        _upload_scenario(collection, "Normal baseline", NORMAL_STATUSES)

        while True:
            selection = _prompt_for_scenario().casefold()
            if selection == "end":
                _upload_scenario(collection, "Normal baseline", NORMAL_STATUSES)
                print("All sensors restored to normal. Exiting.")
                return
            if selection not in {"1", "2", "3"}:
                print("Invalid selection; choose 1, 2, 3, or END.")
                continue

            name, statuses = SCENARIOS[int(selection) - 1]
            confirmation = input(
                f"Type UPLOAD to apply {name}, or anything else to cancel: "
            ).strip()
            if confirmation.casefold() != "upload":
                print(f"{name} cancelled; current database values are unchanged.")
                continue

            _upload_scenario(collection, name, statuses)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled; no further database changes were made.")
