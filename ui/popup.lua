local _, LIF = ...

-- ============================================================
-- LIFItemTooltip / LIFCompareTooltip — created once at file load scope.
-- Both use GameTooltipTemplate but are NOT named "GameTooltip", so TSM hooks
-- and Blizzard's shopping-tooltip system (which watch GameTooltip by name) never
-- interfere with them.
-- CRITICAL: must be at load scope, not inside a function (D-11 anti-pattern).
-- ============================================================
LIFItemTooltip = CreateFrame("GameTooltip", "LIFItemTooltip", UIParent, "GameTooltipTemplate")
LIFItemTooltip:SetClampedToScreen(true)

LIFCompareTooltip = CreateFrame("GameTooltip", "LIFCompareTooltip", UIParent, "GameTooltipTemplate")
LIFCompareTooltip:SetClampedToScreen(true)

-- Module-local upvalues.
-- Plans 02 and 03 extend itemSections by adding item section sub-frames and candidate rows.
local frame               -- the popup frame (lazily created by createPopupFrame)
local itemSections = {}   -- keyed by itemLink

-- Frame dimension constants
local FRAME_WIDTH      = 340
local FRAME_MIN_HEIGHT = 30   -- title bar (24px) + bottom padding (6px)
local TITLE_BAR_HEIGHT = 24
local SECTION_HEADER_H = 44
local ROW_H            = 48
local SECTION_GAP      = 6
local SECTION_INSET    = 6    -- keeps sections inside the 1px edgeFile border

-- Forward declaration — _removeSection is defined after the layout helpers.
local _removeSection

-- pendingTrade: set by [Trade] button OnClick; consumed by TRADE_SHOW handler.
-- Shape: { itemLink = string, unit = string, t = GetTime() } or nil.
-- TTL guard (REV-007): InitiateTrade can fail silently (target out of trade
-- range, dead, busy, declined) and TRADE_SHOW never fires — without an expiry
-- a later unrelated trade window (even one another player opens with us)
-- would auto-populate the loot item into trade slot 1.
local pendingTrade = nil
local PENDING_TRADE_TTL = 5  -- seconds; TRADE_SHOW from our InitiateTrade arrives well within this

-- Bag-cache-lag retry budget for TRADE_CLOSED's "did the item leave bags" check.
-- Same WoW client behavior as core/loot.lua's confirmTradeableAndProceed (dfec109):
-- the bag cache can still report a just-traded item as present for longer than
-- one 0.3s check during a busy moment. Retry until the item disappears
-- (completed) or the budget is exhausted (genuinely cancelled).
local TRADE_CLOSED_RETRY_DELAY = 0.3
local TRADE_CLOSED_RETRY_MAX   = 5

-- tradedItemLink: set by TRADE_SHOW after auto-populate; consumed by TRADE_CLOSED to detect
-- whether the trade completed (item left bags) so the popup can be dismissed.
local tradedItemLink = nil

-- tradeRecipient: name of the player we traded to; set alongside tradedItemLink so
-- the TRADE_CLOSED handler can include it in the info log.
local tradeRecipient = nil

-- examplePopupActive: set true by ShowExamplePopup before calling ShowPopup;
-- cleared by the popup frame's OnHide script. Whisper and Trade buttons
-- check this flag and early-return in example mode (D-19).
LIF.examplePopupActive = false

-- ============================================================
-- Dismiss (module-local so the Dismiss button OnClick can reference it)
-- ============================================================

local function dismissPopup()
  if not frame then return end
  -- Tear down all section frames
  for itemLink, _ in pairs(itemSections) do
    _removeSection(itemLink)
  end
  itemSections = {}
  pendingTrade = nil
  tradedItemLink = nil
  frame:SetHeight(FRAME_MIN_HEIGHT)
  frame:Hide()
  LIF.Log("popup: dismissed")
end

local function _saveDraggedPosition()
  local xOfs = frame:GetLeft() - UIParent:GetLeft()
  local yOfs = frame:GetTop() - UIParent:GetBottom()
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", xOfs, yOfs)
  if LootItForward and LootItForward.db then
    LootItForward.db.char.popupPosition = { x = xOfs, y = yOfs }
    LIF.Log("popup: position saved x=" .. xOfs .. " y=" .. yOfs)
  end
end

-- ============================================================
-- Trade auto-populate handler (one-shot per trade, D-01)
-- ============================================================
local tradeEventFrame = CreateFrame("Frame")

