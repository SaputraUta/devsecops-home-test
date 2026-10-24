#!/usr/bin/env bash
set -euo pipefail

: "${CLUSTER:?}" "${SERVICE:?}" "${TASK_FAMILY:?}" "${IMAGE_URI:?}"

aws ecs describe-task-definition --task-definition "$TASK_FAMILY" --query taskDefinition > current.json

jq --arg img "$IMAGE_URI" '
  .containerDefinitions[0].image = $img
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
' current.json > next.json

ARN=$(aws ecs register-task-definition --cli-input-json file://next.json \
  --query taskDefinition.taskDefinitionArn --output text)

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$ARN" > /dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
echo "deployed $ARN"
