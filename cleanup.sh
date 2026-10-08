#!/usr/bin/env bash
# Removes only this project's resources, using IDs recorded in deploy-state.env.
# Never touches the shared HTTPS zone, certificate, VPC, subnets or security group.
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE="${AWS_PROFILE:-hackweek-a}" AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 AWS_PAGER=""
# shellcheck disable=SC1091
source deploy-state.env

if [ -n "${DNS_NAME:-}" ]; then
  rec="$(aws route53 list-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${DNS_NAME}.' && Type=='A'] | [0]" --output json)"
  [ "$rec" != null ] && aws route53 change-resource-record-sets --hosted-zone-id "$DNS_ZONE_ID" \
    --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":${rec}}]}" >/dev/null
fi
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --desired-count 0 >/dev/null || true
aws ecs delete-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --force >/dev/null || true
aws ecs wait services-inactive --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" || true
aws elbv2 delete-listener --listener-arn "$HTTPS_LISTENER_ARN" || true
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" || true
aws elbv2 delete-target-group --target-group-arn "$TG_ARN" || true
aws ecs deregister-task-definition --task-definition "$TASK_DEF_ARN" >/dev/null || true
aws ecs delete-cluster --cluster "$ECS_CLUSTER" >/dev/null || true
aws iam detach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam delete-role --role-name "$EXEC_ROLE" || true
aws logs delete-log-group --log-group-name "$LOG_GROUP" || true
aws ecr delete-repository --repository-name "${ECR_REPO##*/}" --force >/dev/null || true
echo "Cleanup complete for $ECS_CLUSTER"