tradeEventFrame:RegisterEvent("TRADE_SHOW")
tradeEventFrame:RegisterEvent("TRADE_CLOSED")
tradeEventFrame:SetScript("OnEvent", function(self, event)
  if event == "TRADE_SHOW" then
    if not pendingTrade then
      LIF.Log("popup: TRADE_SHOW fired with no pendingTrade — ignoring")
      return
    end

    -- Stale entry: our InitiateTrade never produced a TRADE_SHOW and this is
    -- some later, unrelated trade. Do not touch its slots (REV-007).
    if GetTime() - (pendingTrade.t or 0) > PENDING_TRADE_TTL then
      LIF.Log("popup: TRADE_SHOW with stale pendingTrade ("
        .. string.format("%.1f", GetTime() - (pendingTrade.t or 0)) .. "s old) — ignoring")
      pendingTrade = nil
      return
    end

    local targetLink = pendingTrade.itemLink
    local targetUnit = pendingTrade.unit
    pendingTrade = nil   -- clear before any early returns to avoid stale state

    -- Match by itemID, not full hyperlink — loot events use |cnIQ3: notation while
    -- C_Container.GetContainerItemInfo().hyperlink uses |cffXXXXXX hex notation.
    -- FindTradeableSlot ensures we pick up the fresh (tradeable) copy, not an
    -- existing owned copy of the same item that has no trade timer.
    local targetItemID = tonumber(targetLink:match("item:(%d+)"))
    local foundBag, foundSlot = LIF.FindTradeableSlot(targetItemID)
    if not foundBag then
      -- Fall back to any copy if the tooltip scan can't discriminate (locale/API issue).
      -- The item passed IsItemTradeable so it should be the right one.
      foundBag, foundSlot = LIF.FindItemInBags(targetItemID)
    end

    if not foundBag then
      LIF.Log("popup: TRADE_SHOW — item not found in bags: " .. tostring(targetLink))
      return
    end

    -- Pick up the item and place it in trade slot 1, then clear cursor.
    C_Container.PickupContainerItem(foundBag, foundSlot)
    ClickTradeButton(1)
    ClearCursor()
    tradedItemLink = targetLink   -- save so TRADE_CLOSED can detect success
    tradeRecipient = targetUnit and UnitName(targetUnit) or "?"
    LIF.Log("popup: auto-populated trade slot 1 with " .. tostring(targetLink))
    LIF.Log("Trade window opened — offering " .. tostring(targetLink) .. " to " .. tostring(tradeRecipient), "info")

  elseif event == "TRADE_CLOSED" then
    if not tradedItemLink then return end
    local link = tradedItemLink
    local itemID = tonumber(link:match("item:(%d+)"))
    local recipient = tradeRecipient
    tradedItemLink = nil
    tradeRecipient = nil   -- capture-and-clear now so a trade opened during the retry window can't clobber it

    -- WoW updates container state after TRADE_CLOSED fires, so an immediate
    -- scan sees the item still present even on a successful trade. Retry up
    -- to TRADE_CLOSED_RETRY_MAX+1 times (~1.8s budget) before concluding the
    -- trade was actually cancelled — see TRADE_CLOSED_RETRY_DELAY above.
    -- Match by trade timer, not bare itemID (FindItemInBags): a pre-owned,
    -- untimed copy of the same item would otherwise read as "still have it"
    -- forever and misreport a completed trade as cancelled.
    local function checkTradeResult(attempt)
      C_Timer.After(TRADE_CLOSED_RETRY_DELAY, function()
        if not itemSections[link] then return end   -- popup already torn down/repopulated elsewhere
        local foundBag = LIF.FindTradeableSlot(itemID)
        local stillHaveIt = foundBag ~= nil

        if not stillHaveIt then
          LIF.Log("popup: trade completed — dismissing popup")
          LIF.Log("Traded " .. tostring(link) .. " to " .. tostring(recipient), "info")
          dismissPopup()
        elseif attempt < TRADE_CLOSED_RETRY_MAX then
          checkTradeResult(attempt + 1)
        else
          LIF.Log("popup: trade cancelled — item still in bags")
          LIF.Log("Trade cancelled — " .. tostring(link) .. " still in bags", "info")
        end
      end)
    end
    checkTradeResult(0)
  end
end)

