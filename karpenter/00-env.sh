# Source this file:  source karpenter/00-env.sh
# Shared settings for the Karpenter install on ac-ws-dev-use2.
export CLUSTER_NAME="${CLUSTER_NAME:-ac-ws-dev-use2}"
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_PARTITION="aws"
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.14.1"                     # Kubernetes 1.36 needs Karpenter >= 1.13
export SYSTEM_NODEGROUP="${SYSTEM_NODEGROUP:-agents}" # Karpenter itself runs here, never on its own nodes

export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export OIDC_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
	--query 'cluster.identity.oidc.issuer' --output text)"
export K8S_VERSION="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
	--query 'cluster.version' --output text)"
# Pin the AL2023 AMI release that matches the cluster version (e.g. v20261001)
export ALIAS_VERSION="$(aws ssm get-parameter --region "${AWS_REGION}" \
	--name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
	--query Parameter.Value --output text |
	xargs aws ec2 describe-images --region "${AWS_REGION}" --query 'Images[0].Name' --output text --image-ids |
	sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"

echo "cluster=${CLUSTER_NAME} region=${AWS_REGION} account=${AWS_ACCOUNT_ID} k8s=${K8S_VERSION} ami=al2023@${ALIAS_VERSION} karpenter=${KARPENTER_VERSION}"
