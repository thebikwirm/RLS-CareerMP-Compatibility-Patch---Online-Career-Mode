local M = {}
local saved
local source = "careerDynoControls"

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

local function zeroForce()
  local id = hydros.getFFBID()
  if id and id >= 0 then
    -- Disabling future sends alone can leave the last torque held by the driver.
    hydros.getForceFeedbackFunction()(obj, id, 0, 0, 0, 0)
  end
end

local function enforce()
  if not saved then return end
  hydros.enableFFB = false
  input.allowedInputSources.steering = {[source] = true}
  input.event("steering", 0, FILTER_DIRECT or 1, nil, nil, nil, source)
  input.steering = 0
  electrics.values.steering = 0
  electrics.values.steering_input = 0
end

local function protect(nativeConfig)
  if extensions and extensions.load then
    extensions.load("careerDynoLoad")
    careerDynoLoad.activate()
  end
  if not saved then
    saved = {ffb = hydros.enableFFB, sources = copy(input.allowedInputSources.steering),
      inputSource = input.state.steering and input.state.steering.source or "local",
      nativeConfig = copy(nativeConfig)}
  elseif nativeConfig then
    saved.nativeConfig = copy(nativeConfig)
  end
  hydros.enableFFB = false
  zeroForce()
  enforce()
end

local function release(nativeConfig)
  if careerDynoLoad then careerDynoLoad.release() end
  if not saved then return end
  local previous = saved
  saved = nil
  zeroForce()
  -- Native FFB configuration refresh clears its safety smoother, ramping output
  -- from zero again. This touches runtime state only, never the saved bindings.
  local config = nativeConfig or previous.nativeConfig
  if config then hydros.onFFBConfigChanged(config) end
  hydros.enableFFB = previous.ffb
  input.allowedInputSources.steering = previous.sources
  local last = input.lastInputs and input.lastInputs[previous.inputSource]
  input.event("steering", last and last.steering or 0, FILTER_DIRECT or 1,
    nil, nil, nil, previous.inputSource)
end

local function onReset()
  if saved then zeroForce(); enforce() end
end

M.protect = protect
M.release = release
M.updateGFX = enforce
M.onReset = onReset
M.onExtensionUnloaded = release
M.getState = function() return {active = saved ~= nil, ffbEnabled = hydros.enableFFB,
  steering = input.steering, deviceId = hydros.getFFBID()} end
return M