-- Default popup position for characters with no saved position yet (or a
-- corrupted/off-screen save) — centered on screen. The old fixed (0, 400)
-- default pinned the popup to the far bottom-left corner, which a first-time
-- character could easily miss entirely (2026-07-03).
local function _defaultPopupPosition(frameHeight)
  local w = UIParent:GetWidth() or 1024
  local h = UIParent:GetHeight() or 768
  local x = (w - FRAME_WIDTH) / 2
  local y = (h + (frameHeight or FRAME_MIN_HEIGHT)) / 2
  return x, y
end

-- ============================================================
-- Frame factory
-- ============================================================

local function createPopupFrame()
  -- Read saved position; center on screen if none saved yet or corrupted (y <= 0).
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  local x, y
  if pos and pos.y and pos.y > 0 then
    x, y = pos.x, pos.y
  else
    x, y = _defaultPopupPosition()
  end

  local f = CreateFrame("Frame", "LIFPopupFrame", UIParent, "BackdropTemplate")
  f:SetSize(FRAME_WIDTH, FRAME_MIN_HEIGHT)
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetToplevel(true)
  f:SetFrameStrata("MEDIUM")

  f:SetBackdrop({
    bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Buttons/WHITE8x8",
    edgeSize = 1,
    insets   = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  f:SetBackdropColor(0.047, 0.047, 0.059, 0.97)
  f:SetBackdropBorderColor(0.22, 0.22, 0.22, 1)

  -- Title bar FontString
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", 8, -6)
  title:SetText("Loot It Forward")
  f.title = title

  -- Drag handle scoped to title bar — prevents StartMoving() from stealing button clicks.
  -- Uses OnMouseDown (not RegisterForDrag) to avoid WoW's built-in pixel-threshold delay.
  -- Close button is created after this frame, so it sits on top and captures its own clicks.
  local dragHandle = CreateFrame("Frame", nil, f)
  dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  dragHandle:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  dragHandle:SetHeight(TITLE_BAR_HEIGHT)
  dragHandle:EnableMouse(true)
  dragHandle:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then f:StartMoving() end
  end)
  dragHandle:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      f:StopMovingOrSizing()
      _saveDraggedPosition()
    end
  end)

  -- Close (X) button — top-right corner.
  local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  closeBtn:SetSize(20, 20)
  closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
  closeBtn:SetScript("OnClick", function() dismissPopup() end)
  f.closeBtn = closeBtn

  -- Clear the example-mode flag when the popup is hidden (D-19 / RESEARCH.md Pitfall 4).
  f:SetScript("OnHide", function()
    LIF.examplePopupActive = false
  end)

  -- CRITICAL: CreateFrame starts IsShown=true (Pitfall 1) — must Hide() before returning
  f:Hide()

  frame = f
  return f
end

-- ============================================================
-- Section and row layout helpers
-- ============================================================

local function _recalcFrameHeight()
  if not frame then return end

  -- Collect sections in stable order: we store insertionOrder on each section
  local ordered = {}
  for _, sec in pairs(itemSections) do
    table.insert(ordered, sec)
  end
  table.sort(ordered, function(a, b) return a.insertionOrder < b.insertionOrder end)

  local totalH = FRAME_MIN_HEIGHT
  local yOffset = -TITLE_BAR_HEIGHT

  for _, sec in ipairs(ordered) do
    -- Each section starts with a separator gap, then its header, then its rows
    yOffset = yOffset - SECTION_GAP
    sec.sectionFrame:ClearAllPoints()
    sec.sectionFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", SECTION_INSET, yOffset)

    local rowCount = 0
    for _ in pairs(sec.candidateRows) do rowCount = rowCount + 1 end
    local secH = SECTION_HEADER_H + (rowCount * ROW_H)
    sec.sectionFrame:SetHeight(secH)
    totalH = totalH + SECTION_GAP + secH

    -- Re-anchor candidate rows within the section
    local rowOrdered = {}
    for guid, row in pairs(sec.candidateRows) do
      table.insert(rowOrdered, { guid = guid, row = row, order = sec.rowOrder[guid] or 999 })
    end
    table.sort(rowOrdered, function(a, b) return a.order < b.order end)

    local rowY = -SECTION_HEADER_H
    for _, r in ipairs(rowOrdered) do
      r.row:ClearAllPoints()
      r.row:SetPoint("TOPLEFT", sec.sectionFrame, "TOPLEFT", 0, rowY)
      rowY = rowY - ROW_H
    end

    yOffset = yOffset - secH
  end

  frame:SetHeight(totalH)
end

