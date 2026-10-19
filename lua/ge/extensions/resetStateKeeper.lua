-- Preserve selected runtime vehicle state when the player resets/repairs a vehicle.
-- Tested only by static review in this package; run in BeamNG.drive to validate API compatibility.

local M = {}

local POLL_INTERVAL = 0.20
local RESET_FIRST_DELAY = 0.18
local RESET_SECOND_DELAY = 0.25
local RESET_SETTLE_DELAY = 0.45
local INVALID_TEMP = -1000000
local CONFIG_PATH = "settings/resetStateKeeper.json"
local DEFAULT_FUEL_MULTIPLIER = 1.0
local MAX_FUEL_MULTIPLIER = 100.0

local fuelConsumptionMultiplier = DEFAULT_FUEL_MULTIPLIER
local skipNextRestore = false
local cachedStates = {}
local pendingResets = {}
local switchDefaultsPending = {}
-- Only IDs that have been the player's current vehicle are managed. AI traffic
-- objects may spawn/despawn in the same mission, but are never added by polling
-- or by onVehicleSpawned unless they actually become the player's selected car.
local playerVehicleIds = {}
local destroyedVehicleIds = {}
local pendingVehicleSwitches = {}
local pollTimer = 0
local lastPlayerVehicleId = nil
local fuelStatus = { available = false, detected = false, vehicleId = nil, current = 0, capacity = 0 }

local function loadConfig()
  fuelConsumptionMultiplier = DEFAULT_FUEL_MULTIPLIER
  if type(jsonReadFile) ~= "function" then
    log("W", "resetStateKeeper", "jsonReadFile unavailable; using fuel multiplier x1.0")
    return
  end

  local ok, config = pcall(jsonReadFile, CONFIG_PATH)
  if not ok or type(config) ~= "table" then
    log("W", "resetStateKeeper", "Config file not found or invalid; using fuel multiplier x1.0")
    return
  end

  local configured = tonumber(config.fuelConsumptionMultiplier)
  if configured and configured == configured and configured ~= math.huge and configured ~= -math.huge then
    fuelConsumptionMultiplier = math.max(0.1, math.min(MAX_FUEL_MULTIPLIER, configured))
  end
  log("I", "resetStateKeeper", "Fuel consumption multiplier: x" .. tostring(fuelConsumptionMultiplier))
end

local function publishFuelMultiplier()
  if guihooks and type(guihooks.trigger) == "function" then
    pcall(function()
      guihooks.trigger("ResetStateKeeperMultiplierUpdate", { multiplier = fuelConsumptionMultiplier })
    end)
  end
end

local function publishFuelStatus()
  if guihooks and type(guihooks.trigger) == "function" then
    pcall(function()
      guihooks.trigger("ResetStateKeeperFuelStatusUpdate", {
        available = fuelStatus.available == true,
        detected = fuelStatus.detected == true,
        vehicleId = fuelStatus.vehicleId,
        current = fuelStatus.current or 0,
        capacity = fuelStatus.capacity or 0
      })
    end)
  end
end

