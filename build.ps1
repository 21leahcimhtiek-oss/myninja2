# AURORA-MANAGED: build-shim-v1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Write-BuildResult {
    param(
        [string]$State,
        [int]$Code,
        [string]$Reason,
        [object]$Details = $null
    )

    $statusDir = Join-Path $repoRoot ".aurora"
    New-Item -ItemType Directory -Path $statusDir -Force | Out-Null

    $payload = [ordered]@{
        repo = Split-Path $repoRoot -Leaf
        script = "build.ps1"
        state = $State
        code = $Code
        reason = $Reason
        details = $Details
        generatedAt = (Get-Date).ToString("s")
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $statusDir "last-build.json") -Encoding utf8
    Write-Host ($payload | ConvertTo-Json -Compress)
    exit $Code
}

function Invoke-NpmScript {
    param([string]$Name)

    & npm.cmd run $Name
    if ($LASTEXITCODE -ne 0) {
        Write-BuildResult -State "failed" -Code 1 -Reason "npm run $Name failed" -Details @{ script = $Name }
    }
}

$packagePath = Join-Path $repoRoot "package.json"
$pyprojectPath = Join-Path $repoRoot "pyproject.toml"
$makefilePath = Join-Path $repoRoot "Makefile"

if (Test-Path $packagePath) {
    try {
        $packageJson = Get-Content $packagePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-BuildResult -State "invalid-package-json" -Code 1 -Reason "Could not parse package.json"
    }

    if (-not (Test-Path (Join-Path $repoRoot "node_modules"))) {
        $scriptNames = if ($null -ne $packageJson.scripts) { @($packageJson.scripts.PSObject.Properties.Name) } else { @() }
        Write-BuildResult -State "deps-missing" -Code 3 -Reason "node_modules is missing" -Details @{ scripts = $scriptNames }
    }

    foreach ($candidate in @("build", "build:web", "build:both", "build:apk", "build:aab")) {
        if ($null -ne $packageJson.scripts -and $null -ne $packageJson.scripts.PSObject.Properties[$candidate] -and -not [string]::IsNullOrWhiteSpace([string]$packageJson.scripts.$candidate)) {
            Invoke-NpmScript -Name $candidate
            Write-BuildResult -State "passed" -Code 0 -Reason "Build script completed" -Details @{ script = $candidate }
        }
    }

    Write-BuildResult -State "no-build-script" -Code 2 -Reason "No build-oriented npm scripts detected"
}

if (Test-Path $pyprojectPath) {
    $pyprojectContent = Get-Content $pyprojectPath -Raw
    if ($pyprojectContent -notmatch '(?m)^\[build-system\]') {
        Write-BuildResult -State "no-build-backend" -Code 2 -Reason "pyproject.toml does not define a build-system"
    }

    & python -c "import build" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-BuildResult -State "deps-missing" -Code 3 -Reason "Python build package is not installed"
    }

    & python -m build
    if ($LASTEXITCODE -ne 0) {
        Write-BuildResult -State "failed" -Code 1 -Reason "python -m build failed"
    }

    Write-BuildResult -State "passed" -Code 0 -Reason "python -m build completed"
}

if (Test-Path $makefilePath) {
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-BuildResult -State "deps-missing" -Code 3 -Reason "make is not available on PATH"
    }

    $makefileContent = Get-Content $makefilePath -Raw
    if ($makefileContent -match '(?m)^build\s*:') {
        & make build
        if ($LASTEXITCODE -ne 0) {
            Write-BuildResult -State "failed" -Code 1 -Reason "make build failed"
        }

        Write-BuildResult -State "passed" -Code 0 -Reason "make build completed" -Details @{ target = "build" }
    }

    Write-BuildResult -State "no-build-target" -Code 2 -Reason "No build target detected in Makefile"
}

Write-BuildResult -State "no-tooling" -Code 2 -Reason "No package.json, pyproject.toml, or Makefile detected"
