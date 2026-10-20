"""RLS 2.7.2 garage/insurance source contract for CareerMP 0.39.

The 2.6.7 compatibility versions of these modules must not replace newer
2.7.2 code. Check the APIs we depend upon before making a test build.
"""
from __future__ import annotations

GARAGE = "lua/ge/extensions/career/modules/garageManager.lua"
INSURANCE = "lua/ge/extensions/overrides/career/modules/insurance/insurance.lua"
REPAIR = "lua/ge/extensions/overrides/career/modules/insurance/repairScreen.lua"

def verify_rls_272_garage_insurance(entries: dict[str, bytes]) -> None:
    missing = [p for p in (GARAGE, INSURANCE, REPAIR) if p not in entries]
    if missing:
        raise RuntimeError("Missing RLS 2.7.2 garage/insurance modules: " + ", ".join(missing))
    garage, insurance, repair = (entries[p].decode("utf-8") for p in (GARAGE, INSURANCE, REPAIR))

    if "career_saveSystem.getCurrentSaveSlot(" in garage or "career_saveSystem.getCurrentSaveSlot(" in insurance:
        raise RuntimeError("Legacy save-slot API reintroduced into 2.7.2 garage/insurance")
    for label, src in (("garage", garage), ("insurance", insurance)):
        if "career_saveSystem.getCurrentProfile()" not in src:
            raise RuntimeError("Missing current-profile access in 2.7.2 " + label)
    if 'getFacilityIfExists("garage", loc)' not in garage:
        raise RuntimeError("2.7.2 cross-map garage preservation missing")
    if "not locOnCurrentMap" not in garage:
        raise RuntimeError("2.7.2 cross-map garage location guard missing")
    if "M.onCareerActive = onCareerActive" not in insurance:
        raise RuntimeError("2.7.2 insurance career activation hook missing")
    if "career_modules_inventory" not in insurance or "career_modules_inventory" not in garage:
        raise RuntimeError("2.7.2 garage/insurance inventory integration missing")
    if "career_modules_insurance" not in repair and "insurance" not in repair.lower():
        raise RuntimeError("2.7.2 repair screen no longer refers to insurance")
    print("  - RLS 2.7.2 garage/insurance profile, cross-map and inventory contracts verified")
