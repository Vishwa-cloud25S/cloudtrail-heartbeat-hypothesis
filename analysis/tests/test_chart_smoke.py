#!/usr/bin/env python3
"""Charts the delay comparison using *synthetic* data to prove the plotting code
renders end-to-end without any AWS access. Used by CI as a smoke test."""
import json
import os
import sys
import tempfile

import matplotlib

matplotlib.use("Agg")  # no display; write to file

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import run_analysis  # noqa: E402  (imports the plotting + histogram helpers)


def synth(scale: float) -> pd.Series:
    """Build an aggregate stats row in the exact shape Athena returns."""
    rng = np.random.default_rng(42)
    vals = rng.gamma(2, 45, 80000) * scale
    bins = np.linspace(0, 3000, 100)
    hist, edges = np.histogram(vals, bins=bins)
    pairs = [[float(bins[i] + 15), float(hist[i])] for i in range(len(hist))]
    return pd.Series(
        {
            "s3_write_delay_seconds_histogram": json.dumps(pairs).replace("[", "{").replace("]", "}"),
            "s3_write_delay_seconds_avg": float(np.mean(vals)),
            "s3_write_delay_seconds_p95": float(np.percentile(vals, 95)),
            "s3_write_delay_seconds_p99": float(np.percentile(vals, 99)),
        }
    )


def main() -> int:
    run_analysis.init_style()
    results = {
        "quiet-baseline": synth(1.0),
        "quiet-heartbeat": synth(0.78),
        "busy-control": synth(0.6),
    }
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "chart.png")
        fig = run_analysis.draw_comparison(results, out)
        assert os.path.exists(out) and os.path.getsize(out) > 0, "chart not written"
        assert fig is not None
        print(f"chart rendered OK -> {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
