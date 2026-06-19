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
  maxShownWares = 8, -- one per available graph_data_N color
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
-- across checkbox toggles.
local function colorForWare(wareList, wareId)
  for i, w in ipairs(wareList) do
    if w == wareId then
      return config.seriesColors[((i - 1) % #config.seriesColors) + 1]
    end
  end
  return config.seriesColors[1]
end

-- Plots one change-only series onto a graph data record, adding two carry-forward
-- anchor points so the line stays continuous even though most wares only get a
-- new stored point when their value actually changes:
--   - left edge (x = -xRange): the most recent known value at/before the visible
--     window's start, so a ware unchanged for longer than the selected zoom range
--     still draws a flat line across the whole window instead of showing nothing;
--   - right edge (x = 0 / "now"): the series' latest known value, so the line
--     reaches the present instead of stopping at whenever the value last changed.
-- ctx (mutable) carries { startTime, now, graphXScale, xRange, minY, maxY }.
local function plotSeries(datarecord, series, ctx)
  local lastBefore, firstInWindowIdx = nil, nil
  for i = 1, #series do
    local point = series[i]
    if point.t <= ctx.startTime then
      lastBefore = point
    elseif firstInWindowIdx == nil then
      firstInWindowIdx = i
    end
  end

  local lastPlottedX = nil
  if lastBefore ~= nil then
    datarecord:addData(-ctx.xRange, lastBefore.v, nil, nil)
    ctx.minY = math.min(ctx.minY, lastBefore.v)
    ctx.maxY = math.max(ctx.maxY, lastBefore.v)
    lastPlottedX = -ctx.xRange
  end

  if firstInWindowIdx ~= nil then
    for i = firstInWindowIdx, #series do
      local point = series[i]
      local px = (point.t - ctx.now) / ctx.graphXScale
      datarecord:addData(px, point.v, nil, nil)
      ctx.minY = math.min(ctx.minY, point.v)
      ctx.maxY = math.max(ctx.maxY, point.v)
      lastPlottedX = px
    end
  end

  if lastPlottedX == nil or lastPlottedX < 0 then
    local latestValue = series[#series].v
    datarecord:addData(0, latestValue, nil, nil)
    ctx.minY = math.min(ctx.minY, latestValue)
    ctx.maxY = math.max(ctx.maxY, latestValue)
  end
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
    if shownCount < config.maxShownWares then
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

  menu.createLeftPanel(Helper.frameBorder, leftWidth)
  menu.createGraphPanel(graphX, graphWidth)

  menu.infoFrame:display()
  menu.lastRefreshTime = getElapsedTime()
end

function menu.createLeftPanel(x, width)
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
      for _, wareId in ipairs(wareList) do
        local wareName = GetWareData(wareId, "name") or wareId
        row = leftTable:addRow("ware_" .. wareId, {})
        row[1]:createCheckBox(menu.shownWares[wareId] == true, { height = Helper.standardTextHeight })
        row[1].handlers.onClick = function (_, checked) return menu.checkboxWareToggled(wareId, checked) end
        row[2]:createText(wareName, { halign = "left" })
      end
    end
  end
end

function menu.createGraphPanel(x, width)
  local now = C.GetCurrentGameTime()
  local zoomStep   = config.zoomSteps[menu.xZoom]
  local startTime  = math.max(0, now - (60 * zoomStep.zoom))
  local xGranularity = zoomStep.granularity

  local graphHeight = math.floor(width * 9 / 16)
  local table_graph = menu.infoFrame:addTable(1, { tabOrder = 2, width = width, x = x, y = Helper.frameBorder })

  local title = (menu.selectedIdcode ~= nil) and swh.getStationName(menu.selectedIdcode) or ""

  local row = table_graph:addRow(false, { fixed = true })
  menu.graph = row[1]:createGraph({ height = graphHeight, scaling = false })
    :setTitle(title, { font = Helper.titleFont, fontsize = Helper.scaleFont(Helper.titleFont, Helper.titleFontSize) })

  local graphXScale = 60
  local xUnitSuffix = "min"
  if xGranularity >= (24 * 60 * 60) then
    graphXScale = 24 * 3600
    xUnitSuffix = "d"
  elseif xGranularity >= (1 * 60 * 60) then
    graphXScale = 3600
    xUnitSuffix = "h"
  end

  local ctx = {
    startTime    = startTime,
    now          = now,
    graphXScale  = graphXScale,
    xRange       = (now - startTime) / graphXScale,
    minY         = 0,
    maxY         = 1,
  }

  if menu.selectedIdcode ~= nil then
    local wareList = swh.getWaresForStation(menu.selectedIdcode)
    for wareId in pairs(menu.shownWares) do
      local series = swh.getSeries(menu.selectedIdcode, wareId)
      if #series > 0 then
        local color = colorForWare(wareList, wareId)
        local datarecord = menu.graph:addDataRecord({
          markertype  = config.point.type,
          markersize  = config.point.size,
          markercolor = color,
          linetype    = config.line.type,
          linewidth   = config.line.size,
          linecolor   = color,
          mouseOverText = GetWareData(wareId, "name") or wareId,
        })
        plotSeries(datarecord, series, ctx)
      end
    end
  end

  local maxY = math.max(ctx.maxY, 1)
  local granularity = math.max(1, Helper.round((maxY - ctx.minY) / 10))

  local xRange = ctx.xRange
  local xGran  = Helper.round(xGranularity / graphXScale, 3)

  menu.graph:setXAxis({ startvalue = -xRange, endvalue = 0, granularity = xGran, gridcolor = Color["graph_grid"] })
  menu.graph:setXAxisLabel(ReadText(1001, 6519) .. " (" .. xUnitSuffix .. ")")
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
