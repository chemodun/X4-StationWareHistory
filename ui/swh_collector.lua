-- Station Ware History — Collector
--
-- MD raises 'StationWareHistory.Collect' on a configurable timer
-- (player.entity.$stationWareHistory.$config.$collectionIntervalMinutes, 1-10 min).
-- On each collection, samples reservation-corrected cargo for every player-owned
-- station and appends change-only points to a per-station/per-ware time series,
-- persisted on player.entity.$stationWareHistoryData so it survives save/reload.
--
-- Series shape: data[stationIdcode][wareId] = { {t=gameTime, v=amount}, ... },
-- ordered by t ascending. A new point is appended only when the value differs
-- from the series' last point (mirrors vanilla's transaction-log money-graph
-- compaction in ego_detailmonitorhelper/helper.lua, which only keeps a point when
-- money differs from the previous/next sample). This keeps the table small even
-- at the finest interval/longest retention, since most wares on most stations sit
-- at a stable level between deliveries.
--
-- Pruning (run once per collection cycle, after sampling) drops points older than
-- the configured retention window, except it always keeps the single most recent
-- point at/before the cutoff so an unchanged series still renders a flat line
-- across the full selected graph range instead of vanishing once its only point
-- ages past the window.
--
-- station cargo/idcode/owner enumeration mirrors the reservation-correction logic
-- in smart_freight_dispatcher/ui/sfd_engine.lua's collectData/processOffers.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
    UniverseID reserverid;
    const char* ware;
    uint32_t    amount;
    bool        isbuyreservation;
    double      eta;
    TradeID     tradedealid;
    MissionID   missionid;
    bool        isvirtual;
    bool        issupply;
  } WareReservationInfo2;

  double     GetCurrentGameTime(void);
  UniverseID GetPlayerID(void);

  uint32_t GetNumContainerWareReservations2(UniverseID containerid,
             bool includevirtual, bool includemission, bool includesupply);
  uint32_t GetContainerWareReservations2(WareReservationInfo2* result,
             uint32_t resultlen, UniverseID containerid,
             bool includevirtual, bool includemission, bool includesupply);
]]

local swh = {
  playerId   = nil,
  debugLevel = "debug",
  data       = {},  -- data[stationIdcode][wareId] = { {t=,v=}, ... }
  stations   = {},  -- stations[stationIdcode] = { name=, sectorName=, luaId= }; rebuilt every collect
}

-- *** debug helpers ***
-- Lazy formatting: format args are only evaluated into a string when the
-- current debug level allows output. Mirrors smart_freight_dispatcher/ui/sfd_engine.lua.

local function debugLog(fmt, ...)
  if swh.debugLevel ~= "none" then
    if select("#", ...) > 0 then
      DebugError("[SWH] " .. string.format(fmt, ...))
    else
      DebugError("[SWH] " .. fmt)
    end
  end
end

local function traceLog(fmt, ...)
  if swh.debugLevel == "trace" then
    if select("#", ...) > 0 then
      DebugError("[SWH] " .. string.format(fmt, ...))
    else
      DebugError("[SWH] " .. fmt)
    end
  end
end

function swh.onDebugLevelChanged(_, param)
  if param ~= nil then
    swh.debugLevel = tostring(param)
  end
end

-- *** persistence ***

local function loadFromBlackboard()
  swh.data = GetNPCBlackboard(swh.playerId, "$stationWareHistoryData") or {}
end

local function saveToBlackboard()
  SetNPCBlackboard(swh.playerId, "$stationWareHistoryData", swh.data)
end

-- *** data collection ***

-- All ware IDs relevant to a station regardless of current stock: produced,
-- consumed (production module resources), explicitly traded, and
-- workforce-consumed (food, water, medicine, ...). "cargo" alone only lists
-- wares currently held in storage, so a resource sitting at 0 (nothing
-- delivered yet, or consumed as fast as it arrives) would otherwise never be
-- discovered at all. Mirrors the ware-set construction in
-- station_storage_allocation/ui/station_storage_allocation.lua.
local function relevantWareSet(objId64)
  local wareSet = {}
  local products, allresources, tradewares = GetComponentData(objId64, "products", "allresources", "tradewares")
  if products then
    for _, wareId in ipairs(products) do wareSet[wareId] = true end
  end
  if allresources then
    for _, wareId in ipairs(allresources) do wareSet[wareId] = true end
  end
  if tradewares then
    for _, wareId in ipairs(tradewares) do wareSet[wareId] = true end
  end
  if type(GetWorkForceRaceResources) == "function" then
    local wfInfos = GetWorkForceRaceResources(objId64)
    if wfInfos then
      for _, raceInfo in ipairs(wfInfos) do
        for _, res in ipairs(raceInfo.resources or {}) do
          wareSet[res.ware] = true
        end
      end
    end
  end
  return wareSet