-- Called by the in-game UI app. Changes the effective multiplier immediately
-- and stores it in the user's settings JSON for the next game session.
local function setFuelConsumptionMultiplier(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fuelConsumptionMultiplier
  end

  value = math.max(0.1, math.min(MAX_FUEL_MULTIPLIER, value))
  fuelConsumptionMultiplier = math.floor(value * 10 + 0.5) / 10

  if type(jsonWriteFile) == "function" then
    local ok, result = pcall(jsonWriteFile, CONFIG_PATH, {
      fuelConsumptionMultiplier = fuelConsumptionMultiplier
    }, true)
    if not ok or result == false then
      log("W", "resetStateKeeper", "Could not save settings/resetStateKeeper.json; live multiplier is still active.")
    end
  else
    log("W", "resetStateKeeper", "jsonWriteFile unavailable; live multiplier is not persisted.")
  end

  publishFuelMultiplier()
  if type(ui_message) == "function" then
    pcall(function()
      ui_message("Fuel consumption set to x" .. string.format("%.1f", fuelConsumptionMultiplier), 3, "info")
    end)
  end
  log("I", "resetStateKeeper", "Fuel consumption multiplier set to x" .. tostring(fuelConsumptionMultiplier))
  return fuelConsumptionMultiplier
end

local function sendFuelConsumptionMultiplierToUI()
  publishFuelMultiplier()
  return fuelConsumptionMultiplier
end

-- This code is evaluated inside the active vehicle's Vehicle Lua VM.
-- It returns values to this Game Engine extension via obj:queueGameEngineLua().
local captureCommand = [==[
local __vehicleId = __RESET_STATE_VEHICLE_ID__
local __fuelMultiplier = tonumber(__RESET_STATE_FUEL_MULTIPLIER__) or 1.0
if __fuelMultiplier < 0.1 then __fuelMultiplier = 1.0 end
local __invalid = -1000000

-- This table lives in the vehicle Lua VM between queued capture commands.
__resetStateKeeperPreviousFuel = __resetStateKeeperPreviousFuel or {}
local __previousFuel = __resetStateKeeperPreviousFuel

local function __isFuelStorage(storage)
  if type(storage) ~= "table" then return false end
  local kind = tostring(storage.type or storage.storageType or storage.typeName or ""):lower()
  if string.find(kind, "fuel", 1, true) then return true end
  local energyType = tostring(storage.energyType or ""):lower()
  if energyType == "" then return false end
  if energyType == "electricenergy" or energyType == "electric" or energyType == "n2o" or
      energyType == "nitrous" or energyType == "nitrousoxide" or energyType == "air" or
      energyType == "unknown" then
    return false
  end
  return true
end

local function __finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function __firstNumber(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if __finiteNumber(value) then return value end
  end
  return __invalid
end

-- Capture all named energy storages, not only mainTank. The storedEnergy field
-- is used by current BeamNG builds; older storage implementations can use volume.
local __fuelEntries = {}
local __fuelSeen = {}
local function __captureStorage(name, storage)
  if type(name) ~= "string" or type(storage) ~= "table" or __fuelSeen[name] then return end
  local value, mode
  if __finiteNumber(storage.storedEnergy) then
    value, mode = storage.storedEnergy, "energy"

    -- Increase/decrease the fuel drain by adjusting the amount spent between
    -- two snapshots. The game's native engine and powertrain files are untouched.
    if __isFuelStorage(storage) then
      local previous = __previousFuel[name]
      if __finiteNumber(previous) and value < previous and __fuelMultiplier ~= 1.0 then
        local nativeConsumption = previous - value
        local adjustedValue = math.max(0, value - nativeConsumption * (__fuelMultiplier - 1.0))
        if adjustedValue ~= value then
          pcall(function() storage.storedEnergy = adjustedValue end)
          value = adjustedValue
        end
      end
      __previousFuel[name] = value
    else
      __previousFuel[name] = nil
    end
  elseif __finiteNumber(storage.remainingVolume) then
    value, mode = storage.remainingVolume, "volume"
  elseif type(storage.getRemainingVolume) == "function" then
    local ok, result = pcall(function() return storage:getRemainingVolume() end)
    if ok and __finiteNumber(result) then value, mode = result, "volume" end
  end
  if value ~= nil then
    __fuelSeen[name] = true
    __fuelEntries[#__fuelEntries + 1] = "[" .. string.format("%q", name) .. "]={mode=" .. string.format("%q", mode) .. ",value=" .. string.format("%.12g", value) .. "}"
  end
end

if energyStorage then
  if type(energyStorage.getStorages) == "function" then
    local allStorages = energyStorage.getStorages()
    for key, storage in pairs(allStorages or {}) do
      local name = type(key) == "string" and key or (type(storage) == "table" and storage.name or nil)
      __captureStorage(name, storage)
    end
  end
  if type(energyStorage.getStorage) == "function" then
    local mainTank = energyStorage.getStorage("mainTank")
    __captureStorage("mainTank", mainTank)
  end
end
local __fuelLiteral = "{" .. table.concat(__fuelEntries, ",") .. "}"
local __electricsValues = electrics and electrics.values or nil

-- Fuel telemetry is read in liters when the vehicle exposes the standard
-- electrics values. Fall back to the runtime energy-storage objects for mods
-- with non-standard telemetry.
local function __finiteNonNegative(value)
  return __finiteNumber(value) and value >= 0
end
local __fuelVolume = __firstNumber(
  __electricsValues and __electricsValues.fuelVolume,
  __electricsValues and __electricsValues.fuel_volume
)
local __fuelCapacity = __firstNumber(
  __electricsValues and __electricsValues.fuelCapacity,
  __electricsValues and __electricsValues.fuel_capacity,
  __electricsValues and __electricsValues.fuelCapacityLiters
)
local __fallbackVolume, __fallbackCapacity = 0, 0
local __foundFallbackVolume, __foundFallbackCapacity = false, false
if energyStorage and type(energyStorage.getStorages) == "function" then
  local __allStorages = energyStorage.getStorages()
  for __key, __storage in pairs(__allStorages or {}) do
    if __isFuelStorage(__storage) then
      local __volume = nil
      if type(__storage.getRemainingVolume) == "function" then
        local __ok, __result = pcall(function() return __storage:getRemainingVolume() end)
        if __ok and __finiteNonNegative(__result) then __volume = __result end
      end
      if __volume == nil and __finiteNonNegative(__storage.remainingVolume) then
        __volume = __storage.remainingVolume
      end
      local __ed = tonumber(__storage.energyDensity)
      local __density = tonumber(__storage.fuelLiquidDensity)
      if __volume == nil and __finiteNonNegative(__storage.storedEnergy) and __ed and __ed > 0 and __density and __density > 0 then
        __volume = __storage.storedEnergy / (__ed * __density)
      end
      if __volume ~= nil then
        __fallbackVolume = __fallbackVolume + __volume
        __foundFallbackVolume = true
      end

      local __capacity = nil
      if __finiteNonNegative(__storage.fuelCapacity) and __storage.fuelCapacity > 0 then
        __capacity = __storage.fuelCapacity
      elseif __finiteNonNegative(__storage.capacity) and __storage.capacity > 0 then
        __capacity = __storage.capacity
      elseif __finiteNonNegative(__storage.energyCapacity) and __storage.energyCapacity > 0 and __ed and __ed > 0 and __density and __density > 0 then
        __capacity = __storage.energyCapacity / (__ed * __density)
      end
      if __capacity ~= nil then
        __fallbackCapacity = __fallbackCapacity + __capacity
        __foundFallbackCapacity = true
      end
    end
  end
end
if not __finiteNonNegative(__fuelVolume) and __foundFallbackVolume then __fuelVolume = __fallbackVolume end
if (not __finiteNonNegative(__fuelCapacity) or __fuelCapacity <= 0) and __foundFallbackCapacity then __fuelCapacity = __fallbackCapacity end
if not __finiteNonNegative(__fuelVolume) then __fuelVolume = -1 end
if not __finiteNonNegative(__fuelCapacity) or __fuelCapacity <= 0 then __fuelCapacity = -1 end

local __device = nil
if powertrain and type(powertrain.getDevice) == "function" then
  local ok, result = pcall(function() return powertrain.getDevice("mainEngine") end)
  if ok then __device = result end
end
local __thermals = __device and __device.thermals or nil
local __legacyEngine = drivetrain and drivetrain.engine or nil
local __engineModule = engine

local __oil = __firstNumber(
  __thermals and __thermals.oilTemperature,
  __legacyEngine and __legacyEngine.oilTemperature,
  __engineModule and __engineModule.oilTemperature,
  __electricsValues and __electricsValues.oiltemp
)
local __coolant = __firstNumber(
  __thermals and __thermals.coolantTemperature,
  __legacyEngine and __legacyEngine.coolantTemperature,
  __engineModule and __engineModule.coolantTemperature,
  __electricsValues and __electricsValues.watertemp
)
local __block = __firstNumber(
  __legacyEngine and __legacyEngine.engineBlockTemperature,
  __engineModule and __engineModule.engineBlockTemperature,
  __thermals and __thermals.engineBlockTemperature
)
local __cylinder = __firstNumber(
  __legacyEngine and __legacyEngine.cylinderWallTemperature,
  __engineModule and __engineModule.cylinderWallTemperature,
  __thermals and __thermals.cylinderWallTemperature
)

local __lights = 0
local __hazard = 0
if __electricsValues then
  local lightValue = __electricsValues.lights_state
  if type(lightValue) ~= "number" then lightValue = __electricsValues.lights end
  if type(lightValue) == "number" and lightValue >= 0 and lightValue <= 2 then __lights = math.floor(lightValue) end

  local hazardValue = __electricsValues.hazard_enabled
  if type(hazardValue) ~= "number" then
    local left = __electricsValues.signal_left_input
    local right = __electricsValues.signal_right_input
    hazardValue = (type(left) == "number" and type(right) == "number" and left > 0 and right > 0) and 1 or 0
  end
  __hazard = hazardValue and hazardValue > 0 and 1 or 0
end

local __reply = "extensions.resetStateKeeper.receiveState(" ..
  tostring(__vehicleId) .. "," .. string.format("%q", __fuelLiteral) .. "," ..
  string.format("%.8f", __oil) .. "," .. string.format("%.8f", __coolant) .. "," ..
  string.format("%.8f", __block) .. "," .. string.format("%.8f", __cylinder) .. "," ..
  tostring(__lights) .. "," .. tostring(__hazard) .. "," ..
  string.format("%.4f", __fuelVolume) .. "," .. string.format("%.4f", __fuelCapacity) .. ")"
obj:queueGameEngineLua(__reply)
]==]

local function safeGetId(vehicle)
  if not vehicle then return nil end
  local ok, id = pcall(function() return vehicle:getId() end)
  if ok and id ~= nil then return tonumber(id) or id end
  ok, id = pcall(function() return vehicle:getID() end)
  if ok and id ~= nil then return tonumber(id) or id end
  return nil
end

local function getObject(id)
  if id == nil then return nil end
  if be and type(be.getObjectByID) == "function" then
    local ok, object = pcall(function() return be:getObjectByID(id) end)
    if ok then return object end
  end
  if type(getObjectByID) == "function" then
    local ok, object = pcall(function() return getObjectByID(id) end)
    if ok then return object end
  end
  return nil
end

local function isTruthyFlag(value)
  if value == true then return true end
  local text = tostring(value):lower()
  if text == "true" or text == "yes" then return true end
  local n = tonumber(value)
  return n ~= nil and n ~= 0
end

-- BeamNG's traffic extension marks AI traffic objects with isTraffic=1.
-- Check both the object flags and known traffic-extension queries when available.
local function isTrafficVehicle(id)
  if id == nil then return false end
  local object = getObject(id)
  if not object then return false end

  for _, key in ipairs({"isTraffic", "isTrafficVehicle", "isTrafficAi", "isAITraffic"}) do
    local ok, value = pcall(function() return object[key] end)
    if ok and isTruthyFlag(value) then return true end
  end

  local trafficExtension = extensions and extensions.gameplay_traffic or nil
  if type(trafficExtension) == "table" then
    for _, name in ipairs({"isTrafficVehicle", "isTraffic"}) do
      local fn = trafficExtension[name]
      if type(fn) == "function" then
        local ok, value = pcall(fn, id)
        if ok and isTruthyFlag(value) then return true end
      end
    end
  end
  return false
end

local function isManagedPlayerVehicle(id)
  return id ~= nil and playerVehicleIds[id] == true and not isTrafficVehicle(id)
end

local function getPlayerVehicleId()
  local vehicle = nil
  if type(getPlayerVehicle) == "function" then
    local ok, result = pcall(function() return getPlayerVehicle(0) end)
    if ok then vehicle = result end
  elseif be and type(be.getPlayerVehicle) == "function" then
    local ok, result = pcall(function() return be:getPlayerVehicle(0) end)
    if ok then vehicle = result end
  end
  return safeGetId(vehicle)
end

local function requestSnapshot(id)
  if id == nil or pendingResets[id] or switchDefaultsPending[id] then return end
  if not isManagedPlayerVehicle(id) then return end
  local vehicle = getObject(id)
  if not vehicle then return end
  local command = captureCommand:gsub("__RESET_STATE_VEHICLE_ID__", tostring(id))
  command = command:gsub("__RESET_STATE_FUEL_MULTIPLIER__", string.format("%.4f", fuelConsumptionMultiplier))
  pcall(function() vehicle:queueLuaCommand(command) end)
end

local function makeRestoreCommand(state)
  local fuelLiteral = type(state.fuelLiteral) == "string" and state.fuelLiteral or "{}"
  -- The storage names in fuelLiteral have been quoted in Vehicle Lua using %q.
  if #fuelLiteral > 12000 then fuelLiteral = "{}" end

  local values = {
    fuelLiteral,
    string.format("%.8f", state.oil or INVALID_TEMP),
    string.format("%.8f", state.coolant or INVALID_TEMP),
    string.format("%.8f", state.block or INVALID_TEMP),
    string.format("%.8f", state.cylinder or INVALID_TEMP),
    tostring(state.lights or 0),
    tostring(state.hazard or 0)
  }

  return ([==[
local __fuelData = %s
if energyStorage and type(energyStorage.getStorage) == "function" then
  for name, item in pairs(__fuelData) do
    local storage = energyStorage.getStorage(name)
    if storage and type(item) == "table" and type(item.value) == "number" then
      if item.mode == "energy" then
        pcall(function() storage.storedEnergy = item.value end)
      elseif item.mode == "volume" and type(storage.setRemainingVolume) == "function" then
        pcall(function() storage:setRemainingVolume(item.value) end)
      end
    end
  end
end

local __oil = %s
local __coolant = %s
local __block = %s
local __cylinder = %s
local __invalid = -999000
local __device = nil
if powertrain and type(powertrain.getDevice) == "function" then
  local ok, result = pcall(function() return powertrain.getDevice("mainEngine") end)
  if ok then __device = result end
end
local __thermals = __device and __device.thermals or nil
local __legacyEngine = drivetrain and drivetrain.engine or nil
local __engineModule = engine
local function __setNumber(object, key, value)
  if object and type(value) == "number" and value > __invalid and type(object[key]) == "number" then
    pcall(function() object[key] = value end)
  end
end
__setNumber(__thermals, "oilTemperature", __oil)
__setNumber(__thermals, "coolantTemperature", __coolant)
__setNumber(__thermals, "engineBlockTemperature", __block)
__setNumber(__thermals, "cylinderWallTemperature", __cylinder)
__setNumber(__legacyEngine, "oilTemperature", __oil)
__setNumber(__legacyEngine, "coolantTemperature", __coolant)
__setNumber(__legacyEngine, "engineBlockTemperature", __block)
__setNumber(__legacyEngine, "cylinderWallTemperature", __cylinder)
__setNumber(__engineModule, "oilTemperature", __oil)
__setNumber(__engineModule, "coolantTemperature", __coolant)
__setNumber(__engineModule, "engineBlockTemperature", __block)
__setNumber(__engineModule, "cylinderWallTemperature", __cylinder)

if electrics then
  if type(electrics.setLightsState) == "function" then pcall(function() electrics.setLightsState(%s) end) end
  if type(electrics.set_warn_signal) == "function" then pcall(function() electrics.set_warn_signal(%s) end) end
end
]==]):format(unpack(values))
end

local function makeSetFuelAmountCommand(ratio)
  ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
  return ([==[
local __targetRatio = %s
local function __isFuelStorage(storage)
  if type(storage) ~= "table" then return false end
  local kind = tostring(storage.type or storage.storageType or storage.typeName or ""):lower()
  if string.find(kind, "fuel", 1, true) then return true end
  local energyType = tostring(storage.energyType or ""):lower()
  if energyType == "" then return false end
  if energyType == "electricenergy" or energyType == "electric" or energyType == "n2o" or
      energyType == "nitrous" or energyType == "nitrousoxide" or energyType == "air" or
      energyType == "unknown" then return false end
  return true
end
__resetStateKeeperPreviousFuel = __resetStateKeeperPreviousFuel or {}
local __changed = false
if energyStorage and type(energyStorage.getStorages) == "function" then
  for name, storage in pairs(energyStorage.getStorages() or {}) do
    if __isFuelStorage(storage) then
      local __ok = false
      if type(storage.setRemainingRatio) == "function" then
        __ok = pcall(function() storage:setRemainingRatio(__targetRatio) end)
      end
      if not __ok and type(storage.energyCapacity) == "number" then
        __ok = pcall(function() storage.storedEnergy = storage.energyCapacity * __targetRatio end)
      end
      if __ok then
        __changed = true
        local __storageName = type(name) == "string" and name or (type(storage.name) == "string" and storage.name or nil)
        if __storageName and type(storage.storedEnergy) == "number" then
          __resetStateKeeperPreviousFuel[__storageName] = storage.storedEnergy
        elseif __storageName then
          __resetStateKeeperPreviousFuel[__storageName] = nil
        end
      end
    end
  end
end
if not __changed and energyStorage and type(energyStorage.getStorage) == "function" then
  local __storage = energyStorage.getStorage("mainTank")
  if __storage then
    local __ok = false
    if type(__storage.setRemainingRatio) == "function" then
      __ok = pcall(function() __storage:setRemainingRatio(__targetRatio) end)
    end
    if not __ok and type(__storage.energyCapacity) == "number" then
      __ok = pcall(function() __storage.storedEnergy = __storage.energyCapacity * __targetRatio end)
    end
    if __ok then
      __changed = true
      __resetStateKeeperPreviousFuel["mainTank"] = __storage.storedEnergy
    end
  end
end
obj:queueGameEngineLua("extensions.resetStateKeeper.onFuelAmountApplied(" .. tostring(__changed) .. ")")
]==]):format(string.format("%.8f", ratio))
end

local function copyState(state)
  if not state then return nil end
  return {
    fuelLiteral = state.fuelLiteral,
    oil = state.oil,
    coolant = state.coolant,
    block = state.block,
    cylinder = state.cylinder,
    lights = state.lights,
    hazard = state.hazard
  }
end

-- Called asynchronously by the active vehicle's Lua VM.
local function receiveState(id, fuelLiteral, oil, coolant, block, cylinder, lights, hazard, currentFuel, fuelCapacity)
  id = tonumber(id) or id
  if id == nil or not isManagedPlayerVehicle(id) or pendingResets[id] or switchDefaultsPending[id] or skipNextRestore then return end
  if type(fuelLiteral) ~= "string" or #fuelLiteral > 12000 then fuelLiteral = "{}" end
  cachedStates[id] = {
    fuelLiteral = fuelLiteral,
    oil = tonumber(oil) or INVALID_TEMP,
    coolant = tonumber(coolant) or INVALID_TEMP,
    block = tonumber(block) or INVALID_TEMP,
    cylinder = tonumber(cylinder) or INVALID_TEMP,
    lights = tonumber(lights) or 0,
    hazard = tonumber(hazard) or 0
  }
  if getPlayerVehicleId() == id then
    currentFuel = tonumber(currentFuel)
    fuelCapacity = tonumber(fuelCapacity)
    if currentFuel and currentFuel >= 0 and fuelCapacity and fuelCapacity > 0 then
      fuelStatus = { available = true, detected = true, vehicleId = id, current = math.max(0, math.min(currentFuel, fuelCapacity)), capacity = fuelCapacity }
    else
      fuelStatus = { available = false, detected = true, vehicleId = id, current = 0, capacity = 0 }
    end
    publishFuelStatus()
  end
end
M.receiveState = receiveState
M.setFuelConsumptionMultiplier = setFuelConsumptionMultiplier
M.sendFuelConsumptionMultiplierToUI = sendFuelConsumptionMultiplierToUI
M.getFuelConsumptionMultiplier = function() return fuelConsumptionMultiplier end

local function sendFuelStatusToUI()
  local id = getPlayerVehicleId()
  if id ~= nil and isManagedPlayerVehicle(id) then
    requestSnapshot(id)
  else
    fuelStatus = { available = false, detected = false, vehicleId = id, current = 0, capacity = 0 }
    publishFuelStatus()
  end
  publishFuelStatus()
end
M.sendFuelStatusToUI = sendFuelStatusToUI

local function setFuelAmountLiters(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return false
  end
  local id = getPlayerVehicleId()
  if id == nil or not isManagedPlayerVehicle(id) or not fuelStatus.available or fuelStatus.vehicleId ~= id or fuelStatus.capacity <= 0 then
    if type(ui_message) == "function" then
      pcall(function() ui_message("Could not determine the fuel tank capacity for this vehicle.", 4, "warning") end)
    end
    sendFuelStatusToUI()
    return false
  end
  value = math.max(0, math.min(fuelStatus.capacity, value))
  local ratio = value / fuelStatus.capacity
  local vehicle = getObject(id)
  if not vehicle then return false end
  local command = makeSetFuelAmountCommand(ratio)
  local ok = pcall(function() vehicle:queueLuaCommand(command) end)
  if not ok then return false end
  log("I", "resetStateKeeper", "Requested fuel amount " .. tostring(value) .. " L (" .. tostring(ratio) .. " tank ratio).")
  return true
end
M.setFuelAmountLiters = setFuelAmountLiters

local function onFuelAmountApplied(changed)
  if changed == true or tostring(changed) == "true" then
    if type(ui_message) == "function" then
      pcall(function() ui_message("Fuel level updated.", 3, "info") end)
    end
    local id = getPlayerVehicleId()
    if id ~= nil and isManagedPlayerVehicle(id) then requestSnapshot(id) end
  else
    if type(ui_message) == "function" then
      pcall(function() ui_message("Could not change the fuel level for this vehicle.", 4, "warning") end)
    end
  end
end
M.onFuelAmountApplied = onFuelAmountApplied

-- Defaults are applied only when the previous active player vehicle was removed
-- (Replace Current / same-ID respawn). Switching among still-existing player cars
-- preserves their independent state instead of resetting the newly selected car.
local function makeSwitchDefaultsCommand(vehicleId)
  return ([==[
local __vehicleId = %s
local function __isFuelStorage(storage)
  if type(storage) ~= "table" then return false end
  local kind = tostring(storage.type or storage.storageType or storage.typeName or ""):lower()
  if string.find(kind, "fuel", 1, true) then return true end
  local energyType = tostring(storage.energyType or ""):lower()
  if energyType == "" then return false end
  if energyType == "electricenergy" or energyType == "electric" or energyType == "n2o" or
      energyType == "nitrous" or energyType == "nitrousoxide" or energyType == "air" or
      energyType == "unknown" then return false end
  return true
end
local function __setFull(storage)
  if type(storage) ~= "table" then return false end
  if type(storage.setRemainingRatio) == "function" then
    local ok = pcall(function() storage:setRemainingRatio(1.0) end)
    if ok then return true end
  end
  if type(storage.energyCapacity) == "number" and storage.energyCapacity > 0 then
    return pcall(function() storage.storedEnergy = storage.energyCapacity end)
  end
  return false
end

-- Start from full fuel storage for the newly selected car. Electric batteries
-- and other non-fuel energy stores are excluded by __isFuelStorage.
__resetStateKeeperPreviousFuel = {}
local __fuelStoresChanged = false
if energyStorage and type(energyStorage.getStorages) == "function" then
  for name, storage in pairs(energyStorage.getStorages() or {}) do
    if __isFuelStorage(storage) then
      if __setFull(storage) then __fuelStoresChanged = true end
      local __name = type(name) == "string" and name or (type(storage.name) == "string" and storage.name or nil)
      if __name and type(storage.storedEnergy) == "number" then
        __resetStateKeeperPreviousFuel[__name] = storage.storedEnergy
      end
    end
  end
end
if not __fuelStoresChanged and energyStorage and type(energyStorage.getStorage) == "function" then
  local storage = energyStorage.getStorage("mainTank")
  if storage then
    __setFull(storage)
    if type(storage.storedEnergy) == "number" then __resetStateKeeperPreviousFuel["mainTank"] = storage.storedEnergy end
  end
end

-- Reset engine thermal state without repairing collision/mechanical damage.
local __ambient = 20
if type(getEnvTemperature) == "function" then
  local __ok, __value = pcall(function() return getEnvTemperature() end)
  if __ok and type(__value) == "number" and __value == __value and __value > -100 and __value < 200 then
    __ambient = __value
  end
end
local __device = nil
if powertrain and type(powertrain.getDevice) == "function" then
  local __ok, __value = pcall(function() return powertrain.getDevice("mainEngine") end)
  if __ok then __device = __value end
end
local __thermals = __device and __device.thermals or nil
local __thermalReset = false
if __thermals and type(__thermals.reset) == "function" then
  local __ok = pcall(function() __thermals:reset() end)
  __thermalReset = __ok
end
if not __thermalReset then
  local __keys = {"oilTemperature", "coolantTemperature", "engineBlockTemperature", "cylinderWallTemperature"}
  local function __setAmbientTemperatures(__target)
    local __targetType = type(__target)
    if __targetType ~= "table" and __targetType ~= "userdata" then return end
    for _, __key in ipairs(__keys) do
      local __ok, __value = pcall(function() return __target[__key] end)
      if __ok and type(__value) == "number" then
        pcall(function() __target[__key] = __ambient end)
      end
    end
  end
  __setAmbientTemperatures(__thermals)
  __setAmbientTemperatures(drivetrain and drivetrain.engine or nil)
  __setAmbientTemperatures(engine)
end

-- Turn off exterior lighting and the hazard warning signal.
if electrics then
  if type(electrics.setLightsState) == "function" then pcall(function() electrics.setLightsState(0) end) end
  if type(electrics.set_warn_signal) == "function" then pcall(function() electrics.set_warn_signal(false) end) end
  if type(electrics.values) == "table" then
    electrics.values.lights_state = 0
    electrics.values.hazard_enabled = 0
  end
end

obj:queueGameEngineLua("extensions.resetStateKeeper.onVehicleSwitchDefaultsApplied(" .. tostring(__vehicleId) .. ")")
]==]):format(tostring(vehicleId))
end

local function onVehicleSwitchDefaultsApplied(id)
  id = tonumber(id) or id
  switchDefaultsPending[id] = nil
  log("I", "resetStateKeeper", "Applied default managed state after vehicle switch for vehicle " .. tostring(id))
  if getPlayerVehicleId() == id and isManagedPlayerVehicle(id) then
    fuelStatus = { available = false, detected = false, vehicleId = id, current = 0, capacity = 0 }
    publishFuelStatus()
    if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
      pcall(function()
        guihooks.trigger("toastrMsg", {
          type = "info",
          title = "Reset State Keeper",
          msg = "Vehicle changed: fuel, temperature and lights have been reset to defaults.",
          config = {timeOut = 4000}
        })
      end)
    end
    requestSnapshot(id)
  end
end
M.onVehicleSwitchDefaultsApplied = onVehicleSwitchDefaultsApplied

local function scheduleVehicleSwitch(oldId, newId)
  oldId = tonumber(oldId) or oldId
  newId = tonumber(newId) or newId
  if newId == nil then return end

  -- Never touch AI traffic, even if it is present in the world or a traffic
  -- setting allows switching to it. The active/player ID is still tracked so
  -- a later switch back to a player-spawned car can be handled correctly.
  if isTrafficVehicle(newId) then
    lastPlayerVehicleId = newId
    fuelStatus = { available = false, detected = false, vehicleId = newId, current = 0, capacity = 0 }
    publishFuelStatus()
    log("I", "resetStateKeeper", "Traffic vehicle selected; state management skipped for vehicle " .. tostring(newId))
    return
  end

  if oldId == nil or oldId == newId then
    lastPlayerVehicleId = newId
    playerVehicleIds[newId] = true
    destroyedVehicleIds[newId] = nil
    fuelStatus = { available = false, detected = false, vehicleId = newId, current = 0, capacity = 0 }
    publishFuelStatus()
    requestSnapshot(newId)
    return
  end

  local oldWasPlayer = oldId ~= nil and not isTrafficVehicle(oldId) and
    (playerVehicleIds[oldId] == true or lastPlayerVehicleId == oldId or getObject(oldId) ~= nil)
  local newWasManaged = playerVehicleIds[newId] == true
  local oldDestroyed = destroyedVehicleIds[oldId] == true

  pendingVehicleSwitches[newId] = {
    oldId = oldId,
    newId = newId,
    oldWasPlayer = oldWasPlayer,
    newWasManaged = newWasManaged,
    oldDestroyed = oldDestroyed,
    delay = 0.35
  }

  lastPlayerVehicleId = newId
  destroyedVehicleIds[newId] = nil
  fuelStatus = { available = false, detected = false, vehicleId = newId, current = 0, capacity = 0 }
  publishFuelStatus()
  log("I", "resetStateKeeper", "Queued player vehicle switch classification: " .. tostring(oldId) .. " -> " .. tostring(newId))
end

local function processPendingVehicleSwitches(dt)
  for newId, pending in pairs(pendingVehicleSwitches) do
    pending.delay = pending.delay - dt
    if pending.delay <= 0 then
      pendingVehicleSwitches[newId] = nil

      -- The target must still exist and must not have been registered as AI traffic
      -- after the switch event. Otherwise the mod deliberately does nothing to it.
      if not getObject(newId) or isTrafficVehicle(newId) then
        log("I", "resetStateKeeper", "Skipped state handling for missing/traffic vehicle " .. tostring(newId))
      else
        local oldId = pending.oldId
        local oldStillExists = oldId ~= nil and not pending.oldDestroyed and not destroyedVehicleIds[oldId] and getObject(oldId) ~= nil and not isTrafficVehicle(oldId)

        if pending.newWasManaged or (pending.oldWasPlayer and oldStillExists) then
          -- Both cars exist: this is Spawn New or switching between cars spawned
          -- by the player. Keep each car's independent cache; do not apply defaults.
          if oldStillExists then playerVehicleIds[oldId] = true end
          playerVehicleIds[newId] = true
          destroyedVehicleIds[newId] = nil
          switchDefaultsPending[newId] = nil
          log("I", "resetStateKeeper", "Preserving per-vehicle state for existing player car " .. tostring(newId))
          requestSnapshot(newId)
        else
          -- The old active car disappeared and the target has no previously known
          -- player-car state: this is Replace Current (or a newly reused ID).
          if oldId ~= nil then
            cachedStates[oldId] = nil
            pendingResets[oldId] = nil
            playerVehicleIds[oldId] = nil
          end
          cachedStates[newId] = nil
          pendingResets[newId] = nil
          playerVehicleIds[newId] = true
          skipNextRestore = false
          switchDefaultsPending[newId] = { delay = 0.20, attempts = 0 }
          log("I", "resetStateKeeper", "Confirmed replacement of current car; applying defaults to vehicle " .. tostring(newId))
        end
      end
    end
  end
end

local function processSwitchDefaults(dt)
  for id, pending in pairs(switchDefaultsPending) do
    pending.delay = pending.delay - dt
    if pending.delay <= 0 then
      local vehicle = getObject(id)
      if isTrafficVehicle(id) then
        switchDefaultsPending[id] = nil
      elseif vehicle and pending.attempts < 3 then
        local ok = pcall(function() vehicle:queueLuaCommand(makeSwitchDefaultsCommand(id)) end)
        pending.attempts = pending.attempts + 1
        pending.delay = ok and 0.75 or 0.25
      else
        switchDefaultsPending[id] = nil
        log("W", "resetStateKeeper", "Could not apply defaults after switching to vehicle " .. tostring(id) .. "; cached state remains cleared.")
        if getPlayerVehicleId() == id then requestSnapshot(id) end
      end
    end
  end
end

local function processPendingResets(dt)
  for id, pending in pairs(pendingResets) do
    pending.delay = pending.delay - dt
    if pending.delay <= 0 then
      if pending.stage == 0 then
        local vehicle = getObject(id)
        if pending.state and vehicle then
          local command = makeRestoreCommand(pending.state)
          pcall(function() vehicle:queueLuaCommand(command) end)
          pending.stage = 1
          pending.delay = RESET_SECOND_DELAY
        else
          pending.stage = 2
          pending.delay = RESET_SETTLE_DELAY
        end
      elseif pending.stage == 1 then
        local vehicle = getObject(id)
        if pending.state and vehicle then
          local command = makeRestoreCommand(pending.state)
          pcall(function() vehicle:queueLuaCommand(command) end)
        end
        pending.stage = 2
        pending.delay = RESET_SETTLE_DELAY
      else
        pendingResets[id] = nil
        if getPlayerVehicleId() == id then requestSnapshot(id) end
      end
    end
  end
end

-- Public action exposed to the Controls menu. Clears every player-car snapshot,
-- then bypasses custom restoration once so BeamNG performs a normal reset.
local function clearSavedStates()
  cachedStates = {}
  pendingResets = {}
  skipNextRestore = true
  log("I", "resetStateKeeper", "Saved vehicle states cleared. The next recovery will use default game behavior.")

  -- Show a small in-game toast so the player receives immediate feedback.
  if guihooks and type(guihooks.trigger) == "function" then
    pcall(function()
      guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Reset State Keeper",
        msg = "Saved states cleared. The next reset will use the game's default behavior.",
        config = {timeOut = 4000}
      })
    end)
  end
end
M.clearSavedStates = clearSavedStates

local function onUpdate(dtReal, dtSim)
  local dt = tonumber(dtReal) or tonumber(dtSim) or 0
  if dt < 0 then dt = 0 end

  processPendingResets(dt)
  processSwitchDefaults(dt)
  processPendingVehicleSwitches(dt)
  pollTimer = pollTimer + dt
  if pollTimer >= POLL_INTERVAL then
    pollTimer = 0
    local id = getPlayerVehicleId()
    if id ~= nil then
      if lastPlayerVehicleId ~= nil and id ~= lastPlayerVehicleId then
        -- Fallback when the normal switch callback wasn't delivered.
        scheduleVehicleSwitch(lastPlayerVehicleId, id)
      elseif lastPlayerVehicleId == nil then
        lastPlayerVehicleId = id
        if not isTrafficVehicle(id) then
          playerVehicleIds[id] = true
          destroyedVehicleIds[id] = nil
        end
      end
      if isManagedPlayerVehicle(id) then requestSnapshot(id) end
    end
  end
end

local function onVehicleResetted(id)
  id = tonumber(id) or id
  if id == nil or not isManagedPlayerVehicle(id) then return end
  -- After the user clears the cache, let the next reset run with vanilla defaults.
  -- The post-reset state will then become the new baseline for this vehicle.
  local state = nil
  if skipNextRestore and getPlayerVehicleId() == id then
    skipNextRestore = false
    cachedStates[id] = nil
    log("I", "resetStateKeeper", "Next recovery is using the game's default reset behavior.")
  elseif not skipNextRestore then
    state = copyState(cachedStates[id])
  end

  -- Freeze incoming snapshots until the reset path has settled.
  pendingResets[id] = {
    state = state,
    delay = RESET_FIRST_DELAY,
    stage = 0
  }
end

local function onVehicleSpawned(id)
  id = tonumber(id) or id
  if id == nil then return end

  local wasDestroyed = destroyedVehicleIds[id] == true
  destroyedVehicleIds[id] = nil
  local activeId = getPlayerVehicleId()
  if activeId ~= id or isTrafficVehicle(id) then return end

  if wasDestroyed then
    -- Some replace/reload paths reuse the old object ID.
    cachedStates[id] = nil
    pendingResets[id] = nil
    playerVehicleIds[id] = true
    lastPlayerVehicleId = id
    switchDefaultsPending[id] = { delay = 0.20, attempts = 0 }
    log("I", "resetStateKeeper", "Destroyed player vehicle ID reused; applying defaults to " .. tostring(id))
  elseif playerVehicleIds[id] and lastPlayerVehicleId == id and not pendingVehicleSwitches[id] then
    -- A spawn event for the already-active ID means the vehicle was replaced in
    -- place (rather than another player car being added beside it).
    cachedStates[id] = nil
    pendingResets[id] = nil
    switchDefaultsPending[id] = { delay = 0.20, attempts = 0 }
    log("I", "resetStateKeeper", "Active player vehicle respawned in place; applying defaults to " .. tostring(id))
  elseif lastPlayerVehicleId == nil then
    playerVehicleIds[id] = true
    lastPlayerVehicleId = id
    requestSnapshot(id)
  end
  -- If another ID was active before this spawn, wait for onVehicleSwitched (or
  -- polling fallback) to determine Spawn New versus Replace Current.
end

local function onVehicleSwitched(oldId, newId)
  oldId = tonumber(oldId) or oldId
  newId = tonumber(newId) or newId
  if newId == nil then return end
  scheduleVehicleSwitch(oldId, newId)
end

local function onVehicleDestroyed(id)
  id = tonumber(id) or id
  if id == nil then return end

  destroyedVehicleIds[id] = true
  cachedStates[id] = nil
  pendingResets[id] = nil
  switchDefaultsPending[id] = nil
  playerVehicleIds[id] = nil

  for _, pending in pairs(pendingVehicleSwitches) do
    if pending.oldId == id then pending.oldDestroyed = true end
  end
  pendingVehicleSwitches[id] = nil
  -- Keep lastPlayerVehicleId until the switch callback/poll sees the new ID;
  -- it is needed to classify a Replace Current operation correctly.
end

local function onClientEndMission()
  cachedStates = {}
  pendingResets = {}
  switchDefaultsPending = {}
  playerVehicleIds = {}
  destroyedVehicleIds = {}
  pendingVehicleSwitches = {}
  skipNextRestore = false
  pollTimer = 0
  lastPlayerVehicleId = nil
  fuelStatus = { available = false, detected = false, vehicleId = nil, current = 0, capacity = 0 }
  publishFuelStatus()
end

local function onExtensionLoaded()
  loadConfig()
  log("I", "resetStateKeeper", "Loaded. Caching player-vehicle state for reset restoration.")
end

M.onUpdate = onUpdate
M.onVehicleResetted = onVehicleResetted
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission
M.onExtensionLoaded = onExtensionLoaded

return M
