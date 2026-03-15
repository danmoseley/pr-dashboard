<#
.SYNOPSIS
    CI validation script for the PR Dashboard.
.DESCRIPTION
    Runs offline checks to catch regressions before merging:
      1. PowerShell syntax validation (all .ps1 files)
      2. JavaScript syntax validation (pr-refresh.js)
      3. JSON config validation (maintainers.json, repos.json)
      4. HTML generation smoke test (Build-Reports + Build-Index on 2 small repos)
      5. HTML structure validation (required elements exist)
      6. Output file completeness (expected files with correct schema)
    Exits non-zero if any critical check fails.
#>
[CmdletBinding()]
param(
    [string]$ArtifactDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$failed = @()
$passed = @()

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) {
        Write-Host "  PASS: $Name" -ForegroundColor Green
        $script:passed += $Name
    } else {
        Write-Host "  FAIL: $Name — $Detail" -ForegroundColor Red
        if ($env:GITHUB_ACTIONS) { Write-Host "::error::$Name — $Detail" }
        $script:failed += $Name
    }
}

# ─── T1: PowerShell Syntax Validation ─────────────────────────────────
Write-Host "`n=== T1: PowerShell Syntax Validation ===" -ForegroundColor Cyan
$ps1Files = Get-ChildItem -Path (Join-Path $root "scripts") -Filter "*.ps1" -Recurse
foreach ($f in $ps1Files) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    $ok = ($null -eq $errors -or $errors.Count -eq 0)
    $detail = if (-not $ok) { ($errors | ForEach-Object { $_.Message }) -join "; " } else { "" }
    Write-Check -Name "Syntax: $($f.Name)" -Ok $ok -Detail $detail
}

# ─── T2: JavaScript Syntax Validation ─────────────────────────────────
Write-Host "`n=== T2: JavaScript Syntax Validation ===" -ForegroundColor Cyan
$jsFile = Join-Path $root "docs/pr-refresh.js"
if (-not (Test-Path $jsFile)) {
    Write-Check -Name "JS syntax: pr-refresh.js" -Ok $false -Detail "File not found"
} elseif (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: node not found on PATH, skipping JS syntax check" -ForegroundColor Yellow
} else {
    $jsOutput = & node --check $jsFile 2>&1
    $jsOk = $LASTEXITCODE -eq 0
    $jsDetail = if (-not $jsOk) { ($jsOutput | Out-String).Trim() } else { "" }
    Write-Check -Name "JS syntax: pr-refresh.js" -Ok $jsOk -Detail $jsDetail
}

# ─── T3: JSON Config Validation ───────────────────────────────────────
Write-Host "`n=== T3: JSON Config Validation ===" -ForegroundColor Cyan

# maintainers.json
$maintainersFile = Join-Path $root "config/maintainers.json"
$maintainersOk = $false
$maintainersDetail = ""
try {
    $m = Get-Content $maintainersFile -Raw | ConvertFrom-Json
    # Verify it's an object with repo keys mapping to arrays
    $keys = @($m.PSObject.Properties.Name)
    if ($keys.Count -eq 0) {
        $maintainersDetail = "No repo entries found"
    } else {
        $badKeys = @($keys | Where-Object { $_ -notmatch '^[\w.-]+/[\w.-]+$' })
        if ($badKeys.Count -gt 0) {
            $maintainersDetail = "Invalid repo keys: $($badKeys -join ', ')"
        } else {
            # Verify each value is an array
            $badValues = @($keys | Where-Object {
                $val = $m.$_
                $val -isnot [System.Collections.IEnumerable] -or $val -is [string]
            })
            if ($badValues.Count -gt 0) {
                $maintainersDetail = "Values must be arrays: $($badValues -join ', ')"
            } else {
                $maintainersOk = $true
            }
        }
    }
} catch {
    $maintainersDetail = "Parse error: $_"
}
Write-Check -Name "JSON: maintainers.json" -Ok $maintainersOk -Detail $maintainersDetail

