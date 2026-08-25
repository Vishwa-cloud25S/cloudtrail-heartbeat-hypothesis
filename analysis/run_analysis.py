#!/usr/bin/env python3
"""
Run the CloudTrail delivery-delay experiment and produce the comparison chart.

This extends Sam Cox's published notebook
(tracebit-com/cloudtrail-latency-investigation) to test his open question:

    "Is it possible to induce a noticeably lower average delay in inactive
     regions by creating a small but frequent level of background noise; say
     by calling GetCallerIdentity every 30 seconds or so?"

For each condition it runs the same Athena summary query (01_summary_by_region.sql)
and plots the cumulative distribution of s3_write_delay_seconds exactly the way
Sam did (symlog x-axis, dashed ticks at 1/5/10 min/1h/24h, % cumulative).

Usage
-----
    python run_analysis.py --aws-profile myprofile --database cloudtrail_latency \
        --table cloudtrail_logs --workgroup cloudtrail-latency \
        --busy-region us-east-1 --quiet-region eu-west-2 \
        --baseline-start 2026/08/01 --baseline-end 2026/08/03 \
        --heartbeat-start 2026/08/05 --heartbeat-end 2026/08/07 \
        --out delay_comparison.png

Requirements: pip install -r ../requirements.txt  (awswrangler, boto3, pandas,
numpy, matplotlib, pyarrow, jupyter).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
from datetime import timedelta

import awswrangler as wr
import boto3
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib import cycler
from matplotlib.ticker import PercentFormatter

QUERY_DIR = pathlib.Path(__file__).parent / "queries"
SUMMARY_TEMPLATE = (QUERY_DIR / "01_summary_by_region.sql").read_text()

# --------------------------------------------------------------------------
# Athena client (mirrors Sam's execute_query helper)
# --------------------------------------------------------------------------


def make_session(profile: str | None):
    """Build a boto3 session; None profile uses the default credential chain."""
    return boto3.session.Session(profile_name=profile) if profile else boto3.session.Session()


def run_query(session, query: str, database: str, workgroup: str, catalog: str) -> pd.DataFrame:
    return wr.athena.read_sql_query(
        query,
        database=database,
        workgroup=workgroup,
        data_source=catalog,
        boto3_session=session,
        athena_cache_settings={"max_cache_seconds": 60 * 60},
        ctas_approach=False,
    )


def partition_predicate(start: str, end: str) -> str:
    """
    Turn a YYYY/MM/dd..YYYY/MM/dd window into a pruned predicate over the
    partition columns (year, month, day). This is what lets Athena skip
    partitions and keep scans/speed reasonable — the table partitions on
    region/year/month/day, not on a single `eventdate`.
    """
    from datetime import date, timedelta

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


def summary_for(session, database, workgroup, catalog, table, start, end, region) -> pd.Series:
    """Run the summary query for one region + partition window; return the stats row."""
    query = (
        SUMMARY_TEMPLATE.replace(":TABLE", table)
        .replace(":PARTITION_WHERE", partition_predicate(start, end))
        .replace(":REGION", region)
    )
    df = run_query(session, query, database, workgroup, catalog)
    if df.empty:
        raise RuntimeError(f"No events for region={region} window={start}..{end}")
    return df.iloc[0]


# --------------------------------------------------------------------------
# Histogram parsing (same as Sam: Athena returns the array-of-pairs as a
# brace-string that pops into JSON once braces become brackets).
# --------------------------------------------------------------------------


def parse_histogram(raw) -> tuple[np.ndarray, np.ndarray]:
    text = raw if isinstance(raw, str) else json.dumps(raw)
    as_json = text.replace("{", "[").replace("}", "]")
    pairs = json.loads(as_json)
    bins = np.array([p[0] for p in pairs], dtype=float)
    counts = np.array([p[1] for p in pairs], dtype=float)
    # Extend the final bin to 24h so the cumulative curve reaches 100%.
    if bins[-1] < 24 * 3600:
        bins = np.append(bins, 24 * 3600)
        counts = np.append(counts, 0)
    return bins, counts


# --------------------------------------------------------------------------
# Plotting (faithful to Sam's Tokyo-Night style draw_latency)
# --------------------------------------------------------------------------


def init_style() -> None:
    background = "#24283b"
    foreground = "#c0caf5"
    comment = "#565f89"
    cycle = [
        "#7aa2f7",  # blue
        "#ff9e64",  # orange
        "#9ece6a",  # green
        "#f7768e",  # red
        "#9d7cd8",  # purple
        "#bb9af7",  # magenta
        "#565f89",  # comment
        "#e0af68",  # yellow
        "#7dcfff",  # cyan
    ]
    plt.style.use(
        {
            "lines.color": foreground,
            "patch.edgecolor": foreground,
            "text.color": foreground,
            "axes.facecolor": background,
            "axes.edgecolor": foreground,
            "axes.labelcolor": foreground,
            "xtick.color": foreground,
            "ytick.color": foreground,
            "legend.framealpha": 0,
            "grid.color": comment,
            "figure.facecolor": background,
            "figure.edgecolor": background,
            "savefig.facecolor": background,
            "savefig.edgecolor": background,
            "axes.prop_cycle": cycler(color=cycle),
        }
    )


TICK_SECONDS = [60, 300, 600, 3600, 86400]
TICK_LABELS = ["1 min", "5 min", "10 min", "1 hour", "24 hours"]


def draw_comparison(results: dict, out_path: str) -> plt.Figure:
    """
    results: {label: stats_row}. Overlays the cumulative delay distribution for
    every condition on a single symlog axis ("5 min" is the linear/log knee).
    """
    fig, ax = plt.subplots(figsize=(12, 7))

    for label, row in results.items():
        bins, counts = parse_histogram(row["s3_write_delay_seconds_histogram"])
        total = counts.sum()
        cumulative = 100 * np.cumsum(counts) / total
        ax.step(bins, cumulative, where="post", label=_with_metrics(label, row))
        ax.set_xscale("symlog", linthresh=600)
        ax.set_xticks(TICK_SECONDS, TICK_LABELS)
        ax.set_xticks([], [], minor=True)
        ax.yaxis.set_major_formatter(PercentFormatter())

    for tick in TICK_SECONDS:
        ax.axvline(x=tick, linestyle="dashed", alpha=0.3)

    ax.set_xlim(10, 86400)
    ax.set_ylim(0, 103)
    ax.set_xmargin(0)
    ax.set_ymargin(0.05)
    ax.set_xlabel("CloudTrail delay delivering to S3")
    ax.set_ylabel("Cumulative events delivered")
    ax.set_title("Null hypothesis test: background noise in an inactive region")
    ax.legend(loc="lower right")

    fig.tight_layout()
    fig.savefig(out_path, dpi=160)
    return fig


def _with_metrics(label: str, row: pd.Series) -> str:
    return f"{label}  (avg {_fmt(row['s3_write_delay_seconds_avg'])}  p95 {_fmt(row['s3_write_delay_seconds_p95'])})"


def _fmt(seconds) -> str:
    value = float(seconds)
    if value < 3600:
        return f"{value:.0f}s"
    return str(timedelta(seconds=round(value)))


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--aws-profile", default=None)
    ap.add_argument("--database", default="cloudtrail_latency")
    ap.add_argument("--table", default="cloudtrail_logs")
    ap.add_argument("--workgroup", default="cloudtrail-latency")
    ap.add_argument("--catalog", default="AwsDataCatalog")
    ap.add_argument("--busy-region", default="us-east-1")
    ap.add_argument("--quiet-region", default="eu-west-2")
    ap.add_argument("--baseline-start", required=True, help="partition date YYYY/MM/dd (noise OFF)")
    ap.add_argument("--baseline-end", required=True, help="partition date YYYY/MM/dd (noise OFF)")
    ap.add_argument("--heartbeat-start", required=True, help="partition date YYYY/MM/dd (noise ON)")
    ap.add_argument("--heartbeat-end", required=True, help="partition date YYYY/MM/dd (noise ON)")
    ap.add_argument("--out", default="delay_comparison.png")
    args = ap.parse_args()

    init_style()
    session = make_session(args.aws_profile)

    conditions = [
        (f"{args.quiet_region} quiet region — baseline", args.quiet_region, args.baseline_start, args.baseline_end),
        (f"{args.quiet_region} quiet region — heartbeat", args.quiet_region, args.heartbeat_start, args.heartbeat_end),
        (f"{args.busy_region} busy region — control", args.busy_region, args.heartbeat_start, args.heartbeat_end),
    ]

    results = {}
    stats_rows = []
    for label, region, start, end in conditions:
        row = summary_for(session, args.database, args.workgroup, args.catalog, args.table, start, end, region)
        results[label] = row
        stats_rows.append(
            {
                "condition": label,
                "region": region,
                "events": int(row["count"]),
                "avg_delay_s": round(float(row["s3_write_delay_seconds_avg"]), 1),
                "p95_delay_s": round(float(row["s3_write_delay_seconds_p95"]), 1),
                "p99_delay_s": round(float(row["s3_write_delay_seconds_p99"]), 1),
                "max_delay_s": round(float(row["s3_write_delay_seconds_max"]), 1),
            }
        )
        print(f"  {label}: {stats_rows[-1]}")

    fig = draw_comparison(results, args.out)
    plt.show() if not os.environ.get("CI") else None
    print(f"\nWrote chart -> {args.out}")
    print("\nSummary table:")
    print(pd.DataFrame(stats_rows).to_string(index=False))


if __name__ == "__main__":
    main()
