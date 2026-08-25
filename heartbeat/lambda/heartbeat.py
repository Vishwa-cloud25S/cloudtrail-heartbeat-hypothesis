#!/usr/bin/env python3
"""
Tracebit hypothesis heartbeat.

Generates a small, constant stream of innocuous CloudTrail events in one or
more ("quiet") AWS regions. The idea — straight from Sam Cox's blog post
"How fast is CloudTrail today?" — is to test whether a tiny bit of background
noise lets CloudTrail deliver logs to S3 noticeably faster in an otherwise
inactive region than it does when the region is silent.

Design notes
------------
* EventBridge Scheduler's minimum cadence is 1 minute, so a single invocation
  issues `HEARTBEATS_PER_INVOCATION` passes spaced `HEARTBEAT_INTERVAL_SECONDS`
  apart. 2 passes x 30s = an effective 30s cadence.
* By default we issue BOTH:
    - sts:GetCallerIdentity        (the exact call Sam proposed; needs no IAM
                                    permissions, but STS is a *global* service
                                    and records in us-east-1)
    - ec2:DescribeAvailabilityZones (a regional Read-only call, so the event is
                                    guaranteed to land in the target region's
                                    partition — this is what actually drives
                                    the per-region "noise" in Athena)
  You can tune via HEARTBEAT_METHODS. Keep the runtime under the Lambda
  timeout and under the 60s scheduler period to avoid overlapping invocations.

Configuration (env vars)
------------------------
HEARTBEAT_REGIONS            comma-separated regions (default: eu-west-2)
HEARTBEAT_METHODS            comma-separated "service:method" (default above)
HEARTBEAT_INTERVAL_SECONDS   spacing between passes (default 30)
HEARTBEATS_PER_INVOCATION    passes per 60s invocation (default 2)
MAX_RUNTIME_SECONDS          safety cap so we never hit the invocation timeout
"""

import json
import logging
import os
import sys
import time

import boto3

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# --------------------------------------------------------------------------
# Parsing a "service:method" spec into a callable on a region-scoped client.
# --------------------------------------------------------------------------

def build_calls(methods, region):
    """Return a callable that performs each requested API call in `region`."""
    session = boto3.Session(region_name=region)
    calls = []
    for spec in methods:
        service, method = spec.split(":", 1)
        client = session.client(service)
        calls.append((f"{service}:{method}", getattr(client, method)))
    return calls


def perform_heartbeat(region, methods):
    """Issue all configured calls once and log the outcome."""
    calls = build_calls(methods, region)
    results = []
    for name, fn in calls:
        try:
            resp = fn()
            results.append({"method": name, "status": "ok", "RequestId": resp.get("ResponseMetadata", {}).get("RequestId")})
            log.info("heartbeat ok region=%s method=%s", region, name)
        except Exception as exc:  # noqa: BLE001
            results.append({"method": name, "status": "error", "error": str(exc)})
            log.warning("heartbeat failed region=%s method=%s error=%s", region, name, exc)
    return results


def handler(event, context):  # noqa: ARG001
    regions = [r.strip() for r in os.environ.get("HEARTBEAT_REGIONS", "eu-west-2").split(",") if r.strip()]
    methods = [m.strip() for m in os.environ.get("HEARTBEAT_METHODS", "sts:GetCallerIdentity,ec2:DescribeAvailabilityZones").split(",") if m.strip()]
    interval = int(os.environ.get("HEARTBEAT_INTERVAL_SECONDS", "30"))
    passes = int(os.environ.get("HEARTBEATS_PER_INVOCATION", "2"))
    max_runtime = int(os.environ.get("MAX_RUNTIME_SECONDS", "50"))

    started = time.time()
    all_results = []

    for i in range(passes):
        if (time.time() - started) >= max_runtime:
            break
        for region in regions:
            all_results.extend(perform_heartbeat(region, methods))
        if i < passes - 1:
            time.sleep(interval)

    return {
        "statusCode": 200,
        "body": json.dumps({"region_count": len(regions), "passes": passes, "results": all_results}),
    }


if __name__ == "__main__":
    # Allow local smoke-testing: `python heartbeat.py eu-west-2`
    region = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("HEARTBEAT_REGIONS", "eu-west-2")
    print(handler({}, None))
