#!/usr/bin/env bash
# Lets nodes launched with KarpenterNodeRole join the cluster.
# Uses an EKS access entry when the cluster allows it (API or API_AND_CONFIG_MAP),
# and falls back to the aws-auth ConfigMap otherwise.
set -euo pipefail
cd "$(dirname "$0")"
source ./00-env.sh
ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"

MODE="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
	--query 'cluster.accessConfig.authenticationMode' --output text)"
echo "authentication mode: ${MODE}"

if [ "${MODE}" = "API" ] || [ "${MODE}" = "API_AND_CONFIG_MAP" ]; then
	if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
		--principal-arn "${ROLE_ARN}" >/dev/null 2>&1; then
		echo "access entry already exists"
	else
		aws eks create-access-entry --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
			--principal-arn "${ROLE_ARN}" --type EC2_LINUX >/dev/null
		echo "access entry created for ${ROLE_ARN}"
	fi
else
	echo "Cluster uses CONFIG_MAP only; adding the role to aws-auth with eksctl"
	eksctl create iamidentitymapping --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
		--arn "${ROLE_ARN}" --username 'system:node:{{EC2PrivateDNSName}}' \
		--group system:bootstrappers --group system:nodes
fi
