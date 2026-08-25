#!/usr/bin/env python3
"""Shared, dependency-light helpers (kept import-safe so CI can run without the
heavy pandas/awswrangler stack)."""

from datetime import date, timedelta


def partition_predicate(start: str, end: str) -> str:
    """
    Turn a YYYY/MM/dd..YYYY/MM/dd window into a pruned predicate over the
    partition columns (year, month, day). This is what lets Athena skip whole
    partitions and keep scans/speed reasonable — the table partitions on
    region/year/month/day, not on a single `eventdate`.
    """
    d0 = date.fromisoformat(start.replace("/", "-"))
    d1 = date.fromisoformat(end.replace("/", "-"))
    if d1 < d0:
        raise ValueError(f"end ({end}) is before start ({start})")

    # Group days into contiguous (year, month) segments -> day ranges.
    segments = []
    d = d0
    current = None
    while d <= d1:
        key = (d.year, f"{d.month:02d}")
        if current is None or current[0] != key:
            if current is not None:
                segments.append(current)
            current = (key, d.day, d.day)
        else:
            current = (key, current[1], d.day)
        d += timedelta(days=1)
    if current is not None:
        segments.append(current)

    parts = []
    for (year, month), d_start, d_end in segments:
        if d_start == d_end:
            parts.append(f"(year = '{year}' AND month = '{month}' AND day = '{d_start:02d}')")
        else:
            parts.append(
                f"(year = '{year}' AND month = '{month}' AND day BETWEEN '{d_start:02d}' AND '{d_end:02d}')"
            )
    return " OR ".join(parts)
