<#
.SYNOPSIS
Smoke tests a built windows-nano-mysql image. Throws on the first failure.
.DESCRIPTION
Starts a server container, talks to it from a second container over the container network,
and restarts it to check the data survives. Removes only the containers and volumes it creates, by name.
.EXAMPLE
./nano-server-mysql/smoke-test.ps1 -Image windows-nano-mysql:2025
#>
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$server = "mysql-smoke-$suffix"
$volume = "mysql-smoke-$suffix"
$names = @()
# Alphanumeric only: the entrypoint writes the password into SQL through cmd
$rootPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$appPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })

# Runs the bundled mysql client in a second, throwaway container. The password goes in the environment, not on the command line.
function Invoke-Client {
    param([string]$ServerIp, [string]$User, [string]$Password, [string]$Sql)
    $name = "mysql-smoke-client-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $script:names += $name
    $out = docker run --name $name -e "MYSQL_PWD=$Password" $Image mysql -h $ServerIp -u $User -N -B -e $Sql 2>&1
    $code = $LASTEXITCODE
    docker rm -f $name | Out-Null
    [pscustomobject]@{ ExitCode = $code; Output = ($out | Out-String).Trim() }
}

function Wait-Ready {
    param([int]$Count)
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 3
        $log = docker logs $server 2>&1 | Out-String
        $running = (docker inspect -f '{{.State.Running}}' $server) -eq 'true'
        $ready = [regex]::Matches($log, 'ready for connections').Count
    } until ($ready -ge $Count -or -not $running -or (Get-Date) -gt $deadline)
    if ($ready -lt $Count) { throw "mysqld did not become ready (running=$running). Log:`n$log" }
}

function Get-ServerIp {
    $ip = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $server
    if (-not $ip) { throw 'the server container has no IP address' }
    return $ip
}

try {
    # 1. Refuses to start without a root password
    $name = "mysql-smoke-nopw-$suffix"
    $names += $name
    docker run --name $name $Image mysqld 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'the server started without MYSQL_ROOT_PASSWORD' }
    docker rm -f $name | Out-Null
    Write-Host 'ok: refuses to start without a root password'

    # 2. Starts with a generated password, a database and an application user
    docker volume create $volume | Out-Null
    docker run -d --name $server -v "${volume}:C:\mysql\data" `
        -e "MYSQL_ROOT_PASSWORD=$rootPassword" -e MYSQL_DATABASE=appdb -e MYSQL_USER=appuser -e "MYSQL_PASSWORD=$appPassword" `
        $Image | Out-Null
    Wait-Ready -Count 1
    $user = docker exec $server cmd /c "echo %USERNAME%"
    Write-Host "ok: server ready, running as $user"
    if ($user -match 'administrator') { throw "mysqld should not run as an administrator, but runs as $user" }

    # 3. Connect from a second container over the container network, create, insert and select
    $ip = Get-ServerIp
    $r = Invoke-Client $ip root $rootPassword 'CREATE DATABASE smoke; CREATE TABLE smoke.t (id INT PRIMARY KEY, v VARCHAR(20)); INSERT INTO smoke.t VALUES (1, ''nano-ok''); SELECT v FROM smoke.t WHERE id = 1;'
    if ($r.ExitCode -ne 0 -or $r.Output -ne 'nano-ok') { throw "CREATE/INSERT/SELECT from a second container failed ($($r.ExitCode)): $($r.Output)" }
    Write-Host "ok: root created, inserted and selected a row from a second container ($ip)"

    # 4. A wrong password is rejected
    $r = Invoke-Client $ip root "wrong$rootPassword" 'SELECT 1'
    if ($r.ExitCode -eq 0) { throw 'a wrong root password was accepted' }
    if ($r.Output -notmatch 'Access denied') { throw "wrong password failed for the wrong reason: $($r.Output)" }
    Write-Host 'ok: wrong password rejected'

    # 5. The MYSQL_DATABASE / MYSQL_USER account works and is limited to its database
    $r = Invoke-Client $ip appuser $appPassword 'CREATE TABLE appdb.t (id INT); SHOW DATABASES;'
    if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'appdb') { throw "MYSQL_USER could not use MYSQL_DATABASE: $($r.Output)" }
    if ($r.Output -match 'smoke') { throw 'MYSQL_USER can see databases it has no grant on' }
    Write-Host 'ok: MYSQL_USER works in MYSQL_DATABASE only'

    # 6. The data survives a restart, and the entrypoint doesn't re-initialize
    docker restart $server | Out-Null
    Wait-Ready -Count 2
    $ip = Get-ServerIp
    $r = Invoke-Client $ip root $rootPassword 'SELECT v FROM smoke.t WHERE id = 1'
    if ($r.ExitCode -ne 0 -or $r.Output -ne 'nano-ok') { throw "the row did not survive a restart ($($r.ExitCode)): $($r.Output)" }
    Write-Host 'ok: data and credentials persisted across a restart'
}
finally {
    # Only what this script created, by name. Never prune.
    foreach ($n in @($server) + $names) { docker rm -f $n 2>&1 | Out-Null }
    docker volume rm $volume 2>&1 | Out-Null
}
