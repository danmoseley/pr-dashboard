<#
.SYNOPSIS
    Safety-check helpers for Update-Maintainers.ps1.
#>

<#
.SYNOPSIS
    Validates that a proposed maintainers update is safe to apply.
.DESCRIPTION
    Checks two invariants:
      1. No existing repo key would be lost.
      2. The total maintainer count would not decrease.
    Returns a result object: Safe (bool) and Reason (string, empty when Safe).
.PARAMETER Existing
    The current maintainers hashtable (keys are repo slugs, values are string arrays).
.PARAMETER Proposed
    The proposed (ordered) hashtable of maintainers to write.
#>
function Test-MaintainerSafety {
    [CmdletBinding()]
    param(
        $Existing,
        $Proposed
    )

    # Check 1: no existing repo key may be absent from the proposed output
    $missingKeys = @($Existing.Keys | Where-Object { -not $Proposed.Contains($_) })
    if ($missingKeys.Count -gt 0) {
        return [PSCustomObject]@{
            Safe     = $false
            Reason   = "would lose repo keys: $($missingKeys | Sort-Object | Join-String -Separator ', ')"
            OldTotal = ($Existing.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum ?? 0
            NewTotal = ($Proposed.Values  | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum ?? 0
        }
    }

    # Check 2: total maintainer count must not decrease
    $oldTotal = ($Existing.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum ?? 0
    $newTotal = ($Proposed.Values  | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum ?? 0
    if ($newTotal -lt $oldTotal) {
        return [PSCustomObject]@{
            Safe     = $false
            Reason   = "total maintainer count would decrease from $oldTotal to $newTotal"
            OldTotal = $oldTotal
            NewTotal = $newTotal
        }
    }

    return [PSCustomObject]@{ Safe = $true; Reason = ''; OldTotal = $oldTotal; NewTotal = $newTotal }
}
