"""Quarantine legacy per-part paint until an RLS-native inventory port exists.

The 0.39 extension dereferences career_modules_inventory on vehicle spawn,
which does not exist in RLS 2.8. A no-op prevents the Lua error without
silently altering RLS paint, inventory or player vehicles.
"""
from __future__ import annotations

PAINT = "lua/ge/extensions/careerMPPerPartPaint.lua"

def patch_legacy_paint(entries: dict[str, bytes]) -> None:
    if PAINT not in entries:
        raise RuntimeError("Expected CareerMP legacy paint extension missing: " + PAINT)
    source = entries[PAINT].decode("utf-8-sig")
    marker = "-- CareerMP040: legacy per-part paint disabled for RLS-only mode"
    if marker in source:
        return
    if "career_modules_inventory" not in source:
        raise RuntimeError("Legacy CareerMP paint source no longer uses vanilla inventory; re-audit before disabling")
    entries[PAINT] = (marker + """
-- TODO: implement equivalent hooks against RLS Overhaul inventory
-- after confirming RLS paint lifecycle and multiplayer ownership checks.
local M = {}
-- The CareerMP vehicle-ready dispatch invokes this method directly.
-- Keep the API available while disabling legacy vanilla-career paint logic.
function M.onVehicleReady(...) return nil end
return M
""").encode("utf-8")
