"""Run the unchanged upstream tests that do not require a Windows desktop."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
WINDOWS_ONLY = {
    "tests.test_table.BilliardsMotionTests.test_pointer_charges_linearly_in_one_and_a_half_seconds",
    "tests.test_table.BilliardsMotionTests.test_pointer_cycles_and_releases_at_the_current_power",
    "tests.test_table.BilliardsMotionTests.test_release_outside_table_cancels_cycle_and_new_press_starts_at_zero",
    "tests.test_table.BilliardsMotionTests.test_zero_charge_is_a_small_nudge_and_full_power_is_unchanged",
    "tests.test_rank.ApiTests.test_rankings_preserves_round_counts_and_formats_optional_details",
}

def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item

suite = unittest.defaultTestLoader.loadTestsFromNames([
    "tests.test_table", "tests.test_balls", "tests.test_card", "tests.test_rank", "tests.test_update",
])
tests = list(flatten(suite))
excluded = WINDOWS_ONLY if sys.platform != "win32" else set()
for identity in sorted(excluded):
    print(f"Windows-only, not executed on this OS: {identity}")
selected = unittest.TestSuite(test for test in tests if test.id() not in excluded)
result = unittest.TextTestRunner(verbosity=1).run(selected)
sys.exit(0 if result.wasSuccessful() else 1)