-- Remove a section by itemLink: hide and unparent its frame and all rows, clear table entry.
_removeSection = function(itemLink)
  local section = itemSections[itemLink]
  if not section then return end

  -- Two-pass: collect guids first to avoid mutating candidateRows inside pairs() (IN-01).
  -- Mutating an unvisited key during pairs() is undefined in Lua 5.1/LuaJIT.
  local guids = {}
  for guid in pairs(section.candidateRows) do table.insert(guids, guid) end
  for _, guid in ipairs(guids) do
    local row = section.candidateRows[guid]
    if row then row:Hide(); row:SetParent(nil) end
    section.candidateRows[guid] = nil
  end

  -- Hide and unparent the section frame itself
  if section.sectionFrame then
    section.sectionFrame:Hide()
    section.sectionFrame:SetParent(nil)
  end

  itemSections[itemLink] = nil
end

-- Track insertion order for stable section stacking
local _sectionCounter = 0

-- _addItemSection(itemData): builds a section sub-frame as a child of the main frame.
-- Returns the section table (sectionFrame, candidateRows, candidateDataByGuid, itemData, insertionOrder, rowOrder, _rowCounter).
local function _addItemSection(itemData)
  _sectionCounter = _sectionCounter + 1

  local sec = CreateFrame("Frame", nil, frame)
  sec:SetWidth(FRAME_WIDTH - 2 * SECTION_INSET)
  sec:SetHeight(SECTION_HEADER_H)
  -- Position is set by _recalcFrameHeight; placeholder anchor here
  sec:SetPoint("TOPLEFT", frame, "TOPLEFT", SECTION_INSET, -TITLE_BAR_HEIGHT)

  -- Subtle background tint — BACKGROUND layer so it renders below the icon and text.
  -- Full-size white at alpha 0.03 gives a near-invisible separation from candidate rows (D-16).
  local tint = sec:CreateTexture(nil, "BACKGROUND")
  tint:SetAllPoints(sec)
  tint:SetColorTexture(1, 1, 1, 0.03)
  sec.tint = tint

  -- Item icon (32x32 Texture)
  -- Anchored to TOPLEFT (not LEFT/CENTER) so position stays in the header when sec grows for rows.
  local icon = sec:CreateTexture(nil, "ARTWORK")
  icon:SetSize(32, 32)
  icon:SetPoint("TOPLEFT", sec, "TOPLEFT", 8, -2)
  local itemID = tonumber(itemData.link and itemData.link:match("item:(%d+)"))
  local iconPath = itemID and C_Item.GetItemIconByID(itemID)
  if iconPath then
    icon:SetTexture(iconPath)
  end
  sec.icon = icon

  -- sec needs EnableMouse to block click-through on gaps between child frames.
  -- Drag is intentionally NOT handled here — only the title bar initiates drags.
  sec:EnableMouse(true)

  -- Dedicated tooltip zone covering only the header strip (icon + name + ilvl).
  -- Created before nameStr/ilvlStr so they are FontString children of headerZone;
  -- OnHyperlinkClick fires on the frame that owns the FontString, so headerZone
  -- (the topmost interactive frame) must be the owner for shift-click to work.
  local headerZone = CreateFrame("Frame", nil, sec)
  headerZone:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, 0)
  headerZone:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, 0)
  headerZone:SetHeight(SECTION_HEADER_H)
  headerZone:EnableMouse(true)

  -- Item name FontString — child of headerZone for shift-click hyperlink support.
  -- SetText(itemData.link) renders the full WoW hyperlink: quality-colored [Item Name]
  -- that shift-clicks into chat. 48px left = 8px margin + 32px icon + 8px gap.
  local nameStr = headerZone:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local font, _, flags = GameFontNormal:GetFont()
  nameStr:SetFont(font, 13, flags)
  nameStr:SetPoint("TOPLEFT", sec, "TOPLEFT", 48, -4)
  nameStr:SetPoint("TOPRIGHT", sec, "TOPRIGHT", -8, -4)
  nameStr:SetJustifyH("LEFT")
  nameStr:SetWordWrap(false)
  nameStr:SetText(itemData.link or itemData.name or "Unknown Item")
  sec.nameStr = nameStr

  -- Item ilvl FontString — child of headerZone; anchored below nameStr.
  local ilvlStr = headerZone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  local ilvlFont, _, ilvlFlags = GameFontHighlightSmall:GetFont()
  ilvlStr:SetFont(ilvlFont, 11, ilvlFlags)
  ilvlStr:SetPoint("TOPLEFT", nameStr, "BOTTOMLEFT", 0, -2)
  ilvlStr:SetTextColor(1, 1, 1, 1)
  ilvlStr:SetText("ilvl " .. tostring(itemData.ilvl or "?"))
  sec.ilvlStr = ilvlStr

  -- OnHyperlinkClick does not fire on plain Frame children in WoW retail; use
  -- OnMouseUp directly. Shift+click anywhere on the header inserts the item link
  -- into the active chat box (mirrors standard WoW shift-click-item behavior).
  headerZone:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and IsShiftKeyDown() then
      LIF.Log("hover: shift-click item-header — inserting link")
      -- Defer one frame: ChatEdit_InsertLink touches Blizzard's chat frame from a
      -- click handler and can inherit taint the same way SendChatMessage does.
      local link = itemData.link
      C_Timer.After(0, function()
        local ok = ChatEdit_InsertLink(link)
        LIF.Log("hover: ChatEdit_InsertLink result=" .. tostring(ok))
      end)
    end
  end)
  headerZone:SetScript("OnEnter", function(self)
    LIFItemTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    LIFItemTooltip:ClearAllPoints()
    LIFItemTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 5, 0)
    LIFItemTooltip:SetHyperlink(itemData.link)
    LIFItemTooltip:Show()
    local equippedLink = itemData.slotIDs and itemData.slotIDs[1]
      and GetInventoryItemLink("player", itemData.slotIDs[1])
    LIFCompareTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    LIFCompareTooltip:ClearAllPoints()
    LIFCompareTooltip:SetPoint("TOPLEFT", LIFItemTooltip, "TOPRIGHT", 5, 0)
    if equippedLink then
      LIFCompareTooltip:SetHyperlink(equippedLink)
    else
      LIFCompareTooltip:AddLine("Nothing equipped", 0.6, 0.6, 0.6)
    end
    LIFCompareTooltip:Show()
  end)
  headerZone:SetScript("OnLeave", function(self)
    LIFItemTooltip:Hide()
    LIFCompareTooltip:Hide()
  end)
  sec.headerZone = headerZone

  -- Section table
  local section = {
    sectionFrame         = sec,
    candidateRows        = {},    -- guid -> Button
    candidateDataByGuid  = {},    -- guid -> candidateData
    itemData             = itemData,
    insertionOrder       = _sectionCounter,
    rowOrder             = {},    -- guid -> insertion order within this section
    _rowCounter          = 0,
  }

  return section
