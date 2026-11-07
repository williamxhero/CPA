# Local CPA-Core deployment task

This is the local-only elevation bridge for Codex. It never targets yosef-server or any other host.

Register it once from an elevated PowerShell in `D:\WILL\AGENT\CPA`:

```powershell
& .\ops\register-local-cpa-core-deploy-task.ps1
```

The task is named `CPA-Local-Core-Deploy`, runs as the current interactive user with the highest available run level, and invokes `run-local-cpa-core-deploy-task.ps1`. The runner selects the newest `CPA-Core-ex\local-deploy-output-*\cli-proxy-api.exe` and delegates the actual replacement to `deploy-local-cpa-core.ps1`, which owns backup, service restart, health checks, and rollback.

After registration, Codex can trigger and wait for a deployment without its own process being elevated:

```powershell
& .\ops\invoke-local-cpa-core-deploy-task.ps1
```

The wrapper result is written to `ops\local-cpa-core-deploy-task-result.json`; the underlying deployment receipt remains under `ops\local-core-redeploy-20261107\deploy-result.json`.
