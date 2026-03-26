<#
.SYNOPSIS
    Helpers for parsing CODEOWNERS files and matching changed file paths to owners.
.DESCRIPTION
    Exports three functions:
      ConvertTo-CodeownersRegex  – converts a CODEOWNERS glob pattern to a compiled .NET Regex
      ConvertFrom-CodeownersText – parses raw CODEOWNERS text into an ordered rule list
      Get-CodeownersForFiles     – returns owners for a set of changed file paths (last-match-wins)
#>

# Convert a CODEOWNERS glob pattern to a compiled, case-sensitive .NET Regex.
function ConvertTo-CodeownersRegex {
    param([string]$pattern)
    $anchored = $pattern.StartsWith('/')
    $p = $pattern.TrimStart('/')
    $dirOnly = $p.EndsWith('/')
    if ($dirOnly) { $p = $p.TrimEnd('/') }
    # Escape all regex metacharacters, then restore CODEOWNERS glob semantics.
    $regexStr = [regex]::Escape($p)
    # Use a null-byte placeholder that can never appear in a file path.
    $regexStr = $regexStr -replace '\\\*\\\*', "`x00DBLSTAR`x00"  # ** placeholder
    $regexStr = $regexStr -replace '\\\*',     '[^/]*'            # * → any non-slash chars
    $regexStr = $regexStr -replace "`x00DBLSTAR`x00", '.*'        # ** → any chars incl. /
    $regexStr = $regexStr -replace '\\\?',     '[^/]'             # ? → single non-slash char
    $prefix = if ($anchored) { '^' }  else { '(^|/)' }
    $suffix = if ($dirOnly)  { '(/|$)' } else { '(/.*)?$' }
    return [regex]::new("$prefix$regexStr$suffix")
}

# Parse raw CODEOWNERS file text into an ordered list of rules.
# Returns: [PSCustomObject]@{ pattern; compiled; rawOwners }
# Rules with no @-handles are recorded as unown entries (rawOwners = @()) so that
# last-match-wins correctly suppresses owners from a broader earlier rule.
function ConvertFrom-CodeownersText {
    param([string]$text)
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($text -split "`n")) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $parts = $line -split '\s+'
        $pat = $parts[0]
        # Gather raw owner tokens (@login or @org/team); empty list = unown entry.
        $rawOwners = @()
        if ($parts.Count -ge 2) {
            $rawOwners = @(
                $parts[1..($parts.Count - 1)] |
                Where-Object { $_ -match '^@' } |
                ForEach-Object { $_.TrimStart('@') }
            )
        }
        try {
            $compiled = ConvertTo-CodeownersRegex $pat
            $rules.Add([PSCustomObject]@{ pattern = $pat; compiled = $compiled; rawOwners = $rawOwners })
        } catch {
            Write-Verbose "CODEOWNERS: skipping malformed pattern '$pat': $_"
        }
    }
    return @($rules)
}

# Return owners for a set of changed file paths.
# Semantics: for each file, the LAST matching rule wins (git CODEOWNERS spec).
# Owners are accumulated in first-seen insertion order across all files.
#
# Parameters:
#   rules         – output of ConvertFrom-CodeownersText
#   filePaths     – changed file paths (relative, may have leading /)
#   expandOwnerFn – optional scriptblock: takes a raw owner string (login or org/team)
#                   and returns an array of login strings.  Used to expand team handles.
function Get-CodeownersForFiles {
    param(
        [object[]]$rules,
        [string[]]$filePaths,
        [scriptblock]$expandOwnerFn
    )
    if (-not $rules -or $rules.Count -eq 0 -or -not $filePaths) { return @() }
    $seen   = @{}
    $owners = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $filePaths) {
        $normalFile = $file.TrimStart('/')
        # $null = no rule matched; @() = unown entry matched (both contribute no owners)
        $lastMatch = $null
        foreach ($rule in $rules) {
            if ($rule.compiled.IsMatch($normalFile)) { $lastMatch = $rule.rawOwners }
        }
        if ($null -ne $lastMatch) {
            foreach ($rawOwner in $lastMatch) {
                $expanded = if ($expandOwnerFn) {
                    @(& $expandOwnerFn $rawOwner)
                } else {
                    @($rawOwner)
                }
                foreach ($login in $expanded) {
                    if ($login -and -not $seen.ContainsKey($login)) {
                        $seen[$login] = $true
                        [void]$owners.Add($login)
                    }
                }
            }
        }
    }
    return @($owners)
}

Export-ModuleMember -Function ConvertTo-CodeownersRegex, ConvertFrom-CodeownersText, Get-CodeownersForFiles
