#requires -Version 5.1

<#
.SYNOPSIS
Read-only PIM eligibility inventory for an exact user in an explicit tenant.
.DESCRIPTION
Standalone: does not load the cloning or granting engine. Cloud requests are GET only.
Lists direct Entra/Azure eligibility and PIM group eligibility. Exports HTML, JSON and a
request checklist locally. Missing permissions or incomplete queries are reported explicitly.
Requires Microsoft.Graph.Authentication; Azure CLI is needed unless -SkipAzure is used.
Only Azure public cloud is supported in this version; other clouds are refused.
.PARAMETER User
Exact user principal name (email-style sign-in) or user object GUID. No prefix guessing.
.PARAMETER TenantId
The directory GUID to inspect. Both Graph and Azure CLI must use this tenant.
.PARAMETER GroupId
Optional group GUIDs to check if the directory-wide PIM group query is refused.
This fallback is always labeled partial: supplied groups are not a complete inventory.
.PARAMETER ScanAllGroups
If the directory-wide PIM group query fails, enumerate cloud, non-dynamic groups and
check them individually. Can take a long time. Any failures remain visible.
.PARAMETER AzureScope
Optional ARM scopes. By default, checks visible enabled subscriptions and management groups.
Explicit scopes limit coverage. Subscription scopes must belong to the selected tenant.
.PARAMETER SkipAzure
Check Entra and PIM groups only, explicitly marking Azure as not checked.
.PARAMETER UseExistingGraphSession
Do not open a sign-in prompt. A Graph session in the selected tenant must already exist.
.PARAMETER UseDeviceCode
Use device-code sign-in when creating a new Graph session.
.PARAMETER OutDir
Local report folder. Defaults to LocalApplicationData/PIM-Automation/eligibility.
.EXAMPLE
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<directory-guid>'
.EXAMPLE
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<directory-guid>' -SkipAzure
.NOTES
Exit 0: all attempted reads completed in the declared scope. Exit 2: report has gaps or
skipped areas. Exit 1: startup/user-resolution/export failure. No grant or activation occurs.
Eligibility is not active access. This is not a complete effective-permissions assessment.
#>


[CmdletBinding()]
param(
    [string]$User,
    [guid]$TenantId,
    [guid[]]$GroupId = @(),
    [switch]$ScanAllGroups,
    [string[]]$AzureScope = @(),
    [switch]$SkipAzure,
    [switch]$UseExistingGraphSession,
    [switch]$UseDeviceCode,
    [string]$OutDir
)

function Get-RoValue {
    param($Object, [string]$Key, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) { return ,$Object[$Key] }
    } elseif ($Object.PSObject.Properties[$Key]) { return ,$Object.$Key }
    return ,$Default
}

function Assert-RoUri {
    param([string]$Uri, [ValidateSet('Graph','Arm')][string]$Provider)
    $u = [uri]$Uri
    $hostName = if ($Provider -eq 'Graph') { 'graph.microsoft.com' } else { 'management.azure.com' }
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.Host -ne $hostName -or
        $u.Port -ne 443 -or $u.UserInfo -or $u.Fragment) { throw 'Refused unexpected API or pagination URL.' }
    if ($Provider -eq 'Graph' -and -not $u.AbsolutePath.StartsWith('/v1.0/')) {
        throw 'Only Microsoft Graph v1.0 read endpoints are allowed.'
    }
}

function Assert-RoGraphContext {
    param([string]$ExpectedTenant)
    $ctx = Get-MgContext
    if (-not $ctx -or [string]$ctx.TenantId -ne $ExpectedTenant) {
        throw 'Graph session tenant does not match -TenantId. Connect to the intended tenant first.'
    }
    if ([string](Get-RoValue $ctx 'Environment' 'Global') -ne 'Global') {
        throw 'This checker currently supports public cloud only.'
    }
}

