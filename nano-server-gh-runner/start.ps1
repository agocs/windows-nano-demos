# Container entrypoint: register the runner on first start, then run it.
# Registration is kept in the container's filesystem, so `docker restart` reuses it without a new token.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Test-Path .runner)) {
    if (-not $env:RUNNER_URL -or -not $env:RUNNER_TOKEN) {
        throw 'RUNNER_URL and RUNNER_TOKEN must be set for the first start'
    }
    $name = $env:RUNNER_NAME ?? $env:COMPUTERNAME
    $labels = $env:RUNNER_LABELS ?? 'nanoserver,docker'
    & .\config.cmd --unattended --replace --url $env:RUNNER_URL --token $env:RUNNER_TOKEN --name $name --labels $labels --work _work
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

docker version --format 'Connected to docker {{.Server.Version}} ({{.Server.Os}})'
& .\run.cmd
exit $LASTEXITCODE
