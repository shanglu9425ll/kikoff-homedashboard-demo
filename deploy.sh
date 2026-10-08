#!/usr/bin/env bash
# Deploys the Kikoff showcase to a Hackweek sandbox as an ECS Fargate nginx service
# behind an internal ALB with a private HTTPS name. Follows CLAUDE.md "ECS / static sites".
# Usage: DEPLOYER_EMAIL=you@kikoff.com [OWNER_EMAIL=...] bash deploy.sh
# Each created resource ID is appended to deploy-state.env so a partial run can resume/clean up.
set -euo pipefail
cd "$(dirname "$0")"

: "${DEPLOYER_EMAIL:?Set DEPLOYER_EMAIL to your verified company email}"
OWNER_EMAIL="${OWNER_EMAIL:-$DEPLOYER_EMAIL}"
PROJECT_SLUG="kikoff-showcase"
PERSON="$(echo "${DEPLOYER_EMAIL%@*}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g')"
NAME="hackweek-${PERSON}-${PROJECT_SLUG}"
SHORT="hw-${PERSON}-kshow"          # ALB/target group names are limited to 32 chars

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_SESSION_NAME
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS
export AWS_PROFILE="${AWS_PROFILE:-hackweek-a}"
export AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 AWS_STS_REGIONAL_ENDPOINTS=regional AWS_PAGER=""

case "$AWS_PROFILE" in
  hackweek-a)
    ACCOUNT=632472162753; HTTPS_DOMAIN=a.hackweek.kikoff.dev
    SUBNETS="subnet-0f12bcf8bb29245a6,subnet-096bef3bec563ef8d"; SG=sg-0be56bdc1d1df9d0e ;;
  hackweek-b)
    ACCOUNT=552808407519; HTTPS_DOMAIN=b.hackweek.kikoff.dev
    SUBNETS="subnet-0e1f2acb4027d429b,subnet-0cbe55e77aa88795c"; SG=sg-037cc04918927d44d ;;
  *) echo "Select hackweek-a or hackweek-b" >&2; exit 1 ;;
esac
BOUNDARY="arn:aws:iam::${ACCOUNT}:policy/hackweek-permissions-boundary"
HOST="${PERSON}-${PROJECT_SLUG}.${HTTPS_DOMAIN}"

identity="$(aws sts get-caller-identity --query '[Account,Arn]' --output text)"
read -r actual arn <<< "$identity"
if [ "$actual" != "$ACCOUNT" ] || [[ "$arn" != *"assumed-role/AWSReservedSSO_hackweek-administrator_"* ]]; then
  echo "Identity mismatch: $identity" >&2; exit 1
fi

STATE=deploy-state.env
touch "$STATE"
record() { echo "$1=$2" >> "$STATE"; echo "  $1=$2"; }
TAGS_KV="Key=project,Value=${PROJECT_SLUG} Key=owner,Value=${OWNER_EMAIL} Key=created-by,Value=${DEPLOYER_EMAIL}"
TAGS_JSON="[{\"key\":\"project\",\"value\":\"${PROJECT_SLUG}\"},{\"key\":\"owner\",\"value\":\"${OWNER_EMAIL}\"},{\"key\":\"created-by\",\"value\":\"${DEPLOYER_EMAIL}\"}]"

ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$HTTPS_DOMAIN" \
  --query "HostedZones[?Name=='${HTTPS_DOMAIN}.' && Config.PrivateZone].Id | [0]" --output text)"
CERT_ARN="$(aws acm list-certificates \
  --query "CertificateSummaryList[?DomainName=='*.${HTTPS_DOMAIN}' && Status=='ISSUED'].CertificateArn | [0]" --output text)"
[ -n "$ZONE_ID" ] && [ "$ZONE_ID" != None ] && [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != None ] || {
  echo "Shared HTTPS zone/cert missing; ask Infra." >&2; exit 1; }

echo "== ECR + image"
aws ecr describe-repositories --repository-names "$NAME" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$NAME" --tags $TAGS_KV >/dev/null
REPO="${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com/${NAME}"
record ECR_REPO "$REPO"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com"
TAG="$(date +%Y%m%d%H%M%S)"
docker build --platform linux/arm64 -t "${REPO}:${TAG}" .
docker push "${REPO}:${TAG}"

