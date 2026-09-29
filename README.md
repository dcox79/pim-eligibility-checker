# PIM Eligibility Checker

Inspect a reference user's Microsoft PIM eligibility without granting, removing, or activating access.

The standalone PowerShell script creates an HTML report, a text checklist for reviewing access requests,
and a JSON evidence file. Failed reads are marked **PARTIAL**, not mistaken for no access.

## Requirements

- **Windows with PowerShell 7 recommended**, or Windows PowerShell 5.1. Other operating systems have not been validated.
- **Microsoft.Graph.Authentication** for Microsoft sign-in and read-only Graph requests.
- **Azure CLI** for Azure resource eligibility. Omit it when using `-SkipAzure`.
- The organization's **Tenant ID** and the reference user's **full sign-in name or object ID**.
- An organization with PIM available and an account authorized to inspect the relevant user/groups/scopes.
  An administrator may need to approve the Graph application's read permissions. App consent and
  the inspecting account's roles are separate requirements.

Global Reader is one supported reader role for the directory/group APIs, but is not a guarantee
that every query is permitted. Azure resource visibility requires separate Azure read access.
See the [permission guide](handoff/pim-eligibility-readonly.md#permissions-your-administrator-may-need-to-enable)
and Microsoft's [directory eligibility](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleeligibilityscheduleinstances?view=graph-rest-1.0)
and [group eligibility](https://learn.microsoft.com/en-us/graph/api/privilegedaccessgroup-list-eligibilityscheduleinstances?view=graph-rest-1.0) documentation.
PIM licensing is separate from this script; see [Microsoft's licensing requirements](https://learn.microsoft.com/en-us/entra/id-governance/licensing-fundamentals).

## Quick start

**Easiest on Windows:** download the release ZIP, extract it, and double-click
`Start-PimEligibility.cmd`. Enter the organization's Tenant ID and the user's full sign-in
name, choose whether to include Azure resource roles, then sign in. The report opens automatically.
The console stays open so you can read errors or copy the checklist location. Enter Q to quit.

Prerequisites still apply: install the Graph module once using the command below. Azure CLI
is optional if you choose N for Azure roles. The launcher handles Azure sign-in when selected;
it does not install software, change execution policies, or request write permissions.
If your organization blocks scripts, follow its approved process. For a downloaded file blocked
by Windows, review it first and use the file's Properties > Unblock if permitted.

### Command-line alternative

Download or clone this repository, open PowerShell in its folder, then:

```powershell
# Once, if the module is not already installed:
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# For Azure resource roles, sign in to your intended organization:
az login --tenant '<your-directory-guid>'

# Inspect the reference user:
.\scripts\Get-PimEligibility.ps1 -User 'reference-admin@example.com' -TenantId '<your-directory-guid>'
```

For Entra roles and PIM groups only, add `-SkipAzure`. Use `-UseDeviceCode` if you need device-code sign-in.
The script refuses a Graph/Azure context pointing to a different tenant. It supports public Microsoft/Azure cloud only.

The command prints where it saved the report and checklist. Default storage is
`%LOCALAPPDATA%/PIM-Automation/eligibility/`. Reports stay local and may contain sensitive identity data.
The supplied `.gitignore` excludes generated reports and local credentials.

Read the [full setup, options, permissions, and troubleshooting guide](handoff/pim-eligibility-readonly.md).
The ZIP includes the launcher, scripts, and setup guide. Python is not required to run them.

## Coverage and limits

- Direct Microsoft Entra administrator-role eligibility.
- Eligible PIM group membership and ownership, kept distinct; Entra roles attached to groups are explained separately.
- Direct Azure-resource eligibility in visible scopes, retaining assignment conditions and dates.
- A per-query coverage record, including denied/skipped areas and partial paging results.

This is not a complete effective-access audit: it does not expand ordinary standing access,
current/nested group-derived eligibility, or Azure/application permissions conveyed by eligible groups.
Eligibility is not active access. The checklist does not compare your own permissions or automatically
recommend copying every privilege. Visible scope coverage is not proof of tenant-wide visibility.

## Read-only design

The script is independent of any provisioning engine. It exposes no grant, activation, deletion,
or apply command. Its Graph and ARM data requests are GET-only, and it requests only Graph read scopes.
It follows paging links only on the expected Microsoft host. It writes local report files and uses
normal Microsoft authentication; it does not upload reports.

## Validation

**Initial release: offline-tested, not yet validated against a live tenant.**

The behavioral suite exercises 21 scenarios on PowerShell 7 and Windows PowerShell 5.1, including
wrong-tenant refusal, GET-only transports, permission errors, paging failures, fallback group discovery,
condition preservation, schedule dates, and HTML escaping. All identities in tests are synthetic.
No Azure account, Graph module, cloud credentials, or live tenant is needed to run the tests.

```powershell
pwsh -NoProfile -File tests/identity/Invoke-PimEligibilityTests.ps1 -ArtifactDirectory reports/test-pwsh
powershell -NoProfile -File tests/identity/Invoke-PimEligibilityTests.ps1 -ArtifactDirectory reports/test-ps51
```

The GitHub Actions workflow runs these checks in both PowerShell editions with read-only repository permissions.
It also runs 12 offline launcher checks in each edition, including input validation, cancellation,
tenant-specific sign-in, skipped Azure checks, partial results, and failed sign-in/report handling.
Optional Python wrapper and source-boundary checks:

```powershell
python -m pip install -r requirements-dev.txt
python -B -m pytest -q tests/identity/test_pim_eligibility_readonly.py
```

Exit codes: `0` = reads completed within declared visibility; `2` = partial report exported;
`1` = startup, user lookup, or report export failure.
