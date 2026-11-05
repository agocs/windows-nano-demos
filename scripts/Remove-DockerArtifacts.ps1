<#
.SYNOPSIS
Removes only the Docker containers and images whose names start with a given prefix, such as the leftovers of an
experiment. It never prunes, and it refuses prefixes that would touch shared infrastructure.

.DESCRIPTION
Experiments should name everything they create with a unique prefix (for example `cgo-exp-`). This script removes:
- containers whose name starts with the prefix (stopped or running)
- image tags whose repository starts with the prefix

By default an image is untagged with `docker rmi --no-prune`, which keeps its untagged parent layers, because those
may be the build cache other images share. Pass -IncludeParents to free that space too, for images that only the
experiment used.

Use -WhatIf to see what would be removed.

.EXAMPLE
./scripts/Remove-DockerArtifacts.ps1 -Prefix cgo-exp- -WhatIf
./scripts/Remove-DockerArtifacts.ps1 -Prefix mysql-spike -IncludeParents
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateLength(4, 128)]
    [string]$Prefix,
    [switch]$IncludeParents
)
$ErrorActionPreference = 'Stop'

# Shared infrastructure that this script must never touch, whatever prefix it is given
$protected = @('DEARING-HP-Z-nano', 'windows-nano-gh-runner', 'windows-nano-artifact-cache', 'zippy1981/', 'mcr.microsoft.com')
foreach ($name in $protected) {
    if ($name.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -or $Prefix.StartsWith($name, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing prefix '$Prefix': it overlaps protected '$name'"
    }
}

$containers = docker ps -a --format '{{.Names}}' | Where-Object { $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) }
$images = docker images --format '{{.Repository}}:{{.Tag}}' |
    Where-Object { $_ -notlike '*<none>*' -and $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) }

foreach ($container in $containers) {
    if ($PSCmdlet.ShouldProcess($container, 'docker rm -f')) {
        docker rm -f $container | Out-Null
        Write-Host "removed container $container"
    }
}
foreach ($image in $images) {
    $rmiArgs = if ($IncludeParents) { @('rmi', $image) } else { @('rmi', '--no-prune', $image) }
    if ($PSCmdlet.ShouldProcess($image, "docker $($rmiArgs -join ' ')")) {
        docker @rmiArgs | Out-Null
        Write-Host "removed image $image"
    }
}
if (-not $containers -and -not $images) { Write-Host "Nothing matches '$Prefix'." }
