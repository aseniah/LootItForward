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

-- Forward declarations — these are defined after the layout helpers but are
-- referenced earlier (e.g. by the TRADE_CLOSED handler's completion cascade).
local _removeSection
local _recalcFrameHeight

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

-- tradedItemCount: copy count of the item's itemID captured at TRADE_SHOW (before we
-- pick one up). For a timered item (BoP): the tradeable-copy count, consulted for the
-- D-03 stacked-drop case (>= 2) where presence can't tell a completed trade from a
-- cancel when a second tradeable copy remains (AUD-310). For an untimed item (BoE):
-- the plain copy count, whose decrease is the ONLY completion signal (AUD-402).
local tradedItemCount = nil

-- tradedItemTimered: whether the copy we picked up at TRADE_SHOW had an active trade
-- timer. A BoE/BoU passes IsItemTradeable with no timer, so FindTradeableSlot can't
-- see it and presence-by-timer would read "completed" vacuously on a cancel — the
-- untimed case must detect completion by a plain count decrease instead (AUD-402).
local tradedItemTimered = nil

-- examplePopupActive: set true by ShowExamplePopup before calling ShowPopup;
-- cleared by dismissPopup (the teardown path) — NOT an OnHide script, which would
-- also fire on a parent-driven hide and desync the flag (AUD-302). Whisper and Trade
-- buttons check this flag and early-return in example mode (D-19).
LIF.examplePopupActive = false

-- Whisper prefix, prepended to every outgoing whisper (AUD-014). Counts toward the
-- 255-byte SendChatMessage limit. Exported so ui/settings.lua's length counter and
-- the send-time backstop below share one source of truth (popup.lua loads first).
LIF.WHISPER_PREFIX = "[Loot It Forward] "
LIF.WHISPER_MAX_BYTES = 255
local WHISPER_MAX_BYTES = LIF.WHISPER_MAX_BYTES
-- Max characters the settings whisper-template editbox accepts. Exported so the
-- settings hint, SetMaxLetters, and length counter share one source of truth (AUD-318).
LIF.WHISPER_MAX_TEMPLATE_CHARS = 100
-- Default whisper template. Single source of truth (AUD-408): the AceDB `defaults`
-- table in LootItForward.lua (which loads after popup.lua per TOC) and the send-time
-- fallback both reference this, rather than repeating the literal.
LIF.DEFAULT_WHISPER_TEMPLATE = "Hey, {link} dropped for me and I don't need it. Do you want it?"

-- ============================================================
-- Dismiss (module-local so the Dismiss button OnClick can reference it)
-- ============================================================

local function dismissPopup()
  -- Nothing to dismiss (frame never created, or already hidden with no sections):
  -- return before logging so the location-change dismiss on every PLAYER_ENTERING_WORLD
  -- doesn't spam "popup: dismissed" with nothing showing (AUD-309). A parent-driven
  -- hide (Alt+Z) leaves the frame's own IsShown true, so this never swallows a real
  -- dismiss.
  if not frame or (not frame:IsShown() and not next(itemSections)) then return end
  -- If an event-driven dismiss (roster prune, TRADE_CLOSED cascade, PEW location
  -- change) lands mid-drag, OnMouseUp never fires on the hidden frame, so the frame
  -- would stay in the moving state and stick to the cursor on the next Show. Stop the
  -- move here (harmless when not moving). Deliberately do NOT save the dragged
  -- position — a dismiss is not a deliberate placement (AUD-307).
  frame:StopMovingOrSizing()
  -- Tear down all section frames
  for itemLink, _ in pairs(itemSections) do
    _removeSection(itemLink)
  end
  itemSections = {}
  pendingTrade = nil
  tradedItemLink = nil
  tradeRecipient = nil
  tradedItemCount = nil
  tradedItemTimered = nil
  -- Clear the example-mode flag here, in the actual teardown, rather than in an
  -- OnHide script: WoW fires OnHide on any effective visibility change, including a
  -- parent-driven hide (UIParent hidden by Alt+Z / a cinematic), which would desync
  -- the flag to false while the example content is still logically up (AUD-302).
  LIF.examplePopupActive = false
  frame:SetHeight(FRAME_MIN_HEIGHT)
  frame:Hide()
  LIF.Log("popup: dismissed")
end

