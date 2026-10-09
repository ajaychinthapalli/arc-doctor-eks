#!/usr/bin/env bash
# Creates the linux-x64 NodePool and EC2NodeClass for ARC runners.
set -euo pipefail
cd "$(dirname "$0")"
source ./00-env.sh
sed -e "s/\${CLUSTER_NAME}/${CLUSTER_NAME}/g" -e "s/\${ALIAS_VERSION}/${ALIAS_VERSION}/g" nodepool-linux-x64.yaml |
	kubectl apply -f -
sleep 5
kubectl get ec2nodeclass linux-x64 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl get nodepool linux-x64
