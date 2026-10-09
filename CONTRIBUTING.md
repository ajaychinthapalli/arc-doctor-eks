# Contributing

Thanks for helping improve this project.

## Development workflow

1. Fork the repository and create a feature branch.
1. Keep changes focused and related to the same issue or improvement.
1. Update documentation or examples when behavior changes.
1. Validate YAML and repo structure before opening a pull request.

## Repository structure

- `.github/workflows/` contains reusable GitHub Actions workflows.
- `manifests/` contains Kubernetes manifests used for the ARC and kagent
  deployment.
- `karpenter/` contains Karpenter configuration and values.
- `docs/` contains setup, verification, and lessons learned notes.
- `evidence/` contains execution logs and supporting material.

## Pull request checklist

- Use a clear PR title and summary.
- Include any required documentation updates.
- Check that workflow files are placed under `.github/workflows/`.
- Confirm YAML remains valid and examples still match the repo structure.

## Code review expectations

- Keep changes easy to review and avoid unrelated formatting churn.
- Prefer small, well-scoped commits.
- Explain the operational impact of changes, especially for cluster or runner
  configuration.
