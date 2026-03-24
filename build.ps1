#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build / release script for FS Property Borders mod.
.DESCRIPTION
    Builds a distributable .zip mod artifact, or creates a release tag to trigger CI.

    --fs_ver accepts a single version or comma-separated list (e.g. 25,28).
    If omitted, defaults to the highest-numbered FS*_Src directory found.
.PARAMETER Command
    One of: build, release-test, release
.PARAMETER Version
    Semver for release command (e.g. 1.0.0.0, 1.0.0.0-beta.1). Required for 'release'.
.PARAMETER fs_ver
    FS version(s) as a comma-separated string. Defaults to latest FS*_Src found.
.EXAMPLE
    .\build.ps1 build
    .\build.ps1 build --fs_ver 28
    .\build.ps1 release 1.0.0.0
    .\build.ps1 release 1.0.0.0 --fs_ver 25,28
    .\build.ps1 release 1.0.0.0-beta.1 --fs_ver 25
#>
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("build", "release-test", "release")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Version,

    [string]$fs_ver
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Find the highest-numbered FS*_Src directory
function Get-LatestFsVersion {
    $latest = $null
    Get-ChildItem -Path $ScriptDir -Directory -Filter "FS*_Src" | ForEach-Object {
        $n = $_.Name -replace '^FS(\d+)_Src$', '$1'
        if ($n -match '^\d+$') {
            $num = [int]$n
            if ($null -eq $latest -or $num -gt $latest) {
                $latest = $num
            }
        }
    }
    if ($null -eq $latest) {
        Write-Error "No FS*_Src directories found in $ScriptDir"
        exit 1
    }
    return $latest.ToString()
}

# Parse --fs_ver value (comma-separated) or detect latest
function Resolve-FsVersions {
    param([string]$Raw)
    if ($Raw) {
        return $Raw -split ',' | ForEach-Object { $_.Trim() }
    }
    return @(Get-LatestFsVersion)
}

function Invoke-Build {
    param([string]$FsVer)

    $srcDir  = Join-Path $ScriptDir "FS${FsVer}_Src"
    $modName = "FS${FsVer}_PropertyBorders"
    $outDir  = Join-Path $ScriptDir "dist"
    $zipPath = Join-Path $outDir "${modName}.zip"

    if (-not (Test-Path $srcDir)) {
        Write-Error "Source directory not found: $srcDir"
        exit 1
    }

    Write-Host "Building ${modName}.zip from FS${FsVer}_Src ..." -ForegroundColor Cyan

    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # Remove previous artifact
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }

    # Stage into a temp dir
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "${modName}-staging-$(Get-Random)"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # Copy mod contents (exclude dev-only files)
    $excludePatterns = @("*.bak", "*.log", "icon_PropertyBorders.png")

    Get-ChildItem -Path $srcDir -Force | ForEach-Object {
        $skip = $false
        foreach ($pattern in $excludePatterns) {
            if ($_.Name -like $pattern) { $skip = $true; break }
        }
        if (-not $skip) {
            if ($_.PSIsContainer) {
                Copy-Item $_.FullName -Destination (Join-Path $staging $_.Name) -Recurse -Force
            } else {
                Copy-Item $_.FullName -Destination (Join-Path $staging $_.Name) -Force
            }
        }
    }

    # Create zip using .NET ZipFile to ensure forward-slash paths (GIANTS Engine requires it)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipStream = [System.IO.File]::Create($zipPath)
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
    $stagingFullPath = (Resolve-Path $staging).Path
    Get-ChildItem -Path $staging -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName.Substring($stagingFullPath.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
    $archive.Dispose()
    $zipStream.Dispose()

    # Cleanup
    Remove-Item $staging -Recurse -Force

    $sizeKB = [math]::Round((Get-Item $zipPath).Length / 1024, 1)
    Write-Host "  Created: $zipPath ($sizeKB KB)" -ForegroundColor Green
    Write-Host "Done." -ForegroundColor Cyan
}

function Invoke-Release {
    param([string]$Ver, [string[]]$FsVers)

    $tag = "release/$Ver"

    # Validate version format
    if ($Ver -notmatch '^\d+\.\d+\.\d+\.\d+(-[a-zA-Z]+\.\d+)?$') {
        Write-Error "Invalid version format '$Ver'. Expected: X.Y.Z.W or X.Y.Z.W-alpha.N or X.Y.Z.W-beta.N"
        exit 1
    }

    # Validate that source dirs exist for all requested FS versions
    foreach ($fv in $FsVers) {
        $srcDir = Join-Path $ScriptDir "FS${fv}_Src"
        if (-not (Test-Path $srcDir)) {
            Write-Error "Source directory not found: $srcDir"
            exit 1
        }
    }

    # Ensure working tree is clean
    $status = git -C $ScriptDir status --porcelain
    if ($status) {
        Write-Error "Working tree is not clean. Commit or stash changes first."
        exit 1
    }

    # Build all versions locally to verify artifacts are valid
    foreach ($fv in $FsVers) {
        Invoke-Build -FsVer $fv
    }

    # Update fs_versions.json so CI knows which versions to build
    $jsonVersions = $FsVers | ForEach-Object { [int]$_ }
    @{ versions = $jsonVersions } | ConvertTo-Json -Compress | Set-Content (Join-Path $ScriptDir "fs_versions.json") -Encoding UTF8

    # Commit the config change
    git -C $ScriptDir add fs_versions.json
    $null = git -C $ScriptDir diff --cached --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        $fsList = $FsVers -join ","
        git -C $ScriptDir commit -m "Set build targets to FS$fsList for $Ver"
    }

    $fsList = $FsVers -join ", "
    Write-Host ""
    Write-Host "Creating tag: $tag (FS versions: $fsList)" -ForegroundColor Cyan
    git -C $ScriptDir tag -a $tag -m "Release $Ver (FS$fsList)"

    Write-Host "Pushing commit and tag to origin ..."
    git -C $ScriptDir push origin HEAD $tag

    Write-Host ""
    Write-Host "Release tag '$tag' pushed. CI will build and publish the GitHub release." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$fsVersions = @(Resolve-FsVersions -Raw $fs_ver)

switch ($Command) {
    "build" {
        Invoke-Build -FsVer $fsVersions[0]
    }
    "release-test" {
        Invoke-Build -FsVer $fsVersions[0]
    }
    "release" {
        if (-not $Version) {
            Write-Error "release requires a version argument. Usage: .\build.ps1 release <version> [--fs_ver VER]"
            exit 1
        }
        Invoke-Release -Ver $Version -FsVers $fsVersions
    }
}
