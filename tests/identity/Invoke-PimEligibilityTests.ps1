#requires -Version 5.1
# Behavioral checks with synthetic identities and mocked cloud boundaries. No cloud access.
param([string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
$checker = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/Get-PimEligibility.ps1'
$tenant = '11111111-1111-1111-1111-111111111111'
$userId = '22222222-2222-2222-2222-222222222222'
$testGroupGuid = '33333333-3333-3333-3333-333333333333'
$results = [System.Collections.Generic.List[object]]::new()

function Assert-That { param([bool]$Condition, [string]$Message = 'Assertion failed'); if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Match)
    $caught = ''
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-That ($caught -and $caught -match $Match) "Expected failure matching '$Match'; got '$caught'"
}
function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & {
            . $checker
            $script:RoTenant = $tenant
            function Get-MgContext { [pscustomobject]@{ TenantId = $tenant; Environment = 'Global' } }
            function Invoke-MgGraphRequest { throw 'Unexpected real Graph SDK call' }
            function Invoke-RoAzCommand { throw 'Unexpected Azure CLI call' }
            function Initialize-RoAz { }
            function Write-Host { }
            function Write-Progress { }
            & $Body
        }
        $results.Add([pscustomobject]@{ Test = $Name; Result = 'PASS' })
    } catch { $results.Add([pscustomobject]@{ Test = $Name; Result = 'FAIL'; Error = $_.Exception.Message }) }
}
function New-CheckReport {
    @{ Checks = [System.Collections.Generic.List[object]]::new(); CoverageNotes = [System.Collections.Generic.List[string]]::new() }
}

