local M = {}

function M.isDevToolsEnabled()
  local em = rawget(_G, "overhaul_extensionManager")
  return em and em.isDevKeyValid and em.isDevKeyValid() or false
end

function M.requireDevTools()
  if not M.isDevToolsEnabled() then
    return false, "dev_tools_disabled"
  end
  return true
end

function M.isEnabled()
  if not M.isDevToolsEnabled() then
    return false
  end
  local settings = rawget(_G, "overhaul_settings")
  if not (settings and settings.getSetting) then
    return false
  end
  return settings.getSetting("racingTeamDevConsole") == true
end

function M.requireEnabled()
  if not M.isEnabled() then
    return false, "dev_console_disabled"
  end
  return true
end

local DEV_TOOLS_MESSAGE = "Dev tools require a valid dev key."

function M.devToolsDisabledResult()
  return {success = false, message = DEV_TOOLS_MESSAGE}
end

function M.devToolsDisabledInvariantResult()
  return {success = false, failures = {DEV_TOOLS_MESSAGE}, checks = 0}
end

return M
