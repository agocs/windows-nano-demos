<#
.SYNOPSIS
  Merges apiprobe results.jsonl files into a Markdown compatibility matrix.

.DESCRIPTION
  Reads every results.jsonl under -Path (one per target and Windows version)
  and writes -Out with three tables:
    1. a summary per target-version (os_build, L1, L2 and L3 counts, regressions)
    2. the L3 behaviour probes, one row per probe and one column per target-version
    3. L1 and L2 per DLL (inside <details>, it is long)
  Cells are ok, skip, missing-dll, missing-export, error <code>, crash or timeout.
  A regression against the baseline is shown in bold with a (!) marker.

.EXAMPLE
  ./api-tests/scripts/ConvertTo-ApiMatrix.ps1 -Path results -Out api-matrix.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Out = 'api-matrix.md'
)

$ErrorActionPreference = 'Stop'

function Format-Cell($r) {
    if (-not $r) { return '' }
    $s = $r.status
    if ($s -eq 'error' -or $s -eq 'crash') { $s = "$s $($r.win32_error)" }
    if ($r.level -eq 2 -and $r.total) { $s = "$s $($r.resolved)/$($r.total)" }
    switch ($r.verdict) {
        'fail' { return "**$s (!)**" }
        'improved' { return "$s (+)" }
        default { return $s }
    }
}

function Format-Count([int] $a, [int] $b) { '{0:N0}/{1:N0}' -f $a, $b }

$files = @(Get-ChildItem -Recurse -File -Path $Path -Filter results.jsonl)
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('## Win32 API compatibility matrix')
$lines.Add('')
if (-not $files) {
    $lines.Add('No results.jsonl files were found.')
    Set-Content -Path $Out -Value $lines -Encoding utf8
    return
}

$cols = [System.Collections.Generic.List[string]]::new()
$meta = @{}
$l3 = [ordered]@{}
$l3info = @{}
$dll = [ordered]@{}
foreach ($f in $files) {
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        if (-not $line) { continue }
        $r = $line | ConvertFrom-Json
        $col = "$($r.target)-$($r.windows_version)"
        if (-not $meta.ContainsKey($col)) {
            $cols.Add($col)
            $meta[$col] = [ordered]@{ os_build = $r.os_build; l1 = 0; l1ok = 0; l2 = 0; l2ok = 0; l3 = 0; l3ok = 0; fail = 0; improved = 0 }
        }
        $m = $meta[$col]
        if ($r.verdict -eq 'fail') { $m.fail++ }
        if ($r.verdict -eq 'improved') { $m.improved++ }
        switch ($r.level) {
            1 {
                $m.l1++
                if ($r.status -eq 'ok') { $m.l1ok++ }
                if (-not $dll.Contains($r.dll)) { $dll[$r.dll] = @{} }
                if (-not $dll[$r.dll].ContainsKey($col)) { $dll[$r.dll][$col] = @{} }
                $dll[$r.dll][$col].l1 = $r
            }
            2 {
                if ($r.check -ne 'exports') { continue }
                $m.l2 += [int]$r.total
                $m.l2ok += [int]$r.resolved
                if (-not $dll.Contains($r.dll)) { $dll[$r.dll] = @{} }
                if (-not $dll[$r.dll].ContainsKey($col)) { $dll[$r.dll][$col] = @{} }
                $dll[$r.dll][$col].l2 = $r
            }
            3 {
                $m.l3++
                if ($r.status -eq 'ok') { $m.l3ok++ }
                if (-not $l3.Contains($r.id)) { $l3[$r.id] = @{} }
                $l3[$r.id][$col] = $r
                $l3info[$r.id] = "$($r.dll)!$($r.function)"
                if ($r.check) { $l3info[$r.id] += ": $($r.check)" }
            }
        }
    }
}
$cols = @($cols | Sort-Object { ($_ -split '-')[-1] }, { $_ })

$lines.Add('### Summary')
$lines.Add('')
$lines.Add('| Target | OS build | L1 DLLs loaded | L2 exports resolved | L3 probes ok | Regressions | Improvements |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($c in $cols) {
    $m = $meta[$c]
    $lines.Add("| $c | $($m.os_build) | $(Format-Count $m.l1ok $m.l1) | $(Format-Count $m.l2ok $m.l2) | $(Format-Count $m.l3ok $m.l3) | $($m.fail) | $($m.improved) |")
}
$lines.Add('')
$lines.Add('Cells: `ok`, `skip`, `missing-dll`, `missing-export`, `error <win32 code>`, `crash <code>`, `timeout`. **Bold (!)** is a regression against the baseline, (+) an improvement.')
$lines.Add('')

$lines.Add('### L3 behaviour probes')
$lines.Add('')
$lines.Add("| Probe | $($cols -join ' | ') |")
$lines.Add("| --- |$(' --- |' * $cols.Count)")
foreach ($id in $l3.Keys) {
    $cells = foreach ($c in $cols) { Format-Cell $l3[$id][$c] }
    $name = $l3info[$id] -replace '\|', '\|'
    $lines.Add("| $name | $($cells -join ' | ') |")
}
$lines.Add('')

$lines.Add('### L1 load and L2 exports per DLL')
$lines.Add('')
$lines.Add('<details><summary>Every DLL of the servercore inventory</summary>')
$lines.Add('')
$lines.Add("| DLL | $($cols -join ' | ') |")
$lines.Add("| --- |$(' --- |' * $cols.Count)")
foreach ($d in $dll.Keys) {
    $cells = foreach ($c in $cols) {
        $e = $dll[$d][$c]
        if (-not $e) { '' }
        elseif ($e.l1 -and $e.l1.status -ne 'ok') { Format-Cell $e.l1 }
        elseif ($e.l2) {
            $s = if ($e.l2.total) { Format-Count $e.l2.resolved $e.l2.total } else { 'ok' }
            if ($e.l2.verdict -eq 'fail' -or $e.l1.verdict -eq 'fail') { "**$s (!)**" } else { $s }
        } else { Format-Cell $e.l1 }
    }
    $lines.Add("| $d | $($cells -join ' | ') |")
}
$lines.Add('')
$lines.Add('</details>')
Set-Content -Path $Out -Value $lines -Encoding utf8
Write-Host "wrote $Out ($($cols.Count) targets, $($l3.Count) L3 probes, $($dll.Count) DLLs)"
