local _, LIF = ...

local function PlayerLabel(unit)
  local name, realm = UnitFullName(unit)
  name = name or UnitName(unit)
  if not name or name == "Unknown" then return unit end
  if realm and realm ~= "" then return name .. "-" .. realm end
  return name
end

local currentlyInspecting = nil
local scanQueue = {}
local scanTicker = nil

-- Scan reconciliation job (REV-006): one 5s base ticker, two phases.
-- Fast phase: act on EVERY tick for FAST_TICKS ticks (60s) after group
-- formation or a member joining. Steady phase: act every SLOW_TICK_EVERY
-- ticks (30s) indefinitely while any member is not COMPLETE. No give-up cap —
-- a member who becomes reachable late still gets scanned; the ticker stops
-- only when no PENDING members remain (and restarts on roster change/loot).
local TICKER_INTERVAL = 5
local FAST_TICKS      = 12  -- 60s of every-tick attempts
local SLOW_TICK_EVERY = 6   -- act every 6th tick (30s) in steady phase

-- SCAN_TIMEOUT (REQ-inspect-slot-sharing): NotifyInspect/INSPECT_READY/
-- ClearInspectPlayer is a single client-wide slot shared by every addon, not
-- namespaced per-addon. A third-party addon (e.g. a mouseover-tooltip addon)
-- can silently steal it mid-inspect, and our own INSPECT_READY never fires.
-- Blizzard's server-side inspect throttle is ~6 requests/10s and a throttled
-- request just silently drops (no error) — see docs/wow-api-pitfalls.md.
-- 2s comfortably covers an occasional clobber plus its reassert; under
-- SUSTAINED conflict (a foreign addon clobbering every attempt) LIF's own
-- reasserts can themselves start hitting the shared throttle and silently
-- drop — that degrades to this timeout loop rather than erroring, so it's
-- self-healing, just slower. See MAX_REASSERTS below for the faster
-- clobber-detection path that usually beats this timer.
local SCAN_TIMEOUT    = 2

-- Reassert (REQ-inspect-slot-sharing): rather than passively waiting out
-- SCAN_TIMEOUT whenever another addon steals the inspect slot, detect the
-- theft via hooksecurefunc("NotifyInspect") and re-request our own target.
-- Delayed slightly so a rapid mouseover sweep (many foreign calls in quick
-- succession) settles before we re-assert, instead of re-clobbering ourselves
-- immediately. Capped per attempt so a persistent conflict falls back to the
-- SCAN_TIMEOUT loop rather than spamming NotifyInspect's own throttle.
local REASSERT_DELAY  = 0.5
local MAX_REASSERTS   = 2

local fastTicksLeft   = 0
local slowTickCounter = 0
local currentReassertCount = 0

local SLOT_NAMES = {
  "HEADSLOT", "NECKSLOT", "SHOULDERSLOT", "CHESTSLOT", "WAISTSLOT",
  "LEGSSLOT", "FEETSLOT", "WRISTSLOT", "HANDSSLOT",
  "FINGER0SLOT", "FINGER1SLOT", "TRINKET0SLOT", "TRINKET1SLOT",
  "BACKSLOT", "MAINHANDSLOT", "SECONDARYHANDSLOT",
}
local SLOT_SHORT = {
  HEADSLOT="HD", NECKSLOT="NK", SHOULDERSLOT="SH", CHESTSLOT="CH", WAISTSLOT="WA",
  LEGSSLOT="LG", FEETSLOT="FT", WRISTSLOT="WR", HANDSSLOT="HN",
  FINGER0SLOT="R1", FINGER1SLOT="R2", TRINKET0SLOT="T1", TRINKET1SLOT="T2",
  BACKSLOT="BK", MAINHANDSLOT="MH", SECONDARYHANDSLOT="OH",
}
local SLOT_IDS = {}
for _, name in ipairs(SLOT_NAMES) do
  SLOT_IDS[name] = GetInventorySlotInfo(name)
end

-- Exported for debug.lua and future diagnostics.
LIF.SLOT_NAMES = SLOT_NAMES
LIF.SLOT_IDS   = SLOT_IDS
LIF.SLOT_SHORT = SLOT_SHORT

local function GuidToUnit(guid)
  if UnitGUID("player") == guid then return "player" end
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitGUID(unit) == guid then return unit end
  end
  return nil
