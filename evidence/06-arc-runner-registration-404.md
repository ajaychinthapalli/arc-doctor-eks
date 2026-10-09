# Incident: runner scale set stuck in Pending (404 from GitHub)

**Symptom:** After `helm install linux-x64`, the AutoscalingRunnerSet stayed in
phase `Pending` and no listener pod appeared.

**Evidence** (from `04-arc-install.log`):

```
request POST https://api.github.com/orgs/ajaychinthapalli/actions/runners/registration-token
failed(status="404 Not Found")
```

**Cause:** `githubConfigUrl` was `https://github.com/ajaychinthapalli`. ARC
treats a bare owner URL as an **organization** and calls the org runner API.
`ajaychinthapalli` is a personal account, which cannot have org-level runners,
so GitHub returns 404.

**Fix:** Point the scale set at a repository
(`https://github.com/<user>/<repo>`) and `helm upgrade`. The listener started
within 30 s and the phase became `Running`.

**Takeaway:** This is the "wrong githubConfigUrl (404)" case ARC Doctor's
runbook checks for in listener and controller logs.