-- Combat start clears any open example/preview popup (M5): real loot usually lands
-- via ENCOUNTER_LOOT_RECEIVED after combat begins, so eagerly clearing the example
-- here avoids the interleave in the common case. This is NOT the only backstop —
-- a real drop can call ShowPopup in the post-combat scanning window with an example
-- still up, so ShowPopup itself also evicts a live example (AUD-002). dismissPopup
-- clears examplePopupActive as part of teardown.
function LIF.Popup_DismissExample()
  if LIF.examplePopupActive then
    dismissPopup()
  end
end

-- Public dismiss for whichever popup is up (real OR example — they share one
-- frame). Used by PLAYER_ENTERING_WORLD to close the popup on a location change
-- (AUD-021). No-op when nothing is showing.
function LIF.Popup_Dismiss()
  dismissPopup()
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

    -- Verify the trade partner is who we opened the trade with (AUD-003). The TTL
    -- above only rejects LATE trades; within it, a DIFFERENT player opening a trade
    -- with us (common post-boss, when loot is passed around) would otherwise get our
    -- item auto-placed into their trade. During an open trade the "npc" unit token is
    -- the partner. Block only on a POSITIVE mismatch: if the token is unresolvable we
    -- fall through to the prior behaviour (no regression). UnitIsUnit is used only in
    -- the condition, never string-embedded (cf. secret-boolean pitfall).
    if targetUnit and UnitExists("npc") and not UnitIsUnit("npc", targetUnit) then
      LIF.Log("popup: TRADE_SHOW partner mismatch (trade opened with "
        .. tostring(UnitName("npc")) .. ", expected " .. tostring(UnitName(targetUnit))
        .. ") — not auto-populating")
      return
    end

    -- Match by itemID, not full hyperlink — loot events use |cnIQ3: notation while
    -- C_Container.GetContainerItemInfo().hyperlink uses |cffXXXXXX hex notation.
    -- FindTradeableSlot ensures we pick up the fresh (tradeable) copy, not an
    -- existing owned copy of the same item that has no trade timer.
    local targetItemID = tonumber(targetLink:match("item:(%d+)"))
    local foundBag, foundSlot = LIF.FindTradeableSlot(targetItemID)
    -- Whether the picked-up copy carries a trade timer. A BoE/BoU is tradeable with
    -- NO timer, so FindTradeableSlot misses it and we fall back to a plain bag search;
    -- TRADE_CLOSED must then detect completion by count, not timer presence (AUD-402).
    local timered = foundBag ~= nil
    if not foundBag then
      -- Fall back to any copy if the tooltip scan can't discriminate (locale/API issue)
      -- or the item is an untimed BoE/BoU. It passed IsItemTradeable, so it's the right one.
      foundBag, foundSlot = LIF.FindItemInBags(targetItemID)
    end

    if not foundBag then
      LIF.Log("popup: TRADE_SHOW — item not found in bags: " .. tostring(targetLink))
      return
    end

    -- Baseline copy count BEFORE picking one up (all copies still in bags), so
    -- TRADE_CLOSED can detect a decrease: tradeable-copy count for a timered item
    -- (D-03 duplicate case, AUD-310), plain count for an untimed BoE (AUD-402).
    tradedItemCount = timered and LIF.CountTradeableSlots(targetItemID)
                              or LIF.CountItemInBags(targetItemID)
    tradedItemTimered = timered
    -- Pick up the item and place it in trade slot 1, then clear cursor.
    C_Container.PickupContainerItem(foundBag, foundSlot)
    ClickTradeButton(1)
    ClearCursor()
    tradedItemLink = targetLink   -- save so TRADE_CLOSED can detect success
    -- Name from the actual partner ("npc") when resolvable (authoritative, and now
    -- verified to match the intended unit above); fall back to the intended unit.
    tradeRecipient = (UnitExists("npc") and UnitName("npc"))
      or (targetUnit and UnitName(targetUnit)) or "?"
    LIF.Log("popup: auto-populated trade slot 1 with " .. tostring(targetLink))
    LIF.Log("Trade window opened — offering " .. tostring(targetLink) .. " to " .. tostring(tradeRecipient), "info")

  elseif event == "TRADE_CLOSED" then
    if not tradedItemLink then return end
    local link = tradedItemLink
    local itemID = tonumber(link:match("item:(%d+)"))
    local recipient = tradeRecipient
    local baseline = tradedItemCount   -- copies before we picked one up (AUD-310/AUD-402)
    local timered = tradedItemTimered
    -- Bind the section we're acting on by identity, not just its link key (AUD-405):
    -- a same-link re-drop removes and re-creates the section at the same key, so a
    -- key-only guard would let a stale retry act on the wrong (newer) section.
    local sectionRef = itemSections[link]
    tradedItemLink = nil
    tradeRecipient = nil   -- capture-and-clear now so a trade opened during the retry window can't clobber it
    tradedItemCount = nil
    tradedItemTimered = nil

    -- WoW updates container state after TRADE_CLOSED fires, so an immediate
    -- scan sees the item still present even on a successful trade. Retry up
    -- to TRADE_CLOSED_RETRY_MAX+1 times (~1.8s budget) before concluding the
    -- trade was actually cancelled — see TRADE_CLOSED_RETRY_DELAY above.
    -- Match by trade timer, not bare itemID (FindItemInBags): a pre-owned,
    -- untimed copy of the same item would otherwise read as "still have it"
    -- forever and misreport a completed trade as cancelled.
    --
    -- Untimed BoE/BoU (AUD-402): the item has no trade timer, so FindTradeableSlot
    -- can never see it and presence-by-timer reads "completed" vacuously even on a
    -- cancel. Detect completion by a plain count DECREASE from the TRADE_SHOW baseline.
    -- D-03 stacked-drop (AUD-310): with >= 2 tradeable copies of this itemID,
    -- FindTradeableSlot still finds the second copy after ours is traded, so presence
    -- can't say "completed" either — same count-decrease signal (tradeable count).
    -- The common single-timered-copy path keeps the proven presence check untouched.
    local dupCase = (baseline or 0) >= 2
    local function checkTradeResult(attempt)
      C_Timer.After(TRADE_CLOSED_RETRY_DELAY, function()
        if itemSections[link] ~= sectionRef then return end   -- section torn down or replaced by a same-link re-drop (AUD-405)
        local completed
        if not timered then
          completed = LIF.CountItemInBags(itemID) < baseline
        elseif dupCase then
          completed = LIF.CountTradeableSlots(itemID) < baseline
        else
          completed = LIF.FindTradeableSlot(itemID) == nil
        end

        if completed then
          LIF.Log("popup: trade completed — removing item section")
          LIF.Log("Traded " .. tostring(link) .. " to " .. tostring(recipient), "info")
          -- Remove only the traded item's section (D-03 multi-item): a second
          -- stacked drop's section must stay actionable. Dismiss the whole popup
          -- only when nothing else remains.
          _removeSection(link)
          if not next(itemSections) then
            dismissPopup()
          elseif frame and frame:IsShown() then
            _recalcFrameHeight()
          end
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

-- A saved position is only usable if BOTH coords are real numbers and y is
-- positive (TOPLEFT anchors to UIParent BOTTOMLEFT, so y<=0 is off-screen). A
-- partially-corrupt save such as { y = 400 } with x missing would otherwise
-- pass a y-only guard and then throw on SetPoint(nil x) / the position concat.
local function _hasSavedPosition(pos)
  return pos and type(pos.x) == "number" and type(pos.y) == "number" and pos.y > 0
end

-- Is a saved (x, y) actually on the CURRENT screen? The anchor is the frame's
-- TOPLEFT against UIParent's BOTTOMLEFT, so x is the left edge and y is the top
-- edge's height above the bottom. Require the title bar to stay grabbable: enough
-- horizontal overlap, and the title strip fully within the vertical extent. A
-- position saved at a larger resolution (or after a UI-scale change) can land
-- off-screen; this catches that so the popup is re-centered instead of lost.
local MIN_ONSCREEN = 40  -- px of the frame that must remain visible
local function _isOnScreen(x, y)
  local w = UIParent:GetWidth() or 1024
  local h = UIParent:GetHeight() or 768
  local visibleW = math.min(x + FRAME_WIDTH, w) - math.max(x, 0)
  -- Positive-form comparisons so a NaN coord (which fails every ordered compare)
  -- is treated as off-screen rather than slipping through a `< / >` negation.
  if not (visibleW >= MIN_ONSCREEN) then return false end
  if not (y <= h and y >= TITLE_BAR_HEIGHT) then return false end
  return true
end

-- Resolve the position to open at: the saved one if it is valid AND on-screen,
-- otherwise the centered default. A corrupt or off-screen save is CLEARED so the
-- popup stays centered on later shows rather than being re-detected every time
-- (AUD-018 — mirrors what /lif resetpos does, but automatically).
local function _resolvePopupPosition()
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  if _hasSavedPosition(pos) and _isOnScreen(pos.x, pos.y) then
    return pos.x, pos.y
  end
  if pos and LootItForward and LootItForward.db then
    LootItForward.db.char.popupPosition = nil
    LIF.Log(_hasSavedPosition(pos)
      and "popup: saved position off-screen — re-centering"
      or "popup: ignoring corrupt saved position — re-centering")
  end
  return _defaultPopupPosition()
end

-- ============================================================
-- Frame factory
-- ============================================================

local function createPopupFrame()
  -- Read saved position; center on screen if none saved, corrupted, or off-screen.
  local x, y = _resolvePopupPosition()

  local f = CreateFrame("Frame", "LIFPopupFrame", UIParent, "BackdropTemplate")
  f:SetSize(FRAME_WIDTH, FRAME_MIN_HEIGHT)
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  f:SetMovable(true)
  f:EnableMouse(true)
  -- Keep the frame on screen: blocks dragging the title bar off-edge (which would
  -- persist an unreachable position) and clamps a restored point back into view.
  f:SetClampedToScreen(true)
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

  -- CRITICAL: CreateFrame starts IsShown=true (Pitfall 1) — must Hide() before returning
  f:Hide()

  frame = f
  return f
end

-- ============================================================
-- Section and row layout helpers
-- ============================================================

function _recalcFrameHeight()
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
--
-- KNOWN SMELL (audit L11, accepted): section and row frames are created fresh per
-- popup and only Hide()+SetParent(nil) here — WoW never garbage-collects frames,
-- so they accumulate over a play session. No correctness impact, and the practical
-- cost is negligible (a few dozen frames per popup; even a marathon session is
-- low-thousands, which WoW handles trivially). The standard remedy is a frame pool
-- (acquire on show, hide+return here instead of orphaning), but a correct pool
-- requires splitting create-children-once from configure-per-use and re-pointing
-- every child closure (header/hover zones, whisper/trade buttons) off its captured
-- itemData/candidateData upvalue onto frame-attached fields — a ~300-line rewrite
-- of this file with no offline test coverage. Deferred to a dedicated UI pass where
-- it can be verified in-game; not worth the churn/risk for a leak this minor.
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

-- The player's authoritative compare slot for the header hover, mirroring the slot
-- eligibility actually used so the hover shows that piece (or "Nothing equipped")
-- and not some other, higher-ilvl one:
--   * rings (11/12) and trinkets (13/14): the LOWER-ilvl of the two equipped slots,
--     heirloom-adjusted (an active heirloom reads as math.huge so it never wins the
--     low side) and possibly EMPTY (ilvl 0) — via core's LIF.HeirloomAdjustedIlvl (AUD-308).
--   * weapons: the weaker hand of a dual-wield pair, the off-hand for an off-hand-only
--     drop, or the equipped 2H — via core's LIF.PlayerWeaponCompareSlot (AUD-404).
-- All other categories compare slotIDs[1].
local function _headerCompareSlot(itemData)
  local slots = itemData.slotIDs
  if not slots then return nil end
  if itemData.slotCategory == "ring" or itemData.slotCategory == "trinket" then
    local a, b = slots[1], slots[2]
    if not (a and b) then return a or b end
    local level = UnitLevel("player")
    local function adj(slot)
      local link = GetInventoryItemLink("player", slot)
      local ilvl = link and (C_Item.GetDetailedItemLevelInfo(link) or 0) or 0
      return LIF.HeirloomAdjustedIlvl and LIF.HeirloomAdjustedIlvl(link, level, ilvl) or ilvl
    end
    return (adj(a) <= adj(b)) and a or b   -- tie -> first, matching core
  end
  if itemData.slotCategory == "weapon" and LIF.PlayerWeaponCompareSlot then
    return LIF.PlayerWeaponCompareSlot(itemData) or slots[1]
  end
  return slots[1]
end

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
    if not itemData.link then return end  -- ClassifyItem guarantees a link; guard anyway (AUD-308)
    LIFItemTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    LIFItemTooltip:ClearAllPoints()
    LIFItemTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 5, 0)
    LIFItemTooltip:SetHyperlink(itemData.link)
    LIFItemTooltip:Show()
    -- Compare against the slot eligibility actually used (lower-of-two for
    -- rings/trinkets), not always slotIDs[1] (AUD-308).
    local compareSlot = _headerCompareSlot(itemData)
    local equippedLink = compareSlot and GetInventoryItemLink("player", compareSlot)
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
    candidateRows        = {},    -- guid -> Frame
    candidateDataByGuid  = {},    -- guid -> candidateData
    itemData             = itemData,
    insertionOrder       = _sectionCounter,
    rowOrder             = {},    -- guid -> insertion order within this section
    _rowCounter          = 0,
  }

  return section
