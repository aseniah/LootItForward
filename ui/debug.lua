local _, LIF = ...

local frame, refreshTicker

local DEBUG_WIDTH = 420   -- matches f:SetSize below
local MIN_ONSCREEN = 40   -- px of the frame that must stay visible
local TITLE_STRIP = 22    -- draggable title height; keep it within the screen

-- Is a saved (x, y) actually on the current screen? Anchor is TOPLEFT against
-- UIParent BOTTOMLEFT, so x is the left edge and y the top edge's height above the
-- bottom. Positive-form comparisons so a NaN coord reads as off-screen. Mirrors the
-- popup's _isOnScreen so both windows judge a saved position the same way.
local function _isOnScreen(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local w = UIParent:GetWidth() or 1024
  local h = UIParent:GetHeight() or 768
  local visibleW = math.min(x + DEBUG_WIDTH, w) - math.max(x, 0)
  if not (visibleW >= MIN_ONSCREEN) then return false end
  if not (y <= h and y >= TITLE_STRIP) then return false end
  return true
end

-- Resolve the saved position, self-healing a corrupt/off-screen one: return its
-- coords if valid AND on-screen, else CLEAR the stored value (so it stops
-- persisting a lost point — the debug window used to rely only on the runtime
-- SetClampedToScreen, leaving a bad save in place forever) and return nil so the
-- caller centres. Matches the popup's _resolvePopupPosition self-heal.
local function _resolveDebugPosition()
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.debugPosition
  if pos and _isOnScreen(pos.x, pos.y) then
    return pos.x, pos.y
  end
  if pos and LootItForward and LootItForward.db then
    LootItForward.db.char.debugPosition = nil
    LIF.Log("debug: saved position off-screen — re-centering")
  end
  return nil
end

local function _saveDebugPosition()
  local xOfs = frame:GetLeft() - UIParent:GetLeft()
  local yOfs = frame:GetTop() - UIParent:GetBottom()
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", xOfs, yOfs)
  if LootItForward and LootItForward.db then
    LootItForward.db.char.debugPosition = { x = xOfs, y = yOfs }
  end
end

function LIF.Debug_RestorePosition()
  if not frame then return end
  local x, y = _resolveDebugPosition()
  frame:ClearAllPoints()
  if x and y then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  else
    frame:SetPoint("CENTER")
  end
end

local function buildLines()
  local lines = {}
  local _, instanceType = IsInInstance()
  -- REV-013: use the real activation gate (instance type, enableOpenWorld,
  -- arena/bg exclusions) instead of a divergent re-implementation.
  local active = LootItForward and LootItForward.ShouldBeActive
    and LootItForward:ShouldBeActive() or false

  lines[#lines+1] = ("|cffffd700Active:|r %s  |cffffd700Instance:|r %s  |cffffd700Group:|r %s"):format(
    active and "|cff00ff00yes|r" or "|cffff4444no|r",
    instanceType or "none",
    tostring(IsInGroup()))

  local dbg = LIF.GetDebugInfo()
  local skipHeirloom = LootItForward and LootItForward.db and LootItForward.db.char.skipHeirloomCheck
  lines[#lines+1] = ("|cffffd700Queue:|r %d  |cffffd700Inspecting:|r %s  |cffffd700Ticker:|r %s  |cffffd700Heirloom:|r %s"):format(
    dbg.queueLength,
    dbg.currentlyInspecting and dbg.currentlyInspecting:sub(-6) or "none",
    dbg.tickerRunning and "|cff00ff00on|r" or "off",
    skipHeirloom and "|cffff4444skip|r" or "|cff00ff00check|r")

  local all = LIF.Cache.GetAll()
  local count = 0
  for guid, m in pairs(all) do
    local unit = LIF.GuidToUnit(guid)
    local name = unit and UnitName(unit) or "?"
    local slots = 0
    if m.gear then
      for _ in pairs(m.gear) do slots = slots + 1 end
    end
    local stateColor = m.state == "COMPLETE" and "|cff00ff00" or "|cffffff00"
    local specLabel = (m.specID and LIF.SPEC_LABEL[m.specID]) or tostring(m.specID or "?")
    lines[#lines+1] = ("  %s  %s%s|r  %-10s  gear=%d/16  lvl=%s  ilvl=%s  %s"):format(
      guid:sub(-6), stateColor, m.state,
      specLabel, slots, tostring(m.lvl or "?"), tostring(m.ilvl or "?"), name)
    count = count + 1
  end
  if count == 0 then lines[#lines+1] = "  |cff888888cache is empty|r" end

  -- Last 5 log entries
  lines[#lines+1] = "|cff555555--- log ---|r"
  local entries = LIF.GetLog()
  local start = math.max(1, #entries - 4)
  for i = start, #entries do
    local e = entries[i]
    lines[#lines+1] = ("|cff888888%s|r  %s"):format(e.t, e.msg)
  end
  if #entries == 0 then lines[#lines+1] = "|cff555555(empty)|r" end

  return lines
end

-- Keeps the toggle button's label in sync with the saved flag, including
-- changes made via /lif heirloom on|off while the window is open.
local function updateHeirloomButton()
  if not frame or not frame.btnHeirloom then return end
  local skip = LootItForward and LootItForward.db and LootItForward.db.char.skipHeirloomCheck
  frame.btnHeirloom:SetText(skip and "Heirloom Check: Off" or "Heirloom Check: On")
end

local function refresh()
  if not frame or not frame:IsShown() then return end
  frame.content:SetText(table.concat(buildLines(), "\n"))
  frame.title:SetText(("LIF Debug  |cff888888%.0fs|r"):format(GetTime() % 60))
  if #LIF.GetLog() > 0 then frame.btnClearLog:Enable() else frame.btnClearLog:Disable() end
  if #LIF.GetInspectRecords() > 0 then frame.btnClearInspects:Enable() else frame.btnClearInspects:Disable() end
  updateHeirloomButton()
end

local function createFrame()
  local f = CreateFrame("Frame", "LIFDebugFrame", UIParent, "BackdropTemplate")
  f:SetSize(DEBUG_WIDTH, 264)
  local x, y = _resolveDebugPosition()
  if x and y then
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  else
    f:SetPoint("CENTER")
  end
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then f:StartMoving() end
  end)
  f:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      f:StopMovingOrSizing()
      _saveDebugPosition()
    end
  end)
  f:SetToplevel(true)
  f:SetFrameStrata("MEDIUM")

  f:SetBackdrop({
    bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left=3, right=3, top=3, bottom=3 },
  })
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
  f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", 8, -6)
  f.title = title

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetSize(18, 18)
  close:SetPoint("TOPRIGHT", -2, -2)
  -- X IS /lif debug off (REV-014): persists the flag, cancels the refresh
  -- ticker, and prints the same chat confirmation.
  close:SetScript("OnClick", function()
    LIF.SetDebugMode(false)
  end)

  local content = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  content:SetPoint("TOPLEFT", 8, -22)
  content:SetPoint("BOTTOMRIGHT", -8, 30)
  content:SetJustifyH("LEFT")
  content:SetJustifyV("TOP")
  f.content = content

  local btnClearLog = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnClearLog:SetSize(120, 22)
  btnClearLog:SetPoint("BOTTOMLEFT", 8, 5)
  btnClearLog:SetText("Clear Log")
  btnClearLog:SetScript("OnClick", function()
    LIF.ClearLog()
    refresh()
  end)
  f.btnClearLog = btnClearLog

  local btnClearInspects = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnClearInspects:SetSize(130, 22)
  btnClearInspects:SetPoint("BOTTOMRIGHT", -8, 5)
  btnClearInspects:SetText("Clear Inspects")
  btnClearInspects:SetScript("OnClick", function()
    LIF.ClearInspectRecords()
    refresh()
  end)
  f.btnClearInspects = btnClearInspects

  -- Sits in the gap between Clear Log and Clear Inspects (154px available at 420px width).
  local btnHeirloom = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnHeirloom:SetSize(140, 22)
  btnHeirloom:SetPoint("BOTTOM", f, "BOTTOM", 0, 5)
  btnHeirloom:SetScript("OnClick", function()
    if not (LootItForward and LootItForward.db) then return end
    local enabled = not LootItForward.db.char.skipHeirloomCheck
    LootItForward.db.char.skipHeirloomCheck = enabled
    LIF.Log("heirloom check skip " .. (enabled and "on" or "off"))
    refresh()
  end)
  f.btnHeirloom = btnHeirloom

  f:Hide()
  return f
end

local function showDebugWindow()
  if not frame then frame = createFrame() end
  frame:Show()
  frame:Raise()
  -- Anchor AFTER Show: SetPoint on the freshly-created, still-hidden frame in
  -- createFrame doesn't land (the centre/saved point resolves to a corner until the
  -- frame is realized). Re-applying it here on the shown frame mirrors how ShowPopup
  -- re-anchors post-populate, and self-heals an off-screen save via _resolveDebugPosition.
  LIF.Debug_RestorePosition()
  refresh()
  if not refreshTicker then
    refreshTicker = C_Timer.NewTicker(3, refresh)
  end
end

function LIF.ShowDebugWindow()
  showDebugWindow()
end

function LIF.HideDebugWindow()
  if frame then frame:Hide() end
  if refreshTicker then refreshTicker:Cancel(); refreshTicker = nil end
end

-- Single switch for debug mode — used by /lif debug on|off AND the window's
-- close button, so every path persists the flag, shows/hides the window, and
-- announces in chat identically.
function LIF.SetDebugMode(enabled)
  if LootItForward and LootItForward.db then
    LootItForward.db.char.debugMode = enabled
  end
  if enabled then
    LIF.ShowDebugWindow()
  else
    LIF.HideDebugWindow()
  end
  LIF.Print("debug mode " .. (enabled and "on" or "off"))
end

