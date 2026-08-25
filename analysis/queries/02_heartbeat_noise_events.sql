-- Confirm the heartbeat is actually producing the expected CloudTrail events,
-- and inspect the delay distribution for exactly those noise events.
-- The "did my noise take?" query — run it for the heartbeat window.
--
-- Tokens substituted at runtime: :TABLE, :REGION, :PARTITION_WHERE.

WITH events AS (
    SELECT
        *,
        "$path",
        parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ') AS parsed_eventtime,
        "$file_modified_time",
        "$file_modified_time" - parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ') AS s3_write_delay_interval,
        to_milliseconds("$file_modified_time" - parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ')) / 1000 AS s3_write_delay_seconds
    FROM ":TABLE"
    WHERE addendum IS NULL
      AND eventtype = 'AwsApiCall'
)
SELECT
    eventsource,
    eventname,
    count(1) AS "count",
    min(parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ')) AS first_event,
    max(parse_datetime(eventtime, 'YYYY-MM-dd''T''HH:mm:ssZ')) AS last_event,
    avg(s3_write_delay_seconds) AS "avg_delay_seconds",
    approx_percentile(s3_write_delay_seconds, 0.95) AS "p95_delay_seconds",
    sourceipaddress AS source_ip,
    useragent
FROM events
WHERE :PARTITION_WHERE
  AND region = ':REGION'
  AND eventname IN ('GetCallerIdentity', 'DescribeAvailabilityZones', 'DescribeRegions')
GROUP BY eventsource, eventname, sourceipaddress, useragent
ORDER BY count(1) DESC