function Connect-RoGraph {
    param([string]$ExpectedTenant, [switch]$ExistingOnly, [switch]$DeviceCode)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw 'Install prerequisite: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    # Consent is needed for both a fresh login and a cached session missing our reads.
    $requiredScopes = @('User.Read.All', 'Group.Read.All', 'RoleManagement.Read.Directory',
                        'PrivilegedEligibilitySchedule.Read.AzureADGroup')
    $ctx = Get-MgContext
    if ($ctx) { Assert-RoGraphContext $ExpectedTenant }
    $heldScopes = Get-RoValue $ctx 'Scopes' @()
    $missingScopes = @($requiredScopes | Where-Object { $heldScopes -notcontains $_ })
    if ($ctx -and $missingScopes.Count -and $ExistingOnly) {
        throw "Existing Graph session is missing required read permissions: $($missingScopes -join ', '). Omit -UseExistingGraphSession to request them."
    }
    if (-not $ctx -or $missingScopes.Count) {
        if ($ExistingOnly) { throw 'No Graph session. Sign in first or omit -UseExistingGraphSession.' }
        # RoleManagement.Read.Directory also covers role definitions and group role mappings.
        $p = @{
            TenantId = $ExpectedTenant; Environment = 'Global'; ContextScope = 'Process'
            Scopes = $requiredScopes
            ErrorAction = 'Stop'
        }
        $cmd = Get-Command Connect-MgGraph
        if ($cmd.Parameters.ContainsKey('NoWelcome')) { $p.NoWelcome = $true }
        if ($DeviceCode) {
            if ($cmd.Parameters.ContainsKey('UseDeviceCode')) { $p.UseDeviceCode = $true }
            elseif ($cmd.Parameters.ContainsKey('UseDeviceAuthentication')) { $p.UseDeviceAuthentication = $true }
            else { throw 'Installed Graph SDK does not support device-code authentication.' }
        }
        Write-Host 'Requesting Microsoft Graph read permissions:'
        Write-Host ('  ' + ($requiredScopes -join ', '))
        Write-Host 'If Microsoft shows Need admin approval, ask your tenant administrator to approve these permissions for Microsoft Graph PowerShell.'
        try { Connect-MgGraph @p }
        catch { throw "Graph sign-in/consent failed. A tenant administrator may need to approve the requested read permissions. $($_.Exception.Message)" }
        Assert-RoGraphContext $ExpectedTenant
        $heldScopes = Get-RoValue (Get-MgContext) 'Scopes' @()
        $missingScopes = @($requiredScopes | Where-Object { $heldScopes -notcontains $_ })
        if ($missingScopes.Count) {
            throw "Graph session is still missing required read permissions: $($missingScopes -join ', '). Ask your tenant administrator to approve consent, then run again."
        }
    }
    # Scope metadata is not proof of effective authorization; report reads still surface 403s.
    Assert-RoGraphContext $ExpectedTenant
}

function Invoke-RoGraphGet {
    param([string]$Uri)
    Assert-RoUri $Uri Graph
    Assert-RoGraphContext $script:RoTenant
    # No method/body parameter is exposed. This is the only Graph transport boundary.
    Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
}

function Initialize-RoAz {
    $az = Get-Command az -ErrorAction Stop
    $script:RoAzExe = $az.Source
    $script:RoAzPrefix = @()
    if ($az.Source -match '\.(cmd|bat)$') {
        $python = Join-Path (Split-Path (Split-Path $az.Source)) 'python.exe'
        if (-not (Test-Path -LiteralPath $python)) {
            throw 'Cannot safely invoke this Azure CLI wrapper. Install the standard CLI or use -SkipAzure.'
        }
        $script:RoAzExe = $python
        $script:RoAzPrefix = @('-IBm','azure.cli')
    }
}

function Invoke-RoAzCommand {
    param([ValidateSet('Account','Subscriptions','Cloud','Get')][string]$Operation, [string]$Uri)
    $a = switch ($Operation) {
        'Account' { @('account','show') }
        'Subscriptions' { @('account','list','--all','--refresh') }
        'Cloud' { @('cloud','show') }
        'Get' {
            Assert-RoUri $Uri Arm
            @('rest','--method','get','--url',$Uri,'--subscription',$script:RoAzSubscription)
        }
    }
    $argsList = @($script:RoAzPrefix) + @($a) + @('--output','json','--only-show-errors')
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue' # CLI stderr is captured, never mistaken for an empty read.
        $text = (& $script:RoAzExe @argsList 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "Azure CLI read failed: $text" }
    if (-not $text) { throw 'Azure CLI returned no JSON.' }
    $text | ConvertFrom-Json -ErrorAction Stop
}

