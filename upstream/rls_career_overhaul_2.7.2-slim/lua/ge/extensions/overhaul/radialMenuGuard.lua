local M = {}

local mismatchFrames = 0
local MISMATCH_FRAMES = 30

local function currentRouteName()
  if not extensions.ui_router or not extensions.ui_router.getCurrent then return nil end
  local entry = extensions.ui_router.getCurrent()
  return entry and entry.request and entry.request.name or nil
end

local function isRadialRoute(name)
  return type(name) == "string" and (name == "radial" or name:sub(1, 7) == "radial.")
end

local function releaseStuckRadial()
  if not core_quickAccess or not core_quickAccess.isEnabled or not core_quickAccess.isEnabled() then
    mismatchFrames = 0
    return
  end

  local name = currentRouteName()
  if not name or isRadialRoute(name) then
    mismatchFrames = 0
    return
  end

  mismatchFrames = mismatchFrames + 1
  if mismatchFrames < MISMATCH_FRAMES then return end
  mismatchFrames = 0

  if not core_quickAccess.isRouteHandoffActive or not core_quickAccess.isRouteHandoffActive() then
    return
  end
  if core_quickAccess.endRouteHandoff then
    core_quickAccess.endRouteHandoff()
  end
  if core_quickAccess.isEnabled() and core_quickAccess.setEnabled then
    core_quickAccess.setEnabled(false)
  end
  log("W", "radialMenuGuard", "Closed a radial menu that was still open after leaving its screen")
end

M.onUpdate = releaseStuckRadial

return M
