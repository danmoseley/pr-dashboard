#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Invoke-ChunkedRepoScan — the chunked date-range retry
    logic added to handle large repos (e.g., dotnet/dotnet-api-docs) that
    consistently return HTTP 502 on full-range GraphQL queries.

.DESCRIPTION
    Tests chunk computation, result merging, partial-failure handling, and
    boundary correctness by mocking Invoke-RepoMaintainerScan.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    # Source the script to get the functions (dot-source would execute the
    # main body, so we extract functions only via a helper approach).
    # Instead, we import the modules and define the functions in-scope.
    Import-Module "$PSScriptRoot/../GraphQLHelper.psm1" -Force
    Import-Module "$PSScriptRoot/../MaintainersGuard.psm1" -Force
    Import-Module "$PSScriptRoot/../MaintainerActivity.psm1" -Force

    # Dot-source just the function definitions by extracting them.
    # We'll parse the script AST to avoid executing the main body.
    $scriptPath = "$PSScriptRoot/../Update-Maintainers.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $functionDefs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($funcDef in $functionDefs) {
        . ([scriptblock]::Create($funcDef.Extent.Text))
    }
}

Describe 'Invoke-ChunkedRepoScan' {

    Context 'Chunk computation' {
        It 'Creates correct number of chunks for 90-day window with 30-day chunks' {
            $cutoff = (Get-Date).AddDays(-90).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; MergerCounts = @{}; Activity = @{}
                    TotalFetched = 0; Error = ''
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30

            # Should have 3 chunks (days 1-30, 31-60, 61-90)
            Should -Invoke Invoke-RepoMaintainerScan -Times 3 -Exactly -ParameterFilter { $EndDate }
        }

        It 'Creates a single chunk when window <= ChunkDays' {
            $cutoff = (Get-Date).AddDays(-10).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; MergerCounts = @{}; Activity = @{}
                    TotalFetched = 5; Error = ''
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30

            $result.Success | Should -BeTrue
            Should -Invoke Invoke-RepoMaintainerScan -Times 1 -Exactly
        }

        It 'Returns empty result when cutoff is in the future' {
            $cutoff = (Get-Date).AddDays(5).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan { throw 'Should not be called' }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot')

            $result.Success | Should -BeTrue
            $result.TotalFetched | Should -Be 0
            $result.MergerCounts.Count | Should -Be 0
            Should -Invoke Invoke-RepoMaintainerScan -Times 0 -Exactly
        }

        It 'Produces non-overlapping date ranges' {
            $cutoff = (Get-Date).AddDays(-90).ToString('yyyy-MM-dd')
            $ranges = @()

            Mock Invoke-RepoMaintainerScan {
                $ranges += @{ Start = $CutoffDate; End = $EndDate }
                [PSCustomObject]@{
                    Success = $true; MergerCounts = @{}; Activity = @{}
                    TotalFetched = 0; Error = ''
                }
            }

            Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30 | Out-Null

            # Verify no overlapping ranges
            for ($i = 1; $i -lt $ranges.Count; $i++) {
                $prevEnd = [datetime]::Parse($ranges[$i - 1].End)
                $currStart = [datetime]::Parse($ranges[$i].Start)
                $currStart | Should -BeGreaterThan $prevEnd -Because "chunk $i should start after chunk $($i-1) ends"
            }
        }

        It 'First chunk starts the day after cutoff date (preserving merged:> semantics)' {
            $cutoff = (Get-Date).AddDays(-45).ToString('yyyy-MM-dd')
            $expectedStart = ([datetime]::Parse($cutoff)).AddDays(1).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; MergerCounts = @{}; Activity = @{}
                    TotalFetched = 0; Error = ''
                }
            }

            Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30 | Out-Null

            # The first call should have CutoffDate = cutoff + 1 day
            Should -Invoke Invoke-RepoMaintainerScan -Times 1 -ParameterFilter {
                $CutoffDate -eq $expectedStart
            }
        }
    }

    Context 'Result merging' {
        It 'Sums MergerCounts across chunks' {
            $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
            $chunk1Start = ([datetime]::Parse($cutoff)).AddDays(1).ToString('yyyy-MM-dd')
            $chunk1End   = ([datetime]::Parse($cutoff)).AddDays(30).ToString('yyyy-MM-dd')

            # First chunk returns alice=3, bob=2
            Mock Invoke-RepoMaintainerScan -ParameterFilter { $CutoffDate -eq $chunk1Start } {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 50; Error = ''
                    MergerCounts = @{ alice = 3; bob = 2 }; Activity = @{}
                }
            }
            # All other chunks return alice=1, carol=4
            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 30; Error = ''
                    MergerCounts = @{ alice = 1; carol = 4 }; Activity = @{}
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30

            $result.Success | Should -BeTrue
            $result.TotalFetched | Should -Be 80
            $result.MergerCounts['alice'] | Should -Be 4
            $result.MergerCounts['bob']   | Should -Be 2
            $result.MergerCounts['carol'] | Should -Be 4
        }

        It 'Merges activity paths and labels across chunks' {
            $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
            $chunk1Start = ([datetime]::Parse($cutoff)).AddDays(1).ToString('yyyy-MM-dd')
            $chunk1End   = ([datetime]::Parse($cutoff)).AddDays(30).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan -ParameterFilter { $CutoffDate -eq $chunk1Start } {
                $act = @{}
                $act['alice'] = @{
                    paths  = [System.Collections.Generic.List[string]]@('src/core')
                    labels = [System.Collections.Generic.List[string]]@('area-io')
                    count  = 2
                }
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 20; Error = ''
                    MergerCounts = @{ alice = 2 }; Activity = $act
                }
            }
            Mock Invoke-RepoMaintainerScan {
                $act = @{}
                $act['alice'] = @{
                    paths  = [System.Collections.Generic.List[string]]@('src/net')
                    labels = [System.Collections.Generic.List[string]]@('area-net')
                    count  = 3
                }
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 15; Error = ''
                    MergerCounts = @{ alice = 3 }; Activity = $act
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30

            $result.Activity['alice'].count | Should -Be 5
            $result.Activity['alice'].paths | Should -Contain 'src/core'
            $result.Activity['alice'].paths | Should -Contain 'src/net'
            $result.Activity['alice'].labels | Should -Contain 'area-io'
            $result.Activity['alice'].labels | Should -Contain 'area-net'
        }
    }

    Context 'Partial failure handling' {
        It 'Returns partial results when some chunks fail' {
            $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
            $chunk1Start = ([datetime]::Parse($cutoff)).AddDays(1).ToString('yyyy-MM-dd')

            # First chunk succeeds
            Mock Invoke-RepoMaintainerScan -ParameterFilter { $CutoffDate -eq $chunk1Start } {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 50; Error = ''
                    MergerCounts = @{ alice = 5 }; Activity = @{}
                }
            }
            # Second chunk fails
            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $false; TotalFetched = 0; Error = 'Failed after 5 attempts'
                    MergerCounts = $null; Activity = $null
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30 -MinChunkDays 30

            $result.Success | Should -BeTrue  # partial success — at least one chunk worked
            $result.TotalFetched | Should -Be 50
            $result.MergerCounts['alice'] | Should -Be 5
            $result.FailedChunks | Should -HaveCount 1
            $result.Error | Should -BeLike '*Failed chunks*'
        }

        It 'Returns failure when all chunks fail' {
            $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $false; TotalFetched = 0; Error = 'Failed after 5 attempts'
                    MergerCounts = $null; Activity = $null
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30 -MinChunkDays 30

            $result.Success | Should -BeFalse
            $result.TotalFetched | Should -Be 0
            $result.FailedChunks.Count | Should -BeGreaterOrEqual 2
        }

        It 'FailedChunks is empty when all chunks succeed' {
            $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 10; Error = ''
                    MergerCounts = @{}; Activity = @{}
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30

            $result.Success | Should -BeTrue
            $result.FailedChunks | Should -HaveCount 0
            $result.Error | Should -BeNullOrEmpty
        }
    }

    Context 'EndDate parameter passed to scan' {
        It 'Passes EndDate to Invoke-RepoMaintainerScan for each chunk' {
            $cutoff = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                $EndDate | Should -Not -BeNullOrEmpty -Because 'chunked scan must pass EndDate'
                [PSCustomObject]@{
                    Success = $true; MergerCounts = @{}; Activity = @{}
                    TotalFetched = 0; Error = ''
                }
            }

            Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 30 | Out-Null

            Should -Invoke Invoke-RepoMaintainerScan -Times 1 -Exactly
        }
    }

    Context 'Adaptive sub-chunking' {
        It 'Sub-chunks a failed 7-day chunk into 1-day ranges and merges results' {
            # Use a 14-day window with 7-day chunks => 2 chunks
            $cutoff = (Get-Date).AddDays(-14).ToString('yyyy-MM-dd')
            $chunk1Start = ([datetime]::Parse($cutoff)).AddDays(1).ToString('yyyy-MM-dd')
            $chunk1End   = ([datetime]::Parse($cutoff)).AddDays(7).ToString('yyyy-MM-dd')

            # First 7-day chunk succeeds
            Mock Invoke-RepoMaintainerScan -ParameterFilter { $CutoffDate -eq $chunk1Start } {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 40; Error = ''
                    MergerCounts = @{ alice = 3 }; Activity = @{}
                }
            }
            # All other calls: fail if range > 1 day, succeed if 1-day range
            Mock Invoke-RepoMaintainerScan {
                $start = [datetime]::Parse($CutoffDate)
                $end   = [datetime]::Parse($EndDate)
                $span  = ($end - $start).Days
                if ($span -gt 0) {
                    [PSCustomObject]@{
                        Success = $false; TotalFetched = 0; Error = '502'
                        MergerCounts = $null; Activity = $null
                    }
                } else {
                    [PSCustomObject]@{
                        Success = $true; TotalFetched = 2; Error = ''
                        MergerCounts = @{ bob = 1 }; Activity = @{}
                    }
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 7 -MinChunkDays 1

            $result.Success | Should -BeTrue
            $result.MergerCounts['alice'] | Should -Be 3
            $result.MergerCounts['bob'] | Should -BeGreaterOrEqual 1
            $result.FailedChunks | Should -HaveCount 0
            $result.TotalFetched | Should -BeGreaterThan 40
        }

        It 'Reports 1-day failures as FailedChunks when MinChunkDays reached' {
            $cutoff = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')

            # Everything fails at every granularity
            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $false; TotalFetched = 0; Error = '502'
                    MergerCounts = $null; Activity = $null
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 7 -MinChunkDays 1

            $result.Success | Should -BeFalse
            # Should have individual 1-day failures, not 7-day chunk failures
            foreach ($fc in $result.FailedChunks) {
                $parts = $fc -split '\.\.'
                $start = [datetime]::Parse($parts[0])
                $end   = [datetime]::Parse($parts[1])
                ($end - $start).Days | Should -Be 0 -Because "failed chunks should be 1-day ranges at MinChunkDays"
            }
        }

        It 'Does not sub-chunk when ChunkDays equals MinChunkDays' {
            $cutoff = (Get-Date).AddDays(-14).ToString('yyyy-MM-dd')

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $false; TotalFetched = 0; Error = '502'
                    MergerCounts = $null; Activity = $null
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -BotLogins @('bot') -ChunkDays 7 -MinChunkDays 7

            # With MinChunkDays=ChunkDays, no sub-chunking should occur.
            # FailedChunks should be 7-day ranges, not 1-day ranges.
            $result.Success | Should -BeFalse
            foreach ($fc in $result.FailedChunks) {
                $parts = $fc -split '\.\.'
                $start = [datetime]::Parse($parts[0])
                $end   = [datetime]::Parse($parts[1])
                ($end - $start).Days | Should -BeLessOrEqual 6 -Because "chunks are up to 7 days"
            }
        }

        It 'Respects EndDate parameter for bounded sub-chunking' {
            $cutoff = '2026-03-01'
            $endDate = '2026-03-14'

            Mock Invoke-RepoMaintainerScan {
                [PSCustomObject]@{
                    Success = $true; TotalFetched = 5; Error = ''
                    MergerCounts = @{ carol = 2 }; Activity = @{}
                }
            }

            $result = Invoke-ChunkedRepoScan -Repo 'test/repo' -CutoffDate $cutoff `
                -EndDate $endDate -BotLogins @('bot') -ChunkDays 7

            $result.Success | Should -BeTrue
            $result.TotalFetched | Should -Be 10   # 2 chunks of 5
            # Verify no scan extends beyond EndDate
            Should -Invoke Invoke-RepoMaintainerScan -ParameterFilter {
                -not $EndDate -or [datetime]::Parse($EndDate) -le [datetime]::Parse('2026-03-14')
            }
        }
    }
}
