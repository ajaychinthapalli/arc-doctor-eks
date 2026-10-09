#!/usr/bin/env bash
# Creates the two IAM roles Karpenter needs (from the official v1.14 migration guide):
#   KarpenterNodeRole-<cluster>        assumed by EC2 nodes Karpenter launches
#   KarpenterControllerRole-<cluster>  assumed by the karpenter pod via IRSA
# Safe to re-run: existing roles are kept, policies are re-applied.
set -euo pipefail
cd "$(dirname "$0")"
source ./00-env.sh
WORK="$(mktemp -d)"

# --- 0. IRSA needs the cluster's OIDC provider registered in IAM -------------
eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --approve

# --- 1. Node role ------------------------------------------------------------
cat >"${WORK}/node-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
aws iam get-role --role-name "${NODE_ROLE}" >/dev/null 2>&1 ||
	aws iam create-role --role-name "${NODE_ROLE}" --assume-role-policy-document "file://${WORK}/node-trust.json" >/dev/null
for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryPullOnly AmazonSSMManagedInstanceCore; do
	aws iam attach-role-policy --role-name "${NODE_ROLE}" --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/${p}"
done
echo "node role ready: ${NODE_ROLE}"

# --- 2. Controller role (IRSA) ----------------------------------------------
OIDC="${OIDC_ENDPOINT#*//}"
cat >"${WORK}/controller-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "${OIDC}:aud": "sts.amazonaws.com",
      "${OIDC}:sub": "system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter"
    }}
  }]
}
EOF
CTRL_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
if aws iam get-role --role-name "${CTRL_ROLE}" >/dev/null 2>&1; then
	aws iam update-assume-role-policy --role-name "${CTRL_ROLE}" --policy-document "file://${WORK}/controller-trust.json"
else
	aws iam create-role --role-name "${CTRL_ROLE}" --assume-role-policy-document "file://${WORK}/controller-trust.json" >/dev/null
fi

cat >"${WORK}/controller-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "Karpenter", "Effect": "Allow", "Resource": "*",
     "Action": ["ssm:GetParameter","ec2:DescribeImages","ec2:RunInstances","ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups","ec2:DescribeLaunchTemplates","ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes","ec2:DescribeInstanceTypeOfferings","ec2:DeleteLaunchTemplate",
                "ec2:CreateTags","ec2:CreateLaunchTemplate","ec2:CreateFleet","ec2:DescribeSpotPriceHistory",
                "pricing:GetProducts"]},
    {"Sid": "ConditionalEC2Termination", "Effect": "Allow", "Resource": "*", "Action": "ec2:TerminateInstances",
     "Condition": {"StringLike": {"ec2:ResourceTag/karpenter.sh/nodepool": "*"}}},
    {"Sid": "PassNodeIAMRole", "Effect": "Allow", "Action": "iam:PassRole",
     "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${NODE_ROLE}"},
    {"Sid": "EKSClusterEndpointLookup", "Effect": "Allow", "Action": "eks:DescribeCluster",
     "Resource": "arn:${AWS_PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"},
    {"Sid": "AllowScopedInstanceProfileCreationActions", "Effect": "Allow", "Resource": "*",
     "Action": ["iam:CreateInstanceProfile"],
     "Condition": {"StringEquals": {"aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                                    "aws:RequestTag/topology.kubernetes.io/region": "${AWS_REGION}"},
                   "StringLike": {"aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"}}},
    {"Sid": "AllowScopedInstanceProfileTagActions", "Effect": "Allow", "Resource": "*",
     "Action": ["iam:TagInstanceProfile"],
     "Condition": {"StringEquals": {"aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                                    "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}",
                                    "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                                    "aws:RequestTag/topology.kubernetes.io/region": "${AWS_REGION}"},
                   "StringLike": {"aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
                                  "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"}}},
    {"Sid": "AllowScopedInstanceProfileActions", "Effect": "Allow", "Resource": "*",
     "Action": ["iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:DeleteInstanceProfile"],
     "Condition": {"StringEquals": {"aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
                                    "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}"},
                   "StringLike": {"aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"}}},
    {"Sid": "AllowInstanceProfileReadActions", "Effect": "Allow", "Resource": "*", "Action": "iam:GetInstanceProfile"},
    {"Sid": "AllowUnscopedInstanceProfileListAction", "Effect": "Allow", "Resource": "*", "Action": "iam:ListInstanceProfiles"}
  ]
}
EOF
aws iam put-role-policy --role-name "${CTRL_ROLE}" \
	--policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
	--policy-document "file://${WORK}/controller-policy.json"
echo "controller role ready: ${CTRL_ROLE}"
rm -rf "${WORK}"
