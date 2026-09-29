# Changelog

## 1.1.1 - 2026-09-29

- Request required Graph read permissions when an existing session lacks them.
- Show requested scopes and actionable administrator-consent guidance.
- Preserve explicit no-prompt mode and wrong-tenant rejection.
- Add six offline consent/session regressions; live tenant consent remains unverified.

## 1.1.0 - 2026-09-29

- Windows double-click launcher prompts for tenant, user, Azure coverage, and sign-in method.
- Opens the exact saved HTML report; preserves partial-result warnings and visible errors.
- Signs Azure CLI into the chosen tenant when requested; no dependency installation or policy changes.
- 12 offline launcher checks in each supported PowerShell edition. Live tenant validation remains pending.

## 1.0.0 - 2026-09-29

- Standalone read-only user PIM eligibility inspection for Microsoft public cloud.
- Direct Entra/Azure role eligibility and PIM group membership/ownership eligibility.
- HTML and JSON evidence plus a text access-review checklist.
- Explicit tenant matching, GET-only transport, pagination checks, and partial-coverage reporting.
- Synthetic behavioral tests for PowerShell 5.1 and 7; live tenant validation is pending.
