-- tests/mock_wow_api.lua
-- Standalone WoW API stubs for offline luaunit testing.
-- All globals required by the harness-loaded core modules (see LoadAddonModules) are stubbed here.
-- Call ResetMocks() in each test setUp to prevent state leakage.

-- ============================================================
-- C_Timer mock
-- ============================================================
local pendingAfterCallbacks = {}

C_Timer = {
  -- Records deferred callbacks; call FirePendingAfterCallbacks() in tests to fire them.
  After = function(delay, fn)
    table.insert(pendingAfterCallbacks, { delay = delay, fn = fn })
  end,

  -- Returns a ticker handle with Cancel() and Fire() methods.
  -- Handles are recorded in _mockTickers so tests can drive ticks manually.
  NewTicker = function(interval, fn, iterations)
    local handle = {
      cancelled = false,
      _fn = fn,
      _interval = interval,
      _iterations = iterations,
    }
    function handle:Cancel() self.cancelled = true end
    function handle:Fire() if not self.cancelled then self._fn() end end
    table.insert(_mockTickers, handle)
    return handle
  end,
}

_mockTickers = {}  -- every NewTicker handle, in creation order

-- Helper: most recently created ticker handle (or nil).
function LastMockTicker()
  return _mockTickers[#_mockTickers]
end

-- Helper: count of C_Timer.After callbacks not yet fired. Used to assert a
-- retry is bounded (queues at most once) rather than looping indefinitely.
function CountPendingAfterCallbacks()
  return #pendingAfterCallbacks
end

-- Helper: fire all pending After callbacks then clear the list.
-- Use in tests to simulate the 4-second inspect timeout.
function FirePendingAfterCallbacks()
  local cbs = pendingAfterCallbacks
  pendingAfterCallbacks = {}
  for _, cb in ipairs(cbs) do
    cb.fn()
  end
end

-- Helper: fire a single pending After callback by 1-based insertion index and
-- remove it, leaving the rest pending. Use to fire ONE specific timer (e.g. a
-- stale SCAN_TIMEOUT scheduled before a newer one of the same delay) in isolation.
-- Returns true if a callback existed at that index.
function FirePendingAfterCallbackAt(index)
  local cb = pendingAfterCallbacks[index]
  if not cb then return false end
  table.remove(pendingAfterCallbacks, index)
  cb.fn()
  return true
end

-- Helper: fire only callbacks scheduled with delay <= maxDelay, leaving
-- longer-delay callbacks (e.g. a 2s SCAN_TIMEOUT) pending. Use to isolate a
-- short-delay timer (e.g. a reassert) from a longer fallback timer that was
-- also scheduled, without a real clock.
function FirePendingAfterCallbacksUpTo(maxDelay)
  local remaining, toFire = {}, {}
  for _, cb in ipairs(pendingAfterCallbacks) do
    if cb.delay <= maxDelay then
      table.insert(toFire, cb)
    else
      table.insert(remaining, cb)
    end
  end
  pendingAfterCallbacks = remaining
  for _, cb in ipairs(toFire) do
    cb.fn()
  end
end

-- ============================================================
-- BIND_TRADE_TIME_REMAINING global string (used by LIF.IsItemTradeable)
-- ============================================================
-- Matches modern WoW retail tooltip text (as seen in-game screenshots).
BIND_TRADE_TIME_REMAINING = "You may trade this item with players that were also eligible to loot this item for the next %s (including time offline)."

-- ============================================================
-- C_Container mock
-- ============================================================
-- Tests write: _mockContainerItems[bag][slot] = { hyperlink = "item:ID:..." }
_mockContainerItems = {}

C_Container = {
  GetContainerNumSlots = function(bag)
    if not _mockContainerItems[bag] then return 0 end
    local maxSlot = 0
    for slot in pairs(_mockContainerItems[bag]) do
      if slot > maxSlot then maxSlot = slot end
    end
    return maxSlot
  end,
  GetContainerItemInfo = function(bag, slot)
    if not _mockContainerItems[bag] then return nil end
    return _mockContainerItems[bag][slot]
  end,
}

-- ============================================================
-- Tooltip / CreateFrame mock (for LIF.IsItemTradeable)
-- ============================================================
-- Tests write: _mockScanTooltipLines["item:ID:..."] = { "line1", "line2", ... }
-- Tests write: _mockNonTradeableItems[itemID] = true  (for IsItemTradeable mock override)
_mockScanTooltipLines = {}
_mockNonTradeableItems = {}

local _mockScanTooltip = {
  _numLines    = 0,
  _currentLines = {},
  SetOwner           = function(self) end,
  SetClampedToScreen = function(self) end,
  ClearLines = function(self)
    self._numLines     = 0
    self._currentLines = {}
  end,
  SetBagItem = function(self, bag, slot)
    local info  = _mockContainerItems[bag] and _mockContainerItems[bag][slot]
    local lines = (info and _mockScanTooltipLines[info.hyperlink]) or {}
    self._numLines     = #lines
    self._currentLines = lines
  end,
  NumLines = function(self)
    return self._numLines
  end,
  GetRegions = function(self)
    local regions = {}
    for _, text in ipairs(self._currentLines) do
      local t = text
      table.insert(regions, {
        GetObjectType = function() return "FontString" end,
        GetText       = function() return t end,
      })
    end
    return table.unpack(regions)
  end,
}

function CreateFrame(frameType, name, parent, template)
  if frameType == "GameTooltip" then
    return _mockScanTooltip
  end
  return {}
end

-- ============================================================
-- C_Item mock
-- ============================================================
_mockIlvl = {}  -- tests write: _mockIlvl["itemLink"] = 415

_mockWuEItems = {}  -- tests write: _mockWuEItems["itemLink"] = true (warbound-until-equipped)

C_Item = {
  -- nil for an item the client has not cached — NOT 0. The real API returns nil there,
  -- and 0 is truthy in Lua, so an `or 0` here would make a cold item indistinguishable
  -- from a resolved ilvl-0 one and no test could ever reach the cold-cache path (AUD-530).
  GetDetailedItemLevelInfo = function(link)
    local ilvl = _mockIlvl[link]
    if not ilvl then return nil end
    return ilvl, 0, 0
  end,
  -- REV-023: link-accepting WuE discriminator (in-game verified 2026-06-13).
  IsItemBindToAccountUntilEquip = function(link)
    return _mockWuEItems[link] == true
  end,
}

-- ============================================================
-- C_PaperDollInfo mock
-- ============================================================
-- Tests can set _mockInspectIlvl[unit] = 450 to simulate a specific ilvl.
_mockInspectIlvl = {}

C_PaperDollInfo = {
  GetInspectItemLevel = function(unit)
    return _mockInspectIlvl[unit] or 0
  end,
}

-- ============================================================
-- C_Heirloom mock (Phase 3.1 — D-08)
-- ============================================================
_mockHeirloomItemIDs = {}  -- tests write: _mockHeirloomItemIDs[12345] = true

C_Heirloom = {
  IsItemHeirloom = function(itemID)
    return _mockHeirloomItemIDs[itemID] == true
  end,
}

-- ============================================================
-- Per-unit boolean mocks
-- ============================================================
-- Each mock table is indexed by unit token (e.g. "party1", "player").
-- Default values: true for Exists/IsPlayer/IsConnected, false for IsDeadOrGhost.
_mockIsPlayer       = {}  -- default true
_mockExists         = {}  -- default true
_mockIsConnected    = {}  -- default true
_mockIsDeadOrGhost  = {}  -- default false

function UnitIsPlayer(unit)
  local v = _mockIsPlayer[unit]
  if v == nil then return true end
  return v
end

function UnitExists(unit)
  local v = _mockExists[unit]
  if v == nil then return true end
  return v
end

function UnitIsConnected(unit)
  local v = _mockIsConnected[unit]
  if v == nil then return true end
  return v
end

function UnitIsDeadOrGhost(unit)
  local v = _mockIsDeadOrGhost[unit]
  if v == nil then return false end
  return v
end

-- ============================================================
-- Per-unit GUID mock
-- ============================================================
_mockGuids = {}  -- tests write: _mockGuids["party1"] = "GUID-P1"

function UnitGUID(unit)
  return _mockGuids[unit] or nil
end

-- ============================================================
-- UnitName / UnitFullName mocks
-- ============================================================
_mockUnitNames  = {}  -- tests write: _mockUnitNames["party1"] = "Playername"
_mockUnitRealms = {}  -- tests write: _mockUnitRealms["party1"] = "Realm-Name"

function UnitName(unit)
  return _mockUnitNames[unit] or unit
end

function UnitFullName(unit)
  return UnitName(unit), _mockUnitRealms[unit] or nil
end

-- ============================================================
-- DEFAULT_CHAT_FRAME stub
-- ============================================================
_chatMessages = {}

DEFAULT_CHAT_FRAME = {
  AddMessage = function(self, msg)
    table.insert(_chatMessages, msg)
  end
}

-- ============================================================
-- Boolean global mocks
-- ============================================================
_mockInCombat = false

function InCombatLockdown()
  return _mockInCombat
end

_mockCanInspect = {}  -- default true per unit

function CanInspect(unit)
  local v = _mockCanInspect[unit]
  if v == nil then return true end
  return v
end

_mockIsVisible = {}  -- default true per unit; false = other zone/phase or not loaded

function UnitIsVisible(unit)
  local v = _mockIsVisible[unit]
  if v == nil then return true end
  return v
end

-- ============================================================
-- Inspect spies
-- ============================================================
_notifyInspectCalls = {}  -- records every unit passed to NotifyInspect
_clearInspectCount  = 0

function NotifyInspect(unit)
  table.insert(_notifyInspectCalls, unit)
end

function ClearInspectPlayer()
  _clearInspectCount = _clearInspectCount + 1
end

-- ============================================================
-- hooksecurefunc mock (global-function-name form only: production code
-- only calls hooksecurefunc("NotifyInspect", fn), never the table+name form).
-- ============================================================
function hooksecurefunc(funcName, hookFn)
  local original = _G[funcName]
  _G[funcName] = function(...)
    if original then original(...) end
    hookFn(...)
  end
end

-- ============================================================
-- Gear / spec mocks
-- ============================================================
_mockGearLinks = {}   -- _mockGearLinks[unit][slotID] = "itemLink"
_mockSpecID    = {}   -- _mockSpecID[unit] = specID number

function GetInventoryItemLink(unit, slotID)
  local unitGear = _mockGearLinks[unit]
  if not unitGear then return nil end
  return unitGear[slotID] or nil
end

function GetInspectSpecialization(unit)
  return _mockSpecID[unit] or 0
end

-- ============================================================
-- UnitClass mock (spike 007 — returns class token without inspect)
-- ============================================================
_mockUnitClass = {}  -- _mockUnitClass["party1"] = {"Shaman", "SHAMAN"}

function UnitClass(unit)
  local v = _mockUnitClass[unit]
  if v then return v[1], v[2] end
  return nil, nil
end

-- ============================================================
-- UnitLevel mock (Phase 3.1 — D-09)
-- ============================================================
_mockUnitLevel = {}  -- tests write: _mockUnitLevel["player"] = 50

function UnitLevel(unit)
  return _mockUnitLevel[unit] or 1
end

-- ============================================================
-- GetSpecializationInfoByID stub (spike 002 — spec name resolution)
-- ============================================================
_mockSpecInfo = {}  -- _mockSpecInfo[specID] = {id, name, ...}

function GetSpecializationInfoByID(specID)
  local v = _mockSpecInfo[specID]
  if v then return v[1], v[2] end
  return nil, nil
end

-- ============================================================
-- GetInventorySlotInfo stub (called at load time by queue.lua if used)
-- Returns a stable slot ID matching the WoW retail values.
-- ============================================================
local _slotNameToID = {
  HEADSLOT           = 1,
  NECKSLOT           = 2,
  SHOULDERSLOT       = 3,
  CHESTSLOT          = 5,
  WAISTSLOT          = 6,
  LEGSSLOT           = 7,
  FEETSLOT           = 8,
  WRISTSLOT          = 9,
  HANDSSLOT          = 10,
  FINGER0SLOT        = 11,
  FINGER1SLOT        = 12,
  TRINKET0SLOT       = 13,
  TRINKET1SLOT       = 14,
  BACKSLOT           = 15,
  MAINHANDSLOT       = 16,
  SECONDARYHANDSLOT  = 17,
}

function GetInventorySlotInfo(slotName)
  return _slotNameToID[slotName] or 0, nil, false
end

-- ============================================================
-- IsInRaid stub (used by ShouldBeActive in LootItForward.lua)
-- ============================================================
_mockInRaid = false

function IsInRaid()
  return _mockInRaid
end

-- ============================================================
-- GetNumGroupMembers stub (Phase 5 — minPartySize gate in _tryOpenPopup)
-- Default 5 (full party) preserves existing test behaviour.
-- ============================================================
_mockGroupSize = 5

function GetNumGroupMembers()
  return _mockGroupSize or 0
end

-- ============================================================
-- Time stubs
-- ============================================================
function date(fmt, t)
  return "00:00:00"
end

function time()
  return 0
end

-- GetTime(): WoW returns the client uptime in seconds (float, ms precision).
-- Tests drive it by assigning _mockTime to simulate the passage of time between
-- INSPECT_READY fires (M7 stabilization pacing).
_mockTime = 0
function GetTime()
  return _mockTime
end

-- ============================================================
-- GetItemInfo stub (Phase 3)
-- Returns 14 positional fields matching the WoW retail API order:
--   name, _, rarity, ilvl, _, itype, subtype, _, equipLoc, _, _, classID, subID, bindType
-- Tests populate via _mockItemInfo["itemLink"] = { ... }
-- ============================================================
_mockItemInfo = {}

function GetItemInfo(linkOrID)
  local info = _mockItemInfo[linkOrID]
  if not info then return nil end
  return info[1], info[2], info[3], info[4], info[5], info[6], info[7],
         info[8], info[9], info[10], info[11], info[12], info[13], info[14]
end

-- ============================================================
-- Item mixin stub (REV-008 — ContinueOnItemLoad deferral)
-- Tests fire deferred callbacks manually via FirePendingItemLoads().
-- ============================================================
_pendingItemLoadCallbacks = {}

Item = {
  CreateFromItemLink = function(_, link)
    return {
      IsItemEmpty = function() return link == nil or link == "" end,
      ContinueOnItemLoad = function(_, fn)
        table.insert(_pendingItemLoadCallbacks, { link = link, fn = fn })
      end,
    }
  end,
}

function FirePendingItemLoads()
  local cbs = _pendingItemLoadCallbacks
  _pendingItemLoadCallbacks = {}
  for _, cb in ipairs(cbs) do cb.fn() end
end

-- ============================================================
-- C_Item.GetItemStats stub (Phase 3)
-- Returns a table of stat keys → values, or {} if not set.
-- Tests control ITEM_MOD_AGILITY_SHORT / ITEM_MOD_STRENGTH_SHORT /
-- ITEM_MOD_INTELLECT_SHORT to simulate primary-stat presence.
--
-- Lives on C_Item, not as a bare global: the global GetItemStats no longer exists in
-- retail, so stubbing it there would exercise a branch production can never take.
-- ============================================================
_mockItemStats = {}

C_Item.GetItemStats = function(link)
  return _mockItemStats[link] or {}
end

-- ============================================================
-- GetSpecialization stub (Phase 3)
-- Player-only, no-arg version (distinct from GetInspectSpecialization).
-- Returns a spec index (1-4); tests override _mockGetSpecialization.
-- ============================================================
_mockGetSpecialization = 1

function GetSpecialization()
  return _mockGetSpecialization
end

-- ============================================================
-- GetSpecializationInfo stub (Phase 3)
-- Returns the spec ID for a given spec index on the current player.
-- Tests populate _mockSpecializationInfo[specIndex] = specID.
-- The GetSpecialization→GetSpecializationInfo two-call pattern resolves
-- to: specIndex = GetSpecialization(); specID = select(1, GetSpecializationInfo(specIndex))
-- ============================================================
_mockSpecializationInfo = {}

function GetSpecializationInfo(specIndex)
  local v = _mockSpecializationInfo[specIndex]
  if v then return v end
  return 0
end

-- ============================================================
-- IsInInstance stub (Phase 3)
-- Returns inInstance (bool), instanceType (string).
-- Tests overwrite the whole table for dungeon vs open world contexts.
-- ============================================================
_mockIsInInstance = { false, "none" }

function IsInInstance()
  return _mockIsInInstance[1], _mockIsInInstance[2]
end

-- ============================================================
-- C_Garrison stub — a WoD garrison reports IsInInstance() == true, "party" even
-- though it is personal outdoor content (confirmed in-game 2026-07-12), so
-- ComputeActive has to distinguish it from a real 5-player dungeon.
-- ============================================================
_mockIsOnGarrisonMap = false

C_Garrison = {
  IsOnGarrisonMap = function() return _mockIsOnGarrisonMap end,
}

-- ============================================================
-- IsInGroup stub (Phase 3)
-- ============================================================
_mockIsInGroup = false

function IsInGroup()
  return _mockIsInGroup
end

-- ============================================================
-- ResetMocks — call in setUp to prevent state leakage
-- ============================================================
function ResetMocks()
  -- C_Timer state
  pendingAfterCallbacks = {}
  _mockTickers = {}

  -- Per-unit boolean states
  _mockIsPlayer      = {}
  _mockExists        = {}
  _mockIsConnected   = {}
  _mockIsDeadOrGhost = {}

  -- GUIDs
  _mockGuids = {}

  -- Global booleans
  _mockInCombat = false
  _mockInRaid   = false

  -- Simulated clock (GetTime) — M7 stabilization pacing
  _mockTime = 0

  -- CanInspect / visibility
  _mockCanInspect = {}
  _mockIsVisible  = {}

  -- Spies
  _notifyInspectCalls = {}
  _clearInspectCount  = 0

  -- Gear / spec
  _mockIlvl      = {}
  _mockGearLinks = {}
  _mockSpecID    = {}
  _mockSpecInfo  = {}
  _mockUnitClass = {}

  -- Unit names, realms, and chat
  _mockUnitNames  = {}
  _mockUnitRealms = {}
  _chatMessages   = {}

  -- Item load deferrals
  _pendingItemLoadCallbacks = {}

  -- Warbound-until-equipped items
  _mockWuEItems = {}

  -- C_PaperDollInfo
  _mockInspectIlvl = {}

  -- C_Container / tooltip scan mocks
  _mockContainerItems   = {}
  _mockScanTooltipLines = {}
  _mockNonTradeableItems = {}
  _mockScanTooltip:ClearLines()

  -- Phase 3 stubs
  _mockItemInfo          = {}
  _mockItemStats         = {}
  _mockGetSpecialization = 1
  -- Default the local player to a REAL spec (Arms, STR). Production skips a drop whose
  -- owner it cannot evaluate (AUD-502), so "player has no spec" is not a usable default
  -- for the many tests that only care about the member/pipeline side. Tests that care
  -- about the self-check override _mockSpecializationInfo[1] themselves; tests that want
  -- a genuinely specless player set _mockGetSpecialization = 0.
  _mockSpecializationInfo = { [1] = 71 }
  _mockIsInInstance      = { false, "none" }
  _mockIsOnGarrisonMap   = false
  _mockIsInGroup         = false

  -- Phase 3.1 stubs
  _mockHeirloomItemIDs = {}
  _mockUnitLevel       = {}

  -- Phase 5 stubs
  _mockGroupSize = 5
end

-- ============================================================
-- LoadAddonModules(LIF [, coreDir]) — load cache.lua then queue.lua into LIF.
-- Uses loadfile()+call-with-args to replicate the WoW vararg pattern:
--   local _, LIF = ...
-- Each module chunk is called as chunk(nil, LIF).
-- coreDir defaults to "../core" (works when running from tests/).
-- Pass "core" when running from the project root (e.g. lua tests/test_scan.lua).
-- ============================================================
function LoadAddonModules(LIF, coreDir)
  coreDir = coreDir or "../core"

  local specDataChunk = assert(loadfile(coreDir .. "/character_data.lua"))
  specDataChunk(nil, LIF)

  local armorDataChunk = assert(loadfile(coreDir .. "/armor_data.lua"))
  armorDataChunk(nil, LIF)

  local cacheChunk = assert(loadfile(coreDir .. "/cache.lua"))
  cacheChunk(nil, LIF)

  local queueChunk = assert(loadfile(coreDir .. "/queue.lua"))
  queueChunk(nil, LIF)

  local lootChunk = assert(loadfile(coreDir .. "/loot.lua"))
  lootChunk(nil, LIF)

  local whisperChunk = assert(loadfile(coreDir .. "/whisper.lua"))
  whisperChunk(nil, LIF)

  local framePosChunk = assert(loadfile(coreDir .. "/frame_position.lua"))
  framePosChunk(nil, LIF)
end
