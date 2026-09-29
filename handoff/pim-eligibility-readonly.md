# Read-only PIM eligibility checker

Use this to inspect a reference user's PIM eligibility and prepare a list of access to discuss
with your administrator. It never grants, removes or activates access. It writes local reports.

## Run it

### Windows launcher

Extract the release ZIP and double-click **Start-PimEligibility.cmd**. Install the Graph
module below first if it is missing. Enter your Tenant ID and the full sign-in name of the
user to inspect. Choose whether to include Azure resource roles (requires Azure CLI), then
choose browser or device-code sign-in. Sign in with your own authorized inspecting account.
The launcher signs Azure CLI into the selected tenant when Azure roles are selected, runs
the read-only check, and opens the HTML report. It prints the checklist and JSON locations too.
It uses PowerShell 7 if available, otherwise Windows PowerShell 5.1. No separate Python install
is needed. Enter Q at a prompt to cancel; close the console when finished.

The launcher does not install prerequisites or change execution policies. Follow your
organization's script policy. If Windows blocks a downloaded file, review it and use
Properties > Unblock on the downloaded ZIP before extracting, if your policy permits.
Managed restrictions still apply. You can also run `./scripts/Start-PimEligibility.ps1`
from an existing PowerShell window.

### Command-line use

You only need `Get-PimEligibility.ps1`; the cloning scripts and tenant templates are not required.
Prefer PowerShell 7. Windows PowerShell 5.1 is also tested with mocked APIs.

Install the Graph sign-in module if needed:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

For Azure resource roles, also install Azure CLI and sign in to the organization you want to inspect:

```powershell
az login --tenant '<your-directory-guid>'
```

A **directory GUID** identifies the Microsoft organization. You can find it in Microsoft Entra's
overview page as **Tenant ID**, or inspect your current Azure login with:

```powershell
az account show --query tenantId --output tsv
```

From the folder containing the checker script (the `scripts` folder in the release ZIP):

```powershell
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<your-directory-guid>'
```

Replace both examples with real values. Use the reference user's full sign-in name or object ID,
not their display name. The script opens Microsoft sign-in if Graph is not already connected.
Use an account approved to read that organization's access information.

In this project, the script is in `scripts`, so use `./scripts/Get-PimEligibility.ps1`.
The release ZIP contains the launcher, a `scripts` folder, and this guide; extract it before running.

## What you receive

- **HTML report:** open in a browser; shows role/group names, scope, eligibility dates and coverage.
- **Request checklist:** a text list of currently dated eligibilities to review with your admin.
- **JSON:** structured evidence for troubleshooting or later comparison.

The command prints the file locations. By default they are saved under
`%LOCALAPPDATA%/PIM-Automation/eligibility/`. Use `-OutDir 'C:\path\to\private-folder'` to choose
another location. Reports contain identity/access data; they are not published or sent anywhere.

**Eligible now** means the assignment's dates include today. It does not mean the role is
activated, that activation will succeed, or that another user should receive the same access.
An empty end date means the API did not return one. Future/expired entries stay in the report
but are excluded from the request checklist. The checklist does not compare your own access.

## What is checked

| Area | Coverage |
|---|---|
| Microsoft Entra administrator roles | Direct role eligibility for the exact user, including returned directory/application scopes |
| PIM groups | Eligible membership and ownership kept separate; role names attached to those groups in Entra are explained separately |
| Azure resource roles | Direct eligibility from visible enabled subscriptions and visible management groups; returned assignment conditions are preserved |

This is an eligibility report, not a full access audit. It does not enumerate ordinary standing
access, expand current/nested group-derived eligibility, or resolve Azure/application permissions
conveyed by eligible groups. Requesting a group eligibility by its displayed group name/ID is still
possible without inferring which roles it grants. Group ownership does not automatically convey
the group's member permissions.

The checker cannot prove visibility into scopes your inspecting account cannot see. The coverage
section shows each attempted read and its result. Failed reads and skipped areas produce **PARTIAL**,
not a claim that no access exists. No write-permission fallback is attempted.

## Useful options

```powershell
# Entra and PIM groups only; Azure is explicitly marked not checked.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -SkipAzure

# Use a device code instead of browser sign-in when creating a Graph session.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -UseDeviceCode

# Do not open a sign-in prompt; use an existing Graph session in the specified tenant.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -UseExistingGraphSession

# If the broad group query is denied, check particular known groups.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -GroupId '<group-guid>'

# Alternatively, try every cloud, non-dynamic group. This may take a long time.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -ScanAllGroups

# Limit Azure reads to an approved scope.
.\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<guid>' -AzureScope '/subscriptions/<subscription-guid>'
```

`-AzureScope` accepts subscription, resource-group or management-group scopes. Explicit scopes
limit coverage. Scope validation excludes subscriptions outside the selected tenant's enabled
inventory. Group fallback results retain a partial-coverage warning even when useful rows are found.

If Graph is connected to a different organization, the checker stops. In a dedicated PowerShell
session, run `Disconnect-MgGraph`, then rerun with the intended tenant. It never switches tenants
or signs Azure CLI in automatically. Azure failures still allow the Graph report to be exported.
Only public Microsoft/Azure cloud is supported in this release; sovereign environments are refused.

## Permissions your administrator may need to enable

The checker requests only these Graph read permissions:

- `User.Read.All` and `Group.Read.All`: identify the exact user and group names.
- `RoleManagement.Read.Directory`: read directory role eligibility, definitions and group role mappings.
- `PrivilegedEligibilitySchedule.Read.AzureADGroup`: read group eligibility.

Application consent and the inspecting person's assigned role are separate requirements. An
existing session may hold broader permissions, but this script still sends only GET requests.
It does not grant consent, assign an administrator role or escalate to write permissions itself.

Microsoft documents several supported reader roles for [directory eligibility](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleeligibilityscheduleinstances?view=graph-rest-1.0),
and group ownership/membership or supported directory roles for [group eligibility](https://learn.microsoft.com/en-us/graph/api/privilegedaccessgroup-list-eligibilityscheduleinstances?view=graph-rest-1.0).
Global Reader is among the documented reader roles; a broader directory-wide group query may
still be refused, in which case the group-scoped fallback can provide useful results. Have the
administrator choose the least privilege appropriate to the actual operations.

Azure eligibility reads require authorization at the queried Azure scopes. Existing Reader
access may cover the required management-plane reads, but Entra reader roles alone do not grant
Azure resource visibility. [Azure eligibility API reference](https://learn.microsoft.com/en-us/rest/api/authorization/role-eligibility-schedule-instances/list-for-scope?view=rest-authorization-2020-10-01).

## Validation and exit codes

This is a new standalone reader; it does not call the reviewed grant engine. Behavioral tests use
synthetic identities and mocked APIs on both PowerShell 5.1 and 7. They cover tenant mismatch,
GET-only transports, permission failures, pagination, group fallback, condition retention,
date handling and HTML/report generation. No live tenant run has been performed for this delivery.

- `0`: reads completed within the declared/visible scope; not a guarantee of tenant-wide visibility.
- `2`: report exported with failed or skipped areas.
- `1`: startup, exact user lookup or local export failed.

If a sign-in/consent error appears, request the necessary read access from your administrator;
do not substitute a write permission simply to make a read-only report work.
