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
  -- "Show less"/"show more" zoom (mirrors the transaction log's +/- zoom, but
  -- continuous rather than a fixed step table): menu.zoomMinutes always
  -- doubles/halves, floored at zoomMinimumMinutes and capped only by whatever
  -- history actually exists -- see computeStationMaxRangeMinutes().
  zoomMinimumMinutes = 15,
  zoomDefaultMinutes = 60,
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
  menu.container = nil
  menu.sidebarWidth = nil
end

-- *** Lua-event entry point: opens the menu for a given station component ***

local function onOpenMenuEvent(_, stationLuaId)
  local station64 = ConvertIDTo64Bit(stationLuaId)
  -- param2 = explicit back-target: with no back-target, Helper.closeMenu's
  -- "back" handling falls through to the engine's generic DockedMenu/
  -- TopLevelMenu/nothing fallback instead of returning to the map, since this
  -- menu is always opened from there (via the station's interaction menu).
  OpenMenu("StationWareHistoryMenu", { 0, 0, station64 }, { "MapMenu", { 0, 0 }, nil })
end

-- *** Right side bar integration ***
--
-- Helper.rightSideBar (ego_detailmonitorhelper/helper.lua) is the shared,
-- module-level icon list every station menu with a right side bar
-- (StationConfigurationMenu, StationOverviewMenu, TransactionLogMenu) renders
-- from -- a plain table, appendable at runtime without patching anything.
-- Helper.createRightSideBar's render loop defaults entries with no
-- canresearch/canterraform key to display=true, active=true unconditionally
-- (only "construction"/"transactions" get isplayerowned-gated active state,
-- hardcoded by mode name) -- so our entry shows up active on every station
-- regardless of ownership. Accepted trade-off: clicking it on a station we
-- have no data for just shows our own "no wares with recorded history" empty
-- state (see createLeftPanel) -- no crash, no patch needed beyond this.
--
-- The icon-to-menu mapping (Helper.buttonRightBar) is a flat if/elseif chain
-- with no dispatch table, so wiring our mode in requires wrapping that
-- function: try our mode first, otherwise fall through to the original.
-- Helper.rightSideBar and Helper.buttonRightBar are byte-for-byte identical
-- between 8.00 and 9.00 (diffed directly against
-- extracted/8.00/ui/addons/ego_detailmonitorhelper/helper.lua) -- only
-- Helper.createRightSideBar's call signature differs (see swh.isV9 branch in
-- createFrame below), so nothing here needs a version guard.
local function installRightSideBarEntry()
  if Helper == nil or Helper.rightSideBar == nil then
    return
  end
  for _, entry in ipairs(Helper.rightSideBar) do
    if entry.mode == "wareHistory" then
      return -- already installed (e.g. Init() re-running on a ui reload)
    end
  end

  local insertAt = #Helper.rightSideBar + 1
  for i, entry in ipairs(Helper.rightSideBar) do
    if entry.mode == "transactions" then
      insertAt = i
      break
    end
  end
  table.insert(Helper.rightSideBar, insertAt, {
    name = ReadText(1972092430, 1004),
    icon = "pi_statistics",
    mode = "wareHistory",
  })

  if not Helper.__swhButtonRightBarPatched then
    local originalButtonRightBar = Helper.buttonRightBar
    Helper.buttonRightBar = function (container, currentmode, callback, selfcallback, mode, row)
      if mode == "wareHistory" then
        if mode ~= currentmode then
          callback("StationWareHistoryMenu", { 0, 0, container })
        elseif selfcallback then
          selfcallback()
        end
        return
      end
      return originalButtonRightBar(container, currentmode, callback, selfcallback, mode, row)
    end
    Helper.__swhButtonRightBarPatched = true
  end
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

