BeforeAll {
    Import-Module "$PSScriptRoot/../MaintainersGuard.psm1" -Force
}

Describe 'Test-MaintainerSafety' {
    It 'Returns safe when existing is empty' {
        $existing = @{}
        $proposed = [ordered]@{ 'a/b' = @('alice') }
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe | Should -BeTrue
    }

    It 'Returns safe when count stays the same' {
        $existing = @{ 'a/b' = @('alice', 'bob') }
        $proposed = [ordered]@{ 'a/b' = @('alice', 'bob') }
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe | Should -BeTrue
    }

    It 'Returns safe when count increases' {
        $existing = @{ 'a/b' = @('alice') }
        $proposed = [ordered]@{ 'a/b' = @('alice', 'bob') }
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe | Should -BeTrue
    }

    It 'Returns safe when count increases across multiple repos' {
        $existing = @{ 'a/b' = @('alice'); 'c/d' = @('bob') }
        $proposed = [ordered]@{ 'a/b' = @('alice', 'carol'); 'c/d' = @('bob') }
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe | Should -BeTrue
    }

    It 'Detects missing repo key' {
        $existing = @{ 'a/b' = @('alice'); 'c/d' = @('carol') }
        $proposed = [ordered]@{ 'a/b' = @('alice') }   # c/d is absent
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe   | Should -BeFalse
        $result.Reason | Should -BeLike '*would lose repo keys*'
        $result.Reason | Should -BeLike '*c/d*'
    }

    It 'Detects total maintainer count decrease' {
        $existing = @{ 'a/b' = @('alice', 'bob', 'carol') }
        $proposed = [ordered]@{ 'a/b' = @('alice') }   # 3 → 1
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe   | Should -BeFalse
        $result.Reason | Should -BeLike '*decrease*'
    }

    It 'Detects count decrease spread across multiple repos' {
        $existing = @{ 'a/b' = @('alice'); 'c/d' = @('bob', 'carol') }
        $proposed = [ordered]@{ 'a/b' = @('alice'); 'c/d' = @('bob') }   # total 3 → 2
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe   | Should -BeFalse
        $result.Reason | Should -BeLike '*decrease*'
    }

    It 'Reports missing key before count decrease when both are violated' {
        # Both conditions violated: c/d missing AND count drops
        $existing = @{ 'a/b' = @('alice', 'bob'); 'c/d' = @('carol') }
        $proposed = [ordered]@{ 'a/b' = @('alice') }   # c/d missing, total 3 → 1
        $result = Test-MaintainerSafety -Existing $existing -Proposed $proposed
        $result.Safe   | Should -BeFalse
        $result.Reason | Should -BeLike '*would lose repo keys*'   # key loss reported first
    }
}