end

-- Renders the full whisper text for a template + item link, including the prefix.
-- Pure string op — no send. gsub replaces EVERY {link} occurrence, so a multi-{link}
-- template is measured exactly (AUD-014). Shared by the send path (real link) and the
-- settings length counter (EXAMPLE_ITEM_LINK) so both measure identical byte lengths.
function LIF.RenderWhisperMessage(template, link)
  -- gsub treats % as magic in the REPLACEMENT (%1..%9; a lone %x errors), and a
  -- localized item name/link is outside our control (the over-length degrade path
  -- feeds the raw name in by design), so escape % before substituting (AUD-304).
  -- Assign to a local first: inlining the :gsub would pass its match COUNT as the
  -- outer gsub's n argument and cap replacements.
  local replacement = (link or ""):gsub("%%", "%%%%")
  return LIF.WHISPER_PREFIX .. string.gsub(template or "", "{link}", replacement)
end

-- Reduce WoW color/hyperlink/texture markup to plain text. Used on the whisper
-- over-length degrade path so a byte-truncated message can never end mid-escape
-- (AUD-306): |H..|h / |c..|r sequences are pure ASCII, so the UTF-8 boundary back-up
-- doesn't protect them, and a cut inside one throws "Invalid escape code". Reducing
-- to plain text BEFORE the cut makes truncation safe at any byte. A literal-pipe
-- escape "||" is protected first (swapped to \1) so the strip patterns can't match
-- at its second pipe and mangle a following escape-shaped run into a stray "|"
-- (AUD-407), then restored — "||" is already the correct form to send.
local function _stripWoWEscapes(s)
  s = s:gsub("||", "\1")                 -- protect literal-pipe escapes
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")   -- color open (|cAARRGGBB)
  s = s:gsub("|H.-|h(.-)|h", "%1")       -- hyperlink -> its display text
  s = s:gsub("|T.-|t", "")               -- inline texture
  s = s:gsub("|A.-|a", "")               -- inline atlas
  s = s:gsub("|[rhta]", "")              -- stray color/link/texture/atlas closers
  s = s:gsub("\1", "||")                 -- restore literal-pipe escapes
  return s
