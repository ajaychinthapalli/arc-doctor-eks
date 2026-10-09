# Evidence

Terminal output from the live build on `ac-ws-dev-use2` (EKS 1.36, us-east-2) on
2026-10-08, in the order it ran. Account ID, OIDC ID, IP addresses, and subnet
and security group IDs are masked; everything else is as captured.

| File                                                                         | What it shows                                                                     | Tests |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | ----- |
| [01-cluster-baseline.log](01-cluster-baseline.log)                           | Namespaces before any install                                                     | —     |
| [02-preflight.log](02-preflight.log)                                         | Versions, nodes, no autoscaler, OIDC provider missing, capacity, Bedrock profiles | T1    |
| [03-karpenter-install.log](03-karpenter-install.log)                         | IAM, tags, access entry, Helm, NodePool Ready                                     | T2    |
| [04-arc-install.log](04-arc-install.log)                                     | ARC controller + scale set, 404 failure and fix                                   | T3    |
| [05-smoke-test-karpenter-scale-up.log](05-smoke-test-karpenter-scale-up.log) | Job → runner → c6a.large in 38 s → job done in 59 s                               | T4    |
| [06-arc-runner-registration-404.md](06-arc-runner-registration-404.md)       | Write-up of the 404 incident                                                      | T3    |
| [07-kagent-install.log](07-kagent-install.log)                               | kagent 0.10.3 install, controller restarts, bundled agents                        | T5    |
| [08-kagent-bundled-agents.log](08-kagent-bundled-agents.log)                 | Chart keys for bundled agents, reconcile error                                    | T6    |
| [09-kagent-disable-bundled-agents.log](09-kagent-disable-bundled-agents.log) | Bundled agents removed                                                            | T6    |
| [10-bedrock-role-and-tools.log](10-bedrock-role-and-tools.log)               | Bedrock IAM policy + IRSA role, tool server SA and tool names                     | T7    |
| [11-arc-doctor-deploy.log](11-arc-doctor-deploy.log)                         | `kubectl apply -k .`, agent Ready, SA annotation                                  | T8    |
| [12-a2a-agent-card.log](12-a2a-agent-card.log)                               | A2A 0.3 agent card                                                                | T9    |
| [13-a2a-healthy-diagnosis.log](13-a2a-healthy-diagnosis.log)                 | First diagnosis on a healthy cluster                                              | T10   |
| [14-watcher-healthy.log](14-watcher-healthy.log)                             | CronJob reports healthy                                                           | T11   |
| [15-failure-drill-setup.log](15-failure-drill-setup.log)                     | NodePool capped at 1 vCPU, runner Pending, no NodeClaims                          | T12   |
| [16-failure-drill-local-watcher.log](16-failure-drill-local-watcher.log)     | Watcher (60 s threshold) + full diagnosis                                         | T12   |
| [17-failure-drill-cronjob-slack.log](17-failure-drill-cronjob-slack.log)     | In-cluster CronJob + diagnosis posted to Slack                                    | T13   |
| [18-slack-connection.log](18-slack-connection.log)                           | Webhook test and secret                                                           | T13   |
| [../docs/images/slack-diagnosis.png](../docs/images/slack-diagnosis.png)     | The post in `#arc-alerts`                                                         | T13   |
