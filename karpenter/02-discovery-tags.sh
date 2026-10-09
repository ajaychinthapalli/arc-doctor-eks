#!/usr/bin/env bash
# Tags the subnets and security groups Karpenter should launch nodes into with
#   karpenter.sh/discovery=<cluster>
# Uses the same subnets as your managed node groups, plus the cluster security group
# (attached to every managed node) and any security groups in node group launch templates.
set -euo pipefail
cd "$(dirname "$0")"
source ./00-env.sh
TAG="Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"

SUBNETS=""
for NG in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'nodegroups' --output text); do
	SUBNETS="${SUBNETS} $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
		--nodegroup-name "${NG}" --query 'nodegroup.subnets' --output text)"
done
SUBNETS="$(echo ${SUBNETS} | tr ' ' '\n' | sort -u | tr '\n' ' ')"
[ -n "${SUBNETS// /}" ] || {
	echo "No node group subnets found" >&2
	exit 1
}
aws ec2 create-tags --region "${AWS_REGION}" --tags "${TAG}" --resources ${SUBNETS}
echo "tagged subnets: ${SUBNETS}"

SGS="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
	--query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
for NG in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'nodegroups' --output text); do
	LT="$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --nodegroup-name "${NG}" \
		--query 'nodegroup.launchTemplate.[id,version]' --output text)"
	if [ "${LT}" != "None	None" ] && [ "${LT}" != "None" ] && [ -n "${LT}" ]; then
		LT_ID="$(echo "${LT}" | cut -f1)"
		LT_VER="$(echo "${LT}" | cut -f2)"
		SGS="${SGS} $(aws ec2 describe-launch-template-versions --region "${AWS_REGION}" \
			--launch-template-id "${LT_ID}" --versions "${LT_VER}" \
			--query 'LaunchTemplateVersions[0].LaunchTemplateData.[NetworkInterfaces[0].Groups||SecurityGroupIds]' \
			--output text | tr '\t' ' ' | sed 's/None//g')"
	fi
done
SGS="$(echo ${SGS} | tr ' ' '\n' | grep '^sg-' | sort -u | tr '\n' ' ')"
aws ec2 create-tags --region "${AWS_REGION}" --tags "${TAG}" --resources ${SGS}
echo "tagged security groups: ${SGS}"
