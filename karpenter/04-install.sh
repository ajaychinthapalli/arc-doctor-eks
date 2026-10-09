#!/usr/bin/env bash
# Installs Karpenter (CRDs included) into kube-system with IRSA.
set -euo pipefail
cd "$(dirname "$0")"
source ./00-env.sh

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
	--version "${KARPENTER_VERSION}" \
	--namespace "${KARPENTER_NAMESPACE}" \
	-f values.yaml \
	--set "settings.clusterName=${CLUSTER_NAME}" \
	--set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
	--wait --timeout 5m

kubectl -n "${KARPENTER_NAMESPACE}" get pods -l app.kubernetes.io/name=karpenter -o wide
kubectl get crd | grep -E 'karpenter\.(sh|k8s\.aws)'
