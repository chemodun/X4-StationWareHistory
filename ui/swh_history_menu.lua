-- Station Ware History — Menu
--
-- Standalone top-level menu (registered the same way vanilla registers
-- TransactionLogMenu in ego_detailmonitor/menu_transactionlog.lua): a station
-- dropdown on the left, a checkbox per ware with recorded history below it, and
-- a multi-series graph on the right (one addDataRecord per checked ware), with
-- time-range buttons mirroring the transaction log's zoom-step row.
--
-- Opened from the station's right-click interaction menu via
-- md.Interact_Menu_API ("Show Ware History" action -> raise_lua_event
-- 'StationWareHistory.OpenMenu' param=<station component>).

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  double GetCurrentGameTime(void);
]]

local swh = require("extensions.station_ware_history.ui.swh_collector")

-- Shares swh.debugLevel (kept in sync by the options menu's debug dropdown via
-- swh.onDebugLevelChanged) rather than tracking a second copy here.
local function debugLog(fmt, ...)
  if swh.debugLevel ~= "none" then
    if select("#", ...) > 0 then
      DebugError("[SWH] " .. string.format(fmt, ...))
    else
      DebugError("[SWH] " .. fmt)
    end
  end
end

local menu = {
  name            = "StationWareHistoryMenu",
  lastRefreshTime = 0,
  updateInterval  = 0.1,
}

local config = {
  infoLayer = 4,
  point = { type = "square", size = 6, highlightSize = 6 },
  line  = { type = "normal", size = 2, highlightSize = 2 },
  -- Zoom steps in minutes (mirrors ego_detailmonitorhelper/helper.lua's
  -- Helper.transactionLogConfig.zoomSteps), capped at the retention slider's
  -- maximum (120h); the last entry is always labelled "All" regardless of the
  -- user's currently configured retention. Labels are static strings rather
  -- than Helper.formatTimeShort(seconds), which is not available in all builds.
  zoomSteps = {
    { zoom = 60,   granularity = 300,          label = "1h" },
    { zoom = 360,  granularity = 1800,         label = "6h" },
    { zoom = 1440, granularity = 3600,         label = "24h" },
    { zoom = 2880, granularity = 3600 * 3,     label = "48h" },
    { zoom = 7200, granularity = 3600 * 12,    label = nil },  -- last step always shows "All"
  },
  defaultZoom  = 3,  -- 24h
  defaultDataMode = "res", -- "real" | "res" | "both" -- see dataMode dropdown
  maxShownWares = 8,    -- hard cap on simultaneous LINES: one per available graph_data_N color
  maxTotalPoints = 200, -- shared budget across every currently shown line; see fairShareCaps()
  maxYRoundTo = 1000,   -- the Y axis' endvalue is always rounded up to a multiple of this
  -- Checkbox availability (separate from maxTotalPoints/fairShareCaps, which only
  -- decide how to downsample once something is already shown): below
  -- wareCountSoftLimit shown wares, unchecked checkboxes always stay clickable;
  -- at/above it, an unchecked checkbox is disabled once the *currently shown*
  -- wares' combined full-fidelity point count reaches wareSelectionPointsBudget
  -- (leaving headroom under maxTotalPoints before decimation would kick in for
  -- one more line); at maxShownWares, unchecked checkboxes are always disabled,
  -- no point counting needed. Both thresholds are WARE counts in "real"/"res"
  -- mode (1 line/ware); in "both" mode each ware costs 2 lines, so the
  -- effective ware-count thresholds are halved -- see effectiveWareCaps().
  wareCountSoftLimit       = 5,
  wareSelectionPointsBudget = 160,
  -- "Both" mode is unavailable (disabled in the dropdown) once this many wares
  -- are already selected, regardless of effectiveWareCaps() -- a simple,
  -- conservative guard against confusing combinations rather than a precise
  -- feasibility check.
  bothModeMaxWaresToOffer = 2,
  seriesColors = {
    Color["graph_data_1"], Color["graph_data_2"], Color["graph_data_3"], Color["graph_data_4"],
    Color["graph_data_5"], Color["graph_data_6"], Color["graph_data_7"], Color["graph_data_8"],
  },
}