function Invoke-RoArmGet {
    param([string]$Uri)
    Assert-RoUri $Uri Arm
    # Pin requests to the verified tenant's subscription context, not a changing CLI default.
    Invoke-RoAzCommand -Operation Get -Uri $Uri
}

function Read-RoCollection {
    param([ValidateSet('Graph','Arm')][string]$Provider, [string]$Uri, [int]$MaxPages = 1000)
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = @{}; $next = $Uri; $pages = 0
    try {
        while ($next) {
            if ($pages -ge $MaxPages -or $seen.ContainsKey($next)) { throw 'Pagination incomplete (limit or repeated page).' }
            Assert-RoUri $next $Provider
            $seen[$next] = $true; $pages++
            $r = if ($Provider -eq 'Graph') { Invoke-RoGraphGet $next } else { Invoke-RoArmGet $next }
            $values = Get-RoValue $r 'value'
            if ($null -eq $values) { throw 'Expected a collection response with value; received an incomplete/unexpected response.' }
            foreach ($v in $values) { if ($null -ne $v) { $items.Add($v) } }
            $nextKey = if ($Provider -eq 'Graph') { '@odata.nextLink' } else { 'nextLink' }
            $next = [string](Get-RoValue $r $nextKey '')
        }
        return [pscustomobject]@{ Complete = $true; Items = $items.ToArray(); Error = ''; Pages = $pages }
    } catch {
        return [pscustomobject]@{ Complete = $false; Items = $items.ToArray(); Error = $_.Exception.Message; Pages = $pages }
    }
}

function Add-RoCheck {
    param($Report, [string]$Area, [string]$Scope, [string]$Status, [string]$Detail)
    $Report.Checks.Add([pscustomobject]@{ Area = $Area; Scope = $Scope; Status = $Status; Detail = $Detail })
}

function Read-RoChecked {
    param($Report, [string]$Area, [string]$Scope, [string]$Provider, [string]$Uri)
    $r = Read-RoCollection -Provider $Provider -Uri $Uri
    $status = if ($r.Complete) { 'Read' } else { 'Incomplete' }
    $detail = if ($r.Complete) { "$($r.Items.Count) record(s) returned; $($r.Pages) page(s)." } else { $r.Error }
    Add-RoCheck $Report $Area $Scope $status $detail
    return $r
}

