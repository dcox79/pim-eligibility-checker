#requires -Version 5.1
# Interactive wrapper around the same standalone, read-only checker.
. (Join-Path $PSScriptRoot 'Get-PimEligibility.ps1')

function Read-PimLauncherValue {
    param([string]$Prompt, [scriptblock]$Validate, [string]$Hint)
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if ($value -ieq 'q') { throw [System.OperationCanceledException]::new('Cancelled. No report created.') }
        if (& $Validate $value) { return $value }
        Write-Host $Hint -ForegroundColor Yellow
    }
}

function Read-PimLauncherChoice {
    param([string]$Prompt, [bool]$Default)
    $value = Read-PimLauncherValue $Prompt { param($v) $v -match '^(y|yes|n|no)?$' } 'Enter Y or N, or Q to quit.'
    if (-not $value) { return $Default }
    return ($value -match '^(y|yes)$')
}

function Connect-PimLauncherAzure {
    param([guid]$Tenant, [bool]$DeviceCode)
    Initialize-RoAz
    if ((Invoke-RoAzCommand -Operation Cloud).name -ne 'AzureCloud') {
        throw 'Only public Azure cloud is supported. Select AzureCloud in Azure CLI before running again.'
    }
    $loginArgs = @($script:RoAzPrefix) + @('login', '--tenant', $Tenant.ToString(), '--allow-no-subscriptions', '--output', 'none')
    if ($DeviceCode) { $loginArgs += '--use-device-code' }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue' # Windows PowerShell can treat CLI sign-in messages on stderr as errors.
        & $script:RoAzExe @loginArgs | Out-Host
        $loginExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($loginExitCode -ne 0) { throw 'Azure sign-in failed. Run again, or choose N for Azure resource roles.' }
}

function Invoke-PimEligibilityLauncher {
    $ErrorActionPreference = 'Stop'
    try {
        Write-Host "`nPIM Eligibility Checker - read only" -ForegroundColor Cyan
        Write-Host 'No access is granted or activated. Enter Q at any prompt to quit.'
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
            throw 'First run this in PowerShell, then reopen the launcher: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
        }
        $tenantText = Read-PimLauncherValue 'Organization Tenant ID (directory GUID)' {
            param($v)
            $parsed = [guid]::Empty
            [guid]::TryParse($v, [ref]$parsed) -and $parsed -ne [guid]::Empty
        } 'Use the Tenant ID from Microsoft Entra Overview (a GUID, not the organization name).'
        $userRef = Read-PimLauncherValue 'User to inspect (full sign-in name or object ID)' {
            param($v)
            $parsed = [guid]::Empty
            ($v -match '^[^\s@]+@[^\s@]+$') -or ([guid]::TryParse($v, [ref]$parsed) -and $parsed -ne [guid]::Empty)
        } 'Enter the full sign-in name, such as reference-admin@example.com, or a user object GUID.'
        $includeAzure = Read-PimLauncherChoice 'Also check Azure resource roles? Requires Azure CLI [Y/n]' $true
        $deviceCode = Read-PimLauncherChoice 'Use device-code sign-in instead of browser sign-in? [y/N]' $false
        $script:RoTenant = ([guid]$tenantText).ToString()
        if ($includeAzure) {
            Write-Host 'Signing in to Azure for the selected organization...'
            Connect-PimLauncherAzure -Tenant $script:RoTenant -DeviceCode $deviceCode
        }
        Write-Host 'Sign in with an account allowed to read this user''s eligibility.'
        Connect-RoGraph -ExpectedTenant $script:RoTenant -DeviceCode:$deviceCode
        $report = New-RoPimReport -UserRef $userRef -ExpectedTenant $script:RoTenant -WithoutAzure:(-not $includeAzure)
        $paths = Export-RoPimReport -Report $report
        Write-Host "`n$($report.Status)"
        Write-Host "Report:    $($paths.Html)"
        Write-Host "Checklist: $($paths.Checklist)"
        Write-Host "JSON:      $($paths.Json)"
        if ($report.Status -like 'PARTIAL*') {
            Write-Host 'Some areas were skipped or could not be read. Review What was checked in the report.' -ForegroundColor Yellow
        }
        try { Start-Process -FilePath $paths.Html -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Report saved, but could not open automatically. Open this file: $($paths.Html)" }
        if ($report.Status -like 'PARTIAL*') { return 2 }
        return 0
    } catch [System.OperationCanceledException] {
        Write-Host $_.Exception.Message
        return 1
    } catch {
        Write-Host "`nCould not finish: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-PimEligibilityLauncher) }
