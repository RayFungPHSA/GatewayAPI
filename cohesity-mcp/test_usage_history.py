import json
import os
import tempfile
import unittest
from unittest.mock import patch

import cohesity_mcp as module


class FakeClient:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def request(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return json.dumps(self.payload)


class UsageHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "usage.sqlite3")
        self.env = patch.dict(os.environ, {"COHESITY_USAGE_DB": self.db_path})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp_dir.cleanup()

    def collect(self, day, rows):
        client = FakeClient({"statsList": rows})
        captured_at = module.datetime.fromisoformat(f"{day}T12:00:00+00:00")
        fake_now = type("FakeDateTime", (), {
            "now": staticmethod(lambda tz: captured_at)
        })
        with patch.object(module, "datetime", fake_now):
            result = module.collect_protection_group_usage(client, "123", "test-cluster")
        self.assertEqual(client.calls[0][0][1], "/stats/consumers")
        self.assertEqual(client.calls[0][1]["params"]["consumerType"], "kProtectionRuns")
        return result

    @staticmethod
    def row(name, consumed, data=0, resiliency=0):
        return {"name": name, "stats": {
            "storageConsumedBytes": consumed,
            "dataWrittenBytes": data,
            "localTierResiliencyImpactBytes": resiliency,
        }}

    def test_collect_get_and_compare(self):
        self.collect("2026-07-03", [self.row("group-a", 1_000_000_000_000), self.row("removed", 500_000_000_000)])
        self.collect("2026-08-03", [self.row("group-a", 1_250_000_000_000), self.row("new", 100_000_000_000)])

        july = module.get_protection_group_usage_snapshot("123", "2026-07-03")
        self.assertEqual(july["totalConsumedTB"], 1.5)

        comparison = module.compare_protection_group_usage_snapshots("123", "2026-07-03", "2026-08-03")
        by_name = {row["name"]: row for row in comparison["protectionGroups"]}
        self.assertEqual(by_name["group-a"]["changeTB"], 0.25)
        self.assertEqual(by_name["group-a"]["changePercent"], 25.0)
        self.assertEqual(by_name["new"]["changePercent"], "new")
        self.assertEqual(by_name["removed"]["changeTB"], -0.5)

    def test_missing_date_and_invalid_date_are_clear(self):
        with self.assertRaisesRegex(ValueError, "YYYY-MM-DD"):
            module.get_protection_group_usage_snapshot("123", "July 3")
        with self.assertRaisesRegex(ValueError, "No stored usage snapshot"):
            module.get_protection_group_usage_snapshot("123", "2026-07-03")


if __name__ == "__main__":
    unittest.main()