end

-- Reservation-corrected cargo table for one container: buy reservations remove
-- stock about to leave, sell reservations add stock about to arrive. Mirrors
-- sfd_engine.lua's processOffers cargo correction, applied to the whole cargo
-- table rather than only to wares with an active trade offer. Every ware in
-- wareSet gets an entry (defaulting to 0) even if absent from "cargo" or any
-- reservation, so zero-stock production wares are still tracked.
local function correctedCargo(objId64, wareSet)
  local cargoTable = {}
  for wareId in pairs(wareSet) do
    cargoTable[wareId] = 0
  end
  local cargo = GetComponentData(objId64, "cargo")
  for wareId, amount in pairs(cargo or {}) do
    cargoTable[wareId] = tonumber(amount) or 0
  end

  local nRes = tonumber(C.GetNumContainerWareReservations2(objId64, true, true, true))
  if nRes > 0 then
    local resBuf = ffi.new("WareReservationInfo2[?]", nRes)
    nRes = tonumber(C.GetContainerWareReservations2(resBuf, nRes, objId64, true, true, true))
    for ri = 0, nRes - 1 do
      if (not resBuf[ri].isvirtual) and resBuf[ri].missionid == 0 then
        local wareId  = ffi.string(resBuf[ri].ware)
        local resAmt  = tonumber(resBuf[ri].amount) or 0
        local current = cargoTable[wareId] or 0
        if resBuf[ri].isbuyreservation then
          cargoTable[wareId] = math.max(0, current - resAmt)
        else
          cargoTable[wareId] = current + resAmt
        end
      end
    end
  end

  return cargoTable
end