end

-- Whisper button enable state (AUD-014). A whisper is only valid when the template is
-- non-empty (an explicitly-cleared "" template renders a useless prefix-only message;
-- nil never happens — AceDB seeds a default) AND chat is not in messaging lockdown
-- (boss encounters block addon whispers). ENCOUNTER_START/END toggle these buttons.
local function _whisperEnabledNow()
  local db = LootItForward and LootItForward.db
  local template = db and db.profile.whisperMessage
  if not template or template == "" then return false end
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
    return false
  end
  return true
end

-- Applies fn to every open whisper button across all sections.
local function _forEachWhisperButton(fn)
  for _, section in pairs(itemSections) do
    for _, row in pairs(section.candidateRows) do
      if row.whisperBtn then fn(row.whisperBtn) end
    end
  end
end

-- Force-greys every whisper button. Driven by ENCOUNTER_START, which can fire before
-- InChatMessagingLockdown() flips, so this greys unconditionally rather than recomputing.
function LIF.Popup_GreyWhisperButtons()
  _forEachWhisperButton(function(btn) btn:Disable() end)
end

-- Recomputes each whisper button's state from the current template + lockdown. Driven
-- by ENCOUNTER_END (re-enable only once lockdown clears AND the template is non-empty)
-- and by the settings template edit (enable/disable as the field is filled/cleared).
function LIF.Popup_RefreshWhisperButtons()
  local enabled = _whisperEnabledNow()
  _forEachWhisperButton(function(btn)
    if enabled then btn:Enable() else btn:Disable() end
  end)
