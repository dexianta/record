$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "Record\Record.csproj"
$output = Join-Path $PSScriptRoot "..\dist\windows-x64"
$archive = Join-Path $PSScriptRoot "..\dist\record-windows-x64.zip"

if (Test-Path $output) {
    Remove-Item $output -Recurse
}
dotnet publish $project `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --output $output `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

$executable = Join-Path $output "record.exe"
& $executable --self-check
if ($LASTEXITCODE -ne 0) {
    throw "Record Windows self-check failed with exit code $LASTEXITCODE"
}

if (Test-Path $archive) {
    Remove-Item $archive
}
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $archive
Write-Host "Built $archive"