echo "== Logs, cluster, roles"
aws logs create-log-group --log-group-name "/ecs/${NAME}" --tags "project=${PROJECT_SLUG},owner=${OWNER_EMAIL},created-by=${DEPLOYER_EMAIL}" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/ecs/${NAME}" --retention-in-days 7
record LOG_GROUP "/ecs/${NAME}"
aws ecs create-cluster --cluster-name "$NAME" --tags "$TAGS_JSON" >/dev/null
record ECS_CLUSTER "$NAME"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
EXEC_ROLE="${SHORT}-exec"
if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "$TRUST" \
    --permissions-boundary "$BOUNDARY" --tags $TAGS_KV >/dev/null
  aws iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi
record EXEC_ROLE "$EXEC_ROLE"
# Static site needs no AWS permissions, so no separate application role is created.

echo "== Task definition"
TASK_DEF_ARN="$(aws ecs register-task-definition --family "$NAME" \
  --requires-compatibilities FARGATE --network-mode awsvpc --cpu 256 --memory 512 \
  --runtime-platform cpuArchitecture=ARM64,operatingSystemFamily=LINUX \
  --execution-role-arn "arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE}" \
  --tags "$TAGS_JSON" \
  --container-definitions "[{\"name\":\"web\",\"image\":\"${REPO}:${TAG}\",\"essential\":true,
    \"portMappings\":[{\"containerPort\":80,\"protocol\":\"tcp\"}],
    \"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/${NAME}\",\"awslogs-region\":\"us-west-2\",\"awslogs-stream-prefix\":\"web\"}}}]" \
  --query taskDefinition.taskDefinitionArn --output text)"
record TASK_DEF_ARN "$TASK_DEF_ARN"

echo "== Internal ALB, target group, listeners"
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNETS%%,*}" --query 'Subnets[0].VpcId' --output text)"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$SHORT" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || \
  aws elbv2 create-load-balancer --name "$SHORT" --scheme internal --type application \
    --subnets ${SUBNETS//,/ } --security-groups "$SG" --tags $TAGS_KV \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
record ALB_ARN "$ALB_ARN"
TG_ARN="$(aws elbv2 describe-target-groups --names "$SHORT" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
  aws elbv2 create-target-group --name "$SHORT" --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
    --target-type ip --health-check-path /healthz --tags $TAGS_KV \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
record TG_ARN "$TG_ARN"
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
existing_443="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text)"
if [ "$existing_443" = None ] || [ -z "$existing_443" ]; then
  existing_443="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
    --certificates CertificateArn="$CERT_ARN" --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" --tags $TAGS_KV \
    --query 'Listeners[0].ListenerArn' --output text)"
fi
record HTTPS_LISTENER_ARN "$existing_443"

echo "== ECS service"
if aws ecs describe-services --cluster "$NAME" --services "$NAME" --query 'services[?status==`ACTIVE`] | [0].serviceName' --output text | grep -q "$NAME"; then
  aws ecs update-service --cluster "$NAME" --service "$NAME" --task-definition "$TASK_DEF_ARN" >/dev/null
else
  aws ecs create-service --cluster "$NAME" --service-name "$NAME" --task-definition "$TASK_DEF_ARN" \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SG}],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=web,containerPort=80" \
    --propagate-tags SERVICE --tags "$TAGS_JSON" >/dev/null
fi
record ECS_SERVICE "$NAME"

echo "== Private DNS alias"
read -r ALB_DNS ALB_ZONE <<< "$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text)"
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${HOST}\",\"Type\":\"A\",
  \"AliasTarget\":{\"HostedZoneId\":\"${ALB_ZONE}\",\"DNSName\":\"dualstack.${ALB_DNS}\",\"EvaluateTargetHealth\":false}}}]}" \
  --query ChangeInfo.Id --output text)"
record DNS_ZONE_ID "$ZONE_ID"
record DNS_NAME "$HOST"

echo "== Waiting for DNS INSYNC and service stability"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
aws ecs wait services-stable --cluster "$NAME" --services "$NAME"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text

echo
echo "Deployed. With Twingate connected, verify:"
echo "  curl --noproxy '*' --fail --show-error --max-time 20 https://${HOST}/ | grep hackweek-kikoff-showcase"
