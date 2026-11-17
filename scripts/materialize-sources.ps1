[CmdletBinding()]
param(
    [string] $LockFile = (Join-Path $PSScriptRoot '..\sources.lock.json'),
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sources = Join-Path $root '.sources'
$allowed = @('contoso-web', 'contoso-students', 'contoso-academics', 'contoso-enrollments')
$document = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json -AsHashtable
if ($document -isnot [System.Collections.IDictionary] -or
    @($document.Keys).Count -ne 2 -or
    -not $document.Contains('version') -or -not $document.Contains('repositories') -or
    $document.version -isnot [long] -or $document.version -ne 1 -or
    $document.repositories -isnot [array] -or $document.repositories.Count -ne $allowed.Count) {
    throw 'Invalid source lock: expected version 1 and four repositories.'
}

$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in $document.repositories) {
    if ($entry -isnot [System.Collections.IDictionary] -or
        @($entry.Keys).Count -ne 2 -or
        -not $entry.Contains('name') -or -not $entry.Contains('commit') -or
        $entry.name -isnot [string] -or $entry.name -cnotin $allowed -or
        -not $seen.Add($entry.name) -or $entry.commit -isnot [string] -or
        $entry.commit -cnotmatch '^[0-9a-f]{40}$' -or
        $entry.commit -eq ('0' * 40)) {
        throw 'Invalid source lock: unknown, duplicate or unpinned repository.'
    }
}
if ($ValidateOnly) {
    Write-Output 'Source lock is structurally valid; this does not establish release readiness.'
    return
}

if (Test-Path -LiteralPath $sources) {
    $sourceItem = Get-Item -LiteralPath $sources -Force
    if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The .sources path must be a real directory, not a link.'
    }
} else {
    New-Item -ItemType Directory -Path $sources | Out-Null
}

function Assert-ExistingSource([string] $Path, [string] $Name, [string] $Commit) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Source path for $Name is not a real directory."
    }
    $top = & git -C $Path rev-parse --show-toplevel
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($LASTEXITCODE -ne 0 -or
        -not [string]::Equals([IO.Path]::GetFullPath($top), [IO.Path]::GetFullPath($Path), $comparison)) {
        throw "Source path for $Name is not its own Git checkout."
    }
    $remote = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $remote -cne "https://github.com/msft-contoso-university/$Name.git") {
        throw "Source origin for $Name does not match the approved repository."
    }
    $head = & git -C $Path rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $Commit) {
        throw "Source checkout for $Name is not at its locked commit; it will not be modified."
    }
    $status = & git -C $Path status --porcelain --untracked-files=all --ignored=matching
    if ($LASTEXITCODE -ne 0 -or $status) {
        throw "Source checkout for $Name is not pristine; it will not be modified."
    }
}

foreach ($entry in $document.repositories) {
    $target = Join-Path $sources $entry.name
    if (Test-Path -LiteralPath $target) {
        Assert-ExistingSource $target $entry.name $entry.commit
    }
}
foreach ($entry in $document.repositories) {
    $target = Join-Path $sources $entry.name
    if (-not (Test-Path -LiteralPath $target)) {
        & git clone --no-checkout -- "https://github.com/msft-contoso-university/$($entry.name).git" $target
        if ($LASTEXITCODE -ne 0) {
            throw "Clone failed for $($entry.name); inspect the partial checkout before retrying."
        }
        & git -C $target checkout --detach $entry.commit
        if ($LASTEXITCODE -ne 0) {
            throw "Checkout failed for $($entry.name); inspect the partial checkout before retrying."
        }
        Assert-ExistingSource $target $entry.name $entry.commit
    }
}
Write-Output 'All locked sources were materialized and verified.'