end

-- _addCandidateRow(section, candidateData, itemLink): builds a Button row in a section.
-- Returns the row Button.
local function _addCandidateRow(section, candidateData, itemLink)
  section._rowCounter = section._rowCounter + 1
  section.rowOrder[candidateData.guid] = section._rowCounter

  local row = CreateFrame("Frame", nil, section.sectionFrame)
  row:SetSize(FRAME_WIDTH - 2 * SECTION_INSET, ROW_H)
  -- Position placeholder; _recalcFrameHeight will re-anchor properly
  row:SetPoint("TOPLEFT", section.sectionFrame, "TOPLEFT", 0, -SECTION_HEADER_H)

  -- Dedicated info-area hover zone covering only the name+ilvl region (left side).
  local infoZone = CreateFrame("Frame", nil, row)
  infoZone:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  infoZone:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -88, 0)
  infoZone:EnableMouse(true)
  infoZone:SetScript("OnEnter", function(self)
    LIFItemTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    LIFItemTooltip:ClearAllPoints()
    LIFItemTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 5, 0)
    LIFItemTooltip:SetHyperlink(section.itemData.link)
    LIFItemTooltip:Show()
    local member = LIF.Cache.GetMember(candidateData.guid)
    local equippedLink = member and member.gear and member.gear[candidateData.slotID]
      and member.gear[candidateData.slotID].link
    LIFCompareTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    LIFCompareTooltip:ClearAllPoints()
    LIFCompareTooltip:SetPoint("TOPLEFT", LIFItemTooltip, "TOPRIGHT", 5, 0)
    if equippedLink then
      LIFCompareTooltip:SetHyperlink(equippedLink)
    else
      LIFCompareTooltip:AddLine("Nothing equipped", 0.6, 0.6, 0.6)
    end
    LIFCompareTooltip:Show()
  end)
  infoZone:SetScript("OnLeave", function(self)
    LIFItemTooltip:Hide()
    LIFCompareTooltip:Hide()
  end)

  -- Player name — class-colored, constrained to the info area (left flex).
  -- Info area right boundary: -96 = 88px actions column + 8px right padding.
  local colorStr = (RAID_CLASS_COLORS and RAID_CLASS_COLORS[candidateData.class]
    and RAID_CLASS_COLORS[candidateData.class].colorStr) or "ffffffff"
  local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local font, _, flags = GameFontNormal:GetFont()
  nameStr:SetFont(font, 13, flags)
  nameStr:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -7)
  nameStr:SetPoint("TOPRIGHT", row, "TOPRIGHT", -96, -7)
  nameStr:SetWordWrap(false)
  nameStr:SetJustifyH("LEFT")
  nameStr:SetText("|c" .. colorStr .. (candidateData.name or "?") .. "|r")
  row.nameStr = nameStr

  -- Ilvl delta — anchored below name inside info area; green delta segment.
  local ilvlText = string.format("%d -> %d (|cff00ff00+%d|r)",
    candidateData.ilvl_current or 0,
    candidateData.ilvl_dropped or 0,
    candidateData.delta or 0)
  local ilvlStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  local ilvlFont, _, ilvlFlags = GameFontHighlightSmall:GetFont()
  ilvlStr:SetFont(ilvlFont, 11, ilvlFlags)
  ilvlStr:SetPoint("TOPLEFT", nameStr, "BOTTOMLEFT", 0, -2)
  ilvlStr:SetPoint("TOPRIGHT", nameStr, "BOTTOMRIGHT", 0, -2)
  ilvlStr:SetJustifyH("LEFT")
  ilvlStr:SetText(ilvlText)
  row.ilvlStr = ilvlStr

  -- Action buttons — stacked vertically in the right-side 88px actions column.
  local whisperBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  whisperBtn:SetSize(68, 20)
  whisperBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -2)
  whisperBtn:SetText("Whisper")
  whisperBtn:GetFontString():SetJustifyH("CENTER")
  whisperBtn:SetScript("OnClick", function()
    if LIF.examplePopupActive then return end  -- no-op in example mode (D-19)
    local target = candidateData.whisperTarget or candidateData.name or "?"
    local link = section.itemData.link
    local template = (LootItForward and LootItForward.db and LootItForward.db.profile.whisperMessage)
                     or "Hey, {link} dropped for me and I don't need it. Do you want it?"
    local rendered = string.gsub(template, "{link}", link)
    local msg = "[Loot It Forward] " .. rendered
    -- C_ChatInfo.SendChatMessage, not the global SendChatMessage (reverting e89b0cf):
    -- confirmed live 2026-07-03 that the global's "silently does nothing for WHISPER"
    -- claim was wrong — C_ChatInfo.SendChatMessage delivers whispers fine. Note this
    -- does NOT avoid the local "ChatHistory_GetAccessID" taint error some sessions hit
    -- (confirmed both APIs crash identically when another addon — AccWideUILayoutSelection
    -- here — has tainted Blizzard's chat-history table); that error is cosmetic and
    -- doesn't block delivery either way. See docs/wow-api-pitfalls.md.
    C_ChatInfo.SendChatMessage(msg, "WHISPER", nil, target)
    LIF.Log("popup: whisper sent to " .. target)
    LIF.Log("Whispered " .. tostring(target) .. " about " .. tostring(link), "info")
  end)
  row.whisperBtn = whisperBtn

  -- [Trade]: calls InitiateTrade(unit); TRADE_SHOW listener auto-populates item.
  local tradeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  tradeBtn:SetSize(68, 20)
  tradeBtn:SetPoint("TOP", whisperBtn, "BOTTOM", 0, -4)
  tradeBtn:SetText("Trade")
  tradeBtn:GetFontString():SetJustifyH("CENTER")
  tradeBtn:SetScript("OnClick", function()
    if LIF.examplePopupActive then return end  -- no-op in example mode (D-19)
    local unit = LIF.GuidToUnit(candidateData.guid)
    if not unit then
      LIF.Log("popup: Trade clicked but unit not found for guid=" .. tostring(candidateData.guid))
      return
    end
    -- InitiateTrade is not blocked by combat lockdown (confirmed in-game 2026-07-03) —
    -- the trade window opens fine mid-combat, so pendingTrade must always be set or
    -- TRADE_SHOW fires with no record of what to auto-populate.
    pendingTrade = { itemLink = itemLink, unit = unit, t = GetTime() }
    InitiateTrade(unit)
    LIF.Log("popup: InitiateTrade called for " .. tostring(candidateData.name))
  end)
  row.tradeBtn = tradeBtn

  -- Store in section tables
  section.candidateRows[candidateData.guid]       = row
  section.candidateDataByGuid[candidateData.guid] = candidateData

  return row
end

-- ============================================================
-- Exported API
-- ============================================================

-- Called from LootItForward:OnInitialize after AceDB :New() completes.
-- Lazily creates the frame if needed, then applies the saved position.
function LIF.Popup_RestorePosition()
  if not frame then createPopupFrame() end
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  local x, y
  if pos and pos.y and pos.y > 0 then
    x, y = pos.x, pos.y
  else
    -- y must be positive: TOPLEFT anchored to UIParent BOTTOMLEFT, negative/zero y is off-screen.
    x, y = _defaultPopupPosition()
  end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  LIF.Log("popup: position restored x=" .. x .. " y=" .. y)
end

-- ============================================================
-- Exported popup callbacks
-- TOC load order: loot.lua before popup.lua — these assignments win.
-- ============================================================

function LIF.ShowPopup(itemData, candidates)
  -- Lazily create the frame
  if not frame then createPopupFrame() end

  -- Bring frame forward
  frame:Show()
  frame:Raise()

  -- Phase 5: sound on popup (D-14). Quad guard: truthy, not NONE sentinel,
  -- SOUNDKIT table present, SOUNDKIT[token] present.
  local sound = LootItForward and LootItForward.db and LootItForward.db.profile.popupSound
  if sound and sound ~= "NONE" and SOUNDKIT and SOUNDKIT[sound] ~= nil then
    PlaySound(SOUNDKIT[sound], "Master")
  end

  -- Remove any prior section for this item link before creating a new one (IN-02).
  -- Without this, a duplicate drop overwrites itemSections[link], leaving the old
  -- section frame and child rows orphaned (parented to the popup but unreachable).
  if itemSections[itemData.link] then
    _removeSection(itemData.link)
  end

  -- Create the item section and store it
  local section = _addItemSection(itemData)
  itemSections[itemData.link] = section
  section.itemData = itemData

  -- Populate candidate rows (pre-sorted by loot.lua — do NOT re-sort)
  for _, candidate in ipairs(candidates) do
    _addCandidateRow(section, candidate, itemData.link)
  end

  _recalcFrameHeight()

  -- Recompute the centered default now that the frame has grown to fit its content
  -- (not just at OnInitialize, and not before _recalcFrameHeight — the frame anchors
  -- TOPLEFT and grows downward, so centering against FRAME_MIN_HEIGHT before content
  -- is added leaves the actual box off-center vertically). Only for characters with
  -- no saved (dragged) position — never overrides a real dragged position (2026-07-03).
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  if not (pos and pos.y and pos.y > 0) then
    local x, y = _defaultPopupPosition(frame:GetHeight())
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  end

  LIF.Log("popup: ShowPopup item=" .. tostring(itemData and itemData.link))
end

function LIF.Popup_UpdateCandidate(guid, candidateData, itemLink)
  local section = itemSections[itemLink]
  if not section then
    LIF.Log("popup: UpdateCandidate no section for item=" .. tostring(itemLink))
    return
  end

  if not section.candidateRows[guid] then
    _addCandidateRow(section, candidateData, itemLink)
    _recalcFrameHeight()
  end
end

function LIF.Popup_RemoveCandidate(guid, itemLink)
  local section = itemSections[itemLink]
  if not section then return end

  -- Remove the candidate row if it exists
  local row = section.candidateRows[guid]
  if row then
    row:Hide()
    row:SetParent(nil)
    section.candidateRows[guid] = nil
    section.candidateDataByGuid[guid] = nil
  end

  -- Cascade: if section is now empty, remove it
  if not next(section.candidateRows) then
    _removeSection(itemLink)
    -- If no sections remain, dismiss the popup
    if not next(itemSections) then
      dismissPopup()
      return
    end
  end

  -- Recalculate height if frame is still shown
  if frame and frame:IsShown() then
    _recalcFrameHeight()
  end
end

-- Roster update callback — called by LootItForward:GROUP_ROSTER_UPDATE
-- when a group member leaves. Removes rows for departed GUIDs across all sections.
-- T-04-09 mitigation: collect guids/itemLinks to remove into temporary lists first,
-- then apply removals — never mutate tables while iterating with pairs().
function LIF.Popup_OnRosterUpdate()
  if not frame or not frame:IsShown() then return end

  -- Pass 1: collect departed guids per section and empty section itemLinks
  local sectionsToRemove = {}
  local rowsToRemove = {}  -- list of { itemLink, guid, row, section }

  for itemLink, section in pairs(itemSections) do
    for guid, row in pairs(section.candidateRows) do
      if LIF.GuidToUnit(guid) == nil then
        -- Member no longer in group — schedule row for removal
        table.insert(rowsToRemove, { itemLink = itemLink, guid = guid, row = row, section = section })
      end
    end
  end

  -- Pass 2: apply row removals
  for _, entry in ipairs(rowsToRemove) do
    local row, guid, section = entry.row, entry.guid, entry.section
    local name = section.candidateDataByGuid[guid] and section.candidateDataByGuid[guid].name or guid:sub(-6)
    row:Hide()
    row:SetParent(nil)
    section.candidateRows[guid] = nil
    section.candidateDataByGuid[guid] = nil
    LIF.Log("popup: roster — removed row for " .. name)
  end

  -- Pass 3: collect empty sections (deferred — sections may have become empty after Pass 2)
  for itemLink, section in pairs(itemSections) do
    if not next(section.candidateRows) then
      table.insert(sectionsToRemove, itemLink)
    end
  end

  -- Pass 4: apply section removals
  for _, itemLink in ipairs(sectionsToRemove) do
    LIF.Log("popup: roster — section empty, removing")
    _removeSection(itemLink)
  end

  -- Cascade: if no sections remain, dismiss the popup
  if not next(itemSections) then
    LIF.Log("popup: roster — no candidates remain, dismissing")
    dismissPopup()
    return
  end

  if frame and frame:IsShown() then
    _recalcFrameHeight()
  end
end

-- ============================================================
-- ShowExamplePopup (D-18) — hardcoded Greathelm of Temptation
-- ============================================================

-- Hardcoded example item per D-18: Greathelm of Temptation (item 251126), ilvl 220.
-- Plate head from Kystia Manaheart, Murder Row (Midnight dungeon).
-- Color |cff0070dd = WoW Rare (blue). Position-9 value 90 = character level field.
-- Exported on LIF (REV-017): ui/settings.lua reuses both for the whisper
-- preview and cache warming — single source of truth (popup.lua loads first).
LIF.EXAMPLE_ITEM_ID   = 251126
LIF.EXAMPLE_ITEM_LINK = "|cff0070dd|Hitem:251126::::::::90:::::|h[Greathelm of Temptation]|h|r"
local EXAMPLE_ITEM_LINK = LIF.EXAMPLE_ITEM_LINK

-- LIF.ShowExamplePopup(): renders the popup with fabricated item and candidate data.
-- Called by Phase 5's "Show Example Popup" settings button.
-- Useful for developer positioning and visual testing without a live dungeon.
function LIF.ShowExamplePopup()
  C_Item.RequestLoadItemDataByID(LIF.EXAMPLE_ITEM_ID)  -- warm cache so hover tooltip is correct
  dismissPopup()                          -- clear any previous example before reshowing
  LIF.examplePopupActive = true
  local fakeLink = EXAMPLE_ITEM_LINK
  local fakeName = "Greathelm of Temptation"
  local fakeIlvl = 220

  local fakeItemData = {
    link         = fakeLink,
    name         = fakeName,
    ilvl         = fakeIlvl,
    slotCategory = "armor",
    slotIDs      = { 1 },
    rarity       = 4,
  }

  -- Fabricated candidate 1: Warrior at ilvl 195, would gain +25 (D-18)
  local fakeCandidate1 = {
    guid         = "Player-1-00000001",
    name         = "Tankmaster",
    class        = "WARRIOR",
    ilvl_current = 195,
    ilvl_dropped = 220,
    delta        = 25,
    slotID       = 1,
  }

  -- Fabricated candidate 2: Paladin at ilvl 207, would gain +13 (D-18)
  local fakeCandidate2 = {
    guid         = "Player-1-00000002",
    name         = "Holybuff",
    class        = "PALADIN",
    ilvl_current = 207,
    ilvl_dropped = 220,
    delta        = 13,
    slotID       = 1,
  }

  LIF.ShowPopup(fakeItemData, { fakeCandidate1, fakeCandidate2 })
  LIF.Log("popup: ShowExamplePopup called")
end
