"""Quarantine old CareerMP 0.39 vanilla-career runtime patches under RLS 2.8.

The old wrappers target stock modules with different lifecycles and should
not run on Overhaul. This intentionally disables old garage interceptors until
equivalent RLS-native hooks are individually reviewed.
"""
from __future__ import annotations

PATCHES = "lua/ge/extensions/careerMP/patches.lua"

def patch_overhaul_only_runtime(entries: dict[str, bytes]) -> None:
    if PATCHES not in entries:
        raise RuntimeError("CareerMP runtime patcher missing")
    source = entries[PATCHES].decode("utf-8").replace("\r\n", "\n")
    marker = "-- CareerMP040 disable legacy vanilla career runtime wrappers"
    if marker in source:
        return
    anchor = 'local logTag = "careerMP.patches"'
    if source.count(anchor) != 1:
        raise RuntimeError("CareerMP runtime patcher source changed")
    source = source.replace(anchor, anchor + '\n' + marker, 1)
    old_apply = '''function M.apply()
\tif applied then return true end'''
    new_apply = '''function M.apply()
  -- Overhaul 2.8 owns separate inventory, insurance, tuning, paint and
  -- computer extensions; patching stock career modules here would be unsafe.
  applied = true
  return true
end

-- Legacy implementation retained for later source rebase, but never called.
local function legacyApply()
\tif applied then return true end'''
    if source.count(old_apply) != 1:
        raise RuntimeError("CareerMP patcher apply hook changed")
    source = source.replace(old_apply, new_apply, 1)
    # On unload, M.revert() still safely handles zero originals. The updater
    # sees 'applied=true' and does not retry stale module hooks.
    entries[PATCHES] = source.encode("utf-8")
