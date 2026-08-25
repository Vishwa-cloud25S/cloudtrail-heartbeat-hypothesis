#!/usr/bin/env python3
"""Unit tests for the Athena partition predicate builder (no AWS required)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from partition_utils import partition_predicate  # noqa: E402


class TestPartitionPredicate(unittest.TestCase):
    def test_single_day(self):
        got = partition_predicate("2026/08/05", "2026/08/05")
        self.assertEqual(got, "(year = '2026' AND month = '08' AND day = '05')")

    def test_single_month_span(self):
        got = partition_predicate("2026/08/01", "2026/08/03")
        self.assertEqual(got, "(year = '2026' AND month = '08' AND day BETWEEN '01' AND '03')")

    def test_cross_month_span(self):
        got = partition_predicate("2026/07/30", "2026/08/02")
        self.assertEqual(
            got,
            "(year = '2026' AND month = '07' AND day BETWEEN '30' AND '31') OR "
            "(year = '2026' AND month = '08' AND day BETWEEN '01' AND '02')",
        )

    def test_cross_year_span(self):
        got = partition_predicate("2025/12/31", "2026/01/01")
        self.assertEqual(
            got,
            "(year = '2025' AND month = '12' AND day = '31') OR "
            "(year = '2026' AND month = '01' AND day = '01')",
        )

    def test_end_before_start_raises(self):
        with self.assertRaises(ValueError):
            partition_predicate("2026/08/05", "2026/08/01")


if __name__ == "__main__":
    unittest.main()
