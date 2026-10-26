"""Add a CareerMP Save Career button to the existing RLS pause menu.

Only visible for negotiated multiplayer sessions. Calls RLS's own local save
function, never a BeamMP server-side data write.
"""
from __future__ import annotations

PAUSE = "lua/ge/extensions/overhaul/ui/pause.lua"
ANCHOR = '  return {\n    {id = "progress", label = "Skills"'
INSERT = '''  -- CareerMP040 Save Career button: local RLS profile only.
  local mp = type(extensions) == "table" and rawget(extensions, "careerMPEnabler")
  local negotiated = mp and type(mp.isOverhaulModeNegotiated) == "function"
    and mp.isOverhaulModeNegotiated()
  local tabs = {
    {id = "progress", label = "Skills"'''
OLD_END = '''    }},
  }
end

-- Tab ids this file registered'''
NEW_END = '''    }},
  }
  if negotiated then
    tabs[#tabs + 1] = {id = "careermp", label = "CareerMP", icon = "floppyDisk", buttons = {
      {id = "careermp.save", label = "Save Career", icon = "floppyDisk",
        componentName = ACTION_CARD,
        props = {title = "Save Career", description = "Save your local RLS career profile.",
          actionLabel = "Save Now",
          action = 'if overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() then local ok = overhaul_shell_gameMode.save(); if not ok then guihooks.trigger("toastrMsg", {type="warning", title="Career save", msg="Save not accepted; check the BeamNG log."}) end end'}},
    }}
  end
  return tabs
end

-- Tab ids this file registered'''

def patch_pause_save(entries: dict[str, bytes]) -> None:
    if PAUSE not in entries:
        raise RuntimeError("RLS pause menu extension missing")
    s = entries[PAUSE].decode("utf-8")
    if "-- CareerMP040 Save Career button:" in s:
        return
    if s.count(ANCHOR) != 1 or s.count(OLD_END) != 1:
        raise RuntimeError("RLS pause menu structure changed")
    s = s.replace(ANCHOR, INSERT, 1).replace(OLD_END, NEW_END, 1)
    entries[PAUSE] = s.encode("utf-8")
