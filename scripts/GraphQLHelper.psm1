<#
.SYNOPSIS
    Helpers for parsing and validating GitHub GraphQL API responses.

.DESCRIPTION
    Extracted from Update-Maintainers.ps1 to enable unit testing under
    Set-StrictMode -Version Latest.
#>

Set-StrictMode -Version Latest

function Test-GraphQLResponse {
    <#
    .SYNOPSIS
        Parses a raw JSON string from gh api graphql and validates the response.

    .DESCRIPTION
        Returns a PSCustomObject with:
          - Success  [bool]   : $true when response contains data.search and no GraphQL errors
          - Parsed   [object] : the parsed PSCustomObject (or $null on failure)
          - Error    [string] : human-readable error message (empty on success)

    .PARAMETER RawJson
        The raw JSON string returned by gh api graphql.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RawJson
    )

    if ([string]::IsNullOrWhiteSpace($RawJson)) {
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $null
            Error   = 'Empty or null response'
        }
    }

    $parsed = $null
    try {
        $parsed = $RawJson | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $null
            Error   = "Failed to parse response: $($_.Exception.Message)"
        }
    }

    # Guard against JSON null or non-object top-level values
    if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $null
            Error   = 'Response is not a JSON object'
        }
    }

    # GraphQL-level errors (exit code 0 but errors in body)
    if ($parsed.PSObject.Properties['errors']) {
        $msgs = ($parsed.errors | ForEach-Object { $_.message }) -join '; '
        if ([string]::IsNullOrWhiteSpace($msgs)) {
            $msgs = 'GraphQL returned errors (no message details)'
        }
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $parsed
            Error   = $msgs
        }
    }

    # Validate expected shape: data.search must exist and be non-null
    if (-not $parsed.PSObject.Properties['data'] -or $null -eq $parsed.data) {
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $parsed
            Error   = 'Response missing data.search'
        }
    }
    if (-not $parsed.data.PSObject.Properties['search'] -or $null -eq $parsed.data.search) {
        return [PSCustomObject]@{
            Success = $false
            Parsed  = $parsed
            Error   = 'Response missing data.search'
        }
    }

    return [PSCustomObject]@{
        Success = $true
        Parsed  = $parsed
        Error   = ''
    }
}

Export-ModuleMember -Function Test-GraphQLResponse
