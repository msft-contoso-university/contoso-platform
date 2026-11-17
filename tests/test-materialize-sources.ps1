$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $root 'scripts\materialize-sources.ps1'
$lock = Join-Path $root 'sources.lock.json'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "contoso-lock-$([guid]::NewGuid()).json"
$dirty = Join-Path $root '.sources\contoso-web\source-lock-test.tmp'
$createdMarker = $false
$createdFixture = $false

function Assert-FailsValidation($Document) {
    $Document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture -Encoding utf8
    & pwsh -NoProfile -File $script -LockFile $fixture -ValidateOnly *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Invalid source lock was accepted.' }
}

try {
    $stream = [IO.File]::Open($fixture, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    $createdFixture = $true
    $stream.Dispose()
    & pwsh -NoProfile -File $script -LockFile $lock -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw 'Valid source lock was rejected.' }

    $document = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable
    $document.repositories[1].name = $document.repositories[0].name
    Assert-FailsValidation $document
    $document = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable
    $document.repositories[0].commit = 'main'
    Assert-FailsValidation $document
    $document = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable
    $document.repositories[0].name = '../another-repo'
    Assert-FailsValidation $document

    & pwsh -NoProfile -File $script
    if ($LASTEXITCODE -ne 0) { throw 'Locked materialization failed.' }
    & pwsh -NoProfile -File $script
    if ($LASTEXITCODE -ne 0) { throw 'Repeated materialization failed.' }
    $stream = [IO.File]::Open($dirty, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    $createdMarker = $true
    $stream.Dispose()
    & pwsh -NoProfile -File $script *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Dirty checkout was incorrectly accepted.' }
    Write-Output 'Source lock tests passed.'
} finally {
    if ($createdFixture -and (Test-Path -LiteralPath $fixture)) { Remove-Item -LiteralPath $fixture }
    if ($createdMarker -and (Test-Path -LiteralPath $dirty)) { Remove-Item -LiteralPath $dirty }
}
exit 0