end
LIF.GuidToUnit = GuidToUnit

local function CanScanUnit(unit)
  if not UnitIsPlayer(unit) then return false end
  if not UnitExists(unit) then return false end
  if not UnitIsConnected(unit) then return false end
  if UnitIsDeadOrGhost(unit) then return false end
  if UnitIsDeadOrGhost("player") then return false end
  if InCombatLockdown() then return false end
  -- No UnitIsVisible check: CanInspect() is Blizzard's own authoritative gate
  -- (it's what the manual party-frame Inspect button relies on) and already
  -- allows cross-zone group members. UnitIsVisible incorrectly excluded them.
  if not CanInspect(unit) then return false end
  return true
end

local function HasPendingMembers()
  for _, member in pairs(LIF.Cache.GetAll()) do
    if member.state == "PENDING" then return true end
  end
  return false
end

local function StopScanTicker()
  if scanTicker then
    scanTicker:Cancel()
    scanTicker = nil
  end
  fastTicksLeft   = 0
  slowTickCounter = 0
end

-- Forward declaration so TryQueuePendingMembers can call StartNextInspect.
local StartNextInspect

local function TryQueuePendingMembers()
  for guid, member in pairs(LIF.Cache.GetAll()) do
    if member.state == "PENDING" then
      local unit = GuidToUnit(guid)
      -- Never queue the player's own unit (Pitfall 9).
      if unit and unit ~= "player" and CanScanUnit(unit) then
        -- Skip if already queued.
        local alreadyQueued = false
        for _, qguid in ipairs(scanQueue) do
          if qguid == guid then
            alreadyQueued = true
            break
          end
        end
        if not alreadyQueued then
          table.insert(scanQueue, guid)
        end
      end
    end
  end
  if #scanQueue > 0 then
    StartNextInspect()
  end
end

-- fast=true (re)enters the fast phase — pass when a new member joins or the
-- group forms so stragglers are retried every 5s for the first minute.
local function EnsureScanTickerRunning(fast)
  if fast then fastTicksLeft = FAST_TICKS end
  if scanTicker then return end
  slowTickCounter = 0
  scanTicker = C_Timer.NewTicker(TICKER_INTERVAL, function()
    if not HasPendingMembers() then
      StopScanTicker()
      return
    end
    if fastTicksLeft > 0 then
      fastTicksLeft = fastTicksLeft - 1
      TryQueuePendingMembers()
    else
      slowTickCounter = slowTickCounter + 1
      if slowTickCounter >= SLOW_TICK_EVERY then
        slowTickCounter = 0
        TryQueuePendingMembers()
      end
    end
  end)
end

-- REQ-inspect-slot-sharing: detect another addon stealing the single
-- client-wide inspect slot out from under our in-flight request, and
-- re-assert ours instead of passively waiting out SCAN_TIMEOUT. This fires
-- for EVERY NotifyInspect call, including our own (hooksecurefunc wraps the
-- global) — guids matching currentlyInspecting are our own calls (initial
-- request or a prior reassert) and must not be treated as a clobber.
hooksecurefunc("NotifyInspect", function(unit)
  if currentlyInspecting == nil then return end
  local guid = UnitGUID(unit)
  -- A nil guid means the unit token was already invalid when NotifyInspect
  -- was called (e.g. QuickItemLevel's delayed NotifyInspect("mouseover")
  -- firing after the cursor moved away) — that call never actually stole
  -- the slot, so it must not burn a reassert against a real future clobber.
  if not guid then return end
  if guid == currentlyInspecting then return end
  if currentReassertCount >= MAX_REASSERTS then return end

  currentReassertCount = currentReassertCount + 1
  local guidAtReassert = currentlyInspecting
  LIF.Log("clobber detected guid=" .. guidAtReassert:sub(-6) .. " — reasserting in " .. REASSERT_DELAY .. "s")
  C_Timer.After(REASSERT_DELAY, function()
    if currentlyInspecting == guidAtReassert then
      local ownUnit = GuidToUnit(guidAtReassert)
      if ownUnit then
        LIF.Log("reasserting " .. PlayerLabel(ownUnit))
        NotifyInspect(ownUnit)
      end
    end
  end)
end)

StartNextInspect = function()
  if currentlyInspecting ~= nil then return end
  if #scanQueue == 0 then return end

  local guid = table.remove(scanQueue, 1)

  local member = LIF.Cache.GetMember(guid)
  if not member or member.state ~= "PENDING" then
    StartNextInspect()
    return
  end

  local unit = GuidToUnit(guid)
  if not unit then
    LIF.Cache.Remove(guid)
    StartNextInspect()
    return
  end

  if not CanScanUnit(unit) then
    StartNextInspect()
    return
  end

  currentlyInspecting = guid
  currentReassertCount = 0
  LIF.Log("inspecting " .. PlayerLabel(unit))
  NotifyInspect(unit)

  -- Capture GUID as a local so the closure is not affected by later changes
  -- to currentlyInspecting (Pitfall 6).
  local inspectingGuid = guid
  C_Timer.After(SCAN_TIMEOUT, function()
    if currentlyInspecting == inspectingGuid then
      currentlyInspecting = nil
      ClearInspectPlayer()  -- release the inspect slot for other addons
      table.insert(scanQueue, inspectingGuid)
      StartNextInspect()
    end
  end)
end

function LIF.GetDebugInfo()
  return {
    currentlyInspecting = currentlyInspecting,
    queueLength         = #scanQueue,
    tickerRunning       = scanTicker ~= nil,
  }
end

function LIF.Queue_StopAndReset()
  currentlyInspecting = nil
  currentReassertCount = 0
  -- Clear in-place so that LIF.scanQueue reference stays live.
  for i = #scanQueue, 1, -1 do
    table.remove(scanQueue, i)
  end
  StopScanTicker()
end

function LIF.OnGroupRosterUpdate()
  local currentGuids = {}

  local selfGuid = UnitGUID("player")
  if selfGuid then currentGuids[selfGuid] = "player" end

  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) and UnitIsPlayer(unit) then
      local guid = UnitGUID(unit)
      -- Guard against follower-dungeon companions: real player GUIDs start with "Player-"
      if guid and guid:sub(1, 7) == "Player-" then
        currentGuids[guid] = unit
      end
    end
  end

  -- Remove departed members from cache.
  for guid in pairs(LIF.Cache.GetAll()) do
    if not currentGuids[guid] then
      if currentlyInspecting == guid then currentlyInspecting = nil end
      local unit = GuidToUnit(guid)
      LIF.Log("remove " .. (unit and PlayerLabel(unit) or guid:sub(-6)))
      LIF.Cache.Remove(guid)
      -- Clear departed member from any pending loot scan windows so _tryOpenPopup
      -- is not blocked waiting for a member who will never complete (WR-03).
      for _, entry in ipairs(LIF.pendingLootItems or {}) do
        if entry.scanningGuids then entry.scanningGuids[guid] = nil end
      end
    end
  end

  -- Add new party members as PENDING. Never add self.
  local addedNewMember = false
  for guid in pairs(currentGuids) do
    if guid ~= selfGuid and not LIF.Cache.GetMember(guid) then
      local unit = currentGuids[guid]
      LIF.Log("queue " .. PlayerLabel(unit))
      LIF.Cache.Add(guid)
      table.insert(scanQueue, guid)
      addedNewMember = true
    end
  end

  TryQueuePendingMembers()
  -- Only (re)start the ticker for an actual new member (or initial formation) —
  -- GROUP_ROSTER_UPDATE fires far more often than real roster changes (Blizzard
  -- syncs personal-loot eligibility per item/skin through the same event), and
  -- restarting the ticker on every one of those churns through short-lived
  -- C_Timer tickers for no reason. The loot pipeline (LIF.EnsureScanTickerRunning
  -- in OnPlayerLootReceived) and the reconnect/resurrect recovery path
  -- (OnUnitMaybeScannable) already arm the ticker whenever a member actually
  -- needs (re)scanning, independent of this event.
  if addedNewMember then
    EnsureScanTickerRunning(true)
  end
  StartNextInspect()