local function init()
  Menus = Menus or {}
  table.insert(Menus, menu)
  if Helper then
    Helper.registerMenu(menu)
  end
end

function menu.cleanup()
  menu.infoFrame = nil
  menu.stationDropdown = nil
  menu.graph = nil
end

-- *** Lua-event entry point: opens the menu for a given station component ***

local function onOpenMenuEvent(_, stationLuaId)
  local station64 = ConvertIDTo64Bit(stationLuaId)
  OpenMenu("StationWareHistoryMenu", { 0, 0, station64 }, nil)
end

-- *** Helpers ***

-- Stable colour per ware: index into the full (sorted) ware list for the
-- selected station, not into the selection order, so a ware keeps its colour
-- across checkbox toggles. Used in "real"/"res" mode (1 line/ware, full
-- 8-colour palette).
local function colorForWare(wareList, wareId)
  for i, w in ipairs(wareList) do
    if w == wareId then
      return config.seriesColors[((i - 1) % #config.seriesColors) + 1]
    end
  end
  return config.seriesColors[1]
end

-- Paired colours for "both" mode (2 lines/ware): ware i gets the (2i-1)th
-- colour for "real" and the 2i-th for "res", wrapping every 4 wares (8 colours
-- / 2 per ware). Mirrors vanilla's own buy/sell colour pairing in
-- ego_detailmonitor/menu_station_overview.lua's config.graph.datarecordcolors
-- (which pairs graph_data_1/2, 3/4, 5/6, 7/8 the same way, also capped at 4
-- simultaneous paired series for the same reason: 8 colours / 2 per item).
local function colorPairForWare(wareList, wareId)
  local pairCount = math.floor(#config.seriesColors / 2)
  for i, w in ipairs(wareList) do
    if w == wareId then
      local pairIdx = (i - 1) % pairCount
      return config.seriesColors[pairIdx * 2 + 1], config.seriesColors[pairIdx * 2 + 2]
    end
  end
  return config.seriesColors[1], config.seriesColors[2]
end

-- How many graph lines one shown ware costs in a given display mode.
local function linesPerWare(dataMode)
  return (dataMode == "both") and 2 or 1
end

-- Effective ware-count thresholds for the current display mode: in "both"
-- mode each ware costs 2 lines, so the ware-count versions of
-- wareCountSoftLimit/maxShownWares are halved (floored) compared to single
-- mode, since both thresholds are fundamentally LINE-count limits.
local function effectiveWareCaps(dataMode)
  local perWare = linesPerWare(dataMode)
  return {
    soft = math.floor(config.wareCountSoftLimit / perWare),
    hard = math.floor(config.maxShownWares / perWare),
  }
end

-- Builds the full-fidelity {x=,y=} point list for one change-only series within
-- the visible window, adding the same two carry-forward anchors as before
-- (left edge = most recent known value at/before the window start; right edge =
-- latest known value carried to "now") so the line stays continuous even though
-- most wares only get a new stored point when their value actually changes.
-- Does not touch the graph widget directly -- see decimatePoints()/fairShareCaps()
-- below for how the result is (optionally) downsampled before being plotted, to
-- stay under the graph's total point budget.
-- ctx carries { startTime, now, graphXScale, xRange } (read-only here).
-- valueKey selects which stored value to plot: "real" (raw stock) or "res"
-- (reservation-corrected) -- see swh_collector.lua's series shape.
local function buildPoints(series, ctx, valueKey)
  local lastBefore, firstInWindowIdx = nil, nil
  for i = 1, #series do
    local point = series[i]
    if point.t <= ctx.startTime then
      lastBefore = point
    elseif firstInWindowIdx == nil then
      firstInWindowIdx = i
    end
  end

  local points = {}
  if lastBefore ~= nil then
    points[#points + 1] = { x = -ctx.xRange, y = lastBefore[valueKey] }
  end
  if firstInWindowIdx ~= nil then
    for i = firstInWindowIdx, #series do
      local point = series[i]
      points[#points + 1] = { x = (point.t - ctx.now) / ctx.graphXScale, y = point[valueKey] }
    end
  end

  local lastX = (#points > 0) and points[#points].x or nil
  if lastX == nil or lastX < 0 then
    points[#points + 1] = { x = 0, y = series[#series][valueKey] }
  end
  return points
end

-- Max-min fair allocation of a shared total point budget across several lines,
-- given each line's actual point need (entries = list of { id=, need= }).
-- Lines that need fewer points than the current fair share get exactly what
-- they need, in full fidelity; the budget they don't use is redistributed
-- evenly among the remaining lines (recomputed every step) until every
-- remaining line's need meets or exceeds the current share -- those (and only
-- those) get capped at that final share and decimated. This is the standard
-- "progressive filling" max-min fairness algorithm: process lines ascending by
-- need, so a line is only ever capped below its actual need once it's already
-- larger than what an equal split of the *remaining* budget would give it.
-- Returns: table[id] = cap (integer >= 2).
local function fairShareCaps(entries, budget)
  local sorted = {}
  for _, e in ipairs(entries) do sorted[#sorted + 1] = e end
  table.sort(sorted, function(a, b) return a.need < b.need end)

  local caps = {}
  local remainingBudget = budget
  local remainingCount  = #sorted

  for i = 1, #sorted do
    local share = math.floor(remainingBudget / remainingCount)
    local entry = sorted[i]
    if entry.need <= share then
      caps[entry.id] = entry.need
      remainingBudget = remainingBudget - entry.need
      remainingCount  = remainingCount - 1
    else
      local finalShare = math.max(2, math.floor(remainingBudget / remainingCount))
      for j = i, #sorted do
        caps[sorted[j].id] = finalShare
      end
      break
    end
  end

  return caps
end

-- Downsamples an ordered (x ascending) {x=,y=} step-function point list to
-- exactly `cap` points, resampling at `cap` evenly spaced x-positions across the
-- original list's full x-range (so the first and last resampled points always
-- land exactly on the original first/last x -- the window's left and right
-- edges). Each resampled value carries forward the most recent original point
-- at/before that x (step / forward-fill semantics, matching how the underlying
-- data is actually stored): this is the lossless-as-possible reduction for a
-- piecewise-constant series -- no fabricated values, and a ware that's been
-- flat for the whole window still resamples to a flat line at the same value.
local function decimatePoints(points, cap)
  if #points <= cap then
    return points
  end
  local xStart, xEnd = points[1].x, points[#points].x
  local result = {}
  local srcIdx = 1
  for i = 0, cap - 1 do
    local sampleX = xStart + (xEnd - xStart) * (i / (cap - 1))
    while srcIdx < #points and points[srcIdx + 1].x <= sampleX do
      srcIdx = srcIdx + 1
    end
    result[#result + 1] = { x = sampleX, y = points[srcIdx].y }
  end
  return result
end

-- Time-window context for the currently selected zoom step, shared by the left
-- panel (checkbox-availability point count) and the graph panel (actual
-- plotting), so both agree on exactly the same window/scale.
local function buildZoomContext()
  local now = C.GetCurrentGameTime()
  local zoomStep = config.zoomSteps[menu.xZoom]
  local startTime = math.max(0, now - (60 * zoomStep.zoom))
  local xGranularity = zoomStep.granularity

  local graphXScale = 60
  local xUnitSuffix = "min"
  if xGranularity >= (24 * 60 * 60) then
    graphXScale = 24 * 3600
    xUnitSuffix = "d"
  elseif xGranularity >= (1 * 60 * 60) then
    graphXScale = 3600
    xUnitSuffix = "h"
  end

  return {
    startTime    = startTime,
    now          = now,
    graphXScale  = graphXScale,
    xRange       = (now - startTime) / graphXScale,
    xGranularity = xGranularity,
    xUnitSuffix  = xUnitSuffix,
  }
end

-- Total full-fidelity point count (buildPoints, anchors included) across every
-- currently shown ware for the selected station, for the given display mode
-- ("both" counts both the "real" and "res" lines). Used only to decide
-- checkbox availability -- the actual plotted points may end up lower after
-- decimation.
local function totalShownPoints(ctx, dataMode)
  local total = 0
  if menu.selectedIdcode ~= nil then
    for wareId in pairs(menu.shownWares) do
      local series = swh.getSeries(menu.selectedIdcode, wareId)
      if #series > 0 then
        if dataMode == "both" then
          total = total + #buildPoints(series, ctx, "real") + #buildPoints(series, ctx, "res")
        else
          total = total + #buildPoints(series, ctx, dataMode)
        end
      end
    end
  end
  return total
end

-- *** Menu lifecycle ***

function menu.onShowMenu()
  local stationId64 = menu.param[3]
  menu.selectedIdcode = nil
  if stationId64 ~= nil and stationId64 ~= 0 then
    menu.selectedIdcode = GetComponentData(stationId64, "idcode")
  end
  menu.shownWares = {}
  menu.xZoom = config.defaultZoom
  menu.dataMode = config.defaultDataMode
  menu.createFrame()
end

function menu.viewCreated(_layer, ...)
  -- No persistent table handles are needed across refreshes; tables are
  -- rebuilt from scratch by createFrame() on every refresh.
end

function menu.refreshInfoFrame()
  menu.createFrame()
end

function menu.buttonStationSelected(_, idcode)
  if idcode ~= menu.selectedIdcode then
    menu.selectedIdcode = idcode
    menu.shownWares = {}
    menu.refreshInfoFrame()
  end
end

function menu.checkboxWareToggled(wareId, checked)
  if checked then
    local shownCount = 0
    for _ in pairs(menu.shownWares) do shownCount = shownCount + 1 end
    if shownCount < effectiveWareCaps(menu.dataMode).hard then
      menu.shownWares[wareId] = true
    end
  else
    menu.shownWares[wareId] = nil
  end
  menu.refreshInfoFrame()
end

function menu.buttonZoom(i)
  menu.xZoom = i
  menu.refreshInfoFrame()
end

function menu.buttonDataModeSelected(_, mode)
  if mode ~= menu.dataMode then
    menu.dataMode = mode
    menu.refreshInfoFrame()
  end
end

-- *** Frame construction ***

function menu.createFrame()
  Helper.clearDataForRefresh(menu, config.infoLayer)

  local frameProperties = {
    layer           = config.infoLayer,
    standardButtons = { back = true, close = true, help = true },
    width           = Helper.viewWidth,
    height          = Helper.viewHeight,
    x               = 0,
    y               = 0,
  }
  menu.infoFrame = Helper.createFrameHandle(menu, frameProperties)
  menu.infoFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  local usableWidth = Helper.viewWidth - 2 * Helper.frameBorder
  local leftWidth   = Helper.round(usableWidth * 0.3)
  local graphX      = Helper.frameBorder + leftWidth + Helper.borderSize
  local graphWidth  = usableWidth - leftWidth - Helper.borderSize

  local ctx = buildZoomContext()
  menu.createLeftPanel(Helper.frameBorder, leftWidth, ctx)
  menu.createGraphPanel(graphX, graphWidth, ctx)

  menu.infoFrame:display()
  menu.lastRefreshTime = getElapsedTime()
end

function menu.createLeftPanel(x, width, ctx)
  local leftTable = menu.infoFrame:addTable(2, { tabOrder = 1, width = width, x = x, y = Helper.frameBorder, borderEnabled = true, backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"] })
  leftTable:setColWidth(1, Helper.standardButtonHeight)

  local row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(2):createText(ReadText(1972092430, 1010), Helper.titleTextProperties)

  -- Station selector
  row = leftTable:addRow(false, { fixed = true })
  row[1]:setColSpan(2):createText(ReadText(1972092430, 1011), { halign = "left" })

  local stations = swh.getStationList()
  local options = {}
  local startOption = ""
  for _, station in ipairs(stations) do
    options[#options + 1] = { id = station.idcode, icon = "", text = station.name, displayremoveoption = false }
    if station.idcode == menu.selectedIdcode then
      startOption = station.idcode
    end
  end
  if startOption == "" and #stations > 0 then
    startOption = stations[1].idcode
    menu.selectedIdcode = startOption
  end

  row = leftTable:addRow("station_dropdown", { fixed = true })
  row[1]:setColSpan(2):createDropDown(options, { active = #options > 0, startOption = startOption, height = Helper.standardButtonHeight })
  row[1].handlers.onDropDownConfirmed = menu.buttonStationSelected

  -- Shown-ware count, needed by both the data-mode dropdown (to disable
  -- "Both") and the per-checkbox availability check below.
  local shownCount = 0
  for _ in pairs(menu.shownWares) do shownCount = shownCount + 1 end

  -- Display-mode selector: which stored value(s) to plot per shown ware.
  row = leftTable:addRow(false, { fixed = true })
  row[1]:setColSpan(2):createText(ReadText(1972092430, 1017), { halign = "left" })

  local bothAvailable = shownCount <= config.bothModeMaxWaresToOffer
  local dataModeOptions = {
    { id = "real", icon = "", text = ReadText(1972092430, 1018), displayremoveoption = false },
    { id = "res",  icon = "", text = ReadText(1972092430, 1019), displayremoveoption = false },
    { id = "both", icon = "", text = ReadText(1972092430, 1020), displayremoveoption = false,
      active = bothAvailable, mouseovertext = bothAvailable and "" or ReadText(1972092430, 1021) },
  }
  row = leftTable:addRow("datamode_dropdown", { fixed = true })
  row[1]:setColSpan(2):createDropDown(dataModeOptions, { startOption = menu.dataMode, height = Helper.standardButtonHeight })
  row[1].handlers.onDropDownConfirmed = menu.buttonDataModeSelected

  -- Ware checkboxes
  row = leftTable:addRow(false, { fixed = true })
  row[1]:setColSpan(2):createText(ReadText(1972092430, 1012), { halign = "left" })

  if menu.selectedIdcode == nil then
    row = leftTable:addRow(false, {})
    row[1]:setColSpan(2):createText(ReadText(1972092430, 1016), { halign = "center" })
  else
    local wareList = swh.getWaresForStation(menu.selectedIdcode)
    if #wareList == 0 then
      row = leftTable:addRow(false, {})
      row[1]:setColSpan(2):createText(ReadText(1972092430, 1014), { halign = "center" })
    else
      -- Whether an unchecked checkbox may still be checked. Below the
      -- (mode-adjusted) soft limit, always; at the hard cap, never (no point
      -- counting needed); in between, only while the currently shown wares'
      -- combined point count stays under the budget.
      local caps = effectiveWareCaps(menu.dataMode)
      local allowMore
      if shownCount >= caps.hard then
        allowMore = false
      elseif shownCount >= caps.soft then
        allowMore = totalShownPoints(ctx, menu.dataMode) < config.wareSelectionPointsBudget
      else
        allowMore = true
      end

      for _, wareId in ipairs(wareList) do
        local wareName = GetWareData(wareId, "name") or wareId
        local isShown = menu.shownWares[wareId] == true
        row = leftTable:addRow("ware_" .. wareId, {})
        row[1]:createCheckBox(isShown, { height = Helper.standardTextHeight, active = isShown or allowMore })
        row[1].handlers.onClick = function (_, checked) return menu.checkboxWareToggled(wareId, checked) end
        row[2]:createText(wareName, { halign = "left" })
      end
    end
  end
end

function menu.createGraphPanel(x, width, ctx)
  local graphHeight = math.floor(width * 9 / 16)
  local table_graph = menu.infoFrame:addTable(1, { tabOrder = 2, width = width, x = x, y = Helper.frameBorder })

  local title = (menu.selectedIdcode ~= nil) and swh.getStationName(menu.selectedIdcode) or ""

  local row = table_graph:addRow(false, { fixed = true })
  menu.graph = row[1]:createGraph({ height = graphHeight, scaling = false })
    :setTitle(title, { font = Helper.titleFont, fontsize = Helper.scaleFont(Helper.titleFont, Helper.titleFontSize) })

  -- Build every shown line's full-fidelity point list first, so we know the
  -- total before deciding whether anything needs to be downsampled to stay
  -- within the graph's shared point budget (config.maxTotalPoints, across all
  -- lines combined -- not per line). In "both" mode each shown ware produces
  -- two lines (key="real" and key="res"), each counted/capped independently.
  local lines = {}
  if menu.selectedIdcode ~= nil then
    local keys = (menu.dataMode == "both") and { "real", "res" } or { menu.dataMode }
    for wareId in pairs(menu.shownWares) do
      local series = swh.getSeries(menu.selectedIdcode, wareId)
      if #series > 0 then
        for _, key in ipairs(keys) do
          local points = buildPoints(series, ctx, key)
          lines[#lines + 1] = { id = wareId .. "#" .. key, wareId = wareId, key = key, points = points, need = #points }
        end
      end
    end
  end

  local totalPoints = 0
  for _, line in ipairs(lines) do
    totalPoints = totalPoints + line.need
  end

  local caps = nil
  if totalPoints > config.maxTotalPoints then
    caps = fairShareCaps(lines, config.maxTotalPoints)
    debugLog("createGraphPanel: %d point(s) across %d line(s) exceeds the %d budget, downsampling.",
      totalPoints, #lines, config.maxTotalPoints)
  end

  local maxY = 1
  local wareList = (menu.selectedIdcode ~= nil) and swh.getWaresForStation(menu.selectedIdcode) or {}
  for _, line in ipairs(lines) do
    local points = line.points
    if caps ~= nil and #points > caps[line.id] then
      points = decimatePoints(points, caps[line.id])
    end

    local color
    local wareName = GetWareData(line.wareId, "name") or line.wareId
    local mouseOverText = wareName
    if menu.dataMode == "both" then
      local realColor, resColor = colorPairForWare(wareList, line.wareId)
      color = (line.key == "real") and realColor or resColor
      mouseOverText = wareName .. " (" .. ReadText(1972092430, (line.key == "real") and 1022 or 1023) .. ")"
    else
      color = colorForWare(wareList, line.wareId)
    end

    local datarecord = menu.graph:addDataRecord({
      markertype  = config.point.type,
      markersize  = config.point.size,
      markercolor = color,
      linetype    = config.line.type,
      linewidth   = config.line.size,
      linecolor   = color,
      mouseOverText = mouseOverText,
    })
    for _, p in ipairs(points) do
      datarecord:addData(p.x, p.y, nil, nil)
      maxY = math.max(maxY, p.y)
    end
  end

  -- Round the Y axis' top up to the nearest config.maxYRoundTo (1000) so it
  -- reads as a clean number rather than whatever the data happens to peak at.
  maxY = math.max(config.maxYRoundTo, math.ceil(maxY / config.maxYRoundTo) * config.maxYRoundTo)
  local granularity = maxY / 10

  local xRange = ctx.xRange
  local xGran  = Helper.round(ctx.xGranularity / ctx.graphXScale, 3)

  menu.graph:setXAxis({ startvalue = -xRange, endvalue = 0, granularity = xGran, gridcolor = Color["graph_grid"] })
  menu.graph:setXAxisLabel(ReadText(1001, 6519) .. " (" .. ctx.xUnitSuffix .. ")")
  local yUnitText = ReadText(1972092430, 1015)
  menu.graph:setYAxis({ startvalue = 0, endvalue = maxY, granularity = granularity, gridcolor = Color["graph_grid"] })
  menu.graph:setYAxisLabel(yUnitText)

  -- Time-range buttons, mirrored from the transaction log's range-selection row.
  local table_zoom = menu.infoFrame:addTable(#config.zoomSteps, { tabOrder = 3, borderEnabled = false, width = width, x = x, y = (table_graph.properties.y + table_graph:getFullHeight() + Helper.borderSize), backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"] })
  row = table_zoom:addRow(true, { fixed = true })
  for i = #config.zoomSteps, 1, -1 do
    local label = (i == #config.zoomSteps) and ReadText(1001, 19) or config.zoomSteps[i].label
    local col = #config.zoomSteps - i + 1
    if menu.xZoom == i then
      row[col]:createButton({ bgColor = Color["row_background_selected"] }):setText(label, { halign = "center" })
    else
      row[col]:createButton():setText(label, { halign = "center" })
      row[col].handlers.onClick = function () return menu.buttonZoom(i) end
    end
  end
end

-- *** Standard menu callbacks ***

function menu.onUpdate()
  if menu.infoFrame then
    menu.infoFrame:update()
  end
  local curtime = getElapsedTime()
  if curtime > menu.lastRefreshTime + 10 then
    menu.refreshInfoFrame()
  end
end

function menu.onCloseElement(dueToClose)
  Helper.closeMenu(menu, dueToClose)
  menu.cleanup()
end

local function Init()
  init()
  RegisterEvent("StationWareHistory.OpenMenu", onOpenMenuEvent)
end

Register_OnLoad_Init(Init)
