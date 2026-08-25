-- Optional: compare delivery latency between CloudTrail's S3 delivery path
-- (what the rest of this repo measures) and CloudTrail Lake, which ingests
-- events into an Iceberg table and is queryable in Athena with a *different*
-- ingestion cadence — typically much faster than the ~5 min S3 cadence.
--
-- This is the natural "what's next" from the README: if the S3 path is the
-- bottleneck behind Tracebit's 'seconds, not months' claim, CloudTrail Lake is
-- the alternative event source to measure against.
--
-- Prerequisite: a CloudTrail Lake (AWS::CloudTrail::Channel / EventDataStore)
-- has been created and you have an Athena table over it (typically auto-created
-- as <datastore>_athena_cloudtrail).
--
-- Tokens substituted at runtime:
--   :LAKE_TABLE   the Athena table backing the CloudTrail Lake event data store
--   :REGION       the AWS region to filter
--   :START/:END   event timestamps in 'YYYY-MM-dd''T''HH:mm:ssZ' form
--
-- NOTE: CloudTrail Lake does NOT expose an S3 "$file_modified_time", so latency
-- here is measured differently if you want it: CloudTrail Lake events carry an
-- 'ingestion_time' field. Compare eventTime to ingestion_time. There is no
-- histogram of file-write delay because there's no file — this query simply
-- reports per-event ingress latency percentiles, which is the comparable metric.

SELECT
    count(*) AS event_count,
    from_unixtime(avg(epoch(ingestion_time) - epoch(eventTime))) AS avg_ingest_latency,
    approx_percentile(epoch(ingestion_time) - epoch(eventTime), 0.5) AS p50_latency_s,
    approx_percentile(epoch(ingestion_time) - epoch(eventTime), 0.95) AS p95_latency_s,
    approx_percentile(epoch(ingestion_time) - epoch(eventTime), 0.99) AS p99_latency_s,
    max(epoch(ingestion_time) - epoch(eventTime)) AS max_latency_s
FROM ":LAKE_TABLE"
WHERE region = ':REGION'
  AND eventTime BETWEEN from_iso8601_timestamp(':START') AND from_iso8601_timestamp(':END')
  AND eventType IN ('AwsApiCall')
GROUP BY 1
