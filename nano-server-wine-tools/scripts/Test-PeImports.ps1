<#
.SYNOPSIS
    Fails if any import of the PE files in -Path does not resolve against the DLLs of this Windows image.

.DESCRIPTION
    Parses the import table (and the delay-load import table) of every .exe and .dll in -Path, then
    looks each imported DLL up app-locally (in -Path), in -System32 and in -System32\forwarders, and
    checks that every imported name or ordinal is in that DLL's export table. Forwarded exports count
    as exported, which is what the loader checks first.

    Runs inside the base image (the Dockerfile's check stage), so the exports it checks against are the
    ones of that exact nanoserver build. Pure .NET, no Windows-only modules, so pwsh 7 on nanoserver is enough.

    Missing normal imports are errors (the process would fail to start with 0xC0000135 or 0xC0000139).
    Missing delay-load imports are warnings unless -StrictDelayLoad is given, because they only fail
    when the code path that uses them runs.

.EXAMPLE
    pwsh -NoProfile -File Test-PeImports.ps1 -Path C:\wine-pe -System32 C:\Windows\System32
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $System32 = "$env:SystemRoot\System32",
    [switch] $StrictDelayLoad
)

$ErrorActionPreference = 'Stop'

function Read-Pe {
    param([string] $File)
    $b = [System.IO.File]::ReadAllBytes($File)
    if ($b.Length -lt 0x40 -or [BitConverter]::ToUInt16($b, 0) -ne 0x5A4D) { throw "$File is not a PE file (no MZ)" }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ([BitConverter]::ToUInt32($b, $pe) -ne 0x4550) { throw "$File is not a PE file (no PE signature)" }
    $coff = $pe + 4
    $machine = [BitConverter]::ToUInt16($b, $coff)
    $nSections = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt = $coff + 20
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $is64 = $magic -eq 0x20B
    $dd = $opt + $(if ($is64) { 112 } else { 96 })
    $dirs = for ($i = 0; $i -lt 16; $i++) {
        [pscustomobject]@{ Rva = [BitConverter]::ToUInt32($b, $dd + 8 * $i); Size = [BitConverter]::ToUInt32($b, $dd + 8 * $i + 4) }
    }
    $sec = $opt + $optSize
    $sections = for ($i = 0; $i -lt $nSections; $i++) {
        $s = $sec + 40 * $i
        [pscustomobject]@{
            VA = [BitConverter]::ToUInt32($b, $s + 12)
            VSize = [Math]::Max([BitConverter]::ToUInt32($b, $s + 8), [BitConverter]::ToUInt32($b, $s + 16))
            Raw = [BitConverter]::ToUInt32($b, $s + 20)
        }
    }
    [pscustomobject]@{ File = $File; Bytes = $b; Machine = $machine; Is64 = $is64; Dirs = $dirs; Sections = $sections }
}

function Get-Offset {
    param($Pe, [uint32] $Rva)
    foreach ($s in $Pe.Sections) {
        if ($Rva -ge $s.VA -and $Rva -lt ($s.VA + $s.VSize)) { return [int]($Rva - $s.VA + $s.Raw) }
    }
    return [int]$Rva  # inside the headers
}

function Get-CString {
    param($Pe, [uint32] $Rva)
    $o = Get-Offset $Pe $Rva
    $e = [Array]::IndexOf($Pe.Bytes, [byte]0, $o)
    [System.Text.Encoding]::ASCII.GetString($Pe.Bytes, $o, $e - $o)
}

function Get-Thunks {
    # Returns the names (or '#<ordinal>') of one import lookup table.
    param($Pe, [uint32] $TableRva)
    $o = Get-Offset $Pe $TableRva
    $step = if ($Pe.Is64) { 8 } else { 4 }
    while ($true) {
        if ($Pe.Is64) {
            $v = [BitConverter]::ToUInt64($Pe.Bytes, $o)
            if ($v -eq 0) { break }
            $byOrdinal = ($v -band 0x8000000000000000) -ne 0
        } else {
            $v = [uint64][BitConverter]::ToUInt32($Pe.Bytes, $o)
            if ($v -eq 0) { break }
            $byOrdinal = ($v -band 0x80000000) -ne 0
        }
        if ($byOrdinal) { "#$($v -band 0xFFFF)" } else { Get-CString $Pe ([uint32](($v -band 0x7FFFFFFF) + 2)) }
        $o += $step
    }
}

