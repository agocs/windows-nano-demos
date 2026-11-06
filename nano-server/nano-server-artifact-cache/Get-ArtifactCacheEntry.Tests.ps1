<#
.SYNOPSIS
Pester tests for Get-ArtifactCacheEntry.ps1 against fixture cache files.
.DESCRIPTION
The fixtures under fixtures/cache are in simplefs v0.0.22 format: payload
files named by the xxhash64 of their varied key, and .simplefs-index files
named by the xxhash64 of the base key, holding protobuf StorageMapper
entries. They model one fresh entry without Vary (7zr.exe), one stale entry
with Vary (the Go zip), one expired entry (the Node zip) and one orphan
payload. States are judged at a fixed -Now, 2026-11-10, so the fixtures
never age out.
.EXAMPLE
Invoke-Pester -Path ./nano-server/nano-server-artifact-cache/Get-ArtifactCacheEntry.Tests.ps1
#>
[CmdletBinding()]
param()

BeforeAll {
    . $PSScriptRoot/Get-ArtifactCacheEntry.ps1
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures/cache'
    $script:at = [datetimeoffset]'2026-11-10T00:00:00Z'
    $script:urls = @(
        'https://www.7-zip.org/a/7zr.exe',
        'https://dl.google.com/go/go1.27.3.windows-amd64.zip',
        'https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip'
    )
    $script:entries = @(Get-ArtifactCacheEntry -Path $script:fixtures -CandidateUrl $script:urls -At $script:at -RepoRoot $PSScriptRoot)
    $script:byHash = @{}
    foreach ($entry in $script:entries) { $script:byHash[$entry.Hash] = $entry }
}

Describe 'Get-XxHash64 known vectors' {
    It 'hashes the 7zr.exe key' {
        Get-XxHash64 'GET-https-www.7-zip.org-/a/7zr.exe' | Should -Be '5878554692879206298'
    }
    It 'hashes the Node zip key' {
        Get-XxHash64 'GET-https-nodejs.org-/dist/v26.13.0/node-v26.13.0-win-x64.zip' | Should -Be '10893980105756012850'
    }
    It 'hashes the Go base and varied keys' {
        Get-XxHash64 'GET-https-dl.google.com-/go/go1.27.3.windows-amd64.zip' | Should -Be '4578865327147983338'
        Get-XxHash64 'GET-https-dl.google.com-/go/go1.27.3.windows-amd64.zip{-VARY-}Accept-Encoding:' | Should -Be '15782013875559861339'
    }
}

Describe 'Read-StorageIndex against the fixture indexes' {
    It 'reads every indexed payload with its times and ETag' {
        $index = Read-StorageIndex -IndexPath (Join-Path $script:fixtures '.simplefs-index')
        $index.Count | Should -Be 3
        $go = $index['15782013875559861339']
        $go.IndexHash | Should -Be '4578865327147983338'
        $go.StoredAt | Should -Be ([datetimeoffset]'2026-10-05T00:00:00Z')
        $go.ETag | Should -Be 'etag-go'
        $go.VariedHeaders['Accept-Encoding'] | Should -Be @('')
    }
}

Describe 'Get-ArtifactCacheEntry listing' {
    It 'lists one object per payload, orphans included' {
        $script:entries.Count | Should -Be 4
    }

    It 'matches URLs and states at the fixed time' {
        $script:byHash['5878554692879206298'].Url | Should -Be $script:urls[0]
        $script:byHash['5878554692879206298'].State | Should -Be 'Fresh'
        $script:byHash['15782013875559861339'].Url | Should -Be $script:urls[1]
        $script:byHash['15782013875559861339'].State | Should -Be 'Stale'
        $script:byHash['10893980105756012850'].Url | Should -Be $script:urls[2]
        $script:byHash['10893980105756012850'].State | Should -Be 'Expired'
    }

    It 'lists the orphan by hash with no URL or times' {
        $orphan = $script:byHash['12345678901234567890']
        $orphan.State | Should -Be 'Orphan'
        $orphan.Url | Should -BeNullOrEmpty
        $orphan.IndexHash | Should -BeNullOrEmpty
        $orphan.StoredAt | Should -BeNullOrEmpty
    }

    It 'shows sizes and 720h fresh and 888h stale windows' {
        $sevenZip = $script:byHash['5878554692879206298']
        $sevenZip.Bytes | Should -Be (Get-Item (Join-Path $script:fixtures $sevenZip.Hash)).Length
        ($sevenZip.FreshUntil - $sevenZip.StoredAt) | Should -Be ([timespan]::FromHours(720))
        ($sevenZip.StaleUntil - $sevenZip.StoredAt) | Should -Be ([timespan]::FromHours(888))
    }

    It 'leaves the fixture folder byte-for-byte unchanged' {
        $before = Get-ChildItem -Recurse -File $script:fixtures | ForEach-Object { "$($_.FullName)=$($_.Length)" }
        $null = Get-ArtifactCacheEntry -Path $script:fixtures -CandidateUrl $script:urls -At $script:at -RepoRoot $PSScriptRoot
        $after = Get-ChildItem -Recurse -File $script:fixtures | ForEach-Object { "$($_.FullName)=$($_.Length)" }
        $after | Should -Be $before
    }
}