end

function LIF.OnInspectReady(guid)
  -- REQ-inspect-slot-sharing: the inspect slot is shared client-wide, so an
  -- INSPECT_READY can arrive for a member we're NOT currently driving
  -- ourselves — e.g. another addon's mouseover inspect happened to land on
  -- a party member we still have PENDING. Harvest that data for free rather
  -- than discarding it and waiting for our own turn. Only our own in-flight
  -- target gets to touch currentlyInspecting/ClearInspectPlayer/
  -- StartNextInspect below — releasing those for a harvested read would
  -- rudely cancel whatever OTHER addon's inspect we just piggybacked on.
  local isOwnTarget = (currentlyInspecting == guid)
  local member = LIF.Cache.GetMember(guid)
  if not isOwnTarget and (not member or member.state ~= "PENDING") then return end

  LIF.Log("INSPECT_READY — " .. guid:sub(-6) .. (isOwnTarget and "" or " [harvested]"))

  local unit = GuidToUnit(guid)
  if not unit then
    LIF.Cache.Remove(guid)
    if isOwnTarget then
      currentlyInspecting = nil
      StartNextInspect()
    end
    return
  end

  local gearData = {}
  for _, slotID in pairs(SLOT_IDS) do
    local link = GetInventoryItemLink(unit, slotID)
    if link then
      -- GetItemInfo respects the linkLevel encoded in the hyperlink (the member's character
      -- level), so scaling items report the ilvl at the MEMBER's level, not the local player's.
      -- GetDetailedItemLevelInfo applies the local player's context and will over-report ilvl
      -- for scaling items worn by lower-level party members.
      local actualIlvl = select(4, GetItemInfo(link)) or C_Item.GetDetailedItemLevelInfo(link)
      gearData[slotID] = { link = link, ilvl = actualIlvl }
    end
  end

  local specID = GetInspectSpecialization(unit)
  local slotCount = 0
  for _ in pairs(gearData) do slotCount = slotCount + 1 end
  local label = PlayerLabel(unit)
  local combatTag = InCombatLockdown() and " [combat]" or ""

  -- WoW fires INSPECT_READY before all slot data has loaded — first fire often
  -- returns partial slots even when the player has a full set. 14 requires a
  -- near-complete read before accepting; stabilization handles players who
  -- genuinely equip fewer slots (leveling characters, empty OH, etc.).
  local MIN_SLOTS = 14

  -- Scan stabilization (D-15): accept COMPLETE if the same slotCount is returned
  -- 3 consecutive times, even when below MIN_SLOTS. This handles leveling characters
  -- who genuinely equip fewer than MIN_SLOTS items. Harvested (foreign) reads feed
  -- the same counters, so another addon's inspect traffic can help this converge
  -- faster, not just our own serialized attempts.
  if member then
    if slotCount == member.lastSlotCount then
      member.consistentCount = (member.consistentCount or 0) + 1
    else
      member.lastSlotCount = slotCount
      member.consistentCount = 1
    end
  end

  local stabilized = member and (member.consistentCount or 0) >= 3
  if slotCount < MIN_SLOTS and not stabilized then
    LIF.Log("warn: " .. label .. " gear=" .. slotCount .. "/16" .. combatTag .. " — awaiting data")
    return
  end
  if stabilized and slotCount < MIN_SLOTS then
    LIF.Log("stabilized complete guid=" .. guid:sub(-6) .. " slots=" .. slotCount .. " consistent=" .. (member.consistentCount or 0))
  end

  -- Resolve spec name and class for inspect record and loot evaluation.
  local _, classToken = UnitClass(unit)
  local _, specName = GetSpecializationInfoByID(specID or 0)
  local specTag = specID and (specID .. "(" .. (specName or "?") .. ")") or "nil"

  -- Capture full name+realm for armory lookups. Same-realm members return ""
  -- for realm from UnitFullName, so fall back to the player's own realm.
  local memberName, memberRealm = UnitFullName(unit)
  memberName = memberName or UnitName(unit)
  if not memberRealm or memberRealm == "" then
    _, memberRealm = UnitFullName("player")
  end
  memberRealm = memberRealm or ""

  -- Log which slots returned data (short codes) for slot-coverage analysis.
  local filledSlots, missingSlots = {}, {}
  for _, slotName in ipairs(SLOT_NAMES) do
    local slotID = SLOT_IDS[slotName]
    if gearData[slotID] then
      table.insert(filledSlots, SLOT_SHORT[slotName])
    else
      table.insert(missingSlots, SLOT_SHORT[slotName])
    end
  end

  -- Reset stabilization tracking on COMPLETE.
  if member then
    member.lastSlotCount = nil
    member.consistentCount = nil
  end

  local playerLevel = UnitLevel(unit) or "?"
  local inspectIlvl = C_PaperDollInfo.GetInspectItemLevel(unit)
  local ilvlTag = (inspectIlvl and inspectIlvl > 0) and math.floor(inspectIlvl) or "?"

  LIF.Cache.SetComplete(guid, { gear = gearData, specID = specID, specName = specName, lvl = playerLevel, ilvl = ilvlTag })
  LIF.Log("complete " .. label .. " class=" .. tostring(classToken) ..
    " spec=" .. specTag .. " gear=" .. slotCount .. "/16" ..
    " lvl=" .. playerLevel .. " ilvl=" .. ilvlTag .. combatTag .. (isOwnTarget and "" or " [harvested]"))
  LIF.Log("  got: " .. table.concat(filledSlots, " ") ..
    (#missingSlots > 0 and ("  empty: " .. table.concat(missingSlots, " ")) or ""))
  LIF.RecordInspect({
    t        = date("!%H:%M:%S"),
    name     = memberName,
    realm    = memberRealm,
    class    = tostring(classToken),
    specID   = specID,
    specName = specName,
    slots    = slotCount,
    got      = table.concat(filledSlots, " "),
    nil_     = table.concat(missingSlots, " "),
  })
  if isOwnTarget then
    ClearInspectPlayer()
    currentlyInspecting = nil
    StartNextInspect()
  end
end

function LIF.OnUnitHealthChanged(unitToken)
  if currentlyInspecting == nil then return end
  local guid = UnitGUID(unitToken)
  if guid == nil then return end
  if guid == currentlyInspecting and UnitIsDeadOrGhost(unitToken) then
    currentlyInspecting = nil
    StartNextInspect()
  end
end

function LIF.OnUnitDisconnect(unitToken)
  if currentlyInspecting == nil then return end
  local guid = UnitGUID(unitToken)
  if guid == nil then return end
  if guid == currentlyInspecting then
    currentlyInspecting = nil
    StartNextInspect()
  end
end

function LIF.TryQueuePendingMembers()
  TryQueuePendingMembers()
end

-- LIF.OnUnitMaybeScannable(unitToken)  (REV-006)
-- Recovery direction of REQ-scan-retry-on-events: called when a unit's
-- conditions may have IMPROVED (resurrected via UNIT_HEALTH, reconnected via
-- UNIT_CONNECTION). Cheap: exits immediately unless this member is PENDING.
function LIF.OnUnitMaybeScannable(unitToken)
  local guid = UnitGUID(unitToken)
  if guid == nil then return end
  local member = LIF.Cache.GetMember(guid)
  if member == nil or member.state ~= "PENDING" then return end
  TryQueuePendingMembers()
end

-- LIF.EnsureScanTickerRunning([fast])
-- Public export of the module-local EnsureScanTickerRunning function.
-- Called from core/loot.lua at loot time to (re)start the scan job.
-- fast=true re-enters the 5s fast phase (used on roster changes).
function LIF.EnsureScanTickerRunning(fast)
  EnsureScanTickerRunning(fast)
end

-- LIF.RequestReinspect(guid)  (D-14)
-- Forces a fresh loot-time inspect for a specific party member.
-- Preserves cached class/spec data; resets gear data; moves member to PENDING;
-- inserts the GUID at the FRONT of the scan queue.
function LIF.RequestReinspect(guid)
  local member = LIF.Cache.GetMember(guid)
  if not member then return end  -- member left group

  -- Preserve specID and class info; reset gear data only.
  member.gear  = {}
  member.state = "PENDING"

  -- Reset stabilization counters so next set of INSPECT_READY fires counts fresh.
  member.lastSlotCount  = nil
  member.consistentCount = nil

  -- REV-016: rapid multi-drop loot calls RequestReinspect repeatedly for the
  -- same members — remove any existing entry so the guid is moved to the
  -- front rather than duplicated (duplicates waste NotifyInspect throttle).
  for i, qguid in ipairs(scanQueue) do
    if qguid == guid then
      table.remove(scanQueue, i)
      break
    end
  end
  -- Front-of-queue insertion to prioritize loot-time rescans.
  table.insert(scanQueue, 1, guid)

  LIF.Log("reinspect queued guid=" .. guid:sub(-6))

  -- If nothing is currently scanning, kick off the next inspect immediately.
  if currentlyInspecting == nil then
    StartNextInspect()
  end
end

-- Expose scanQueue for tests that need to inspect queue state.
LIF.scanQueue = scanQueue
