#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for GraphQLHelper.psm1 – Test-GraphQLResponse validation.

.DESCRIPTION
    Exercises the GraphQL response parsing and validation logic that was
    extracted from Update-Maintainers.ps1.  All tests run under
    Set-StrictMode -Version Latest to catch property-access bugs
    (the class of bug that caused the StrictMode crash on main).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module "$PSScriptRoot/../GraphQLHelper.psm1" -Force
}

Describe 'Test-GraphQLResponse' {

    Context 'Valid responses' {
        It 'Accepts a well-formed search response' {
            $json = '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeTrue
            $r.Error   | Should -BeNullOrEmpty
            $r.Parsed.data.search.nodes | Should -HaveCount 0
        }

        It 'Accepts a response with search results' {
            $json = '{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29yOjE="},"nodes":[{"mergedBy":{"login":"alice"}}]}}}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeTrue
            $r.Parsed.data.search.nodes | Should -HaveCount 1
        }
    }

    Context 'GraphQL body errors' {
        It 'Detects errors array in response' {
            $json = '{"errors":[{"message":"API rate limit exceeded"}]}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*rate limit*'
        }

        It 'Joins multiple error messages' {
            $json = '{"errors":[{"message":"first problem"},{"message":"second problem"}]}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*first problem*'
            $r.Error   | Should -BeLike '*second problem*'
        }

        It 'Detects errors even when data is also present' {
            # Some GraphQL APIs return partial data alongside errors
            $json = '{"data":{"search":null},"errors":[{"message":"Something went wrong"}]}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*Something went wrong*'
        }
    }

    Context 'Missing or malformed structure' {
        It 'Fails when data is missing entirely' {
            $json = '{"something":"else"}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*missing data.search*'
        }

        It 'Fails when data exists but search is missing' {
            $json = '{"data":{"repository":{"name":"test"}}}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*missing data.search*'
        }

        It 'Fails on empty string' {
            $r = Test-GraphQLResponse -RawJson ''
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*Empty*'
        }

        It 'Fails on whitespace-only input' {
            $r = Test-GraphQLResponse -RawJson '   '
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*Empty*'
        }

        It 'Fails on invalid JSON' {
            $r = Test-GraphQLResponse -RawJson 'not json at all'
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*Failed to parse*'
        }

        It 'Fails on truncated JSON' {
            $r = Test-GraphQLResponse -RawJson '{"data":{"search":'
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*Failed to parse*'
        }
    }

    Context 'Null and edge-case JSON values' {
        It 'Fails on JSON null literal' {
            $r = Test-GraphQLResponse -RawJson 'null'
            $r.Success | Should -BeFalse
            $r.Error   | Should -Not -BeNullOrEmpty
        }

        It 'Does not throw on JSON null literal under StrictMode' {
            { Test-GraphQLResponse -RawJson 'null' } | Should -Not -Throw
        }

        It 'Fails when data is null' {
            $json = '{"data":null}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*missing data.search*'
        }

        It 'Does not throw when data is null under StrictMode' {
            { Test-GraphQLResponse -RawJson '{"data":null}' } | Should -Not -Throw
        }

        It 'Fails when search is null' {
            $json = '{"data":{"search":null}}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*missing data.search*'
        }

        It 'Handles empty errors array gracefully' {
            $json = '{"errors":[]}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'StrictMode safety (regression)' {
        # These tests specifically verify that property access does not throw
        # under Set-StrictMode -Version Latest — the exact bug that broke main.

        It 'Does not throw when checking errors on a response without errors property' {
            # This is the exact scenario that caused the StrictMode crash:
            # a valid response with data.search but no "errors" key
            $json = '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
            { Test-GraphQLResponse -RawJson $json } | Should -Not -Throw
        }

        It 'Does not throw when data property is absent' {
            $json = '{"something":"else"}'
            { Test-GraphQLResponse -RawJson $json } | Should -Not -Throw
        }

        It 'Does not throw on completely empty object' {
            $json = '{}'
            $r = Test-GraphQLResponse -RawJson $json
            $r.Success | Should -BeFalse
            $r.Error   | Should -BeLike '*missing data.search*'
        }
    }
}
