# AURORA-MANAGED: validate-shim-v1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Write-ValidateResult {
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
        script = "validate.ps1"
        state = $State
        code = $Code
        reason = $Reason
        details = $Details
        generatedAt = (Get-Date).ToString("s")
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $statusDir "last-validate.json") -Encoding utf8
    Write-Host ($payload | ConvertTo-Json -Compress)
    exit $Code
}

function Invoke-NpmScript {
    param([string]$Name)

    & npm.cmd run $Name
    if ($LASTEXITCODE -ne 0) {
        Write-ValidateResult -State "failed" -Code 1 -Reason "npm run $Name failed" -Details @{ script = $Name }
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
        Write-ValidateResult -State "invalid-package-json" -Code 1 -Reason "Could not parse package.json"
    }

    if (-not (Test-Path (Join-Path $repoRoot "node_modules"))) {
        $scriptNames = if ($null -ne $packageJson.scripts) { @($packageJson.scripts.PSObject.Properties.Name) } else { @() }
        Write-ValidateResult -State "deps-missing" -Code 3 -Reason "node_modules is missing" -Details @{ scripts = $scriptNames }
    }

    $ran = @()
    foreach ($candidate in @("check", "typecheck", "type-check", "lint", "test")) {
        if ($null -ne $packageJson.scripts -and $null -ne $packageJson.scripts.PSObject.Properties[$candidate] -and -not [string]::IsNullOrWhiteSpace([string]$packageJson.scripts.$candidate)) {
            Invoke-NpmScript -Name $candidate
            $ran += $candidate
        }
    }

    if ($ran.Count -eq 0) {
        Write-ValidateResult -State "no-validate-script" -Code 2 -Reason "No validate-oriented npm scripts detected"
    }

    Write-ValidateResult -State "passed" -Code 0 -Reason "Validation scripts completed" -Details @{ ran = $ran }
}

if (Test-Path $pyprojectPath) {
    $pythonFiles = @(Get-ChildItem -Path $repoRoot -Recurse -File -Include *.py -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch '\\(\.venv|venv|node_modules|\.git|dist|build)\\'
    })

    if ($pythonFiles.Count -eq 0) {
        Write-ValidateResult -State "skipped" -Code 2 -Reason "pyproject.toml present but no Python files found"
    }

    & python -m compileall -q $repoRoot
    if ($LASTEXITCODE -ne 0) {
        Write-ValidateResult -State "failed" -Code 1 -Reason "python -m compileall failed"
    }

    Write-ValidateResult -State "passed" -Code 0 -Reason "Python compileall completed"
}

if (Test-Path $makefilePath) {
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-ValidateResult -State "deps-missing" -Code 3 -Reason "make is not available on PATH"
    }

    $makefileContent = Get-Content $makefilePath -Raw
    foreach ($target in @("validate", "test")) {
        if ($makefileContent -match "(?m)^$([regex]::Escape($target))\s*:") {
            & make $target
            if ($LASTEXITCODE -ne 0) {
                Write-ValidateResult -State "failed" -Code 1 -Reason "make $target failed"
            }

            Write-ValidateResult -State "passed" -Code 0 -Reason "make $target completed" -Details @{ target = $target }
        }
    }

    Write-ValidateResult -State "no-validate-target" -Code 2 -Reason "No validate/test target detected in Makefile"
}

$missingCollateral = @("README.md", "SELL.md", "MARKETING.md" | Where-Object { -not (Test-Path (Join-Path $repoRoot $_)) })
Write-ValidateResult -State "no-tooling" -Code 2 -Reason "No package.json, pyproject.toml, or Makefile detected" -Details @{ missingCollateral = $missingCollateral }
