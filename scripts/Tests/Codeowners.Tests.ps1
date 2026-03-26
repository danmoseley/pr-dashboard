#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Pester tests for Codeowners.psm1 helpers.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Codeowners.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-CodeownersRegex' {
    It 'matches * at any depth (CODEOWNERS * means all files everywhere)' {
        $re = ConvertTo-CodeownersRegex '*'
        $re.IsMatch('README.md')    | Should -Be $true
        $re.IsMatch('src/foo.cs')   | Should -Be $true   # * in CODEOWNERS matches across directories
        $re.IsMatch('a/b/c/d.txt')  | Should -Be $true
    }

    It 'matches *.js at any depth (no leading /)' {
        $re = ConvertTo-CodeownersRegex '*.js'
        $re.IsMatch('src/foo.js')   | Should -Be $true
        $re.IsMatch('foo.js')       | Should -Be $true
        $re.IsMatch('src/foo.jsx')  | Should -Be $false
        $re.IsMatch('src/foo.ts')   | Should -Be $false
    }

    It 'anchors a leading / to the root' {
        $re = ConvertTo-CodeownersRegex '/src/'
        $re.IsMatch('src/foo.cs')       | Should -Be $true
        $re.IsMatch('src/deep/bar.cs')  | Should -Be $true
        $re.IsMatch('lib/src/bar.cs')   | Should -Be $false
    }

    It 'matches **/*.cs in subdirectories' {
        $re = ConvertTo-CodeownersRegex '**/*.cs'
        $re.IsMatch('src/lib/deep/File.cs')  | Should -Be $true
        $re.IsMatch('src/File.cs')           | Should -Be $true
        $re.IsMatch('src/lib/deep/File.ts')  | Should -Be $false
        # Note: File.cs at the repo root is handled by a bare *.cs rule, not **/*.cs
    }

    It 'matches an anchored file pattern' {
        $re = ConvertTo-CodeownersRegex '/CODEOWNERS'
        $re.IsMatch('CODEOWNERS')         | Should -Be $true
        $re.IsMatch('docs/CODEOWNERS')    | Should -Be $false
    }

    It 'handles ? as single non-separator character' {
        $re = ConvertTo-CodeownersRegex 'foo?.cs'
        $re.IsMatch('food.cs')  | Should -Be $true
        $re.IsMatch('foo.cs')   | Should -Be $false
    }
}

Describe 'ConvertFrom-CodeownersText' {
    It 'skips blank lines and comment lines' {
        $rules = ConvertFrom-CodeownersText "# This is a comment`n`n  `n*.rb @alice"
        $rules.Count | Should -Be 1
        $rules[0].rawOwners | Should -Contain 'alice'
    }

    It 'parses a simple rule with one owner' {
        $rules = ConvertFrom-CodeownersText '*.js @bob'
        $rules[0].pattern    | Should -Be '*.js'
        $rules[0].rawOwners  | Should -Contain 'bob'
    }

    It 'parses a rule with multiple owners including a team handle' {
        $rules = ConvertFrom-CodeownersText '/src/ @alice @dotnet/my-team'
        $rules[0].rawOwners | Should -Contain 'alice'
        $rules[0].rawOwners | Should -Contain 'dotnet/my-team'
    }

    It 'records unown entries with empty rawOwners (no @ handles)' {
        $rules = ConvertFrom-CodeownersText 'docs/generated/'
        $rules.Count           | Should -Be 1
        $rules[0].rawOwners    | Should -HaveCount 0
    }

    It 'ignores tokens without @ prefix (emails etc.)' {
        $rules = ConvertFrom-CodeownersText '*.rb user@example.com @alice'
        $rules[0].rawOwners | Should -Contain 'alice'
        $rules[0].rawOwners | Should -Not -Contain 'user@example.com'
    }

    It 'returns multiple rules in order' {
        $text = "* @default`n/docs/ @docs-team"
        $rules = ConvertFrom-CodeownersText $text
        $rules.Count         | Should -Be 2
        $rules[0].pattern    | Should -Be '*'
        $rules[1].pattern    | Should -Be '/docs/'
    }

    It 'handles malformed patterns without throwing' {
        # A pattern that produces an invalid regex should be silently skipped
        { ConvertFrom-CodeownersText '[invalid @alice' } | Should -Not -Throw
    }
}

Describe 'Get-CodeownersForFiles' {
    BeforeAll {
        $ruleText = @"
# catch-all
* @default-team
# specific path
/docs/ @docs-team
# unown entry – no owners
/docs/generated/
"@
        $script:rules = ConvertFrom-CodeownersText $ruleText
        # Simple expand: return owner as-is (no team expansion needed for these tests)
        $script:noExpand = { param($o) @($o) }
    }

    It 'returns empty array when rules list is empty' {
        $result = Get-CodeownersForFiles -rules @() -filePaths @('README.md') -expandOwnerFn $script:noExpand
        $result | Should -HaveCount 0
    }

    It 'returns empty array when file list is empty' {
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @() -expandOwnerFn $script:noExpand
        $result | Should -HaveCount 0
    }

    It 'applies last-match-wins: /docs/ overrides catch-all *' {
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @('docs/README.md') -expandOwnerFn $script:noExpand
        $result | Should -Contain 'docs-team'
        $result | Should -Not -Contain 'default-team'
    }

    It 'unown entry means no owners for that file path' {
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @('docs/generated/foo.txt') -expandOwnerFn $script:noExpand
        $result | Should -HaveCount 0
    }

    It 'uses catch-all for a file not covered by specific rules' {
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @('README.md') -expandOwnerFn $script:noExpand
        $result | Should -Contain 'default-team'
    }

    It 'unions owners from multiple files preserving insertion order' {
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @('README.md', 'docs/guide.md') -expandOwnerFn $script:noExpand
        $result[0] | Should -Be 'default-team'
        $result[1] | Should -Be 'docs-team'
    }

    It 'deduplicates owners that appear for multiple files' {
        # Both files hit catch-all → only one 'default-team' entry
        $result = Get-CodeownersForFiles -rules $script:rules -filePaths @('README.md', 'LICENSE') -expandOwnerFn $script:noExpand
        ($result | Where-Object { $_ -eq 'default-team' }).Count | Should -Be 1
    }

    It 'expands team handles via expandOwnerFn' {
        $teamRules = ConvertFrom-CodeownersText '* @myorg/my-team'
        $expandFn  = { param($o) if ($o -eq 'myorg/my-team') { @('alice', 'bob') } else { @($o) } }
        $result    = Get-CodeownersForFiles -rules $teamRules -filePaths @('foo.cs') -expandOwnerFn $expandFn
        $result    | Should -Contain 'alice'
        $result    | Should -Contain 'bob'
    }

    It 'excludes null/empty logins from expandOwnerFn' {
        $teamRules = ConvertFrom-CodeownersText '* @broken-team'
        # Simulate a failed team expansion returning empty
        $expandFn  = { param($o) @() }
        $result    = Get-CodeownersForFiles -rules $teamRules -filePaths @('foo.cs') -expandOwnerFn $expandFn
        $result | Should -HaveCount 0
    }

    It 'works without expandOwnerFn (uses rawOwner as login)' {
        $teamRules = ConvertFrom-CodeownersText '* @carol'
        $result    = Get-CodeownersForFiles -rules $teamRules -filePaths @('foo.cs') -expandOwnerFn $null
        $result | Should -Contain 'carol'
    }
}
