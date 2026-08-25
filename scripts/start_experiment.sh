#!/usr/bin/env bash
#
# One-shot launcher for the Tracebit CloudTrail heartbeat experiment.
# Safe to run on YOUR machine / a runner that already has AWS credentials
# configured (SSO or ~/.aws/credentials). Never paste credentials into chat.
#
# What it does:
#   1. Verifies AWS credentials + Terraform exist.
#   2. Applies the Terraform (multi-region trail, S3, Athena partition-projection
#      table, heartbeat Lambda + Scheduler, currently DISABLED).
#   3. Builds and prints the exact experiment date windows (baseline OFF, then
#      treatment ON) and writes them to a ready-to-run command for run_analysis.py.
#   4. Prints exact next steps + sanity-check AWS CLI commands.
#
# Usage:
#   chmod +x scripts/start_experiment.sh
#   ./scripts/start_experiment.sh            # use repo defaults
#   BUSY_REGION=us-east-1 QUIET_REGION=eu-west-2 ./scripts/start_experiment.sh
#
# Notes:
#   * The heartbeat scheduler is left DISABLED so your baseline (noise-OFF)
#     window is clean. You enable it via `aws scheduler start-schedule`.
#   * Requires terraform >= 1.5 and AWS credentials. Idempotent: safe to re-run.

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
BUSY_REGION="${BUSY_REGION:-us-east-1}"
QUIET_REGION="${QUIET_REGION:-eu-west-2}"
SCHEDULE_NAME="${PROJECT_PREFIX:-tracebit-ct-heartbeat}-heartbeat-schedule"

echo "==> Preflight checks"
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not found. Install from https://developer.hashicorp.com/terraform/install"; exit 1; }
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: no AWS credentials detected. Configure SSO or ~/.aws/credentials first."
  echo "  e.g.  aws configure sso   (recommended)   or   aws configure"
  echo "  Never paste access keys into a chat/README."
  exit 1
fi
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "     Authenticated as account: ${ACCOUNT_ID}"

echo "==> Terraform init + apply in ${TF_DIR}"
cd "${TF_DIR}"
terraform init -input=false
terraform plan -input=false -out=/tmp/ct-plan.tfplan
terraform apply -input=false /tmp/ct-plan.tfplan

echo
echo "==> Trail + Athena + Lambda provisioned."

# The scheduler was created DISABLED (state=ENABLED in code is overridden here
# only if you choose; we leave it disabled so baseline is a clean noise-OFF
# window). Confirm current state of the relevant resources:
echo
echo "--- Heartbeat schedule state (should be DISABLED for baseline) ---"
aws scheduler get-schedule --name "${SCHEDULE_NAME}" \
  --query 'state' --output text 2>/dev/null \
  || echo "  (schedule ${SCHEDULE_NAME} not found there; check project_prefix)"

echo
echo "==================================================================="
echo "  EXPERIMENT WINDOWS (generate on your machine so dates are real)"
echo "==================================================================="
# Generate windows relative to today. Baseline = days [1..3), treatment = [3..5).
# This means: let baseline accumulate for ~2 days with the scheduler OFF, then
# enable the heartbeat for ~2 days, then run the query.
export TODAY="$(date -u +%Y/%m/%d)"
BASELINE_START="$(date -u -d "+0 day" +%Y/%m/%d)"
BASELINE_END="$(date -u -d "+2 day" +%Y/%m/%d)"
HEARTBEAT_START="$(date -u -d "+2 day" +%Y/%m/%d)"
HEARTBEAT_END="$(date -u -d "+4 day" +%Y/%m/%d)"

echo "  Baseline (noise OFF):  ${BASELINE_START} -> ${BASELINE_END}"
echo "  Treatment (noise ON):  ${HEARTBEAT_START} -> ${HEARTBEAT_END}"
echo
echo "  Auto-run command (paste after the treatment window elapses):"
echo
echo "  cd analysis && python run_analysis.py \\"
echo "    --busy-region ${BUSY_REGION} --quiet-region ${QUIET_REGION} \\"
echo "    --baseline-start ${BASELINE_START} --baseline-end ${BASELINE_END} \\"
echo "    --heartbeat-start ${HEARTBEAT_START} --heartbeat-end ${HEARTBEAT_END} \\"
echo "    --out delay_comparison.png"

cat <<'NEXT'

===================================================================
  NEXT STEPS
===================================================================
  1. LET BASELINE ACCUMULATE (~2 days). Do NOT give the heartbeat noise
     yet — the scheduler is disabled so this window is a clean noise-OFF
     baseline. Confirm logs are arriving:
        aws cloudtrail get-trail-status --name <prefix>-trail

  2. ENABLE THE HEARTBEAT at end of baseline:
        aws scheduler start-schedule --name <prefix>-heartbeat-schedule
     Wait ~2 days (the treatment window). Verify noise events landed:
        aws athena start-query-execution ... (or run query 02)

  3. RUN THE ANALYSIS with the printed command above (or via the CI
     "Real analysis" workflow with these same dates).

  4. STOP THE HEARTBEAT when done to avoid continued cost/noise:
        aws scheduler stop-schedule --name <prefix>-heartbeat-schedule
===================================================================
NEXT
echo
echo "Done. Adjust dates as needed; re-running this script is safe (idempotent)."