function Get-Imports {
    param($Pe)
    $b = $Pe.Bytes
    $imp = $Pe.Dirs[1]
    if ($imp.Rva -ne 0) {
        $o = Get-Offset $Pe $imp.Rva
        while ($true) {
            $ilt = [BitConverter]::ToUInt32($b, $o); $name = [BitConverter]::ToUInt32($b, $o + 12); $iat = [BitConverter]::ToUInt32($b, $o + 16)
            if ($name -eq 0) { break }
            $table = if ($ilt -ne 0) { $ilt } else { $iat }
            [pscustomobject]@{ Dll = (Get-CString $Pe $name); Delay = $false; Names = @(Get-Thunks $Pe $table) }
            $o += 20
        }
    }
    $dly = $Pe.Dirs[13]
    if ($dly.Rva -ne 0) {
        $o = Get-Offset $Pe $dly.Rva
        while ($true) {
            $name = [BitConverter]::ToUInt32($b, $o + 4); $int = [BitConverter]::ToUInt32($b, $o + 16)
            if ($name -eq 0) { break }
            [pscustomobject]@{ Dll = (Get-CString $Pe $name); Delay = $true; Names = @(Get-Thunks $Pe $int) }
            $o += 32
        }
    }
}

function Get-Exports {
    param($Pe)
    $b = $Pe.Bytes
    $exp = $Pe.Dirs[0]
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $result = [pscustomobject]@{ Names = $names; Base = 0; Count = 0 }
    if ($exp.Rva -eq 0) { return $result }
    $o = Get-Offset $Pe $exp.Rva
    $result.Base = [BitConverter]::ToUInt32($b, $o + 16)
    $result.Count = [BitConverter]::ToUInt32($b, $o + 20)
    $nNames = [BitConverter]::ToUInt32($b, $o + 24)
    $namesOff = Get-Offset $Pe ([BitConverter]::ToUInt32($b, $o + 32))
    for ($i = 0; $i -lt $nNames; $i++) {
        [void]$names.Add((Get-CString $Pe ([BitConverter]::ToUInt32($b, $namesOff + 4 * $i))))
    }
    $result
}

$exportCache = @{}
function Find-Dll {
    param([string] $Name)
    foreach ($dir in @($Path, $System32, (Join-Path $System32 'forwarders'))) {
        $p = Join-Path $dir $Name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Get-DllExports {
    param([string] $Name)
    $key = $Name.ToLowerInvariant()
    if (-not $exportCache.ContainsKey($key)) {
        $file = Find-Dll $Name
        $exportCache[$key] = if ($file) { [pscustomobject]@{ File = $file; Exports = (Get-Exports (Read-Pe $file)) } } else { $null }
    }
    $exportCache[$key]
}

$files = Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.exe', '.dll' }
if (-not $files) { throw "No .exe or .dll files in $Path" }

$errors = 0
$warnings = 0
foreach ($f in $files) {
    $pe = Read-Pe $f.FullName
    if ($pe.Machine -ne 0x8664) { Write-Output "FAIL $($f.Name): machine 0x$('{0:X4}' -f $pe.Machine) is not x64"; $errors++; continue }
    $bad = @()
    $badDelay = @()
    $count = 0
    foreach ($imp in Get-Imports $pe) {
        $dll = Get-DllExports $imp.Dll
        foreach ($n in $imp.Names) {
            $count++
            $ok = $false
            if ($dll) {
                if ($n.StartsWith('#')) {
                    $ord = [int]$n.Substring(1)
                    $ok = $ord -ge $dll.Exports.Base -and $ord -lt ($dll.Exports.Base + $dll.Exports.Count)
                } else {
                    $ok = $dll.Exports.Names.Contains($n)
                }
            }
            if (-not $ok) {
                $what = if ($dll) { "$($imp.Dll)!$n" } else { "$($imp.Dll) (DLL not found)" }
                if ($imp.Delay) { $badDelay += $what } else { $bad += $what }
            }
        }
    }
    $bad = @($bad | Select-Object -Unique)
    $badDelay = @($badDelay | Select-Object -Unique)
    if ($bad) {
        $errors++
        Write-Output "FAIL $($f.Name): $($bad.Count) unresolved import(s): $($bad -join ', ')"
    } else {
        Write-Output "ok   $($f.Name): $count import(s) resolve"
    }
    if ($badDelay) {
        if ($StrictDelayLoad) { $errors++; $tag = 'FAIL' } else { $warnings++; $tag = 'WARN' }
        Write-Output "$tag $($f.Name): unresolved delay-load import(s): $($badDelay -join ', ')"
    }
}

Write-Output "Checked $($files.Count) file(s) against $System32 : $errors failure(s), $warnings warning(s)"
if ($errors) { exit 1 }
exit 0
