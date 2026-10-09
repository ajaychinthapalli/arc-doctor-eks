# Install guide

The exact sequence that was run on `ac-ws-dev-use2`, starting from a plain EKS
cluster with two managed node groups. Each step links to its evidence log. Run
everything from the repo root, and keep the repo outside `~/Downloads` on macOS
(see [lessons learned](lessons-learned.md) #10).

## 0. Prerequisites

| Need                                                                          | Check                                                                            |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| EKS 1.29+ with an OIDC issuer                                                 | `aws eks describe-cluster --name <cluster> --query cluster.identity.oidc.issuer` |
| A managed node group for system pods (here `agents`, 2 × t3.large)            | `eksctl get nodegroup --cluster <cluster>`                                       |
| Bedrock access to Claude Sonnet 4.6                                           | `aws bedrock-runtime converse --model-id us.anthropic.claude-sonnet-4-6 ...`     |
| `kubectl`, `helm` 3.8+, `aws`, `eksctl`, `jq`                                 | `helm version --short`                                                           |
| A GitHub repo (or org) and a classic PAT with `repo` (+ `admin:org` for orgs) | —                                                                                |

Set your account ID in `manifests/02-agent.yaml`,
`iam/bedrock-invoke-policy.json`, and the cluster name and region in
`karpenter/00-env.sh`. In this repo the account ID is the placeholder
`111122223333`.

## 1. Karpenter ([evidence](../evidence/03-karpenter-install.log))

```bash
source karpenter/00-env.sh          # prints cluster, region, account, AMI alias
bash karpenter/01-iam.sh            # OIDC provider, node role, controller role (IRSA)
bash karpenter/02-discovery-tags.sh # tag node group subnets + security groups
bash karpenter/03-node-access.sh    # EKS access entry for the node role
bash karpenter/04-install.sh        # Helm, kube-system, pinned to the agents node group
bash karpenter/05-nodepool.sh       # linux-x64 NodePool + EC2NodeClass
kubectl get ec2nodeclass,nodepool linux-x64   # both READY True
```

## 2. ARC ([evidence](../evidence/04-arc-install.log))

Set `githubConfigUrl` in `arc/linux-x64-values.yaml`. A personal account must
use a repo URL ([why](../evidence/06-arc-runner-registration-404.md)).

```bash
helm install arc --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

kubectl create namespace arc-runners
read -s -p "GitHub PAT: " GH_PAT; echo
kubectl -n arc-runners create secret generic arc-github-app --from-literal=github_token="$GH_PAT"
unset GH_PAT

helm install linux-x64 -n arc-runners -f arc/linux-x64-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
kubectl get pods -n arc-systems     # controller + linux-x64-…-listener Running
```

Smoke test: use `.github/workflows/arc-smoke.yml` in the target repo, run it,
and watch `kubectl get nodeclaims -w`
([evidence](../evidence/05-smoke-test-karpenter-scale-up.log)).

## 3. kagent ([evidence](../evidence/07-kagent-install.log))

```bash
curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --create-namespace
helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.10.3 \
  --namespace kagent \
  --set providers.default=ollama \
  --set grafana-mcp.enabled=false \
  --set k8s-agent.enabled=false --set kgateway-agent.enabled=false \
  --set istio-agent.enabled=false --set promql-agent.enabled=false \
  --set observability-agent.enabled=false --set argo-rollouts-agent.enabled=false \
  --set helm-agent.enabled=false --set cilium-policy-agent.enabled=false \
  --set cilium-manager-agent.enabled=false --set cilium-debug-agent.enabled=false
kubectl -n kagent get pods          # controller, kmcp, postgresql, tools, ui
```

## 4. Bedrock role for the agent ([evidence](../evidence/10-bedrock-role-and-tools.log))

```bash
aws iam create-policy --policy-name arc-doctor-bedrock \
  --policy-document file://iam/bedrock-invoke-policy.json
eksctl create iamserviceaccount --cluster <cluster> --region <region> \
  --namespace kagent --name arc-doctor --role-name arc-doctor-bedrock --role-only \
  --attach-policy-arn arn:aws:iam::<account-id>:policy/arc-doctor-bedrock --approve
```

## 5. Slack (optional, [evidence](../evidence/18-slack-connection.log))

Create an app at https://api.slack.com/apps, enable Incoming Webhooks, add one
for your channel, then:

```bash
read -s -p "Slack webhook URL: " SLACK_URL; echo
kubectl -n arc-systems create secret generic arc-doctor-slack --from-literal=webhook-url="$SLACK_URL"
unset SLACK_URL
```

## 6. ARC Doctor ([evidence](../evidence/11-arc-doctor-deploy.log))

```bash
kubectl apply -k . --dry-run=server
kubectl apply -k .
kubectl -n kagent get agent arc-doctor                       # READY True
kubectl -n kagent get sa arc-doctor -o jsonpath='{.metadata.annotations}'
```

## 7. Verify

```bash
# Agent card (A2A 0.3)
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 &
curl -s localhost:18083/api/a2a/kagent/arc-doctor/.well-known/agent-card.json | jq '.name, .skills[].id'

# Watcher on a healthy cluster
kubectl -n arc-systems create job arc-watch-now --from=cronjob/arc-watcher
kubectl -n arc-systems logs -f job/arc-watch-now            # "All ARC scale sets healthy."
```

## 8. Failure drill ([evidence](../evidence/17-failure-drill-cronjob-slack.log))

```bash
kubectl patch nodepool linux-x64 --type merge -p '{"spec":{"limits":{"cpu":"1"}}}'
# run the smoke-test workflow, wait ~6 minutes
kubectl -n arc-systems delete configmap arc-doctor-state --ignore-not-found
kubectl -n arc-systems delete job arc-watch-now --ignore-not-found
kubectl -n arc-systems create job arc-watch-now --from=cronjob/arc-watcher
kubectl -n arc-systems logs -f job/arc-watch-now            # diagnosis, also posted to Slack
kubectl patch nodepool linux-x64 --type merge -p '{"spec":{"limits":{"cpu":"64"}}}'
```
