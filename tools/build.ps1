# Build script for sc_shell.
# 1) Build Rust DLL for x86_64 and i686 → sc_shell64.dll / sc_shell32.dll.
# 2) Compile Delphi demo (Win64) with dcc64.

param(
    [switch]$Rust,
    [switch]$Rust64,
    [switch]$Rust32,
    [switch]$Delphi,
    [switch]$All
)

$ErrorActionPreference = 'Stop'

$RootDir   = Split-Path -Parent $PSScriptRoot
$RustDir   = Join-Path $RootDir 'rata_shell'
$DelphiDir = Join-Path $RootDir 'delphi\src'
$DemoDir   = Join-Path $RootDir 'demo'
$OutDir    = Join-Path $RootDir 'bin'
$Dcc64     = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe'

$Target64  = 'x86_64-pc-windows-msvc'
$Target32  = 'i686-pc-windows-msvc'

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Ensure-Target([string]$Triple) {
    $installed = & rustup target list --installed 2>$null
    if (-not ($installed -match [regex]::Escape($Triple))) {
        Write-Host "Installing rustup target $Triple ..." -ForegroundColor Yellow
        & rustup target add $Triple
        if ($LASTEXITCODE -ne 0) {
            throw "rustup target add $Triple failed ($LASTEXITCODE)"
        }
    }
}

function Build-RustArch([string]$Triple, [string]$OutName) {
    Write-Host "== Building Rust DLL ($Triple) ==" -ForegroundColor Cyan
    Ensure-Target $Triple

    Push-Location $RustDir
    try {
        $env:RUSTFLAGS = '-C target-feature=+crt-static'
        cargo build --release --target $Triple
        if ($LASTEXITCODE -ne 0) { throw "cargo build $Triple failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }

    $built = Join-Path $RustDir "target\$Triple\release\sc_shell.dll"
    if (-not (Test-Path $built)) {
        throw "Expected DLL not found: $built"
    }
    $dest = Join-Path $OutDir $OutName
    Copy-Item $built $dest -Force
    Write-Host "DLL -> $dest" -ForegroundColor Green
}

function Build-Rust64 { Build-RustArch -Triple $Target64 -OutName 'sc_shell64.dll' }
function Build-Rust32 { Build-RustArch -Triple $Target32 -OutName 'sc_shell32.dll' }

function Build-Delphi {
    Write-Host '== Compiling Delphi demo ==' -ForegroundColor Cyan
    if (-not (Test-Path $Dcc64)) {
        throw "dcc64.exe not found at $Dcc64"
    }
    Push-Location $DemoDir
    try {
        & $Dcc64 -B `
            -U"$DelphiDir" `
            -E"$OutDir" `
            -N"$OutDir\dcu" `
            -LE"$OutDir" `
            -LN"$OutDir" `
            DemoShell.dpr
        if ($LASTEXITCODE -ne 0) { throw "dcc64 failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    Write-Host "EXE -> $OutDir\DemoShell.exe" -ForegroundColor Green
}

# Default: build everything if no flag given.
$noFlag = -not ($Rust -or $Rust64 -or $Rust32 -or $Delphi -or $All)

if ($All -or $noFlag) {
    Build-Rust64
    Build-Rust32
    Build-Delphi
} else {
    if ($Rust)   { Build-Rust64; Build-Rust32 }
    if ($Rust64) { Build-Rust64 }
    if ($Rust32) { Build-Rust32 }
    if ($Delphi) { Build-Delphi }
}

Write-Host '== Done ==' -ForegroundColor Cyan
