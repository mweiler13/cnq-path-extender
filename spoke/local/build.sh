# Local mode's CodeBuild steps (see docs/local-mode.md). The buildspec hands over builds with
# TF_MODE=local. Stacks: client (local/client: security group and role in the hub VPC;
# state network.tfstate, the name the compute Lambda reads) and pcs (the spoke PCS stack,
# given the hub's VPC, subnet and node IPs).
#
# Set by the workflow: TF_ACTION (apply|destroy), TF_STACKS (apply: "client" and/or
# "pcs"), TF_STATE_PREFIX (<hub>/local), TF_VAR_local_* and, for pcs, TF_VAR_network,
# TF_VAR_path, TF_VAR_pcs. Destroy removes pcs then client, then runs local/cleanup.py and
# writes its report to <prefix>/cleanup-report.json.

set -euo pipefail

export TF_VAR_site=local
export TF_VAR_state_bucket="$TF_STATE_BUCKET" TF_VAR_state_region="$TF_STATE_REGION"
export TF_VAR_network_state_key="${TF_STATE_PREFIX}/network.tfstate"
export TF_VAR_cluster_state_key="${TF_STATE_PREFIX}/cluster.tfstate"

dir_of() { case "$1" in client) echo local/client ;; pcs) echo pcs ;; *) echo "unknown stack $1" >&2; exit 1 ;; esac; }
key_of() { case "$1" in client) echo network ;; pcs) echo pcs ;; esac; }

init() {
  local key="${TF_STATE_PREFIX}/$(key_of "$1").tfstate"
  # A lock older than TF_LOCK_STALE_MINUTES belongs to a dead build (as in the buildspec).
  local modified
  if modified=$(aws s3api head-object --region "$TF_STATE_REGION" --bucket "$TF_STATE_BUCKET" \
      --key "${key}.tflock" --query LastModified --output text 2>/dev/null) &&
     [ $(( $(date +%s) - $(date -d "$modified" +%s) )) -gt $(( ${TF_LOCK_STALE_MINUTES:-190} * 60 )) ]; then
    aws s3 rm --region "$TF_STATE_REGION" "s3://${TF_STATE_BUCKET}/${key}.tflock"
  fi
  terraform -chdir="$(dir_of "$1")" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="key=${key}" \
    -backend-config="region=${TF_STATE_REGION}"
}

run() {
  echo "===== terraform ${TF_ACTION} $1 (local mode) ====="
  init "$1"
  terraform -chdir="$(dir_of "$1")" "$TF_ACTION" -input=false -auto-approve
}

case "$TF_ACTION" in
  apply)
    for stack in ${TF_STACKS:-client}; do run "$stack"; done
    ;;
  destroy)
    report=/tmp/cleanup-report.json
    for attempt in 1 2 3; do
      echo "===== local destroy, attempt ${attempt} of 3 ====="
      init client >/dev/null
      vpc=$(terraform -chdir=local/client output -raw vpc_id 2>/dev/null || true)
      subnet=$(terraform -chdir=local/client output -raw private_subnet_id 2>/dev/null || true)
      init pcs >/dev/null
      if [ -n "$(terraform -chdir=pcs state list 2>/dev/null)" ]; then
        export TF_VAR_network="{\"vpc_id\":\"${vpc}\",\"subnet_id\":\"${subnet}\",\"nfs_hosts\":[]}"
        run pcs || echo "terraform destroy of the PCS cluster failed; the sweep follows"
      fi
      run client || echo "terraform destroy of the client stack failed; the sweep follows"
      if python3 local/cleanup.py sweep --hub "$TF_VAR_hub_name" --hub-region "$TF_VAR_region" \
          --report "$report" --run-id "${CODEBUILD_BUILD_ID:-}"; then
        break
      fi
      python3 -c 'import json, sys; sys.exit(not json.load(open(sys.argv[1]))["retryable"])' "$report" || break
      if [ "$attempt" -lt 3 ]; then
        echo "Leftovers remain; retrying in 2 minutes"
        sleep 120
      fi
    done
    aws s3 cp --region "$TF_STATE_REGION" "$report" "s3://${TF_STATE_BUCKET}/${TF_STATE_PREFIX}/cleanup-report.json"
    ;;
  *) echo "TF_ACTION must be apply or destroy, got '$TF_ACTION'"; exit 1 ;;
esac
