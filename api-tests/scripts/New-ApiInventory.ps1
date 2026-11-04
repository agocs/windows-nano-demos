<#
.SYNOPSIS
  Builds the L1/L2 inventory (api-tests/data/<version>/) from servercore's System32.

.DESCRIPTION
  On the host, the script starts a servercore container for each Windows version,
  bind-mounts itself and the output folder, and runs itself again inside the
  container with -InContainer. Inside, Windows PowerShell 5.1 (servercore ships it)
  parses the PE export directory of every C:\Windows\System32\*.dll with a small
  C# reader, so no extra tools are needed.

  Output per version:
    dlls.txt              one DLL base name (no .dll, lower case) per line
    exports/<dll>.txt     the named exports of that DLL, one per line
    source.txt            the image and OS build the data came from

  Kept out of the inventory: non-x64 images, files without the DLL flag, native
  subsystem images (drivers and boot/kernel helpers named *.dll), and the deny
  list below (DLLs whose load has side effects or hangs).

.EXAMPLE
  ./api-tests/scripts/New-ApiInventory.ps1 -WindowsVersion 2022
#>
[CmdletBinding()]
param(
    [string[]] $WindowsVersion = @('2019', '2022', '2025'),
    [string] $OutDir,
    [switch] $InContainer
)

$ErrorActionPreference = 'Stop'

# DLLs left out of L1 on purpose: loading them has side effects that are not
# about API availability. Extend with a comment when a new one is found.
$DenyList = @(
    'hal'          # kernel-mode HAL
)

if (-not $InContainer) {
    if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\data' }
    $OutDir = [System.IO.Path]::GetFullPath($OutDir)
    foreach ($v in ($WindowsVersion -split ',' | Where-Object { $_ })) {
        $image = "mcr.microsoft.com/windows/servercore:ltsc$v-amd64"
        $target = Join-Path $OutDir $v
        if (Test-Path $target) { Remove-Item -Recurse -Force $target }
        New-Item -ItemType Directory -Force $target | Out-Null
        Write-Host "== $image -> $target"
        docker run --rm `
            -v "$($PSScriptRoot):C:\inv:ro" -v "$($target):C:\out" `
            $image powershell -NoProfile -ExecutionPolicy Bypass -File C:\inv\New-ApiInventory.ps1 -InContainer -OutDir C:\out
        if ($LASTEXITCODE -ne 0) { throw "inventory for $v failed ($LASTEXITCODE)" }
        Write-Host ("   {0} DLLs" -f (Get-Content (Join-Path $target 'dlls.txt')).Count)
    }
    return
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public class PeInfo {
    public int Machine;
    public int Subsystem;
    public bool IsDll;
    public List<string> Exports = new List<string>();
    public string Error;
}

public static class PeReader {
    static int RvaToOffset(byte[] b, int secTab, int nsec, uint rva) {
        for (int i = 0; i < nsec; i++) {
            int s = secTab + i * 40;
            uint vsize = BitConverter.ToUInt32(b, s + 8);
            uint va = BitConverter.ToUInt32(b, s + 12);
            uint rawSize = BitConverter.ToUInt32(b, s + 16);
            uint raw = BitConverter.ToUInt32(b, s + 20);
            uint size = Math.Max(vsize, rawSize);
            if (rva >= va && rva < va + size) return (int)(rva - va + raw);
        }
        return -1;
    }

    public static PeInfo Read(string path) {
        PeInfo info = new PeInfo();
        try {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 0x40 || b[0] != (byte)'M' || b[1] != (byte)'Z') { info.Error = "not MZ"; return info; }
            int pe = BitConverter.ToInt32(b, 0x3C);
            if (pe <= 0 || pe + 24 > b.Length || BitConverter.ToUInt32(b, pe) != 0x4550) { info.Error = "not PE"; return info; }
            int coff = pe + 4;
            info.Machine = BitConverter.ToUInt16(b, coff);
            int nsec = BitConverter.ToUInt16(b, coff + 2);
            int optSize = BitConverter.ToUInt16(b, coff + 16);
            int chars = BitConverter.ToUInt16(b, coff + 18);
            info.IsDll = (chars & 0x2000) != 0;
            int opt = coff + 20;
            bool pe32p = BitConverter.ToUInt16(b, opt) == 0x20b;
            info.Subsystem = BitConverter.ToUInt16(b, opt + 68);
            int numDd = BitConverter.ToInt32(b, opt + (pe32p ? 108 : 92));
            if (numDd < 1) return info;
            int dd = opt + (pe32p ? 112 : 96);
            uint expRva = BitConverter.ToUInt32(b, dd);
            if (expRva == 0) return info;
            int secTab = opt + optSize;
            int exp = RvaToOffset(b, secTab, nsec, expRva);
            if (exp < 0) { info.Error = "export directory outside sections"; return info; }
            int numNames = BitConverter.ToInt32(b, exp + 24);
            int names = RvaToOffset(b, secTab, nsec, BitConverter.ToUInt32(b, exp + 32));
            for (int i = 0; i < numNames && names >= 0; i++) {
                int n = RvaToOffset(b, secTab, nsec, BitConverter.ToUInt32(b, names + i * 4));
                if (n < 0) continue;
                int e = n;
                while (e < b.Length && b[e] != 0) e++;
                info.Exports.Add(Encoding.ASCII.GetString(b, n, e - n));
            }
        } catch (Exception ex) {
            info.Error = ex.Message;
        }
        return info;
    }
}
'@

$exportsDir = Join-Path $OutDir 'exports'
New-Item -ItemType Directory -Force $exportsDir | Out-Null
$dlls = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]
$utf8 = New-Object System.Text.UTF8Encoding($false)

Get-ChildItem -File C:\Windows\System32\*.dll | Sort-Object Name | ForEach-Object {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant()
    $info = [PeReader]::Read($_.FullName)
    $why = $null
    if ($info.Error) { $why = $info.Error }
    elseif ($info.Machine -ne 0x8664) { $why = ('machine 0x{0:x}' -f $info.Machine) }
    elseif (-not $info.IsDll) { $why = 'not a DLL' }
    elseif ($info.Subsystem -eq 1 -and $base -ne 'ntdll') { $why = 'native subsystem' }
    elseif ($DenyList -contains $base) { $why = 'deny list' }
    if ($why) { $skipped.Add("$base`t$why"); return }
    $dlls.Add($base)
    $names = @($info.Exports | Where-Object { $_ } | Sort-Object -Unique)
    if ($names.Count -gt 0) {
        [System.IO.File]::WriteAllText((Join-Path $exportsDir "$base.txt"), (($names -join "`n") + "`n"), $utf8)
    }
}

[System.IO.File]::WriteAllText((Join-Path $OutDir 'dlls.txt'), (($dlls -join "`n") + "`n"), $utf8)
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$source = @(
    "image: servercore (C:\Windows\System32)",
    ("os_build: {0}.{1}" -f $cv.CurrentBuild, $cv.UBR),
    ("dlls: {0}" -f $dlls.Count),
    ("skipped: {0}" -f $skipped.Count)
) + ($skipped | ForEach-Object { "  $_" })
[System.IO.File]::WriteAllText((Join-Path $OutDir 'source.txt'), (($source -join "`n") + "`n"), $utf8)
