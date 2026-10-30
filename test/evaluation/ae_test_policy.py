"""Shared synthetic policy for host evolution integration tests."""
import json
from pathlib import Path


def policy(prefix="authored:"):
    result = json.loads((Path(__file__).with_name("policy.json")).read_bytes())
    for case in result["cases"]:
        if case["expected_type"] == "reply":
            case["expected_text"] = case["expected_text"].replace("authored:", prefix, 1)
    return result
