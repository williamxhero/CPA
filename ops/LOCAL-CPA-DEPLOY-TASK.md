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

## Full-stack mode

When `local-deploy-artifacts\manager\` holds a freshly built `cpa-manager-plus.exe` or `management.html`, or `local-deploy-artifacts\keeper\` holds a newer `cpa-usage-keeper.exe`, the runner switches to full-stack mode and calls `deploy-local-cpa-stack.ps1` instead. That script stops Manager → Usage Keeper → Core, replaces only the artifacts whose hash differs (Core, Manager, live panel, Usage Keeper), then starts them in the reverse order and health-checks 8317 / 8318 / 18317. A failed health check restores every replaced binary from the backup.

The panel file matters: `runtime\CPA-Manager-Plus\config.json` sets `panelPath` to `panel\management.html`, so the panel served by the live service comes from that file and not from the copy embedded in the binary. Deploy both or the UI silently keeps the old bundle. Receipts land in `ops\local-stack-redeploy\deploy-result.json` with backups under `ops\local-stack-redeploy\backup-<timestamp>\`.

Rebuild steps for a Manager change:

```powershell
cd D:\WILL\AGENT\CPA\CPA-Manager-Plus-ex
npm run test:web
npm run build
Copy-Item apps\web\dist\index.html apps\manager-server\internal\httpapi\web\management.html -Force
Copy-Item apps\web\dist\index.html D:\WILL\AGENT\CPA\local-deploy-artifacts\manager\management.html -Force
# rebuild cpa-manager-plus.exe into local-deploy-artifacts\manager\ too
& D:\WILL\AGENT\CPA\ops\invoke-local-cpa-core-deploy-task.ps1
```

Rebuild steps for a Usage Keeper change:

```powershell
cd D:\WILL\AGENT\CPA\CPA-Usage-Keeper-ex
npm --prefix web run build
$env:CGO_ENABLED = '1'
go build -trimpath -ldflags '-s -w' -o D:\WILL\AGENT\CPA\local-deploy-artifacts\keeper\cpa-usage-keeper.exe ./cmd/server/main.go
& D:\WILL\AGENT\CPA\ops\invoke-local-cpa-core-deploy-task.ps1
```

The live Keeper binary is `runtime\CPA-Usage-Keeper\cpa-usage-keeper.exe`; `CPAUsageKeeperService.exe` is only the service wrapper and must not be replaced. Vite clears `web\dist`, so restore the tracked `web\dist\.gitkeep` after a build.

## Versions

Every EX repository derives its version from `{source}+{ex}` in its `VERSION` file; the generated Go constant is compiled into ordinary builds, so no `-X ...Version` flag belongs in local build commands. After merging a source repository run `ops\update-ex-versions.ps1` (add `-BumpEx patch` when the fork ships its own change) and rebuild before deploying. Current identities: Core `8.0.76+1.0.0`, Manager `1.14.10+1.0.0`, OpenCode plugin `0.2.2+1.0.0`, Usage Keeper `2.1.1+1.0.0`.
