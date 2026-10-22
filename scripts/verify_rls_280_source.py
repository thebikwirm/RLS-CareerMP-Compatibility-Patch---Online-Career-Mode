"""Source-level RLS 2.8.0 / BeamNG 0.40 compatibility audit.

Run: python scripts/verify_rls_280_source.py
This uses the slim upstream SOURCE files in Git; it does not claim that
CareerMP or BeamMP is compatible or that a runtime test passed.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "upstream" / "rls_2.8.0_slim"
FILES = {
    "startup": "scripts/rls_career_overhaul/modScript.lua",
    "manager": "lua/ge/extensions/overhaul/shell/extensionManager.lua",
    "career": "lua/ge/extensions/overhaul/career/career.lua",
    "save": "lua/ge/extensions/overhaul/career/saveSystem.lua",
    "phone": "lua/ge/extensions/overhaul/phone/phone.lua",
    "vue_entry": "ui/ui-vue/mods/rls_career_overhaul/index.js",
    "vue_routes": "ui/ui-vue/mods/rls_career_overhaul/overhaul/registerRoutes.js",
}
NEEDED = {
    "startup": ('overhaul_shell_extensionManager', 'core_input_categories'),
    "manager": ('SUPPORTED_GAME_MINOR_VERSION = 40', 'loadCareerCore()', 'loadScope("routes")', 'loadScope("shell")'),
    "vue_entry": ('registerOverhaulRoutes()', 'startPhoneShellState(', 'loadPhoneApps('),
    "vue_routes": ('window.bngRoutes?.add(', 'window.bngRoutes?.remove(', 'buildOverhaulRoutes()'),
}

def verify_source(root: Path = SOURCE) -> dict[str, str]:
    found: dict[str, str] = {}
    for key, path in FILES.items():
        file = root / path
        if not file.is_file():
            raise RuntimeError(f"Missing RLS 2.8.0 source: {file}")
        found[key] = file.read_text(encoding="utf-8-sig")
    for key, markers in NEEDED.items():
        for marker in markers:
            if marker not in found[key]:
                raise RuntimeError(f"RLS 2.8.0 {key} API changed: {marker}")
    if 'deactivateBeamMP()' in found["manager"]:
        raise RuntimeError("RLS 2.8.0 manager unexpectedly contains a BeamMP deactivation call")
    if 'import { getComponent } from "@/services/modManager"' in found["vue_entry"]:
        raise RuntimeError("Old Vue 0.39 modManager import detected")
    return found

if __name__ == "__main__":
    result = verify_source()
    print(f"PASS: checked {len(result)} RLS 2.8.0 source files for 0.40 compatibility contracts")
    print("No ZIP built and no gameplay compatibility implied.")