local function appendPoint(stationIdcode, wareId, now, amount)
  local stationSeries = swh.data[stationIdcode]
  if stationSeries == nil then
    stationSeries = {}
    swh.data[stationIdcode] = stationSeries
  end
  local series = stationSeries[wareId]
  if series == nil then
    series = {}
    stationSeries[wareId] = series
  end
  local last = series[#series]
  if last == nil or last.v ~= amount then
    series[#series + 1] = { t = now, v = amount }
    traceLog("appendPoint: station=%s ware=%s amount=%d (was %s) -> new point recorded.",
      stationIdcode, wareId, amount, last and tostring(last.v) or "none")
  end
end

-- Drop points older than cutoff, keeping the single most recent point at/before
-- the cutoff (continuity anchor) plus everything newer than it.
local function pruneSeries(series, cutoff)
  if #series <= 1 then
    return series
  end
  local keepFrom = 1
  for i = 1, #series do
    if series[i].t < cutoff then
      keepFrom = i
    else
      break
    end
  end
  if keepFrom <= 1 then
    return series
  end
  local trimmed = {}
  for i = keepFrom, #series do
    trimmed[#trimmed + 1] = series[i]
  end
  return trimmed
end

local function pruneAll(now)
  local retentionHours = 48
  local root = GetNPCBlackboard(swh.playerId, "$stationWareHistory")
  if root ~= nil and root.config ~= nil and root.config.retentionHours ~= nil then
    retentionHours = tonumber(root.config.retentionHours) or 48
  end
  local cutoff = now - (retentionHours * 3600)

  local prunedSeries = 0
  for stationIdcode, wareSeries in pairs(swh.data) do
    for wareId, series in pairs(wareSeries) do
      local before = #series
      local trimmed = pruneSeries(series, cutoff)
      wareSeries[wareId] = trimmed
      if #trimmed < before then
        prunedSeries = prunedSeries + 1
        traceLog("pruneAll: station=%s ware=%s dropped %d point(s) older than cutoff.",
          stationIdcode, wareId, before - #trimmed)
      end
    end
  end
  debugLog("pruneAll: retentionHours=%d cutoff=%.1f, trimmed %d series.", retentionHours, cutoff, prunedSeries)
end

function swh.onCollect()
  local now           = C.GetCurrentGameTime()
  local stationsList   = GetContainedStationsByOwner("player")
  local stationsSeen   = {}
  local wareSamples    = 0

  debugLog("onCollect: starting, %d player station(s) found, t=%.1f.", #stationsList, now)

  for i = 1, #stationsList do
    local stationLuaId = stationsList[i]
    local id64                       = ConvertIDTo64Bit(stationLuaId)
    local idcode, name, sectorLuaId  = GetComponentData(stationLuaId, "idcode", "name", "sectorid")
    if idcode ~= nil then
      stationsSeen[idcode] = true
      swh.stations[idcode] = {
        name       = name,
        sectorName = GetComponentData(sectorLuaId, "name"),
        luaId      = stationLuaId,
      }

      local wareSet = relevantWareSet(id64)
      local cargoTable = correctedCargo(id64, wareSet)
      local stationWareCount = 0
      for wareId, amount in pairs(cargoTable) do
        appendPoint(idcode, wareId, now, amount)
        stationWareCount = stationWareCount + 1
      end
      wareSamples = wareSamples + stationWareCount
      traceLog("onCollect: station=%s (%s) sampled %d ware(s).", name, idcode, stationWareCount)
    end
  end

  -- Drop stations no longer owned from the live name cache; their recorded
  -- history is left untouched (it ages out via the retention prune below).
  for idcode in pairs(swh.stations) do
    if not stationsSeen[idcode] then
      debugLog("onCollect: station %s no longer player-owned, dropping from name cache.", idcode)
      swh.stations[idcode] = nil
    end
  end

  pruneAll(now)
  saveToBlackboard()
  debugLog("onCollect: done, %d station(s), %d ware sample(s) processed.", #stationsList, wareSamples)
end

-- *** queries for the menu ***

function swh.getStationName(idcode)
  local info = swh.stations[idcode]
  if info ~= nil and info.name ~= nil then
    return info.name
  end
  return idcode
end

function swh.getStationList()
  local seen = {}
  local list = {}
  for idcode, info in pairs(swh.stations) do
    seen[idcode] = true
    list[#list + 1] = { idcode = idcode, name = info.name or idcode, sectorName = info.sectorName or "" }
  end
  for idcode in pairs(swh.data) do
    if not seen[idcode] then
      list[#list + 1] = { idcode = idcode, name = idcode, sectorName = "" }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

function swh.getWaresForStation(idcode)
  local wareSeries = swh.data[idcode]
  local list = {}
  if wareSeries == nil then
    return list
  end
  for wareId, series in pairs(wareSeries) do
    if #series > 0 then
      list[#list + 1] = wareId
    end
  end
  table.sort(list, function(a, b)
    return (GetWareData(a, "name") or a) < (GetWareData(b, "name") or b)
  end)
  return list
end

function swh.getSeries(idcode, wareId)
  local wareSeries = swh.data[idcode]
  if wareSeries == nil then
    return {}
  end
  return wareSeries[wareId] or {}
end

-- *** init ***

function swh.init()
  swh.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  loadFromBlackboard()

  -- Initial debug level (written by the options menu into
  -- player.entity.$stationWareHistory.$config.$debugLevel); kept in sync afterwards
  -- via the DebugLevelChanged event raised by the dropdown's MD handler.
  local root = GetNPCBlackboard(swh.playerId, "$stationWareHistory")
  if root ~= nil and root.config ~= nil and root.config.debugLevel ~= nil then
    swh.debugLevel = tostring(root.config.debugLevel)
  end

  RegisterEvent("StationWareHistory.Collect", swh.onCollect)
  RegisterEvent("StationWareHistory.DebugLevelChanged", swh.onDebugLevelChanged)

  debugLog("init: playerId=%s debugLevel=%s.", tostring(swh.playerId), swh.debugLevel)
end

Register_Require_With_Init("extensions.station_ware_history.ui.swh_collector", swh, swh.init)
