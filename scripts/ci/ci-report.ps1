# Collects the CI status of the current commit into ONE file (ci-report.txt):
# waits until every workflow run for HEAD has finished, then extracts only
# the useful lines (errors, test failures, Trivy totals/CVE rows) from each
# failed job. Works on Windows PowerShell 5.1 and PowerShell 7.
#
#   powershell -ExecutionPolicy Bypass -File scripts\ci\ci-report.ps1
param(
    [int]$TimeoutMinutes = 20,
    [int]$MaxLinesPerRun = 300
)

$ErrorActionPreference = 'Continue'   # gh writes progress to stderr; don't abort on it
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$out = Join-Path (Get-Location) 'ci-report.txt'
$sha = (git rev-parse HEAD).Trim()
$short = $sha.Substring(0, 7)

Write-Host "Waiting for workflow runs on commit $short ..."
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $runs = gh run list --commit $sha --limit 50 --json databaseId,workflowName,status,conclusion,event | ConvertFrom-Json
    $pending = @($runs | Where-Object { $_.status -ne 'completed' })
    if ($runs.Count -gt 0 -and $pending.Count -eq 0) { break }
    Write-Host ("  {0} run(s), {1} still running - checking again in 30s" -f $runs.Count, $pending.Count)
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)

$pattern = '##\[error\]|\[ERROR\]|error:|Error:|FAILED|FAIL |Total: |CVE-|panic:|Traceback|exit code'

$report = New-Object System.Collections.Generic.List[string]
$report.Add("CI report  commit=$short  generated=$(Get-Date -Format s)")
foreach ($r in $runs) {
    $report.Add('')
    $report.Add(("===== {0} [{1}] -> {2}/{3}  (run {4})" -f $r.workflowName, $r.event, $r.status, $r.conclusion, $r.databaseId))
    if ($r.conclusion -eq 'failure') {
        $lines = gh run view $r.databaseId --log-failed |
            Select-String -Pattern $pattern |
            Where-Object { $_.Line -notmatch 'CVE-2026-12345' } |   # the example line in .trivyignore
            Select-Object -First $MaxLinesPerRun |
            ForEach-Object { $_.Line }
        foreach ($l in $lines) { $report.Add($l) }
    }
}
$report | Out-File -FilePath $out -Encoding utf8
Write-Host ""
Write-Host "Summary:"
$runs | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.workflowName, $_.conclusion) }
Write-Host ""
Write-Host "Full details saved to $out"