function Get-RoScheduleState {
    param([string]$Start, [string]$End, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    try {
        if ($End -and [datetimeoffset]::Parse($End) -le $Now) { return 'Expired' }
        if ($Start -and [datetimeoffset]::Parse($Start) -gt $Now) { return 'Future' }
        if (-not $Start) { return 'Dates unknown' }
        return 'Eligible now'
    } catch { return 'Dates unknown' }
}

function Add-RoEligibility {
    param($Report, [string]$Plane, [string]$Name, [string]$Scope, [string]$Access,
          [string]$Start, [string]$End, [string]$Id, [string]$RoleId = '', [string]$Group = '',
          [string]$Condition = '', [string]$ConditionVersion = '')
    $key = "$Plane|$Id|$Scope|$Access|$Start|$End"
    if ($Report.Seen.ContainsKey($key)) { return }
    $Report.Seen[$key] = $true
    $Report.Eligibilities.Add([pscustomobject]@{
        Plane = $Plane; Name = $Name; Scope = $Scope; Access = $Access
        State = (Get-RoScheduleState $Start $End); Start = $Start; End = $End
        AssignmentId = $Id; RoleDefinitionId = $RoleId; GroupId = $Group
        Condition = $Condition; ConditionVersion = $ConditionVersion
    })
}

function Get-RoAzureScopes {
    param($Report, [string[]]$Requested = @())
    Initialize-RoAz
    $acct = Invoke-RoAzCommand Account
    if ([string]$acct.tenantId -ne $script:RoTenant) { throw 'Azure CLI tenant differs from -TenantId. Run az login --tenant <directory-guid> first.' }
    $cloud = Invoke-RoAzCommand Cloud
    if ($cloud.name -ne 'AzureCloud') { throw 'Only public Azure cloud is supported by this checker.' }
    $script:RoAzSubscription = [string]$acct.id
    if (-not $script:RoAzSubscription) { throw 'An Azure CLI subscription context is required. Use -SkipAzure for Graph-only inspection.' }
    $subs = @(Invoke-RoAzCommand Subscriptions | Where-Object { $_.tenantId -eq $script:RoTenant -and $_.state -eq 'Enabled' })
    $subIds = @($subs | ForEach-Object { [string]$_.id })
    $scopes = [System.Collections.Generic.List[string]]::new()
    if ($Requested.Count) {
        foreach ($s in $Requested) {
            if ($s -match '^/subscriptions/([0-9a-fA-F-]{36})(/resourceGroups/[a-zA-Z0-9_.()-]+)?$') {
                if ($subIds -notcontains $Matches[1]) { throw "Requested scope not in selected tenant's enabled subscription inventory: $s" }
            } elseif ($s -notmatch '^/providers/Microsoft.Management/managementGroups/[a-zA-Z0-9_.()-]+$') {
                throw "Use a subscription, resource-group or management-group scope: $s"
            }
            $scopes.Add($s.TrimEnd('/'))
        }
        $Report.CoverageNotes.Add('Azure coverage is limited to the explicitly supplied scopes and records returned by those APIs.')
    } else {
        foreach ($id in $subIds) { $scopes.Add("/subscriptions/$id") }
        $mgs = Read-RoChecked $Report 'Azure scope discovery' 'Visible management groups' Arm `
            'https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01'
        foreach ($mg in $mgs.Items) {
            $mgId = [string](Get-RoValue $mg 'id' '')
            if ($mgId -match '^/providers/Microsoft.Management/managementGroups/[a-zA-Z0-9_.()-]+$') { $scopes.Add($mgId) }
        }
    }
    Add-RoCheck $Report 'Azure scope discovery' 'Selected tenant' 'Read' "$($subs.Count) enabled visible subscription(s). Other tenants excluded."
    if (-not $scopes.Count) { Add-RoCheck $Report 'Azure eligibility' 'Selected tenant' 'Incomplete' 'No visible scopes to query; this does not mean the user has no Azure eligibility.' }
    return @($scopes | Sort-Object -Unique)
}

function Get-RoPimGroups {
    param($Report, [string]$PrincipalId, [guid[]]$FallbackGroups = @(), [switch]$EnumerateGroups)
    $base = 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances'
    $r = Read-RoCollection Graph "$base`?`$filter=principalId eq '$PrincipalId'"
    if ($r.Complete) {
        Add-RoCheck $Report 'PIM groups' 'User eligibility query' 'Read' "$($r.Items.Count) record(s)."
        return @($r.Items)
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $r.Items) { $items.Add($item) }
    Add-RoCheck $Report 'PIM groups' 'User eligibility query' 'Incomplete' $r.Error
    $ids = @($FallbackGroups | ForEach-Object { $_.ToString() })
    if ($EnumerateGroups) {
        $all = Read-RoChecked $Report 'PIM group fallback' 'Cloud group inventory' Graph `
            'https://graph.microsoft.com/v1.0/groups?$select=id,onPremisesSyncEnabled,groupTypes&$top=999'
        foreach ($g in $all.Items) {
            if (-not (Get-RoValue $g 'onPremisesSyncEnabled' $false) -and
                @((Get-RoValue $g 'groupTypes' @())) -notcontains 'DynamicMembership') { $ids += [string]$g.id }
        }
    }
    $ids = @($ids | Sort-Object -Unique)
    if (-not $ids.Count) {
        $Report.CoverageNotes.Add('Group eligibility query failed. Try -GroupId <known-group-guid> or -ScanAllGroups with appropriate read access.')
    }
    $index = 0
    foreach ($id in $ids) {
        $index++; Write-Progress -Activity 'Reading PIM groups' -Status "$index of $($ids.Count)" -PercentComplete (100 * $index / $ids.Count)
        $g = Read-RoChecked $Report 'PIM group fallback' $id Graph "$base`?`$filter=groupId eq '$id'"
        foreach ($e in $g.Items) { if ([string]$e.principalId -eq $PrincipalId) { $items.Add($e) } }
    }
    Write-Progress -Activity 'Reading PIM groups' -Completed
    # Preserve the original coverage failure even when a fallback finds useful rows.
    return $items.ToArray()
}

function New-RoPimReport {
    param([string]$UserRef, [string]$ExpectedTenant, [switch]$WithoutAzure,
          [guid[]]$FallbackGroups = @(), [switch]$EnumerateGroups, [string[]]$Scopes = @())
    $script:RoTenant = $ExpectedTenant
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($UserRef, [ref]$parsedId) -and $UserRef -notmatch '^[^\s/@]+@[^\s/@]+$') {
        throw 'Supply an exact user sign-in name or object GUID; short-name/prefix lookup is disabled.'
    }
    $u = Invoke-RoGraphGet ('https://graph.microsoft.com/v1.0/users/' + [uri]::EscapeDataString($UserRef) + '?$select=id,displayName,userPrincipalName,accountEnabled')
    $uid = [string](Get-RoValue $u 'id' '')
    if (-not [guid]::TryParse($uid, [ref]$parsedId)) { throw 'User lookup did not return a valid exact user object.' }
    $report = @{
        Version = '1.0.0'; TenantId = $ExpectedTenant; GeneratedUtc = [datetime]::UtcNow.ToString('o')
        User = $u; ReadOnly = $true; Status = 'Reads completed in declared scope'
        Eligibilities = [System.Collections.Generic.List[object]]::new()
        GroupRoleMappings = [System.Collections.Generic.List[object]]::new()
        Checks = [System.Collections.Generic.List[object]]::new()
        CoverageNotes = [System.Collections.Generic.List[string]]::new(); Seen = @{}
    }
    $report.CoverageNotes.Add('Lists direct PIM eligibility plus eligible group membership/ownership. Eligibility does not mean active access or approval to request the same privileges.')
    $report.CoverageNotes.Add('Not a complete effective-access audit: current group-derived eligibility, nested groups, ordinary standing access and application-specific group permissions are not expanded.')
    $report.CoverageNotes.Add('Azure inventory is limited to scopes visible to the inspecting account. Successful reads cannot prove visibility across the entire tenant.')
    if (-not (Get-RoValue $u 'accountEnabled' $true)) { $report.CoverageNotes.Add('The reference account is disabled; returned assignments are not evidence it can activate them.') }
    $dir = Read-RoChecked $report 'Entra roles' 'Direct user eligibility' Graph `
        "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=principalId eq '$uid'&`$expand=roleDefinition"
    foreach ($e in $dir.Items) {
        if ([string]$e.principalId -ne $uid) { continue }
        $roleId = [string]$e.roleDefinitionId
        $name = [string](Get-RoValue (Get-RoValue $e 'roleDefinition') 'displayName' $roleId)
        $scope = [string](Get-RoValue $e 'directoryScopeId' '')
        if (-not $scope) { $scope = [string](Get-RoValue $e 'appScopeId' '') }
        Add-RoEligibility $report 'Entra role' $name $scope 'Eligible role' `
            (Get-RoValue $e 'startDateTime' '') (Get-RoValue $e 'endDateTime' '') $e.id $roleId
    }
    $groups = @(Get-RoPimGroups $report $uid -FallbackGroups $FallbackGroups -EnumerateGroups:$EnumerateGroups)
    $names = @{}
    foreach ($e in $groups) {
        if ([string]$e.principalId -ne $uid) { continue }
        $gid = [string]$e.groupId
        if (-not $names.ContainsKey($gid)) {
            try {
                $g = Invoke-RoGraphGet "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=id,displayName"
                $names[$gid] = [string]$g.displayName
            } catch {
                $names[$gid] = $gid
                Add-RoCheck $report 'Group name' $gid 'Incomplete' $_.Exception.Message
            }
        }
        Add-RoEligibility $report 'PIM group' $names[$gid] $gid ([string]$e.accessId) `
            (Get-RoValue $e 'startDateTime' '') (Get-RoValue $e 'endDateTime' '') $e.id '' $gid
    }
    # Explain the Entra roles attached to eligible groups, without claiming an owner is a member.
    foreach ($gid in $names.Keys) {
        $mapping = Read-RoChecked $report 'Group role explanation' $gid Graph `
            "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$gid'&`$expand=roleDefinition"
        foreach ($m in $mapping.Items) {
            $report.GroupRoleMappings.Add([pscustomobject]@{
                Group = $names[$gid]; GroupId = $gid
                Role = [string](Get-RoValue (Get-RoValue $m 'roleDefinition') 'displayName' ([string]$m.roleDefinitionId))
                Scope = [string](Get-RoValue $m 'directoryScopeId' (Get-RoValue $m 'appScopeId' ''))
                Note = 'Role attached to group at scan time. Membership activation may convey it; ownership alone does not. Not an additional direct eligibility.'
            })
        }
    }
    if ($WithoutAzure) {
        Add-RoCheck $report 'Azure eligibility' 'All Azure scopes' 'Not checked' '-SkipAzure was selected.'
    } else {
        try {
            $azureScopes = @(Get-RoAzureScopes $report -Requested $Scopes)
            foreach ($s in $azureScopes) {
                Write-Host "Reading Azure eligibility: $s"
                $a = Read-RoChecked $report 'Azure eligibility' $s Arm `
                    "https://management.azure.com$s/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=principalId eq '$uid'"
                foreach ($e in $a.Items) {
                    $p = $e.properties
                    if ([string]$p.principalId -ne $uid) { continue }
                    $expanded = Get-RoValue $p 'expandedProperties'
                    $roleId = [string]$p.roleDefinitionId
                    $name = [string](Get-RoValue (Get-RoValue $expanded 'roleDefinition') 'displayName' $roleId)
                    $scope = [string](Get-RoValue (Get-RoValue $expanded 'scope') 'id' (Get-RoValue $p 'scope' $s))
                    # ARM instance IDs may vary by the queried parent scope; use stable schedule identity.
                    $id = [string](Get-RoValue $p 'roleEligibilityScheduleId' $e.name)
                    Add-RoEligibility $report 'Azure role' $name $scope 'Eligible role' `
                        (Get-RoValue $p 'startDateTime' '') (Get-RoValue $p 'endDateTime' '') $id $roleId '' `
                        (Get-RoValue $p 'condition' '') (Get-RoValue $p 'conditionVersion' '')
                }
            }
        } catch { Add-RoCheck $report 'Azure eligibility' 'Scope discovery/context' 'Incomplete' $_.Exception.Message }
    }
    if (@($report.Checks | Where-Object { $_.Status -ne 'Read' }).Count) { $report.Status = 'PARTIAL - some areas were not checked successfully' }
    $report.Remove('Seen')
    return $report
}

function Export-RoPimReport {
    param($Report, [string]$Directory)
    if (-not $Directory) {
        $base = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $base) { $base = [IO.Path]::GetTempPath() }
        $Directory = Join-Path $base 'PIM-Automation/eligibility'
    }
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $stem = 'pim-eligibility-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $jsonPath = Join-Path $Directory ($stem + '.json')
    $htmlPath = Join-Path $Directory ($stem + '.html')
    $requestPath = Join-Path $Directory ($stem + '-request.txt')
    $Report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $encode = { param($text) [System.Net.WebUtility]::HtmlEncode([string]$text) }
    $title = & $encode "$($Report.User.displayName) <$($Report.User.userPrincipalName)>"
    $notes = ($Report.CoverageNotes | ForEach-Object { '<li>' + (& $encode $_) + '</li>' }) -join ''
    $elig = if ($Report.Eligibilities.Count) {
        $Report.Eligibilities | Select-Object Plane,Name,Access,Scope,State,Start,End,Condition,ConditionVersion |
            ConvertTo-Html -Fragment | Out-String
    } else { '<p>No eligibility records returned. Check coverage below before drawing a conclusion.</p>' }
    $map = if ($Report.GroupRoleMappings.Count) {
        $Report.GroupRoleMappings | ConvertTo-Html -Fragment | Out-String
    } else { '<p>No group-to-Entra-role mapping returned. This does not establish that a group grants no other access.</p>' }
    $checks = $Report.Checks | ConvertTo-Html -Fragment | Out-String
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PIM eligibility report</title><style>
body{font:16px system-ui,sans-serif;margin:32px;color:#172033;background:#f5f7fb}main{max-width:1400px;margin:auto}
h1{margin-bottom:6px}h2{margin-top:32px}.status{padding:16px;border-left:5px solid #c87800;background:#fff4dc}
table{border-collapse:collapse;width:100%;background:white;font-size:14px}th,td{padding:10px;text-align:left;border:1px solid #d8dfe8;vertical-align:top;overflow-wrap:anywhere}
th{background:#e7edf5}li{margin:8px 0}.scroll{overflow:auto}footer{margin-top:24px;color:#536174}
</style></head><body><main><h1>PIM eligibility</h1><p>$title</p>
<p>Tenant: $(& $encode $Report.TenantId) | Generated UTC: $(& $encode $Report.GeneratedUtc)</p>
<p class="status">$(& $encode $Report.Status). Read-only inspection: no access granted or activated.</p>
<h2>Eligibility found</h2><p>Eligible now means the eligibility dates include today, not that activation is approved or currently active. A blank end date means no end date was returned.</p><div class="scroll">$elig</div>
<h2>Roles attached to eligible groups</h2><div class="scroll">$map</div>
<h2>What was checked</h2><div class="scroll">$checks</div><h2>Coverage and interpretation</h2><ul>$notes</ul>
<footer>This report contains identity and access information. Share only with authorized reviewers.</footer></main></body></html>
"@
    $html | Set-Content -LiteralPath $htmlPath -Encoding utf8
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('REFERENCE ACCESS CHECKLIST - for review, not an automatic grant request')
    $lines.Add("Reference user: $($Report.User.userPrincipalName)")
    $lines.Add("Tenant: $($Report.TenantId)")
    $lines.Add("Coverage: $($Report.Status)")
    $lines.Add('Confirm which items are needed for your work. This does not compare your existing access.')
    foreach ($e in $Report.Eligibilities | Where-Object { $_.State -eq 'Eligible now' }) {
        $lines.Add("[ ] $($e.Plane): $($e.Name); access=$($e.Access); scope=$($e.Scope); source ends=$($e.End)")
        if ($e.Condition) { $lines.Add("    Preserve condition ($($e.ConditionVersion)): $($e.Condition)") }
    }
    foreach ($c in $Report.Checks | Where-Object { $_.Status -ne 'Read' }) {
        $lines.Add("CHECK REQUIRED: $($c.Area) / $($c.Scope): $($c.Detail)")
    }
    $lines | Set-Content -LiteralPath $requestPath -Encoding utf8
    return [pscustomobject]@{ Html = [IO.Path]::GetFullPath($htmlPath); Json = [IO.Path]::GetFullPath($jsonPath); Checklist = [IO.Path]::GetFullPath($requestPath) }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        if (-not $User -or $TenantId -eq [guid]::Empty) { throw 'Use -User <exact-UPN-or-object-ID> -TenantId <directory-GUID>. Run Get-Help on this file for examples.' }
        $script:RoTenant = $TenantId.ToString()
        Connect-RoGraph $script:RoTenant -ExistingOnly:$UseExistingGraphSession -DeviceCode:$UseDeviceCode
        $report = New-RoPimReport -UserRef $User -ExpectedTenant $script:RoTenant -WithoutAzure:$SkipAzure `
            -FallbackGroups $GroupId -EnumerateGroups:$ScanAllGroups -Scopes $AzureScope
        $paths = Export-RoPimReport $report $OutDir
        Write-Host "`n$($report.Status)"
        $report.Eligibilities | Format-Table Plane,Name,Access,State,Scope -AutoSize | Out-Host
        $report.Checks | Where-Object { $_.Status -ne 'Read' } | Format-Table Area,Scope,Status,Detail -Wrap | Out-Host
        Write-Host "Report:    $($paths.Html)"
        Write-Host "Checklist: $($paths.Checklist)"
        Write-Host "JSON:      $($paths.Json)"
        if ($report.Status -like 'PARTIAL*') { exit 2 }
        exit 0
    } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
