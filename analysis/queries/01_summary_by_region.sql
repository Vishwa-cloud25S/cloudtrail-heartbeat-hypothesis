-- Core CloudTrail delivery-delay statistics, for one region + one time window.
-- Adapted directly from Sam Cox's notebook
-- (tracebit-com/cloudtrail-latency-investigation, "data_by_accountregion").
--
-- The delay = eventtime (when the call happened) minus $file_modified_time
-- (when CloudTrail wrote the containing object to S3 — an Athena metadata
-- column over the underlying S3 object).
--
-- Tokens substituted at runtime by analysis/run_analysis.py:
--   :TABLE             Athena table name  (e.g. cloudtrail_logs)
--   :REGION            AWS region          (e.g. eu-west-2)
--   :PARTITION_WHERE   pruned filter over the year/month/day partition columns
--                      (e.g. year='2026' AND month='08' AND day BETWEEN '01' AND '03')
-- Optionally replace the :PARTITION_WHERE ... region filter and add
--   AND eventsource = 'sts.amazonaws.com'   to restrict to STS events (the
-- method Sam used for his busy-region vs quiet-region comparison).

WITH events AS (
    SELECT
        *,
        "$path",
        parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ') AS parsed_eventtime,
        "$file_modified_time",
        "$file_modified_time" - parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ') AS s3_write_delay_interval,
        to_milliseconds("$file_modified_time" - parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ')) / 1000 AS s3_write_delay_seconds,
        regexp_extract("$path", '\d{8}T\d{4}') AS path_timestamp,
        "$file_size"
    FROM ":TABLE"
    WHERE addendum IS NULL            -- drop CloudTrail's internal addendum files
      AND eventtype = 'AwsApiCall'    -- management API calls only
)
SELECT
    region,
    count(1) AS "count",
    min(s3_write_delay_seconds) AS "s3_write_delay_seconds_min",
    avg(s3_write_delay_seconds) AS "s3_write_delay_seconds_avg",
    map_entries(numeric_histogram(100, s3_write_delay_seconds)) AS "s3_write_delay_seconds_histogram",
    avg("$file_size") AS size,
    approx_percentile(s3_write_delay_seconds, 0.5)  AS "s3_write_delay_seconds_p50",
    approx_percentile(s3_write_delay_seconds, 0.95) AS "s3_write_delay_seconds_p95",
    approx_percentile(s3_write_delay_seconds, 0.99) AS "s3_write_delay_seconds_p99",
    approx_percentile(s3_write_delay_seconds, 0.999) AS "s3_write_delay_seconds_p999",
    max(s3_write_delay_seconds) AS "s3_write_delay_seconds_max",
    count(1) FILTER (WHERE s3_write_delay_seconds <= 60)   AS "s3_write_delay_seconds_count_lt_60",
    count(1) FILTER (WHERE s3_write_delay_seconds <= 300)  AS "s3_write_delay_seconds_count_lt_300",
    count(1) FILTER (WHERE s3_write_delay_seconds <= 600)  AS "s3_write_delay_seconds_count_lt_600",
    count(1) FILTER (WHERE s3_write_delay_seconds <= 3600) AS "s3_write_delay_seconds_count_lt_3600",
    count(1) FILTER (WHERE s3_write_delay_seconds <= 86400) AS "s3_write_delay_seconds_count_lt_86400"
FROM events
WHERE :PARTITION_WHERE
  AND region = ':REGION'
GROUP BY region