Invoke-Case 'Graph transport is GET only and checks tenant before sending' {
    $script:methodSeen = ''
    function Invoke-MgGraphRequest {
        param($Method,$Uri,$OutputType,$ErrorAction)
        $script:methodSeen = $Method
        @{ value = @() }
    }
    $null = Invoke-RoGraphGet 'https://graph.microsoft.com/v1.0/users'
    Assert-That ($script:methodSeen -eq 'GET')
    function Get-MgContext { [pscustomobject]@{ TenantId = 'wrong'; Environment = 'Global' } }
    $script:methodSeen = ''
    Assert-Throws { Invoke-RoGraphGet 'https://graph.microsoft.com/v1.0/users' } 'tenant'
    Assert-That (-not $script:methodSeen) 'Wrong tenant reached the API'
}
Invoke-Case 'Authentication asks for read scopes in an explicit process-scoped tenant' {
    $script:context = $null; $script:requested = @()
    function Get-Module { return $true }
    function Import-Module { }
    function Get-MgContext { return $script:context }
    function Connect-MgGraph {
        [CmdletBinding()]
        param($TenantId,$Environment,$ContextScope,$Scopes,[switch]$UseDeviceCode)
        Assert-That ($TenantId -eq $tenant -and $Environment -eq 'Global' -and $ContextScope -eq 'Process')
        $script:requested = $Scopes
        $script:context = [pscustomobject]@{ TenantId = $TenantId; Environment = $Environment; Scopes = $Scopes }
    }
    Connect-RoGraph $tenant -DeviceCode
    Assert-That ($script:requested.Count -eq 4)
    Assert-That (@($script:requested | Where-Object { $_ -match 'Write' }).Count -eq 0)
    Assert-That ($script:requested -contains 'PrivilegedEligibilitySchedule.Read.AzureADGroup')
}
Invoke-Case 'No implicit login when existing session required' {
    function Get-Module { return $true }
    function Import-Module { }
    function Get-MgContext { return $null }
    Assert-Throws { Connect-RoGraph $tenant -ExistingOnly } 'No Graph session'
}
foreach ($authScenario in @('missing', 'complete', 'manual', 'wrong-tenant', 'unconsented', 'consent-error')) {
    Invoke-Case "Graph consent handling: $authScenario" {
        $required = @('User.Read.All', 'Group.Read.All', 'RoleManagement.Read.Directory', 'PrivilegedEligibilitySchedule.Read.AzureADGroup')
        $script:context = [pscustomobject]@{ TenantId = $tenant; Environment = 'Global'; Scopes = @('User.Read') }
        if ($authScenario -eq 'complete') { $script:context.Scopes = $required }
        if ($authScenario -eq 'wrong-tenant') { $script:context.TenantId = 'wrong' }
        $script:connectCount = 0
        function Get-Module { return $true }
        function Import-Module { }
        function Get-MgContext { $script:context }
        function Connect-MgGraph {
            [CmdletBinding()]
            param($TenantId, $Environment, $ContextScope, $Scopes, [switch]$UseDeviceCode)
            $script:connectCount++
            Assert-That ($TenantId -eq $tenant -and $Environment -eq 'Global' -and $ContextScope -eq 'Process')
            Assert-That ($Scopes.Count -eq 4 -and @($Scopes | Where-Object { $_ -match 'Write' }).Count -eq 0)
            if ($authScenario -eq 'consent-error') { throw 'AADSTS65001: consent required' }
            if ($authScenario -ne 'unconsented') { $script:context.Scopes = $Scopes }
        }
        switch ($authScenario) {
            'manual' { Assert-Throws { Connect-RoGraph $tenant -ExistingOnly } 'missing.*permission|missing.*scope' }
            'wrong-tenant' { Assert-Throws { Connect-RoGraph $tenant } 'tenant' }
            'unconsented' { Assert-Throws { Connect-RoGraph $tenant -DeviceCode } 'administrator|admin.*consent' }
            'consent-error' { Assert-Throws { Connect-RoGraph $tenant -DeviceCode } 'administrator|admin.*consent' }
            default { Connect-RoGraph $tenant -DeviceCode }
        }
        $expectedCount = if ($authScenario -in @('complete', 'manual', 'wrong-tenant')) { 0 } else { 1 }
        Assert-That ($script:connectCount -eq $expectedCount) 'Unexpected reconnect count'
    }
}
Invoke-Case 'Wrong cloud refused' {
    function Get-MgContext { [pscustomobject]@{ TenantId = $tenant; Environment = 'USGov' } }
    Assert-Throws { Assert-RoGraphContext $tenant } 'public cloud'
}
Invoke-Case 'Azure adapter only builds GET requests pinned to a subscription' {
    . $checker
    $script:RoAzExe = 'Invoke-FakeAzExecutable'
    $script:RoAzPrefix = @()
    $script:RoAzSubscription = '44444444-4444-4444-4444-444444444444'
    $script:capturedAzArgs = @()
    function Invoke-FakeAzExecutable {
        $script:capturedAzArgs = @($args)
        $global:LASTEXITCODE = 0
        '{"value":[]}'
    }
    $null = Invoke-RoAzCommand Get -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01'
    $captured = $script:capturedAzArgs -join '|'
    Assert-That ($captured -match 'rest\|--method\|get\|--url\|' -and $captured -match '--subscription\|44444444')
    Assert-Throws { Invoke-RoAzCommand -Operation Delete } 'ValidateSet|does not belong|cannot validate'
}
Invoke-Case 'Empty collection is a successful empty read' {
    function Invoke-RoGraphGet { [pscustomobject]@{ value = @() } }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/test'
    Assert-That ($r.Complete -and $r.Items.Count -eq 0) $r.Error
}
Invoke-Case 'All Graph pages included' {
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -like '*page2') { return @{ value = @(@{ id = 2 }) } }
        @{ value = @(@{ id = 1 }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2' }
    }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/page1'
    Assert-That ($r.Complete -and $r.Items.Count -eq 2 -and $r.Pages -eq 2)
}
Invoke-Case 'All ARM pages included' {
    function Invoke-RoArmGet {
        param($Uri)
        if ($Uri -like '*page2') { return @{ value = @(@{ id = 2 }) } }
        @{ value = @(@{ id = 1 }); nextLink = 'https://management.azure.com/page2' }
    }
    $r = Read-RoCollection Arm 'https://management.azure.com/page1'
    Assert-That ($r.Complete -and $r.Items.Count -eq 2)
}
Invoke-Case 'Page failure preserves evidence but marks incomplete' {
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -like '*page2') { throw '403 forbidden' }
        @{ value = @(@{ id = 1 }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2' }
    }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/page1'
    Assert-That (-not $r.Complete -and $r.Items.Count -eq 1 -and $r.Error -match '403')
}
Invoke-Case 'Pagination limit cannot claim completion' {
    function Invoke-RoGraphGet { @{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2' } }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/page1' -MaxPages 1
    Assert-That (-not $r.Complete -and $r.Error -match 'Pagination')
}
Invoke-Case 'Unexpected response is not empty eligibility' {
    function Invoke-RoGraphGet { @{ error = 'unknown' } }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/page1'
    Assert-That (-not $r.Complete)
}
Invoke-Case 'Off-host pagination refused before sending' {
    $script:calls = 0
    function Invoke-RoGraphGet {
        $script:calls++
        @{ value = @(); '@odata.nextLink' = 'https://example.com/v1.0/page2' }
    }
    $r = Read-RoCollection Graph 'https://graph.microsoft.com/v1.0/page1'
    Assert-That (-not $r.Complete -and $script:calls -eq 1)
    Assert-Throws { Assert-RoUri 'http://graph.microsoft.com/v1.0/users' Graph } 'unexpected'
}
Invoke-Case 'Short user references rejected without any API call' {
    Assert-Throws { New-RoPimReport -UserRef 'admin' -ExpectedTenant $tenant } 'exact user'
}
Invoke-Case 'Eligibility dates distinguish future and expired schedules' {
    $now = [datetimeoffset]'2026-09-29T00:00:00Z'
    Assert-That ((Get-RoScheduleState '2026-01-01T00:00:00Z' '' $now) -eq 'Eligible now')
    Assert-That ((Get-RoScheduleState '2027-01-01T00:00:00Z' '' $now) -eq 'Future')
    Assert-That ((Get-RoScheduleState '2026-01-01T00:00:00Z' '2026-09-01T00:00:00Z' $now) -eq 'Expired')
    Assert-That ((Get-RoScheduleState '' '' $now) -eq 'Dates unknown')
    Assert-That ((Get-RoScheduleState 'invalid' '' $now) -eq 'Dates unknown')
}
Invoke-Case 'Azure subscription inventory excludes other tenants' {
    function Invoke-RoAzCommand {
        param($Operation)
        switch ($Operation) {
            Account { @{ id = '44444444-4444-4444-4444-444444444444'; tenantId = $tenant } }
            Cloud { @{ name = 'AzureCloud' } }
            Subscriptions { @(@{ id = '44444444-4444-4444-4444-444444444444'; tenantId = $tenant; state = 'Enabled' },
                              @{ id = '55555555-5555-5555-5555-555555555555'; tenantId = 'other'; state = 'Enabled' }) }
        }
    }
    function Invoke-RoArmGet { @{ value = @() } }
    $r = New-CheckReport
    $s = @(Get-RoAzureScopes $r)
    Assert-That ($s.Count -eq 1 -and $s[0] -like '*44444444*')
    Assert-Throws { Get-RoAzureScopes $r -Requested @('/subscriptions/55555555-5555-5555-5555-555555555555') } 'selected tenant'
}
Invoke-Case 'Wrong Azure tenant rejected before subscription reads' {
    function Invoke-RoAzCommand { param($Operation); if ($Operation -eq 'Account') { return @{ tenantId = 'other' } }; throw 'Should not get this far' }
    Assert-Throws { Get-RoAzureScopes (New-CheckReport) } 'tenant differs'
}
Invoke-Case 'Group fallback filters target and remains partial' {
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -match 'principalId eq') { throw '403 principal query refused' }
        @{ value = @(@{ id = 'own'; principalId = $userId; groupId = $testGroupGuid },
                     @{ id = 'someone-else'; principalId = 'other'; groupId = $testGroupGuid }) }
    }
    $r = New-CheckReport
    $g = @(Get-RoPimGroups $r $userId -FallbackGroups @([guid]$testGroupGuid))
    Assert-That ($g.Count -eq 1 -and $g[0].id -eq 'own')
    Assert-That (@($r.Checks | Where-Object Status -eq 'Incomplete').Count -eq 1)
}
Invoke-Case 'Group scan includes non-role-assignable groups and excludes synced/dynamic groups' {
    $script:groupsRead = @()
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -match 'principalId eq') { throw '403 principal query refused' }
        if ($Uri -match '/v1.0/groups\?') {
            return @{ value = @(
                @{ id = $testGroupGuid; onPremisesSyncEnabled = $false; groupTypes = @() },
                @{ id = 'dynamic'; groupTypes = @('DynamicMembership') },
                @{ id = 'synced'; onPremisesSyncEnabled = $true }
            ) }
        }
        $script:groupsRead += $Uri
        @{ value = @(@{ id = 'own'; principalId = $userId; groupId = $testGroupGuid }) }
    }
    $r = New-CheckReport
    $g = @(Get-RoPimGroups $r $userId -EnumerateGroups)
    Assert-That ($script:groupsRead.Count -eq 1 -and $script:groupsRead[0] -match $testGroupGuid)
    Assert-That ($g.Count -eq 1)
}
Invoke-Case 'Full synthetic report keeps group ownership separate and preserves conditions' {
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -match '/users/') { return @{ id = $userId; displayName = '<script>alert(1)</script>'; userPrincipalName = 'reference@example.com'; accountEnabled = $true } }
        if ($Uri -match '/groups/') { return @{ id = $testGroupGuid; displayName = 'Example privileged group' } }
        if ($Uri -match '/privilegedAccess/group/') {
            return @{ value = @(@{ id = 'group-eligible'; principalId = $userId; groupId = $testGroupGuid; accessId = 'owner'; startDateTime = '2020-01-01T00:00:00Z'; endDateTime = '' }) }
        }
        if ($Uri -match '/roleAssignments\?') {
            return @{ value = @(@{ roleDefinitionId = 'role-mapping'; directoryScopeId = '/'; roleDefinition = @{ displayName = 'Security Reader' } }) }
        }
        @{ value = @(@{ id = 'directory-eligible'; principalId = $userId; roleDefinitionId = 'role-direct'; directoryScopeId = '/'; roleDefinition = @{ displayName = 'Example reader' }; startDateTime = '2020-01-01T00:00:00Z'; endDateTime = '' }) }
    }
    function Get-RoAzureScopes { '/subscriptions/44444444-4444-4444-4444-444444444444' }
    function Invoke-RoArmGet {
        @{ value = @(@{ name = 'azure-eligible'; properties = @{
            principalId = $userId; roleDefinitionId = 'synthetic-role'; roleEligibilityScheduleId = 'stable-id'
            startDateTime = '2020-01-01T00:00:00Z'; condition = 'restricted <container>'; conditionVersion = '2.0'
            expandedProperties = @{ roleDefinition = @{ displayName = 'Example Azure role' }; scope = @{ id = '/subscriptions/synthetic' } }
        } }) }
    }
    $r = New-RoPimReport -UserRef 'reference@example.com' -ExpectedTenant $tenant
    Assert-That ($r.Eligibilities.Count -eq 3) "Unexpected row count $($r.Eligibilities.Count)"
    Assert-That ($r.Status -notlike 'PARTIAL*')
    Assert-That ($r.GroupRoleMappings.Count -eq 1 -and $r.GroupRoleMappings[0].Note -match 'ownership alone does not')
    Assert-That (($r.Eligibilities | Where-Object Plane -eq 'PIM group').Access -eq 'owner')
    Assert-That (($r.Eligibilities | Where-Object Plane -eq 'Azure role').Condition -eq 'restricted <container>')
    if ($ArtifactDirectory) {
        $paths = Export-RoPimReport $r $ArtifactDirectory
        $html = Get-Content -LiteralPath $paths.Html -Raw
        Assert-That ($html -notmatch '<script>alert' -and $html -match '&lt;script&gt;') 'HTML did not encode user data'
        $checklist = Get-Content -LiteralPath $paths.Checklist -Raw
        Assert-That ($checklist -match 'Preserve condition' -and $checklist -match 'access=owner')
        $loaded = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        Assert-That ($loaded.ReadOnly -and $loaded.Eligibilities.Count -eq 3)
    }
}
Invoke-Case 'Denied planes and skipped Azure produce a partial report, never a clean bill' {
    function Invoke-RoGraphGet {
        param($Uri)
        if ($Uri -match '/users/') { return @{ id = $userId; displayName = 'Example'; userPrincipalName = 'reference@example.com' } }
        throw '403 forbidden'
    }
    $r = New-RoPimReport -UserRef 'reference@example.com' -ExpectedTenant $tenant -WithoutAzure
    Assert-That ($r.Status -like 'PARTIAL*' -and $r.Eligibilities.Count -eq 0)
    Assert-That (@($r.Checks | Where-Object { $_.Status -ne 'Read' }).Count -eq 3)
}
Invoke-Case 'Duplicate parent-scope results do not duplicate eligibility' {
    $r = @{ Seen = @{}; Eligibilities = [System.Collections.Generic.List[object]]::new() }
    1..2 | ForEach-Object { Add-RoEligibility $r 'Azure role' 'Example' '/scope' 'Eligible role' '2020-01-01T00:00:00Z' '' 'same-id' }
    Assert-That ($r.Eligibilities.Count -eq 1)
}

$results | Format-Table -AutoSize | Out-Host
$bad = @($results | Where-Object Result -eq 'FAIL')
if ($bad.Count) { $bad | Format-List | Out-Host; exit 1 }
Write-Output "$($results.Count) behavioral checks passed on PowerShell $($PSVersionTable.PSVersion)"