-- Downsamples an ordered (x ascending) {x=,y=} step-function point list to at
-- most `cap` points using min/max-per-bucket decimation (the same technique
-- charting/monitoring tools use for this exact reason -- Highcharts' Boost
-- module, Grafana, RRDtool, etc.): resampling at fixed x-positions instead
-- (the previous approach here) can silently skip any excursion that falls
-- entirely between two sample positions, making volatile data look falsely
-- flat/smooth. Dividing the range into buckets and keeping both the minimum-
-- and maximum-value point from each guarantees any excursion within a bucket
-- is represented by at least its extreme value.
--
-- The very first and last input points are always kept verbatim (not run
-- through bucketing) so the two continuity anchors buildPoints() adds (left
-- edge of the window, and "now") still land exactly where they're supposed
-- to -- losing that would undermine the whole point of having them.
-- The remaining budget (cap - 2) is split into floor((cap-2)/2) buckets, each
-- contributing up to 2 points (its min and max, in chronological order, or
-- just 1 if they coincide). A bucket with no real points in it forward-fills
-- a single point at its right edge from the last known value, rather than
-- being skipped -- skipping it would draw a direct line between two
-- non-adjacent points, implying a gradual ramp where the real, piecewise-
-- constant data actually held flat and then jumped.
local function decimatePoints(points, cap)
  if #points <= cap then
    return points
  end
  if cap <= 2 then
    return { points[1], points[#points] }
  end

  local first, last = points[1], points[#points]
  local numBuckets  = math.max(1, math.floor((cap - 2) / 2))
  local xStart, xEnd = first.x, last.x
  local bucketWidth  = (xEnd - xStart) / numBuckets

  local result    = { first }
  local lastValue = first.y
  local srcIdx    = 2 -- index 1 (first) is already emitted

  for b = 0, numBuckets - 1 do
    local bucketEnd = (b == numBuckets - 1) and xEnd or (xStart + (b + 1) * bucketWidth)

    local minPoint, maxPoint = nil, nil
    while srcIdx < #points and points[srcIdx].x <= bucketEnd do
      local p = points[srcIdx]
      if minPoint == nil or p.y < minPoint.y then minPoint = p end
      if maxPoint == nil or p.y > maxPoint.y then maxPoint = p end
      srcIdx = srcIdx + 1
    end

    if minPoint == nil then
      result[#result + 1] = { x = bucketEnd, y = lastValue }
    elseif minPoint == maxPoint then
      result[#result + 1] = minPoint
      lastValue = minPoint.y
    elseif minPoint.x <= maxPoint.x then
      result[#result + 1] = minPoint
      result[#result + 1] = maxPoint
      lastValue = maxPoint.y
    else
      result[#result + 1] = maxPoint
      result[#result + 1] = minPoint
      lastValue = minPoint.y
    end
  end

  result[#result + 1] = last
  return result
end

-- The full history span actually available for a station, in minutes: from the
-- earliest recorded point across ANY of its tracked wares (not just currently
-- shown ones -- this needs to be well-defined before any checkbox is ticked,
-- e.g. to pick the initial default zoom) to "now". Returns math.huge if there's
-- no station selected or no data at all yet, so callers that compare against it
-- (show-more disablement, the default-zoom cap) simply don't restrict anything
-- in that case. series are stored ascending by t, so the first entry is the
-- earliest.
local function computeStationMaxRangeMinutes(idcode, now)
  if idcode == nil then
    return math.huge
  end
  local earliest = nil
  for _, wareId in ipairs(swh.getWaresForStation(idcode)) do
    local series = swh.getSeries(idcode, wareId)
    if #series > 0 and (earliest == nil or series[1].t < earliest) then
      earliest = series[1].t
    end
  end
  if earliest == nil then
    return math.huge
  end
  return math.max(config.zoomMinimumMinutes, (now - earliest) / 60)
end

-- Display label for the current "show less"/"show more" interval. Every value
-- in the doubling sequence starting at 15 (15,30,60,120,240,480,...) is an
-- exact whole number of hours once >=60 (since 60 itself is in the sequence,
-- and every later step is just 60 * 2^n) -- unlike days (1440 = 60*24, and 24
-- is not a power of two), so this deliberately never converts to a "d" unit;
-- large values just read as e.g. "128h" rather than introducing a fractional
-- day count.
local function formatZoomLabel(minutes)
  if minutes < 60 then
    return Helper.round(minutes) .. "m"
  end
  return Helper.round(minutes / 60) .. "h"
end

-- Time-window context for the current "show less"/"show more" interval,
-- shared by the left panel (checkbox-availability point count) and the graph
-- panel (actual plotting), so both agree on exactly the same window/scale.
local function buildZoomContext()
  local now = C.GetCurrentGameTime()
  local startTime = math.max(0, now - (60 * menu.zoomMinutes))
  -- Aim for ~6 gridlines across the visible window.
  local xGranularity = (60 * menu.zoomMinutes) / 6

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

-- Default zoom for the (newly) selected station: 1h, unless its actual
-- recorded history is shorter, in which case use that instead (still floored
-- at zoomMinimumMinutes).
local function setDefaultZoomForStation()
  local maxRange = computeStationMaxRangeMinutes(menu.selectedIdcode, C.GetCurrentGameTime())
  menu.zoomMinutes = math.max(config.zoomMinimumMinutes, math.min(config.zoomDefaultMinutes, maxRange))
end

function menu.onShowMenu()
  local stationId64 = menu.param[3]
  menu.selectedIdcode = nil
  if stationId64 ~= nil and stationId64 ~= 0 then
    menu.selectedIdcode = GetComponentData(stationId64, "idcode")
  end
  menu.shownWares = {}
  menu.dataMode = config.defaultDataMode
  setDefaultZoomForStation()
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
    setDefaultZoomForStation()
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

function menu.buttonZoomLess()
  menu.zoomMinutes = math.max(config.zoomMinimumMinutes, menu.zoomMinutes / 2)
  menu.refreshInfoFrame()
end

function menu.buttonZoomMore()
  menu.zoomMinutes = menu.zoomMinutes * 2
  menu.refreshInfoFrame()
end

function menu.buttonDataModeSelected(_, mode)
  if mode ~= menu.dataMode then
    menu.dataMode = mode
    menu.refreshInfoFrame()
  end
end

-- *** Frame construction ***

-- Mirrors TransactionLogMenu's own menu.buttonRightBar: navigating to another
-- right-side-bar entry (Trade, Overview, Configuration, ...) from within our
-- menu closes us and opens the target with noreturn=true, so the target
-- inherits whatever back-target we ourselves had (see onOpenMenuEvent).
function menu.buttonRightBar(newmenu, params)
  Helper.closeMenuAndOpenNewMenu(menu, newmenu, params, true)
  menu.cleanup()
end

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

  -- Live 64-bit ref for the selected station, needed to mirror the right side
  -- bar (Trade/Overview/Configuration/...) the same way TransactionLogMenu
  -- does. Sourced from the collector's per-station cache, refreshed every
  -- collection cycle -- nil right after a fresh load before the first
  -- collection pass, or if the station no longer exists; the bar is simply
  -- omitted in that case rather than erroring.
  local stationLuaId = (menu.selectedIdcode ~= nil) and swh.getStationLuaId(menu.selectedIdcode) or nil
  menu.container = (stationLuaId ~= nil) and ConvertIDTo64Bit(stationLuaId) or nil

  -- Mirrors TransactionLogMenu's own createFrame ordering exactly: the right
  -- side bar is created first (before any of our own content tables), and its
  -- table is wired into the tab-navigation chain via addConnection.
  --
  -- Helper.createRightSideBar's signature itself changed in 9.00 (diffed
  -- directly against extracted/8.00 and extracted/9.00's helper.lua):
  --   8.00: Helper.createRightSideBar(frame, container, condition, currentmode, callback, selfcallback)
  --   9.00: Helper.createRightSideBar(menu, frame, container, condition, currentmode, callback, selfcallback, refreshcallback)
  -- 9.00 inserted `menu` as a new first parameter (and an unused trailing
  -- refreshcallback). Calling the 9.00 form under 8.00 shifts every argument
  -- one slot left -- our `menu` table lands in the `frame` slot, so the
  -- function's internal `frame:addTable(...)` becomes `menu:addTable(...)`,
  -- which doesn't exist. This is exactly what crashed before this fix.
  local showSidebar = (menu.container ~= nil)
  if showSidebar then
    menu.sidebarWidth = Helper.scaleX(Helper.sidebarWidth)
    local rightbartable
    if swh.isV9 then
      rightbartable = Helper.createRightSideBar(menu, menu.infoFrame, menu.container, true, "wareHistory", menu.buttonRightBar)
    else
      rightbartable = Helper.createRightSideBar(menu.infoFrame, menu.container, true, "wareHistory", menu.buttonRightBar)
    end
    rightbartable:addConnection(1, 4, true)
  end

  local usableWidth = Helper.viewWidth - 2 * Helper.frameBorder
  if showSidebar then
    usableWidth = usableWidth - menu.sidebarWidth - Helper.borderSize
  end
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

  -- "Show less" / current interval / "show more" row, mirrored from the
  -- transaction log's +/- zoom buttons but continuous rather than a fixed step
  -- table. "Show less" disables at the 15-minute floor; "show more" disables
  -- once the current interval already covers the station's full recorded
  -- history (computeStationMaxRangeMinutes) -- doubling further wouldn't
  -- reveal any more data.
  local maxRangeMinutes = computeStationMaxRangeMinutes(menu.selectedIdcode, ctx.now)
  local showLessActive  = menu.zoomMinutes > config.zoomMinimumMinutes
  local showMoreActive  = menu.zoomMinutes < maxRangeMinutes

  local table_zoom = menu.infoFrame:addTable(9, { tabOrder = 3, borderEnabled = false, width = width, x = x, y = (table_graph.properties.y + table_graph:getFullHeight() + Helper.borderSize), backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"] })
  row = table_zoom:addRow(true, { fixed = true })
  row[4]:createButton({ active = showLessActive }):setText(ReadText(1001, 7777), { halign = "center" })
  row[4].handlers.onClick = function () return menu.buttonZoomLess() end
  row[5]:createText(formatZoomLabel(menu.zoomMinutes), { halign = "center" })
  row[6]:createButton({ active = showMoreActive }):setText(ReadText(1001, 7778), { halign = "center" })
  row[6].handlers.onClick = function () return menu.buttonZoomMore() end
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
  installRightSideBarEntry()
  RegisterEvent("StationWareHistory.OpenMenu", onOpenMenuEvent)
end

Register_OnLoad_Init(Init)
