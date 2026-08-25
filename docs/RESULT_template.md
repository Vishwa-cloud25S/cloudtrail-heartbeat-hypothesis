# Experiment result — can background noise lower CloudTrail delay in inactive regions?

> **Status:** ⏳ In progress — fill this in once real data is collected.
> This replaces the synthetic placeholder in the README with measured numbers.

---

## Method (fixed)

- **Heartbeat:** `sts:GetCallerIdentity` + `ec2:DescribeAvailabilityZones`, ~30s cadence,
  injected into the **quiet** region only.
- **Delay metric:** `$file_modified_time` − `eventtime` (Athena pseudo-column), same as
  Sam Cox's notebook.
- **Conditions:** quiet baseline (noise OFF) · quiet + heartbeat (noise ON) · busy control.

## Timeline

| Window | Region | Noise | Start | End |
|---|---|---|---|---|
| Baseline | quiet (eu-west-2) | OFF | _2026/__/__ | _2026/__/__ |
| Treatment | quiet (eu-west-2) | ON | _2026/__/__ | _2026/__/__ |
| Control | busy (us-east-1) | n/a | _2026/__/__ | _2026/__/__ |

Account ID: `123456789012` (dedicated sandbox) · Scheduler enabled at: _datetime_.

## Results

| Condition | Events | avg delay | p95 | p99 | max |
|---|---|---|---|---|---|
| quiet baseline | _ | _ s | _ s | _ s | _ s |
| quiet + heartbeat | _ | _ s | _ s | _ s | _ s |
| busy control | _ | _ s | _ s | _ s | _ s |

**Paired shift (baseline → heartbeat):** avg Δ = _ s · p95 Δ = _ s · p99 Δ = _ s

![final chart](delay_comparison.png)

## Interpretation

- **Does the hypothesis hold?** (quiet+heartbeat closer to busy control than baseline?)
  - Yes / No / Partially / Inconclusive
- **Mechanism:** is the observed change real end-to-end latency, or file-flush
  batching (a near-empty file waits for cadence; a trickle keeps it "open")?
- **Effect size:** X seconds average — is that material for "seconds, not months"
  detection latency in low-traffic fleets?

## Caveats

- Window length / sample size (few events in a truly quiet region → coarse histogram).
- Account-wide traffic confound (was the account quiet?).
- STS is global — confirm the heartbeat's regional events actually landed in the
  target partition (query `02_heartbeat_noise_events.sql`).

## Next / discussion points for Sam

1. Is `GetCallerIdentity` (global) the right canonical call, or is a regional
   call like `DescribeAvailabilityZones` the faithful test of per-region noise?
2. Batching-vs-latency: which interpretation matters for the detection pipeline?
3. Is a keepalive-noise strategy production-viable, or purely an analysis
   artifact? Detection-latency-vs-cost trade-off?

---

*Generate your numbers with:*
```bash
cd analysis && python run_analysis.py \
  --busy-region us-east-1 --quiet-region eu-west-2 \
  --baseline-start <baseline_start> --baseline-end <baseline_end> \
  --heartbeat-start <heartbeat_start> --heartbeat-end <heartbeat_end> \
  --out delay_comparison.png
```
