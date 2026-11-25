#!/usr/bin/env bash
# Read-only check that a removed control plane (bootstrap destroy) left nothing behind.
#
# Usage: scripts/check-control-plane-cleanup.sh <hub_deployment_unique_name> <hub_region> <state_bucket>
#   e.g. scripts/check-control-plane-cleanup.sh myhub-abc123 us-west-2 my-tfstate-bucket
#
# Checks for everything bootstrap creates, all named after the hub. Only describe/list
# calls; it never changes anything. Run spoke/cleanup.py check for each spoke region as
# well.

set -uo pipefail

if [ $# -ne 3 ]; then
  sed -n '4,5p' "$0" | sed 's/^# //'
  exit 2
fi

HUB="$1"
REGION="$2"
BUCKET="$3"

found=0

# check <label> <command...>: run a query; report its output as leftovers, or "none".
check() {
  local label="$1"
  shift
  local out
  out=$("$@" 2>&1 | grep -v '^None$' | sed '/^[[:space:]]*$/d')
  if [ -z "$out" ]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FOUND %s\n' "$label"
    printf '%s\n' "$out" | sed 's/^/          /'
    found=1
  fi
}

echo "Control plane for hub ${HUB} (${REGION})"
echo

echo "Created by bootstrap"
check "anything tagged cnq-path-extender:hub=${HUB} in ${REGION}" \
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=cnq-path-extender:hub,Values=${HUB}" \
  --query 'ResourceTagMappings[].ResourceARN' --output text
check "state machines deploy-spoke, destroy-spoke, refresh-hub, deploy-local, destroy-local (-${HUB})" \
  aws stepfunctions list-state-machines --region "$REGION" \
  --query "stateMachines[?contains(['deploy-spoke-${HUB}', 'destroy-spoke-${HUB}', 'refresh-hub-${HUB}', 'deploy-local-${HUB}', 'destroy-local-${HUB}'], name)].name" --output text
check "CodeBuild project spoke-build-${HUB}" \
  aws codebuild batch-get-projects --region "$REGION" --names "spoke-build-${HUB}" \
  --query 'projects[].name' --output text
check "Lambda function cnq-path-extender-${HUB}" \
  aws lambda list-functions --region "$REGION" \
  --query "Functions[?FunctionName=='cnq-path-extender-${HUB}'].FunctionName" --output text
check "SNS topic cnq-path-extender-${HUB}" \
  aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':cnq-path-extender-${HUB}')].TopicArn" --output text
check "IAM roles cnq-path-extender-*-${HUB}" \
  aws iam list-roles \
  --query "Roles[?starts_with(RoleName, 'cnq-path-extender-') && ends_with(RoleName, '-${HUB}')].RoleName" --output text
check "security groups cdf-${HUB} / cnq-path-extender-lambda-${HUB}" \
  aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=cdf-${HUB},cnq-path-extender-lambda-${HUB}" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text
check "Lambda network interfaces still held for cnq-path-extender-${HUB} (released by AWS, can take 20-40 min)" \
  aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=description,Values=AWS Lambda VPC ENI-cnq-path-extender-${HUB}*" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text
check "log groups /aws/lambda/cnq-path-extender-${HUB}, /aws/codebuild/spoke-build-${HUB}" \
  bash -c 'for p in "/aws/lambda/cnq-path-extender-$2" "/aws/codebuild/spoke-build-$2"; do
             aws logs describe-log-groups --region "$1" --log-group-name-prefix "$p" --query "logGroups[].logGroupName" --output text
           done' _ "$REGION" "$HUB"
echo

echo "Hub cluster"
check "hub nodes still carrying the CDF security group (detach it in the hub's Terraform)" \
  bash -c 'sg=$(aws ec2 describe-security-groups --region "$1" --filters "Name=group-name,Values=cdf-$2" \
             --query "SecurityGroups[0].GroupId" --output text)
           [ "$sg" = None ] && exit 0
           aws ec2 describe-network-interfaces --region "$1" --filters "Name=group-id,Values=$sg" \
             --query "NetworkInterfaces[].[NetworkInterfaceId,Description]" --output text' _ "$REGION" "$HUB"
echo

echo "State bucket s3://${BUCKET}/${HUB}/ (yours; Terraform empties but doesn't delete these)"
check "objects under ${HUB}/" \
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${HUB}/" \
  --query 'Contents[].[Key,Size]' --output text
check "old object versions / delete markers under ${HUB}/ (versioned bucket)" \
  bash -c 'aws s3api list-object-versions --bucket "$1" --prefix "$2/" --query "Versions[?IsLatest==\`false\`].[Key,VersionId]" --output text
           aws s3api list-object-versions --bucket "$1" --prefix "$2/" --query "DeleteMarkers[].[Key,\`delete-marker\`]" --output text' _ "$BUCKET" "$HUB"
echo

echo "Left on purpose (not checked)"
echo "  EventBridge rule StepFunctionsGetEventForCodeBuildStartBuildRule: created by AWS once"
echo "  per account/region and shared by every Step Functions workflow that waits on CodeBuild."
echo

if [ "$found" -eq 0 ]; then
  echo "Clean: nothing from the control plane is left."
else
  echo "Leftovers found (above)."
  exit 1
fi
