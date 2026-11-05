#Requires -Version 7.3
<#
.SYNOPSIS
    End-to-end test for the windows-nano-ssh image.

.DESCRIPTION
    Starts the image as an SSH server with a throwaway local user, then uses a
    second container of the same image as the SSH client, so the machine that
    runs this script needs only pwsh and the docker CLI (no bind mounts, no
    ssh client). The server is reached by its IP on the nat network.

    Default mode (normal user, password + key, key in %USERPROFILE%\.ssh):
      * key logon works with BatchMode=yes and `whoami` is the created user
      * a command runs and its output comes back
      * password logon works (SSH_ASKPASS, no TTY needed) and `whoami` matches
      * a key that is not authorized is rejected
      * a wrong password is rejected

    -Admin -KeyOnly (administrator, no SSH_PASSWORD, key in
    C:\ProgramData\ssh\administrators_authorized_keys):
      * key logon works and `whoami` is the created user
      * the user is in the local Administrators group
      * a key that is not authorized is rejected
      * password logon is not offered at all
#>
param(
    [Parameter(Mandatory)] [string] $Image,
    [string] $User = 'sshci',
    [switch] $Admin,
    [switch] $KeyOnly,
    [string] $Isolation = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$server = "ssh-server-$suffix"
$client = "ssh-client-$suffix"
# Throwaway credentials, generated per run and never stored.
$password = 'Ci-' + [guid]::NewGuid().ToString('N').Substring(0, 16) + '-x9'
$sshExe = 'C:\Program Files\OpenSSH-Win64\ssh.exe'
$keygenExe = 'C:\Program Files\OpenSSH-Win64\ssh-keygen.exe'
[string[]] $isoArgs = @()
if ($Isolation) { $isoArgs = @("--isolation=$Isolation") }
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-Docker {
    $out = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed ($LASTEXITCODE): $out" }
    $out
}

function Assert-That([bool] $Condition, [string] $Message) {
    if ($Condition) { Write-Host "PASS: $Message" }
    else { Write-Host "FAIL: $Message"; $failures.Add($Message) }
}

# whoami prints MACHINE\user; compare the user part case-insensitively.
function Test-IsUser([string] $Who) {
    $Who -notmatch 'containeradministrator|containeruser' -and
    ($Who -split '\\')[-1].Trim() -ieq $User
}

$commonSsh = @(
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL',
    '-o', 'ConnectTimeout=15',
    '-o', 'LogLevel=ERROR'
)
$keySsh = @('-i', 'C:\good_key', '-o', 'BatchMode=yes') + $commonSsh
$pwSsh = @('-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1') + $commonSsh

try {
    # Client container: `cmd` reading an open stdin keeps it alive for docker exec.
    Invoke-Docker run -d -i @isoArgs --name $client $Image cmd | Out-Null
    Invoke-Docker exec $client $keygenExe -q -t ed25519 -N '' -C ci-good -f 'C:\good_key' | Out-Null
    Invoke-Docker exec $client $keygenExe -q -t ed25519 -N '' -C ci-wrong -f 'C:\wrong_key' | Out-Null
    $pubKey = (Invoke-Docker exec $client cmd /c type 'C:\good_key.pub' | Out-String).Trim()
    Write-Host "Authorized key: $pubKey"

    $envArgs = @('-e', "SSH_USER=$User", '-e', "SSH_AUTHORIZED_KEY=$pubKey")
    if (-not $KeyOnly) { $envArgs += @('-e', "SSH_PASSWORD=$password") }
    if ($Admin) { $envArgs += @('-e', 'SSH_ADMIN=1') }
    Invoke-Docker run -d @isoArgs --name $server @envArgs $Image | Out-Null

    $deadline = (Get-Date).AddSeconds(180)
    do {
        Start-Sleep -Seconds 3
        $logs = (& docker logs $server 2>&1 | Out-String)
        $running = (& docker inspect -f '{{.State.Running}}' $server) -eq 'true'
    } until ($logs -match 'start-sshd: sshd is running' -or -not $running -or (Get-Date) -gt $deadline)
    Write-Host "--- server log ---`n$logs------------------"
    if ($logs -notmatch 'start-sshd: sshd is running') { throw 'sshd did not start' }

    $ip = (Invoke-Docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $server | Out-String).Trim()
    Write-Host "Server IP: $ip"

    # key logon, whoami
    $who = (& docker exec $client $sshExe @keySsh "$User@$ip" whoami 2>&1 | Out-String).Trim()
    $rc = $LASTEXITCODE
    Write-Host "key whoami -> rc=$rc $who"
    Assert-That ($rc -eq 0 -and (Test-IsUser $who)) "key logon: whoami is $User"

    # a command runs and its output comes back
    $echo = (& docker exec $client $sshExe @keySsh "$User@$ip" 'echo ssh-ok-%USERNAME%' 2>&1 | Out-String).Trim()
    $rc = $LASTEXITCODE
    Write-Host "command -> rc=$rc $echo"
    Assert-That ($rc -eq 0 -and $echo -ieq "ssh-ok-$User") 'remote command output returned'

    if ($Admin) {
        $groups = (& docker exec $client $sshExe @keySsh "$User@$ip" 'net localgroup Administrators' 2>&1 | Out-String)
        Assert-That ($groups -match "(?im)^\s*$([regex]::Escape($User))\s*$") "$User is in Administrators"
    }

    # an unauthorized key is rejected
    $bad = (& docker exec $client $sshExe -i 'C:\wrong_key' -o BatchMode=yes @commonSsh "$User@$ip" whoami 2>&1 | Out-String).Trim()
    $rc = $LASTEXITCODE
    Write-Host "wrong key -> rc=$rc $bad"
    Assert-That ($rc -ne 0 -and $bad -match 'Permission denied') 'unauthorized key rejected'

    # Password logon goes through SSH_ASKPASS because there is no TTY in CI.
    Invoke-Docker exec $client cmd /c "echo @echo $password>C:\askpass.cmd" | Out-Null
    Invoke-Docker exec $client cmd /c 'echo @echo not-the-password>C:\badpass.cmd' | Out-Null
    $askGood = @('-e', 'SSH_ASKPASS=C:\askpass.cmd', '-e', 'SSH_ASKPASS_REQUIRE=force')
    $askBad = @('-e', 'SSH_ASKPASS=C:\badpass.cmd', '-e', 'SSH_ASKPASS_REQUIRE=force')

    if ($KeyOnly) {
        $pw = (& docker exec @askGood $client $sshExe @pwSsh "$User@$ip" whoami 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        Write-Host "password (disabled) -> rc=$rc $pw"
        Assert-That ($rc -ne 0 -and $pw -match 'Permission denied \(publickey\)') 'password logon disabled without SSH_PASSWORD'
    }
    else {
        $whoPw = (& docker exec @askGood $client $sshExe @pwSsh "$User@$ip" whoami 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        Write-Host "password whoami -> rc=$rc $whoPw"
        Assert-That ($rc -eq 0 -and (Test-IsUser $whoPw)) "password logon: whoami is $User"

        $badPw = (& docker exec @askBad $client $sshExe @pwSsh "$User@$ip" whoami 2>&1 | Out-String).Trim()
        $rc = $LASTEXITCODE
        Write-Host "wrong password -> rc=$rc $badPw"
        Assert-That ($rc -ne 0 -and $badPw -match 'Permission denied') 'wrong password rejected'
    }
}
finally {
    Write-Host '--- final server log ---'
    & docker logs $server 2>&1 | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    & docker exec $server cmd /c 'type C:\ProgramData\ssh\logs\sshd-session.log' 2>&1 | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    & docker rm -f $server $client 2>&1 | Out-Null
}

if ($failures.Count) { throw "$($failures.Count) assertion(s) failed: $($failures -join '; ')" }
Write-Host 'All SSH assertions passed.'
