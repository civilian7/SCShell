# Build all samples + copy sc_shell.dll next to each EXE.
# Usage: .\build_all.ps1

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$DelphiSrc = Join-Path $RootDir 'delphi\src'
$Bin = Join-Path $RootDir 'bin'
$Dcc64 = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe'

if (-not (Test-Path $Dcc64)) { throw "dcc64 not found: $Dcc64" }
if (-not (Test-Path $DelphiSrc)) { throw "Delphi src not found: $DelphiSrc" }

# Ensure DLL exists
$Dll = Join-Path $Bin 'sc_shell.dll'
if (-not (Test-Path $Dll)) {
    Write-Host "sc_shell.dll missing — building first..." -ForegroundColor Yellow
    & (Join-Path $RootDir 'tools\build.ps1') -Rust64
}

$Samples = @(
    @{Dir='01_minimal';      Dpr='Minimal.dpr'},
    @{Dir='02_menu_driven';  Dpr='MenuDriven.dpr'},
    @{Dir='03_tabs';         Dpr='Tabs.dpr'},
    @{Dir='04_scripted';     Dpr='Scripted.dpr'}
)

foreach ($s in $Samples) {
    $SampleDir = Join-Path $PSScriptRoot $s.Dir
    $OutDir = Join-Path $SampleDir 'bin'
    $DcuDir = Join-Path $SampleDir 'dcu'
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    New-Item -ItemType Directory -Force -Path $DcuDir | Out-Null

    Write-Host "== Building $($s.Dir)/$($s.Dpr) ==" -ForegroundColor Cyan
    Push-Location $SampleDir
    try {
        & $Dcc64 -B `
            -U"$DelphiSrc" `
            -E"$OutDir" `
            -N"$DcuDir" `
            -LE"$OutDir" `
            -LN"$OutDir" `
            $s.Dpr
        if ($LASTEXITCODE -ne 0) { throw "dcc64 failed for $($s.Dpr) ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }

    # Copy DLL next to EXE
    Copy-Item $Dll (Join-Path $OutDir 'sc_shell.dll') -Force
    Write-Host "OK -> $OutDir" -ForegroundColor Green
}

Write-Host "== All samples built ==" -ForegroundColor Cyan
