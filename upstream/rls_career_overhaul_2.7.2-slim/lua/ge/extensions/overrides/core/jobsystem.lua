-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local coroutines = {}
local runningFct = {}

local disableBackgroundTasks = false
local updating = false

local function create(fct, maxdt, ...)
  if disableBackgroundTasks then
    fct({yield = function() end, sleep = function() end}, unpack({...}))
    return
  end
  local res =  {
    fct = fct,
    t = coroutine.create(fct),
    maxdt = maxdt or 0.01,
    args = {...},
    hp = hptimer(),
  }
  runningFct[fct] = true
  res.yield = function()
    if coroutine.running() == nil then return end
    local dt = res.hp:stop() / 1000
    if dt > res.maxdt then
      coroutine.yield()
      res.hp:reset()
    end
  end
  res.sleep = function(secs)
    if coroutine.running() == nil then return end
    res.hp:reset()
    repeat
      coroutine.yield()
      local dt = res.hp:stop() / 1000
      if dt >= secs then break end
    until false
  end

  res.setExitCallback = function(exitFn)
    res.exitcbl = exitFn
  end

  res.running = true

  table.insert(coroutines, res)
  return res
end

local function wrap(fct, maxdt)
  return function(...)
    if runningFct[fct] then
      return
    end
    create(fct, maxdt, unpack({...}))
  end
end

local toRemove = {}
local completed = {}
local dtTable = {dtReal = 0, dtSim = 0, dtRaw = 0}
local function onUpdate(dtReal, dtSim, dtRaw)
  dtTable.dtReal = dtReal
  dtTable.dtSim = dtSim
  dtTable.dtRaw = dtRaw
  table.clear(toRemove)
  table.clear(completed)
  updating = true
  local count = #coroutines
  for i = 1, count do
    local co = coroutines[i]
    if co and not co._deferRemove then
      local errorfree, value
      if co.args and next(co.args) then
        errorfree, value = coroutine.resume(co.t, co, unpack(co.args))
      else
        errorfree, value = coroutine.resume(co.t, co, dtTable)
      end
      if not errorfree then
        log('E', 'jobsystem', "job error: " .. tostring(value) .. ' / ' .. debug.traceback(co.t))
      end
    end
    co = coroutines[i]
    if co and (co._deferRemove or coroutine.status(co.t) == "dead") then
      table.insert(toRemove, i)
    end
  end
  for i = #toRemove, 1, -1 do
    local ci = toRemove[i]
    local co = coroutines[ci]
    if co then
      if not co._deferRemove then
        runningFct[co.fct] = nil
        co.running = false
        if type(co.exitcbl) == 'function' then
          local ok, err = xpcall(function() co.exitcbl(co) end, debug.traceback)
          if not ok then log('E', 'jobsystem', 'job exit callback error: ' .. tostring(err)) end
        end
        completed[#completed + 1] = co
      end
      table.remove(coroutines, ci)
    end
  end
  for i = #coroutines, 1, -1 do
    if coroutines[i]._deferRemove then table.remove(coroutines, i) end
  end
  updating = false
  for _, co in ipairs(completed) do
    extensions.hook('onJobDone', co, #coroutines)
  end
end

local function getRunningJobCount()
  return #coroutines
end

local function cancelJob(jobHandle)
  if not jobHandle then return false end
  for i = #coroutines, 1, -1 do
    if coroutines[i] == jobHandle then
      if jobHandle._deferRemove then return true end
      runningFct[jobHandle.fct] = nil
      jobHandle.running = false
      if updating then
        jobHandle._deferRemove = true
        return true
      end
      table.remove(coroutines, i)
      return true
    end
  end
  return false
end

local function findFilesAsync(rootPath, pattern, yieldFn)
  yieldFn = yieldFn or nop
  local h = hptimer()
  local results = {}

  local fsFindFiles = FS.findFiles
  local fsDirectoryExists = FS.directoryExists

  local rootMatches = fsFindFiles(FS, rootPath, pattern, 0, true, false)
  for i = 1, #rootMatches do
    results[#results + 1] = rootMatches[i]
  end

  local rootEntries = fsFindFiles(FS, rootPath, "*", 0, false, true)
  for i = 1, #rootEntries do
    local entry = rootEntries[i]
    if fsDirectoryExists(FS, entry) then
      local subtreeMatches = fsFindFiles(FS, entry, pattern, -1, true, false)
      for j = 1, #subtreeMatches do
        results[#results + 1] = subtreeMatches[j]
      end
      yieldFn("findFilesAsync " .. entry)
    end
  end

  h:stop()
  return results
end

M.onUpdate = onUpdate
M.create = create
M.wrap = wrap
M.getRunningJobCount = getRunningJobCount
M.cancelJob = cancelJob
M.findFilesAsync = findFilesAsync
return M