# repos.json
$reposJsonFile = Join-Path $root "docs/repos.json"
$reposJsonOk = $false
$reposJsonDetail = ""
try {
    $rj = Get-Content $reposJsonFile -Raw | ConvertFrom-Json
    $arr = @($rj)
    if ($arr.Count -eq 0) {
        $reposJsonDetail = "Empty array"
    } else {
        $missing = @($arr | Where-Object { -not $_.slug -or -not $_.repo })
        if ($missing.Count -gt 0) {
            $reposJsonDetail = "$($missing.Count) entries missing slug or repo"
        } else {
            $reposJsonOk = $true
        }
    }
} catch {
    $reposJsonDetail = "Parse error: $_"
}
Write-Check -Name "JSON: repos.json" -Ok $reposJsonOk -Detail $reposJsonDetail

# ─── T4: HTML Generation Smoke Test ───────────────────────────────────
Write-Host "`n=== T4: HTML Generation Smoke Test ===" -ForegroundColor Cyan

# Pick the 2 smallest scan.json files for speed
$scanFiles = @(Get-ChildItem -Path (Join-Path $root "docs") -Filter "scan.json" -Recurse |
    Sort-Object Length |
    Select-Object -First 2)

if ($scanFiles.Count -eq 0) {
    Write-Check -Name "Smoke test" -Ok $false -Detail "No scan.json files found (need at least one committed)"
} else {
    # Create output directory (use ArtifactDir if specified, otherwise temp)
    if ($ArtifactDir) {
        $tempDocs = $ArtifactDir
        $cleanupTempDocs = $false
    } else {
        $tempDocs = Join-Path ([System.IO.Path]::GetTempPath()) "pr-dashboard-ci-$(Get-Random)"
        $cleanupTempDocs = $true
    }
    New-Item -ItemType Directory -Path $tempDocs -Force | Out-Null

    $smokeOk = $true
    $smokeDetail = ""
    $testedSlugs = @()

    # Read schedule description from workflow YAML (same logic as Regen-Html.ps1)
    $wfFile = Join-Path $root ".github/workflows/generate-reports.yml"
    $scheduleDesc = ""
    if (Test-Path $wfFile) {
        $descLine = Get-Content $wfFile | Where-Object { $_ -match '#\s*schedule-desc:\s*(.+)' } | Select-Object -First 1
        if ($descLine -and $descLine -match '#\s*schedule-desc:\s*(.+)') {
            $scheduleDesc = $Matches[1].Trim()
        }
    }

    foreach ($sf in $scanFiles) {
        $slug = $sf.Directory.Name
        $testedSlugs += $slug
        $outDir = Join-Path $tempDocs $slug
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        # Copy scan.json and history.json to temp so Build-Reports can find them
        Copy-Item $sf.FullName -Destination (Join-Path $outDir "scan.json")
        $histSrc = Join-Path $sf.DirectoryName "history.json"
        if (Test-Path $histSrc) {
            Copy-Item $histSrc -Destination (Join-Path $outDir "history.json")
        }

        # Read repo name from existing meta.json
        $metaSrc = Join-Path $sf.DirectoryName "meta.json"
        $repoName = "dotnet/$slug"
        if (Test-Path $metaSrc) {
            try {
                $meta = Get-Content $metaSrc -Raw | ConvertFrom-Json
                if ($meta.repo) { $repoName = $meta.repo }
            } catch { }
        }

        try {
            & "$root/scripts/Build-Reports.ps1" `
                -ScanFile (Join-Path $outDir "scan.json") `
                -Repo $repoName `
                -Slug $slug `
                -DocsDir $tempDocs `
                -ScheduleDesc $scheduleDesc `
                -SkipAI `
                -SkipHistory
        } catch {
            $smokeOk = $false
            $smokeDetail += "Build-Reports failed for ${slug}: $_  "
        }
    }

    # Generate index page
    if ($smokeOk) {
        try {
            & "$root/scripts/Build-Index.ps1" -DocsDir $tempDocs -ScheduleDesc $scheduleDesc
        } catch {
            $smokeOk = $false
            $smokeDetail += "Build-Index failed: $_  "
        }
    }

    Write-Check -Name "Smoke test ($($testedSlugs -join ', '))" -Ok $smokeOk -Detail $smokeDetail

    # ─── T5: HTML Structure Validation ────────────────────────────────
    Write-Host "`n=== T5: HTML Structure Validation ===" -ForegroundColor Cyan

    if ($smokeOk) {
        # Check index.html structure
        $indexFile = Join-Path $tempDocs "index.html"
        if (Test-Path $indexFile) {
            $indexContent = Get-Content $indexFile -Raw
            $indexChecks = @(
                @{ Name = "index: <table> tag";       Ok = $indexContent -match '<table>' }
                @{ Name = "index: <thead> tag";       Ok = $indexContent -match '<thead>' }
                @{ Name = "index: repo links";        Ok = $indexContent -match 'actionable\.html' }
                @{ Name = "index: metric rows";       Ok = $indexContent -match 'metric-row' }
                @{ Name = "index: data-updated attr"; Ok = $indexContent -match 'data-updated=' }
            )
            foreach ($c in $indexChecks) {
                Write-Check -Name $c.Name -Ok $c.Ok -Detail "Missing expected element"
            }
        } else {
            Write-Check -Name "index.html exists" -Ok $false -Detail "Not generated"
        }

        # Check a report page structure
        $testSlug = $testedSlugs[0]
        $reportFile = Join-Path $tempDocs "$testSlug/actionable.html"
        if (Test-Path $reportFile) {
            $reportContent = Get-Content $reportFile -Raw
            $reportChecks = @(
                @{ Name = "report: <table> tag";            Ok = $reportContent -match '<table[\s>]' }
                @{ Name = "report: <nav> tag";              Ok = $reportContent -match '<nav>' }
                @{ Name = "report: score column";           Ok = $reportContent -match 'class="score"' }
                @{ Name = "report: ci column";              Ok = $reportContent -match 'class="ci"' }
                @{ Name = "report: data-server-updated";    Ok = $reportContent -match 'data-server-updated' }
                @{ Name = "report: pr-refresh.js ref";      Ok = $reportContent -match 'pr-refresh\.js' }
            )
            foreach ($c in $reportChecks) {
                Write-Check -Name $c.Name -Ok $c.Ok -Detail "Missing expected element"
            }
        } else {
            Write-Check -Name "report actionable.html exists" -Ok $false -Detail "Not generated"
        }
    } else {
        Write-Host "  SKIP: HTML structure checks (smoke test failed)" -ForegroundColor Yellow
    }

    # ─── T6: Output File Completeness ─────────────────────────────────
    Write-Host "`n=== T6: Output File Completeness ===" -ForegroundColor Cyan

    if ($smokeOk) {
        foreach ($slug in $testedSlugs) {
            $slugDir = Join-Path $tempDocs $slug
            $expectedFiles = @("actionable.html", "community.html", "quick-wins.html", "consider-closing.html", "meta.json")
            foreach ($ef in $expectedFiles) {
                $exists = Test-Path (Join-Path $slugDir $ef)
                Write-Check -Name "output: $slug/$ef" -Ok $exists -Detail "File not produced"
            }

            # Validate meta.json schema
            $metaFile = Join-Path $slugDir "meta.json"
            if (Test-Path $metaFile) {
                $metaOk = $false
                $metaDetail = ""
                try {
                    $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
                    $requiredFields = @("repo", "slug", "updated", "reports")
                    $missingFields = @($requiredFields | Where-Object { -not $meta.$_ })
                    if ($missingFields.Count -gt 0) {
                        $metaDetail = "Missing fields: $($missingFields -join ', ')"
                    } else {
                        $metaOk = $true
                    }
                } catch {
                    $metaDetail = "Parse error: $_"
                }
                Write-Check -Name "schema: $slug/meta.json" -Ok $metaOk -Detail $metaDetail
            }
        }

        # Check index-level outputs
        Write-Check -Name "output: index.html" -Ok (Test-Path (Join-Path $tempDocs "index.html")) -Detail "Not produced"
        Write-Check -Name "output: repos.json" -Ok (Test-Path (Join-Path $tempDocs "repos.json")) -Detail "Not produced"
    } else {
        Write-Host "  SKIP: Completeness checks (smoke test failed)" -ForegroundColor Yellow
    }

    # Cleanup temp directory (only if we created it)
    if ($cleanupTempDocs) {
        Remove-Item $tempDocs -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Summary ──────────────────────────────────────────────────────────
Write-Host "`n$('=' * 50)" -ForegroundColor Cyan
Write-Host "Results: $($passed.Count) passed, $($failed.Count) failed" -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })
if ($failed.Count -gt 0) {
    Write-Host "Failed checks:" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host "All checks passed!" -ForegroundColor Green
