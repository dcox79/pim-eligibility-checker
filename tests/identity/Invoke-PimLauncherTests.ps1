#requires -Version 5.1
# All sign-ins, reads, exports, and browser launches are mocked. No cloud access.
$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/Start-PimEligibility.ps1'
$tenant = '11111111-1111-1111-1111-111111111111'
$results = [System.Collections.Generic.List[object]]::new()
function Assert-That { param([bool]$Condition, [string]$Message = 'Assertion failed'); if (-not $Condition) { throw $Message } }
function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & {
            . $launcher
            $azureLogin = ${function:Connect-PimLauncherAzure}
            $script:answers = [System.Collections.Generic.Queue[string]]::new()
            @($tenant, 'reference@example.com', 'n', '') | ForEach-Object { $script:answers.Enqueue($_) }
            $script:calls = [System.Collections.Generic.List[string]]::new()
            $script:status = 'Reads completed'
            $script:withoutAzure = $false
            $script:device = $false
            $script:messages = [System.Collections.Generic.List[string]]::new()
            function Read-Host { if (-not $script:answers.Count) { throw 'Unexpected prompt' }; $script:answers.Dequeue() }
            function Write-Host { param($Object, $ForegroundColor); $script:messages.Add([string]$Object) }
            function Write-Warning { }
            function Get-Module { $true }
            function Initialize-RoAz { throw 'Unmocked Azure boundary' }
            function Connect-PimLauncherAzure { param($Tenant,$DeviceCode); $script:calls.Add('Azure'); Assert-That ($Tenant -eq $tenant); $script:device = $DeviceCode }
            function Connect-RoGraph { param($ExpectedTenant,[switch]$DeviceCode); $script:calls.Add('Graph'); Assert-That ($ExpectedTenant -eq $tenant); $script:device = [bool]$DeviceCode }
            function New-RoPimReport { param($UserRef,$ExpectedTenant,[switch]$WithoutAzure); $script:calls.Add('Read'); Assert-That ($ExpectedTenant -eq $tenant -and $UserRef -eq 'reference@example.com'); $script:withoutAzure = [bool]$WithoutAzure; @{ Status = $script:status } }
            function Export-RoPimReport { param($Report); $script:calls.Add('Export'); @{ Html = 'C:\Synthetic Reports\report.html'; Checklist = 'checklist.txt'; Json = 'report.json' } }
            function Start-Process { param($FilePath,$ErrorAction); $script:calls.Add('Open'); Assert-That ($FilePath -eq 'C:\Synthetic Reports\report.html') }
            & $Body
        }
        $results.Add([pscustomobject]@{ Test = $Name; Result = 'PASS' })
    } catch { $results.Add([pscustomobject]@{ Test = $Name; Result = 'FAIL'; Error = $_.Exception.Message }) }
}
Invoke-Case 'Graph-only run skips Azure login and opens the exact exported report' {
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 0)
    Assert-That (($script:calls -join ',') -eq 'Graph,Read,Export,Open' -and $script:withoutAzure)
}
Invoke-Case 'Default includes Azure and device-code choice reaches both sign-ins' {
    $script:answers.Clear()
    @($tenant, 'reference@example.com', '', 'y') | ForEach-Object { $script:answers.Enqueue($_) }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 0)
    Assert-That (($script:calls -join ',') -eq 'Azure,Graph,Read,Export,Open' -and -not $script:withoutAzure -and $script:device)
}
Invoke-Case 'Invalid tenant, user, and choices are retried before sign-in' {
    $script:answers.Clear()
    @('bad', '00000000-0000-0000-0000-000000000000', $tenant, 'display name', 'reference@example.com', 'maybe', 'n', 'no') | ForEach-Object { $script:answers.Enqueue($_) }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 0)
    Assert-That ($script:answers.Count -eq 0 -and $script:withoutAzure)
}
Invoke-Case 'Partial results are opened with a visible warning and exit 2' {
    $script:status = 'PARTIAL - read denied'
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 2)
    Assert-That ($script:calls.Contains('Open') -and ($script:messages -join ' ') -match 'Some areas were skipped')
}
Invoke-Case 'Failed reads do not open an old report' {
    function New-RoPimReport { throw 'Read failed' }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 1)
    Assert-That (-not $script:calls.Contains('Export') -and -not $script:calls.Contains('Open'))
}
Invoke-Case 'Missing Graph module explains setup without sign-in' {
    function Get-Module { $null }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 1)
    Assert-That ($script:calls.Count -eq 0 -and ($script:messages -join ' ') -match 'Install-Module')
}
Invoke-Case 'Quit stops before authentication' {
    $script:answers.Clear(); $script:answers.Enqueue('q')
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 1)
    Assert-That ($script:calls.Count -eq 0)
}
Invoke-Case 'Browser failure preserves successful report result and printed path' {
    function Start-Process { throw 'No file association' }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 0)
    Assert-That (($script:messages -join ' ') -match 'Synthetic Reports')
}
Invoke-Case 'Azure sign-in failure stops all reads and exports' {
    $script:answers.Clear()
    @($tenant, 'reference@example.com', 'y', '') | ForEach-Object { $script:answers.Enqueue($_) }
    function Connect-PimLauncherAzure { throw 'Sign-in cancelled' }
    Assert-That ((Invoke-PimEligibilityLauncher) -eq 1)
    Assert-That ($script:calls.Count -eq 0)
}
Invoke-Case 'Azure login passes only the selected tenant and sign-in flags' {
    function Initialize-RoAz { $script:RoAzExe = 'Invoke-FakeAz'; $script:RoAzPrefix = @() }
    function Invoke-RoAzCommand { @{ name = 'AzureCloud' } }
    function Invoke-FakeAz { $script:loginArguments = $args; $script:LASTEXITCODE = 0 }
    & $azureLogin -Tenant $tenant -DeviceCode $true
    Assert-That (($script:loginArguments -join ' ') -eq "login --tenant $tenant --allow-no-subscriptions --output none --use-device-code")
}
Invoke-Case 'Failed native Azure sign-in is not accepted' {
    function Initialize-RoAz { $script:RoAzExe = 'Invoke-FakeAz'; $script:RoAzPrefix = @() }
    function Invoke-RoAzCommand { @{ name = 'AzureCloud' } }
    function Invoke-FakeAz { $script:LASTEXITCODE = 1 }
    $caught = $false
    try { & $azureLogin -Tenant $tenant -DeviceCode $false } catch { $caught = $_.Exception.Message -match 'sign-in failed' }
    Assert-That $caught
}
Invoke-Case 'Non-public Azure cloud is refused before login' {
    function Initialize-RoAz { $script:RoAzExe = 'Invoke-FakeAz' }
    function Invoke-RoAzCommand { @{ name = 'AzureUSGovernment' } }
    function Invoke-FakeAz { throw 'Login must not happen' }
    $caught = $false
    try { & $azureLogin -Tenant $tenant -DeviceCode $false } catch { $caught = $_.Exception.Message -match 'Only public Azure cloud' }
    Assert-That $caught
}
$results | Format-Table -AutoSize | Out-Host
$bad = @($results | Where-Object Result -eq 'FAIL')
if ($bad.Count) { $bad | Format-List | Out-Host; exit 1 }
Write-Output "$($results.Count) launcher checks passed on PowerShell $($PSVersionTable.PSVersion)"
