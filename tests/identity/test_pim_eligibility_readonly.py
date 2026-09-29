"""Execute the independent read-only checker's behavioral suite without cloud access."""
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/Get-PimEligibility.ps1"


@pytest.mark.parametrize("shell", ["pwsh", "powershell"])
def test_behavior_in_supported_powershell(shell, tmp_path):
    executable = shutil.which(shell)
    if not executable:
        pytest.skip(f"{shell} is not installed")
    result = subprocess.run(
        [executable, "-NoProfile", "-File",
         str(ROOT / "tests/identity/Invoke-PimEligibilityTests.ps1"),
         "-ArtifactDirectory", str(tmp_path)],
        cwd=ROOT, capture_output=True, text=True, timeout=90,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "27 behavioral checks passed" in result.stdout


def test_checker_has_no_grant_engine_or_write_transports():
    source = SCRIPT.read_text(encoding="utf-8-sig")
    for forbidden in ("CadmAccess.Core.ps1", "CadmProfile.ps1", "Copy-CadmAccess.ps1",
                      "ReadWrite", "adminAssign", "selfActivate", "--method','post",
                      "-Method POST", "-Method PUT", "-Method PATCH", "-Method DELETE"):
        assert forbidden not in source
