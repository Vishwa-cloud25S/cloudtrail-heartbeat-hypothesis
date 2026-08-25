# IAM: what permissions you actually need (and why)

This experiment uses **two distinct privilege levels**. Don't lump them into one
key, and don't use your account root key.

## 1. Provisioning (Terraform `apply`) — needs broad create/delete perms

Terraform is what *creates* the CloudTrail trail, S3 bucket, Glue table, Lambda,
and Scheduler. It needs `iam:*`, `cloudtrail:*`, `s3:*`, `glue:*`, `athena:*`,
`lambda:*`, `scheduler:*`, `logs:*`, `events:*` (create/read/update/delete).

**Recommended:** run Terraform with an **AdministratorAccess-equivalent** IAM
role/policy, but only in a **dedicated, disposable AWS account** that contains
nothing sensitive. Never use root. When you're done, you can tear the whole
thing down with `terraform destroy` and the account is gone.

> This is the standard, safe pattern for a sandbox experiment: create a fresh
> account, run Terraform there, and it can't touch anything you care about.

## 2. Running the analysis (read + query) — least privilege

Once the resources exist, the *query* (Terraform-created resources + Athena) only
needs read/query permissions. Attach
[`analysis_least_privilege.json`](analysis_least_privilege.json) to a separate,
narrow IAM user/role and use it for the `run_analysis.py` step and the CI
`Real analysis` job.

It grants exactly:
- `sts:GetCallerIdentity` / `iam:GetUser` — identity check
- `cloudtrail:GetTrailStatus`, `LookupEvents`, `DescribeTrails` — trail sanity
- `athena:*` query lifecycle — run the SQL
- `glue:GetTable/GetDatabase` — read the Athena table definition
- `s3:GetObject/ListBucket` on the `*cloudtrail*` and `*athena*` buckets — read
  the data + Athena results
- `scheduler:StartSchedule/StopSchedule` — start/stop the heartbeat

### Apply it

```bash
# 1. Create the policy
aws iam create-policy --policy-name tracebit-ct-analysis \
  --policy-document file://iam/analysis_least_privilege.json

# 2. Attach to a user/role (or create a fresh one)
aws iam attach-user-policy --user-name <your-user> \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/tracebit-ct-analysis
```

Then configure credentials for that narrow user (SSO or a scoped access key —
**never** pasted into chat) and run `scripts/start_experiment.sh`.

## Security note for the demo/Tracebit conversation

The narrow policy above is exactly the kind of thing that reads well: you've
thought about least-privilege for a security-adjacent experiment. If the
provisioning account is a throwaway sandbox, mention that too — it shows you're
responsible with the blast radius, which is precisely the mindset a CSE at a
security company wants to see.