end

-- _addCandidateRow(section, candidateData, itemLink): builds a Frame row in a section.
-- Returns the row Frame.
local function _addCandidateRow(section, candidateData, itemLink)
  section._rowCounter = section._rowCounter + 1
  section.rowOrder[candidateData.guid] = section._rowCounter

  local row = CreateFrame("Frame", nil, section.sectionFrame)
  row:SetSize(FRAME_WIDTH - 2 * SECTION_INSET, ROW_H)
  -- Position placeholder; _recalcFrameHeight will re-anchor properly
  row:SetPoint("TOPLEFT", section.sectionFrame, "TOPLEFT", 0, -SECTION_HEADER_H)

  -- Dedicated info-area hover zone covering only the name+ilvl region (left side).
  -- AUD-422 intentional: the -88 inset excludes the actions column, so the compare
  -- tooltip does NOT fire while hovering the Whisper/Trade buttons (they consume the
  -- hover) — a deliberate no-conflict layout, not a missing tooltip.
  local infoZone = CreateFrame("Frame", nil, row)
  infoZone:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  infoZone:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -88, 0)
  infoZone:EnableMouse(true)
  infoZone:SetScript("OnEnter", function(self)
    if not section.itemData.link then return end  -- guard nil (AUD-308); ClassifyItem guarantees it
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
    -- Hard backstop (AUD-014): never whisper while chat is in messaging lockdown
    -- (boss encounter) even if the button's greyed state lags the ENCOUNTER_START
    -- event. SendChatMessage would throw ADDON_ACTION_BLOCKED here.
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
      LIF.Log("popup: whisper suppressed — chat messaging lockdown (boss encounter)")
      return
    end
    local target = candidateData.whisperTarget or candidateData.name or "?"
    local link = section.itemData.link
    local template = (LootItForward and LootItForward.db and LootItForward.db.profile.whisperMessage)
                     or LIF.DEFAULT_WHISPER_TEMPLATE
    local msg = LIF.RenderWhisperMessage(template, link)
    -- 255-byte send guard (AUD-014): the client silently truncates an over-length
    -- whisper, and a cut through an item-link escape sequence throws "Invalid escape
    -- code" and can disconnect. Degrade to the item NAME (plain text) so a long link
    -- never yields a broken message, and strip any residual markup the template might
    -- carry so the cut below is escape-safe regardless of how the template was
    -- populated (AUD-306) — the editbox normally prevents template escapes, but this
    -- removes the dependency on that.
    if #msg > WHISPER_MAX_BYTES then
      local name = (section.itemData and section.itemData.name) or link
      msg = _stripWoWEscapes(LIF.RenderWhisperMessage(template, name))
      if #msg > WHISPER_MAX_BYTES then
        -- Cut on a UTF-8 char boundary, never mid-sequence: SetMaxLetters caps
        -- CHARACTERS not bytes, and non-ASCII templates / localized item names can
        -- still overflow. WoW rejects malformed UTF-8. If the byte just past the cut
        -- is a continuation byte (0x80-0xBF) the cut is mid-character, so back it up
        -- to the preceding lead byte.
        local cut = WHISPER_MAX_BYTES
        while cut > 0 do
          local b = msg:byte(cut + 1)
          if b and b >= 0x80 and b <= 0xBF then cut = cut - 1 else break end
        end
        msg = msg:sub(1, cut)
      end
      LIF.Log("popup: whisper over " .. WHISPER_MAX_BYTES .. " bytes — degraded to item name for " .. target)
    end
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
  -- A row created mid-encounter (loot arriving during a later boss fight) starts greyed
  -- if chat is locked down or the template is empty (AUD-014).
  if not _whisperEnabledNow() then whisperBtn:Disable() end

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
  frame:ClearAllPoints()
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  -- Saved position if valid AND on the current screen (a save from a larger
  -- resolution that now lands off-screen is dropped below).
  if _hasSavedPosition(pos) and _isOnScreen(pos.x, pos.y) then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    LIF.Log("popup: position restored x=" .. pos.x .. " y=" .. pos.y)
    return
  end
  -- No usable save: clear a corrupt/off-screen value, then centre on the frame's
  -- CURRENT rendered height — not FRAME_MIN_HEIGHT. A reset (button or /lif resetpos)
  -- while a content-filled popup is open must land where the next ShowPopup would, or
  -- the popup sits low here and jumps up on the following show (V-01). At init the
  -- frame is still min-height, so this matches the old behaviour there.
  if pos and LootItForward and LootItForward.db then
    LootItForward.db.char.popupPosition = nil
  end
  local x, y = _defaultPopupPosition(frame:GetHeight())
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  LIF.Log("popup: position restored x=" .. x .. " y=" .. y)
end

-- ============================================================
-- Exported popup callbacks
-- TOC load order: loot.lua before popup.lua — these assignments win.
-- ============================================================

function LIF.ShowPopup(itemData, candidates)
  -- A real drop always evicts a live example/preview popup (AUD-002). The example
  -- shares this frame, so without this the real section would stack UNDER the fake
  -- rows and examplePopupActive would suppress the real Whisper/Trade buttons. This
  -- covers the post-combat scanning window that the M5 combat-start dismiss
  -- (Popup_DismissExample) does not — a real drop can call ShowPopup seconds after
  -- combat ends, while an example opened during that window is still up. dismissPopup
  -- clears examplePopupActive as part of teardown, so the rebuild below runs clean.
  if LIF.examplePopupActive then dismissPopup() end

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

  -- Re-anchor on every show. With NO saved position, recompute the centered default
  -- now that the frame has grown to fit its content (not just at OnInitialize, and not
  -- before _recalcFrameHeight — the frame anchors TOPLEFT and grows downward, so
  -- centering against FRAME_MIN_HEIGHT before content is added leaves the box off-center
  -- vertically; 2026-07-03). With a saved position, re-apply it: a mid-drag dismiss
  -- (AUD-307) freezes the frame at an abandoned, UNSAVED drag point, so without this
  -- every later popup this session would open there instead of the saved spot (AUD-406).
  -- Idempotent for a deliberate drag, which is saved on mouse-up.
  local pos = LootItForward and LootItForward.db and LootItForward.db.char.popupPosition
  frame:ClearAllPoints()
  if not _hasSavedPosition(pos) then
    local x, y = _defaultPopupPosition(frame:GetHeight())
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  else
    local x, y = _resolvePopupPosition()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  end

  LIF.Log("popup: ShowPopup item=" .. tostring(itemData and itemData.link))
end

-- Roster update callback — called by LootItForward:GROUP_ROSTER_UPDATE
-- when a group member leaves. Removes rows for departed GUIDs across all sections.
-- T-04-09 mitigation: collect guids/itemLinks to remove into temporary lists first,
-- then apply removals — never mutate tables while iterating with pairs().
function LIF.Popup_OnRosterUpdate()
  if not frame or not frame:IsShown() then return end
  -- The example/preview popup uses fabricated GUIDs that never resolve to a unit,
  -- so pruning would remove every row and dismiss it on ANY roster churn while
  -- previewing (AUD-020). Roster changes are irrelevant to a static preview —
  -- leave it untouched.
  if LIF.examplePopupActive then return end

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
  -- Block the example popup when it could collide with real activity: in combat
  -- (real loot arrives mid/post-fight) and while a real loot popup is already
  -- showing (the example would append its fabricated rows to the live popup —
  -- the same interleave M5 guards from the other direction). An example popup
  -- already up is fine to re-render.
  if InCombatLockdown() then
    LIF.Print("Example popup is unavailable in combat.")
    return
  end
  if frame and frame:IsShown() and not LIF.examplePopupActive then
    LIF.Print("Close the active loot popup before showing the example.")
    return
  end
  C_Item.RequestLoadItemDataByID(LIF.EXAMPLE_ITEM_ID)  -- warm cache so hover tooltip is correct
  dismissPopup()                          -- clear any previous example before reshowing
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
  -- Set AFTER ShowPopup: the new evict-example guard at the top of ShowPopup would
  -- otherwise dismiss the example we are building (self-eviction). The Whisper/Trade
  -- button closures read this flag at CLICK time, so setting it now still suppresses
  -- them in example mode (D-19) — behaviour-identical to setting it before.
  LIF.examplePopupActive = true
  LIF.Log("popup: ShowExamplePopup called")
end
