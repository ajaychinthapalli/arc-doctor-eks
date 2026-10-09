# Architecture

![ARC Doctor architecture](images/architecture.png)

ARC Doctor adds two things to a cluster that already runs GitHub Actions Runner
Controller (ARC): a watcher that notices when runners don't start, and a kagent
agent that works out why.

## Components

| Component                             | Namespace     | What it does                                                                                                   | Runs on                     |
| ------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------- |
| ARC controller                        | `arc-systems` | Creates EphemeralRunners for each scale set                                                                    | `agents` node group         |
| Listener pod (`linux-x64-…-listener`) | `arc-systems` | Long-polls GitHub for jobs, sets desired runner count                                                          | `agents` node group         |
| EphemeralRunner pods                  | `arc-runners` | Run the GitHub Actions jobs; tolerate `arc-runners=true:NoSchedule`                                            | Karpenter `linux-x64` nodes |
| Karpenter 1.14.1                      | `kube-system` | Launches on-demand c/m nodes (large–2xlarge, 6th gen+) for pending runners; `limits.cpu: 64`                   | `agents` node group         |
| arc-watcher CronJob                   | `arc-systems` | Every 2 min: finds runners stuck > 5 min, failed runners, unhealthy listeners; calls the agent; posts to Slack | `agents` node group         |
| `arc-doctor-state` ConfigMap          | `arc-systems` | Failure fingerprints for a 30-min cooldown                                                                     | —                           |
| kagent controller                     | `kagent`      | Hosts the A2A endpoint (`:8083`, protocol 0.3)                                                                 | `agents` node group         |
| arc-doctor agent                      | `kagent`      | Runbook prompt, read-only tools, Claude Sonnet 4.6 on Bedrock via IRSA                                         | `agents` node group         |
| kagent tool server                    | `kagent`      | MCP tools (`k8s_get_resources`, `k8s_describe_resource`, `k8s_get_events`, `k8s_get_pod_logs`, …)              | `agents` node group         |

## Design choices

| Choice                                                               | Why                                                                                                               |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Read-only agent                                                      | Fixes are recommended, never applied. The tool server's ClusterRole has get/list/watch only and no Secrets.       |
| Watcher outside the agent                                            | Detection is cheap and deterministic (bash + kubectl + jq); the model is called only when something new is stuck. |
| Fingerprint cooldown                                                 | The same failure is diagnosed once per 30 min; a new failure type on the same scale set triggers right away.      |
| Runners on a tainted Karpenter pool                                  | Runners never compete with system pods, and capacity is capped by `limits.cpu`.                                   |
| `karpenter.sh/do-not-disrupt` on runners + `WhenEmpty` consolidation | A running job is never moved.                                                                                     |
| IRSA for Bedrock and Karpenter                                       | No AWS keys in the cluster.                                                                                       |

See [data flows](data-flows.md) for every arrow on the diagram.
