-- tests/test_loot.lua
-- luaunit test suite for Phase 3 loot detection requirements.
-- Run: lua tests/test_loot.lua  (from project root)
--
-- Wave 1 (this plan): already-implemented helpers pass; pending implementations skip.
-- Waves 2-4 turn the skipped tests GREEN as each plan lands.

-- ============================================================
-- Setup: path and mocks
-- ============================================================
package.path = package.path .. ";./tests/?.lua;../?.lua;../tests/?.lua"

require("mock_wow_api")

local LIF = {}
local _coreDir = "core"
if arg and arg[0] then
  local scriptPath = arg[0]:match("(.+)/[^/]+$") or "."
  if scriptPath == "." or scriptPath == "tests" then
    local f = io.open("core/cache.lua", "r")
    if f then
      f:close()
      _coreDir = "core"
    else
      _coreDir = "../core"
    end
  end
end
LoadAddonModules(LIF, _coreDir)

-- Save the real IsItemTradeable so TestIsItemTradeable can restore it.
local _realIsItemTradeable = LIF.IsItemTradeable

local function mockIsItemTradeable(itemLink, itemID)
  return _mockNonTradeableItems[itemID] ~= true
end

-- Override for all pipeline tests: use _mockNonTradeableItems instead of tooltip scanning.
-- Tests that want an item to be non-tradeable set _mockNonTradeableItems[itemID] = true.
_mockNonTradeableItems = {}
LIF.IsItemTradeable = mockIsItemTradeable

local lu = require("luaunit")

-- ============================================================
-- Skip helpers for not-yet-implemented entry points
-- ============================================================

local function callOnLoot(itemLink, itemID)
  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end
  LIF.OnPlayerLootReceived(itemLink, itemID)
end

local function callIsPlayerUpgrade(itemData, threshold)
  if LIF.IsPlayerUpgrade == nil then
    lu.skip("LIF.IsPlayerUpgrade not yet implemented")
  end
  return LIF.IsPlayerUpgrade(itemData, threshold)
end

local function callEvaluate(itemData, threshold)
  if LIF.EvaluateCandidates == nil then
    lu.skip("LIF.EvaluateCandidates not yet implemented")
  end
  return LIF.EvaluateCandidates(itemData, threshold)
end

local function callOnLootInspectReady(guid)
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end
  LIF.OnLootInspectReady(guid)
end

local function callRequestReinspect(guid)
  if LIF.RequestReinspect == nil then
    lu.skip("LIF.RequestReinspect not yet implemented")
  end
  LIF.RequestReinspect(guid)
end

-- ============================================================
-- Mock population helpers
-- ============================================================

local function mockItem(link, fields)
  _mockItemInfo[link] = fields
end

-- TEST HELPER (not production code): registers GetItemInfo/GetItemStats mocks
-- for a link and runs it through the REAL ClassifyItem, so fixtures exercise
-- production item shapes instead of hand-built tables (REV-012).
local function classifyMockItem(link, fields, stats)
  _mockItemInfo[link] = fields
  if stats ~= nil then _mockItemStats[link] = stats end
  return LIF.ClassifyItem(link)
end

-- Set up a member in cache with gear and register mock API state.
-- gearTable: { [slotID] = ilvl, ... }
-- Production caches equipLoc per slot at inspect time (M1); the weapon slots
-- default to a generic 1H so is2HEquipped reads false and the offhand fail-closed
-- guard doesn't fire. Tests needing a two-hander call equipMember2H (or set
-- gear[16].equipLoc = "INVTYPE_2HWEAPON" directly).
local DEFAULT_SLOT_EQUIPLOC = { [16] = "INVTYPE_WEAPON", [17] = "INVTYPE_WEAPONOFFHAND" }
-- Weapon subclass, cached per slot like equipLoc. Only the heirloom duplication rule
-- (D-17) reads it, and only for a slot holding an active heirloom — but default it on the
-- weapon slots so a fixture never looks "type unresolved" by accident. 7 = sword.
local DEFAULT_SLOT_SUBID = { [16] = 7, [17] = 7 }
local function mockMemberGear(guid, unit, classToken, specID, gearTable)
  _mockGuids[unit] = guid
  _mockUnitClass[unit] = { classToken, classToken }
  _mockSpecID[unit]    = specID
  _mockGearLinks[unit] = {}
  LIF.Cache.Add(guid)
  local cacheGear = {}
  for slotID, ilvl in pairs(gearTable) do
    local link = "item:" .. guid .. "s" .. slotID
    _mockGearLinks[unit][slotID] = link
    _mockIlvl[link] = ilvl
    cacheGear[slotID] = { link = link, ilvl = ilvl,
                          equipLoc = DEFAULT_SLOT_EQUIPLOC[slotID],
                          subID    = DEFAULT_SLOT_SUBID[slotID] }
  end
  LIF.Cache.SetComplete(guid, { gear = cacheGear, specID = specID })
end

-- ============================================================
-- Test class
-- ============================================================
TestLoot = {}

-- Capture the original no-op ShowPopup stub from loot.lua so setUp can restore it
-- after any test that overrides it with a spy.
local _origShowPopup          = LIF.ShowPopup

function TestLoot:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  -- Reset pending loot state so tests are isolated (EvaluateCandidates/OnLootInspectReady).
  LIF.pendingLootItems = {}
  -- Restore the ShowPopup stub so tests that spy on it don't bleed into subsequent tests.
  LIF.ShowPopup             = _origShowPopup
  -- Restore the mock IsItemTradeable override (tests in TestIsItemTradeable swap to real impl).
  _mockNonTradeableItems = {}
  LIF.IsItemTradeable = mockIsItemTradeable
end

-- ============================================================
-- Already-implemented: ring helpers (pass on Wave 1, no skip)
-- ============================================================

function TestLoot:test_ring_upgrade_lower_slot()
  -- droppedIlvl=415, rings={slot11=400, slot12=420}, threshold=10
  -- lower ring = 400; delta = 415 - 400 = 15 >= 10 → true
  lu.assertTrue(
    LIF.IsRingUpgrade(415, { slot11 = 400, slot12 = 420 }, 10),
    "Ring drop is upgrade over lower slot (delta 15 >= threshold 10)"
  )
end

function TestLoot:test_ring_no_upgrade_both_higher()
  -- droppedIlvl=410, rings={slot11=420, slot12=425}, threshold=10
  -- lower ring = 420; delta = 410 - 420 = -10 < 10 → false
  lu.assertFalse(
    LIF.IsRingUpgrade(410, { slot11 = 420, slot12 = 425 }, 10),
    "Ring drop is NOT an upgrade when both equipped rings are higher"
  )
end

function TestLoot:test_trinket_upgrade_over_lower_slot()
  -- droppedIlvl=440, trinkets={slot13=420, slot14=430}, threshold=10
  -- lower trinket = 420; delta = 440 - 420 = 20 >= 10 → true
  lu.assertTrue(
    LIF.IsTrinketUpgrade(440, { slot13 = 420, slot14 = 430 }, 10),
    "Trinket drop is upgrade over lower slot (delta 20 >= threshold 10)"
  )
end

-- ============================================================
-- Trinket: ilvl-only (secondary-stat trinket falls back to ring rules)
-- Pending Plan 03-02/03-03 — uses IsPlayerUpgrade; skip until implemented
-- ============================================================

function TestLoot:test_trinket_ilvl_only_no_stat()
  -- Secondary-stat trinket: GetItemStats returns no AGI/STR/INT keys
  -- Player has both trinkets at 450; drop ilvl 480, threshold 10 → upgrade (ilvl-only)
  local link = "item:trinket_secondary"
  mockItem(link, { "ItemName", nil, 4, 480, nil, "Armor", "Trinket", nil, "INVTYPE_TRINKET", nil, nil, 4, 0, 0 })
  _mockItemStats[link] = {}  -- no primary stat keys
  _mockIsInInstance = { true, "party" }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = {
    [13] = "item:player_trinket1",
    [14] = "item:player_trinket2",
  }
  _mockIlvl["item:player_trinket1"] = 450
  _mockIlvl["item:player_trinket2"] = 450
  -- Spec index 1 → specID that maps to AGI (e.g. 259 Rogue/Assassination)
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "secondary-stat trinket is an ilvl-only self-upgrade (480 - 450 = 30 >= 10)")
end

-- ============================================================
-- Self-upgrade: armor slot (pending Plan 03-02)
-- ============================================================

function TestLoot:test_self_upgrade_armor_no_popup()
  -- Leather chest drop ilvl 480, player slot 5 ilvl 460, threshold 10
  -- IsPlayerUpgrade should return true (delta 20 >= 10)
  local link = "item:leather_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = "item:player_chest" }
  _mockIlvl["item:player_chest"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "leather chest is a self-upgrade for a Rogue (480 - 460 = 20 >= 10)")
end

function TestLoot:test_self_upgrade_empty_slot_is_upgrade()
  -- Player has nil GetInventoryItemLink for slot 5 → empty slot → worstIlvl = 0
  -- Any drop with positive ilvl should be an upgrade
  local link = "item:leather_chest_small"
  mockItem(link, { "Chest", nil, 3, 120, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = {}  -- no gear in slot 5
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "any positive-ilvl drop is a self-upgrade over an empty slot (worstIlvl 0)")
end

function TestLoot:test_request_reinspect_dedups_queue()
  -- REV-016: repeated RequestReinspect for the same guid must not stack
  -- duplicate queue entries. Block the queue with an in-flight inspect so
  -- insertions accumulate instead of being consumed by StartNextInspect.
  local guidA = "Player-0-InFlight"
  _mockGuids["party1"] = guidA
  _mockGuids["player"] = "GUID-SELF"
  LIF.OnGroupRosterUpdate()  -- starts inspecting guidA; sentinel now held
  lu.assertEquals(#_notifyInspectCalls, 1, "setup: guidA inspect must be in flight")

  local guidB = "Player-0-DedupTarget"
  mockMemberGear(guidB, "party2", "DRUID", 103, { [5] = 460 })
  callRequestReinspect(guidB)
  callRequestReinspect(guidB)

  local count = 0
  for _, qguid in ipairs(LIF.scanQueue) do
    if qguid == guidB then count = count + 1 end
  end
  lu.assertEquals(count, 1,
    "RequestReinspect must move an already-queued guid to the front, not duplicate it")
end

-- ============================================================
-- D-02: strict-positive delta boundary (Plan 05-01 RED gate)
-- Locks delta > 0 semantics before Plan 02 hardcodes threshold = 1.
-- ============================================================

function TestLoot:test_delta_strictly_positive_threshold()
  -- Both scenarios use a Rogue/ROGUE player on leather chest (slot 5) — mirrors
  -- test_self_upgrade_armor_no_popup for fixture shape.
  local link = "item:strict_zero_chest"
  mockItem(link, { "Chest", nil, 4, 460, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = "item:player_chest_460" }
  _mockIlvl["item:player_chest_460"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  -- Scenario A: delta == 0 must NOT be a self-upgrade under delta > 0 threshold (threshold=1).
  -- (droppedIlvl 460 - current 460) = 0; 0 >= 1 is false.
  local itemDataA = LIF.ClassifyItem(link)
  lu.assertFalse(callIsPlayerUpgrade(itemDataA, 1),
    "delta 0 must NOT be a self-upgrade under delta > 0 threshold")

  -- Scenario B: delta == 1 MUST be a self-upgrade under delta > 0 threshold (threshold=1).
  -- (droppedIlvl 461 - current 460) = 1; 1 >= 1 is true.
  local linkB = "item:strict_one_chest"
  mockItem(linkB, { "Chest", nil, 4, 461, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGearLinks["player"] = { [5] = "item:player_chest_460b" }
  _mockIlvl["item:player_chest_460b"] = 460

  local itemDataB = LIF.ClassifyItem(linkB)
  lu.assertTrue(callIsPlayerUpgrade(itemDataB, 1),
    "delta 1 MUST be a self-upgrade under delta > 0 threshold")
end

-- ============================================================
-- Self-upgrade: weapon stat check (pending Plan 03-03)
-- ============================================================

function TestLoot:test_weapon_self_upgrade_stat_match()
  -- AGI 1H weapon ilvl 490, player spec AGI, slot 16 ilvl 470, threshold 10 → true
  local link = "item:agi_weapon"
  mockItem(link, { "Dagger", nil, 4, 490, nil, "Weapon", "Daggers", nil, "INVTYPE_WEAPON", nil, nil, 2, 15, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 120 }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [16] = "item:player_dagger" }
  _mockIlvl["item:player_dagger"] = 470
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "AGI dagger is a self-upgrade for an AGI spec (490 - 470 = 20 >= 10)")
end

function TestLoot:test_weapon_self_upgrade_stat_mismatch()
  -- INT staff ilvl 500, player spec AGI → stat mismatch → NOT an upgrade
  local link = "item:int_staff"
  mockItem(link, { "Staff", nil, 4, 500, nil, "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 })
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [16] = "item:player_dagger" }
  _mockIlvl["item:player_dagger"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local itemData = LIF.ClassifyItem(link)
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "INT staff is NOT a self-upgrade for an AGI spec despite out-ilvling the equipped weapon")
end

function TestLoot:test_mainhand_only_weapon_classifies_to_slot_16()
  -- INVTYPE_WEAPONMAINHAND (main-hand-only weapons — common on leveling/caster
  -- loot) must classify like any weapon. This runs through the REAL ClassifyItem
  -- rather than an sff fixture, because the gap was a missing EQUIP_LOC_SLOTS
  -- entry that fixtures bypass. Sibling of REV-001 (INVTYPE_RANGED/RANGEDRIGHT).
  local link = "item:mh_only_dagger"
  local itemData = classifyMockItem(link,
    { "MH Dagger", nil, 4, 490, nil, "Weapon", "Daggers", nil, "INVTYPE_WEAPONMAINHAND", nil, nil, 2, 15, 0 },
    { ITEM_MOD_AGILITY_SHORT = 120 })
  lu.assertNotNil(itemData, "INVTYPE_WEAPONMAINHAND must not be skipped by ClassifyItem")
  lu.assertEquals(itemData.slotCategory, "weapon")
  lu.assertEquals(itemData.slotIDs, { 16 })
  lu.assertEquals(itemData.weaponSubID, 15)
end

function TestLoot:test_neck_self_upgrade_ilvl_only()
  -- Neck with no primary stats (GetItemStats returns {}): ilvl 480 vs 460, threshold 10 → true.
  local link = "item:neck"
  mockItem(link, { "Necklace", nil, 4, 480, nil, "Armor", "Miscellaneous", nil, "INVTYPE_NECK", nil, nil, 4, 0, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [2] = "item:player_neck" }
  _mockIlvl["item:player_neck"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "statless neck is an ilvl-only self-upgrade (480 - 460 = 20 >= 10)")
end

function TestLoot:test_trinket_self_upgrade_stat_mismatch_not_upgrade()
  -- INT trinket drop ilvl 500, player spec AGI, both trinkets ilvl 450 → false (stat mismatch)
  local link = "item:int_trinket"
  mockItem(link, { "Trinket", nil, 4, 500, nil, "Armor", "Trinket", nil, "INVTYPE_TRINKET", nil, nil, 4, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = {
    [13] = "item:player_trinket1",
    [14] = "item:player_trinket2",
  }
  _mockIlvl["item:player_trinket1"] = 450
  _mockIlvl["item:player_trinket2"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI) — stat mismatch

  local itemData = LIF.ClassifyItem(link)
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "INT trinket is NOT a self-upgrade for an AGI spec despite out-ilvling both equipped trinkets")
end

function TestLoot:test_trinket_self_upgrade_no_primary_stat_ilvl_only()
  -- Secondary-stat trinket (no AGI/STR/INT from GetItemStats)
  -- drop ilvl 500, player trinkets at 450, threshold 10, any spec → upgrade (ring rules)
  local link = "item:secondary_trinket"
  mockItem(link, { "Trinket", nil, 4, 500, nil, "Armor", "Trinket", nil, "INVTYPE_TRINKET", nil, nil, 4, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_HASTE_RATING_SHORT = 120 }  -- no primary stat
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = {
    [13] = "item:player_trinket1",
    [14] = "item:player_trinket2",
  }
  _mockIlvl["item:player_trinket1"] = 450
  _mockIlvl["item:player_trinket2"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local itemData = LIF.ClassifyItem(link)
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "secondary-stat trinket falls back to ring rules and IS a self-upgrade (500 - 450 = 50 >= 10)")
end

-- ============================================================
-- RequestReinspect and scan stabilization (Task 0 — queue.lua)
-- ============================================================

function TestLoot:test_request_reinspect_retains_gear_snapshot_sets_pending()
  -- RequestReinspect flips the member to PENDING for a fresh loot-time scan but
  -- RETAINS the last COMPLETE gear as a fallback snapshot (cache-fallback): if the
  -- fresh inspect can't finish (dead/offline/window expiry) the pipeline evaluates
  -- against this snapshot instead of dropping the member. SetComplete overwrites it
  -- wholesale when fresh data lands; OnLootInspectReady's COMPLETE gate ignores it
  -- until then. (Supersedes the old "must clear gear" D-14 behavior.)
  local guid = "Player-0-TestReinspect"
  local unit = "party1"
  mockMemberGear(guid, unit, "DRUID", 103, { [5] = 460, [11] = 440, [12] = 450 })

  local memberBefore = LIF.Cache.GetMember(guid)
  lu.assertEquals(memberBefore.state, "COMPLETE", "Precondition: member must be COMPLETE")

  callRequestReinspect(guid)

  local memberAfter = LIF.Cache.GetMember(guid)
  lu.assertNotNil(memberAfter, "Member must still be in cache after RequestReinspect")
  lu.assertEquals(memberAfter.state, "PENDING",
    "RequestReinspect must set state to PENDING")
  local gearCount = 0
  if memberAfter.gear then
    for _ in pairs(memberAfter.gear) do gearCount = gearCount + 1 end
  end
  lu.assertEquals(gearCount, 3,
    "RequestReinspect must RETAIN the gear snapshot for cache-fallback")
end

function TestLoot:test_request_reinspect_queues_at_front()
  -- scanQueue has one existing guid; call RequestReinspect(newGuid).
  -- The spec says RequestReinspect inserts at the FRONT of the scan queue (D-14),
  -- prioritizing loot-time rescans. If nothing is currently scanning, StartNextInspect
  -- fires immediately and dequeues newGuid into currentlyInspecting. We verify that
  -- newGuid was processed ahead of existingGuid — either it is currentlyInspecting
  -- (started immediately from front position) or still at scanQueue[1].
  local existingGuid = "Player-0-Existing"
  local newGuid      = "Player-0-New"
  local unit         = "party1"

  -- Set up both members in cache.
  LIF.Cache.Add(existingGuid)
  LIF.Cache.Add(newGuid)

  -- Make existingGuid scannable so it WILL block if it is chosen first.
  _mockGuids["party2"] = existingGuid

  -- Make newGuid the member in party1.
  _mockGuids[unit] = newGuid
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass[unit] = { "Druid", "DRUID" }

  -- Simulate an existing in-flight scan so StartNextInspect does NOT immediately
  -- process newGuid. We pre-occupy the sentinel with a dummy guid so newGuid
  -- will sit at scanQueue[1] after RequestReinspect and we can assert its position.
  local dummyGuid = "Player-0-Dummy"
  LIF.Cache.Add(dummyGuid)
  -- Force currentlyInspecting = dummyGuid by inserting a pre-existing scan.
  -- We do this by directly calling StartNextInspect via the inspect flow.
  _mockGuids["party3"] = dummyGuid
  table.insert(LIF.scanQueue, dummyGuid)
  LIF.TryQueuePendingMembers()  -- starts scan for dummyGuid (sets currentlyInspecting)

  -- Verify sentinel is occupied.
  local dbgBefore = LIF.GetDebugInfo()
  if dbgBefore.currentlyInspecting == nil then
    -- CanScanUnit failed for dummy; we can't block the queue this way in the mock.
    -- Verify front-insertion differently: put existingGuid in the queue, then check
    -- that after RequestReinspect the first item to be dispatched is newGuid.
    -- Reset and try approach: insert existingGuid, call RequestReinspect, check
    -- that newGuid was dispatched (NotifyInspect called with its unit).
    LIF.Queue_StopAndReset()
    table.insert(LIF.scanQueue, existingGuid)
    local inspectsBefore = #_notifyInspectCalls
    callRequestReinspect(newGuid)
    -- newGuid should have been dispatched first (front insertion + immediate scan).
    lu.assertTrue(#_notifyInspectCalls > inspectsBefore,
      "RequestReinspect must trigger NotifyInspect for the new guid (front-of-queue, D-14)")
    -- existingGuid should remain in the queue (newGuid was processed first).
    lu.assertEquals(LIF.scanQueue[1], existingGuid,
      "existingGuid must still be waiting in the queue (newGuid went first, D-14)")
    return
  end

  -- Happy path: sentinel occupied, assert newGuid at front.
  callRequestReinspect(newGuid)

  lu.assertEquals(LIF.scanQueue[1], newGuid,
    "RequestReinspect must insert guid at front of scanQueue (D-14)")
end

function TestLoot:test_scan_stabilization_completes_on_consistent_slots()
  -- Simulate OnInspectReady firing with slotCount=5 three consecutive times.
  -- After the 3rd call, the member should be COMPLETE (D-15).
  if LIF.RequestReinspect == nil then
    lu.skip("LIF.RequestReinspect not yet implemented — skipping stabilization test")
  end

  local guid = "Player-0-Leveler"
  local unit = "party1"

  -- Add to cache as PENDING.
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids[unit] = guid
  _mockUnitClass[unit] = { "Warrior", "WARRIOR" }
  _mockSpecID[unit] = 72  -- Fury

  LIF.Cache.Add(guid)

  -- Mock 5 gear slots (below MIN_SLOTS=10).
  _mockGearLinks[unit] = {}
  for slotID = 1, 5 do
    local link = "item:leveler_slot" .. slotID
    _mockGearLinks[unit][slotID] = link
    _mockIlvl[link] = 100
  end

  -- Simulate currentlyInspecting = guid by calling OnInspectReady directly.
  -- We need to set the currentlyInspecting sentinel — do this via a roster update
  -- then intercept, or directly set the sentinel via a helper.
  -- queue.lua exposes currentlyInspecting indirectly through GetDebugInfo().
  -- We'll trigger the scan via TryQueuePendingMembers then OnInspectReady.

  -- Force the queue into "inspecting this guid" state by calling
  -- OnGroupRosterUpdate to queue the member and start the inspect.
  LIF.OnGroupRosterUpdate()

  -- If no inspect started (CanScanUnit failed in mock), skip.
  local dbg = LIF.GetDebugInfo()
  if dbg.currentlyInspecting ~= guid then
    -- Try calling OnInspectReady directly after manually placing guid in position.
    -- This path tests stabilization logic in isolation.
    -- We simulate 3 INSPECT_READY events by calling OnInspectReady 3x.
    -- The first two should NOT complete; the third should.

    -- Reset to a known state: use the sniff hook bypass to test stabilization.
    lu.skip("Cannot force currentlyInspecting in this test environment — skipping")
  end

  -- Fire INSPECT_READY 3 times with 5 slots (same count each time).
  -- 1st fire: slotCount=5, consistentCount=1 — should NOT complete
  LIF.OnInspectReady(guid)
  local m1 = LIF.Cache.GetMember(guid)
  lu.assertNotEquals((m1 and m1.state), "COMPLETE",
    "Member must NOT be COMPLETE after 1st INSPECT_READY with 5 slots")

  -- Must re-acquire currentlyInspecting for 2nd fire (timeout re-queues).
  -- Re-trigger scan for 2nd attempt.
  if LIF.GetDebugInfo().currentlyInspecting ~= guid then
    -- Re-queue and start again.
    LIF.Cache.Add(guid)  -- re-add to ensure PENDING
    if LIF.Cache.GetMember(guid) then
      LIF.Cache.GetMember(guid).state = "PENDING"
    end
    table.insert(LIF.scanQueue, 1, guid)
    LIF.TryQueuePendingMembers()
  end

  -- 2nd fire: slotCount=5, consistentCount=2 — should NOT complete.
  -- Advance the clock past MIN_HARVEST_SPACING (LIF's own retry cadence is ~2s):
  -- a counted stabilization fire only advances if adequately spaced (M7).
  _mockTime = _mockTime + 2
  LIF.OnInspectReady(guid)
  local m2 = LIF.Cache.GetMember(guid)
  lu.assertNotEquals((m2 and m2.state), "COMPLETE",
    "Member must NOT be COMPLETE after 2nd INSPECT_READY with 5 slots")

  -- Re-acquire for 3rd.
  if LIF.GetDebugInfo().currentlyInspecting ~= guid then
    if LIF.Cache.GetMember(guid) then
      LIF.Cache.GetMember(guid).state = "PENDING"
    end
    table.insert(LIF.scanQueue, 1, guid)
    LIF.TryQueuePendingMembers()
  end

  -- 3rd fire: slotCount=5, consistentCount=3 — SHOULD complete (stabilization).
  _mockTime = _mockTime + 2
  LIF.OnInspectReady(guid)
  local m3 = LIF.Cache.GetMember(guid)
  lu.assertEquals((m3 and m3.state), "COMPLETE",
    "Member MUST be COMPLETE after 3rd consecutive INSPECT_READY with same slotCount (D-15)")
end

-- ============================================================
-- Candidate evaluation (pending Plan 03-04) — skip via callEvaluate
-- ============================================================

function TestLoot:test_evaluate_always_returns_empty_candidates()
  -- EvaluateCandidates: any non-empty party → returned table has
  -- .candidates empty; .scanningGuids non-empty (D-04).
  local guid = "Player-0-Druid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460, [11] = 440, [12] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = classifyMockItem("item:leather_ring",
    { "Ring", nil, 3, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })
  local result = callEvaluate(itemData, 10)
  -- If we reach here, evaluate is implemented.
  lu.assertNotNil(result, "EvaluateCandidates must return a result table")
  lu.assertNotNil(result.candidates, "result.candidates must exist")
  lu.assertNotNil(result.scanningGuids, "result.scanningGuids must exist")
  local candidateCount = 0
  for _ in pairs(result.candidates) do candidateCount = candidateCount + 1 end
  lu.assertEquals(candidateCount, 0,
    "candidates must be empty immediately (all data comes from fresh rescans, D-04)")
  local scanningCount = 0
  for _ in pairs(result.scanningGuids) do scanningCount = scanningCount + 1 end
  lu.assertTrue(scanningCount > 0,
    "scanningGuids must be non-empty (all eligible members queued for rescan)")
end

function TestLoot:test_evaluate_armor_filters_by_unit_class()
  -- Leather chest drop: Druid (leather) member → included; Warrior (plate) → excluded.
  local druidGuid   = "Player-0-Druid"
  local warriorGuid = "Player-0-Warrior"
  mockMemberGear(druidGuid,   "party1", "DRUID",   103, { [5] = 460 })
  mockMemberGear(warriorGuid, "party2", "WARRIOR",  72, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = classifyMockItem("item:leather_chest",
    { "Chest", nil, 3, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  local result = callEvaluate(itemData, 10)
  lu.assertNotNil(result.scanningGuids, "scanningGuids must exist")
  lu.assertNotNil(result.scanningGuids[druidGuid],
    "Druid must be in scanningGuids (leather armor matches Druid armor type)")
  lu.assertNil(result.scanningGuids[warriorGuid],
    "Warrior must NOT be in scanningGuids (plate class cannot use leather chest)")
end

function TestLoot:test_pending_member_included_for_ring_drop()
  -- Ring drop: member in PENDING state (no cached gear/spec data).
  -- Ring is universal — include all members regardless of state (D-16).
  local guid = "Player-0-Unknown"
  LIF.Cache.Add(guid)  -- PENDING, no gear data
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Hunter", "HUNTER" }
  _mockGuids["player"] = "GUID-SELF"

  local itemData = classifyMockItem("item:ring",
    { "Ring", nil, 3, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })
  local result = callEvaluate(itemData, 10)
  lu.assertNotNil(result.scanningGuids, "scanningGuids must exist")
  lu.assertNotNil(result.scanningGuids[guid],
    "PENDING member must be included in scanningGuids for ring drop (D-16)")
end

function TestLoot:test_armor_type_match_eligible()
  -- Leather chest drop, Druid member → guid in scanningGuids.
  local guid = "Player-0-Druid2"
  mockMemberGear(guid, "party1", "DRUID", 102, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = classifyMockItem("item:leather_chest2",
    { "Chest", nil, 3, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  local result = callEvaluate(itemData, 10)
  lu.assertNotNil(result.scanningGuids[guid],
    "Druid must be in scanningGuids for leather chest drop (armor type match)")
end

function TestLoot:test_armor_type_mismatch_skip()
  -- Leather chest drop, Warrior member → guid NOT in scanningGuids.
  local guid = "Player-0-Warrior2"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = classifyMockItem("item:leather_chest3",
    { "Chest", nil, 3, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  local result = callEvaluate(itemData, 10)
  lu.assertNil(result.scanningGuids[guid],
    "Warrior must NOT be in scanningGuids for leather chest drop (armor type mismatch)")
end

function TestLoot:test_candidate_sort_delta_desc()
  -- Popup fires only after ALL scans resolve, with all candidates sorted delta desc.
  -- Druid delta 25, Rogue delta 18, Monk delta 12.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local druidGuid = "Player-0-DeltaDruid"
  local monkGuid  = "Player-0-DeltaMonk"
  local rogueGuid = "Player-0-DeltaRogue"

  mockMemberGear(druidGuid, "party1", "DRUID",  103, { [11] = 475, [12] = 480 })  -- lower=475 delta=25
  mockMemberGear(monkGuid,  "party2", "MONK",   268, { [11] = 490, [12] = 488 })  -- lower=488 delta=12
  mockMemberGear(rogueGuid, "party3", "ROGUE",  260, { [11] = 482, [12] = 490 })  -- lower=482 delta=18

  _mockGuids["player"] = "GUID-SELF"

  local showPopupCallCount = 0
  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates)
    showPopupCallCount = showPopupCallCount + 1
    showPopupArgs = { itemData = itemData, candidates = candidates }
  end

  local itemData = { link = "item:sort_ring", ilvl = 500, slotID = 11,
                     equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
                     itype = "Armor", subtype = "Miscellaneous" }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [druidGuid] = true, [monkGuid] = true, [rogueGuid] = true },
    popupOpened         = false,
  })

  -- Partial resolves must NOT open the popup.
  LIF.OnLootInspectReady(druidGuid)
  lu.assertEquals(showPopupCallCount, 0, "ShowPopup must NOT fire while scans are pending")

  LIF.OnLootInspectReady(rogueGuid)
  lu.assertEquals(showPopupCallCount, 0, "ShowPopup must NOT fire while scans are pending")

  -- Final resolve — popup opens with all 3 candidates sorted delta desc.
  LIF.OnLootInspectReady(monkGuid)
  lu.assertEquals(showPopupCallCount, 1, "ShowPopup must fire exactly once after all scans resolve")
  lu.assertNotNil(showPopupArgs, "ShowPopup spy must have captured args")
  lu.assertEquals(#showPopupArgs.candidates, 3, "All three candidates must be included")
  lu.assertEquals(showPopupArgs.candidates[1].guid, druidGuid, "Druid (delta 25) must be first")
  lu.assertEquals(showPopupArgs.candidates[2].guid, rogueGuid, "Rogue (delta 18) must be second")
  lu.assertEquals(showPopupArgs.candidates[3].guid, monkGuid,  "Monk (delta 12) must be third")

  LIF.ShowPopup             = _origShowPopup
end

function TestLoot:test_popup_opens_after_all_scans_resolve()
  -- Popup opens only once all scanningGuids have resolved; both eligible candidates included.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid1 = "Player-0-First"
  local guid2 = "Player-0-Second"
  mockMemberGear(guid1, "party1", "DRUID",  103, { [11] = 475, [12] = 480 })  -- delta=25
  mockMemberGear(guid2, "party2", "ROGUE",  261, { [11] = 482, [12] = 490 })  -- delta=18
  _mockGuids["player"] = "GUID-SELF"

  local showPopupCalls = 0
  local showPopupArgs  = nil
  LIF.ShowPopup = function(itemData, candidates)
    showPopupCalls = showPopupCalls + 1
    showPopupArgs  = { candidates = candidates }
  end

  local itemData = {
    link = "item:gate_ring", ilvl = 500, slotID = 11,
    equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
    itype = "Armor", subtype = "Miscellaneous"
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid1] = true, [guid2] = true },
    popupOpened         = false,
  })

  -- First resolve must not open popup — guid2 still pending.
  LIF.OnLootInspectReady(guid1)
  lu.assertEquals(showPopupCalls, 0, "ShowPopup must NOT fire while guid2 is still pending")

  -- Second resolve clears all scans — popup opens with both candidates.
  LIF.OnLootInspectReady(guid2)
  lu.assertEquals(showPopupCalls, 1, "ShowPopup must fire after all scans resolve")
  lu.assertEquals(#showPopupArgs.candidates, 2, "Both eligible candidates must be included")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_heirloom_adjusted_ilvl_exposed()
  -- AUD-308: HeirloomAdjustedIlvl is exposed so the popup header's ring/trinket hover
  -- can pick the same heirloom-adjusted lower-of-two slot the eligibility engine uses.
  lu.assertNotNil(LIF.HeirloomAdjustedIlvl, "HeirloomAdjustedIlvl must be exposed on LIF")
  _mockHeirloomItemIDs[77001] = true
  lu.assertEquals(LIF.HeirloomAdjustedIlvl("item:77001", 50, 120), math.huge,
    "active heirloom (level<=69) reads as math.huge so it never wins the low side")
  lu.assertEquals(LIF.HeirloomAdjustedIlvl("item:77001", 80, 120), 120,
    "above level 69 the heirloom is inactive → raw ilvl")
  lu.assertEquals(LIF.HeirloomAdjustedIlvl("item:99999", 50, 200), 200,
    "non-heirloom link → raw ilvl")
  lu.assertEquals(LIF.HeirloomAdjustedIlvl(nil, 50, 0), 0,
    "empty slot (nil link) → raw ilvl (0)")
end

-- ============================================================
-- Loot entry + tradeability gate
-- ============================================================

function TestLoot:test_nontradeable_item_skipped()
  -- Item with no active trade timer → IsItemTradeable returns false → not added to pendingLootItems.
  -- Covers the case where loot is non-tradeable (BoP in open world, warbound, WuE, etc).
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:nontradeable_chest"
  mockItem(link, { "NonTradeableChest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade so the pipeline reaches the tradeability gate.
  _mockGearLinks["player"] = { [5] = "item:player_chest_at_same" }
  _mockIlvl["item:player_chest_at_same"] = 480
  -- Mark item as non-tradeable via mock.
  _mockNonTradeableItems[12345] = true

  callOnLoot(link, 12345)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → IsItemTradeable returns false → no entry

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "Non-tradeable item must NOT be added to pendingLootItems (no trade timer)")
end

function TestLoot:test_tradeable_item_proceeds()
  -- Tradeable item (IsItemTradeable returns true) → added to pendingLootItems.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:tradeable_leather_chest"
  mockItem(link, { "TradeableChest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })

  local druidGuid = "Player-0-TradeDruid"
  mockMemberGear(druidGuid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade.
  _mockGearLinks["player"] = { [5] = "item:player_chest_same" }
  _mockIlvl["item:player_chest_same"] = 480
  -- _mockNonTradeableItems is empty by default → IsItemTradeable returns true.

  callOnLoot(link, 12346)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → IsItemTradeable true → entry added

  lu.assertNotNil(LIF.pendingLootItems, "LIF.pendingLootItems must exist")
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "Tradeable item must be added to pendingLootItems after 0-frame defer")
  if LIF.EvaluateCandidates then
    lu.assertEquals(LIF.pendingLootItems[1].scanningGuids[druidGuid], true,
      "Druid must be in scanningGuids for tradeable leather chest")
  end
end

function TestLoot:test_loot_reset_cancels_pending_tradeability_defer()
  -- AUD-010: if Loot_Reset fires (group disband / inactive transition) in the
  -- window between ENCOUNTER_LOOT_RECEIVED and the one-frame tradeability defer
  -- running, the deferred confirmTradeableAndProceed must NOT proceed against the
  -- now-cleared state — otherwise it emits a "0 candidates" chat line and appends
  -- an orphan pending entry after the reset. A loot generation token guards it.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:tradeable_leather_chest_reset"
  mockItem(link, { "TradeableChest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })

  local druidGuid = "Player-0-ResetDruid"
  mockMemberGear(druidGuid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_same_reset" }
  _mockIlvl["item:player_chest_same_reset"] = 480

  callOnLoot(link, 12399)
  LIF.Loot_Reset()              -- group disbands before the tradeability defer fires
  FirePendingAfterCallbacks()   -- fire the 0-frame defer

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "a Loot_Reset before the tradeability defer must cancel it — no orphan pending entry (AUD-010)")
end

function TestLoot:test_nil_ilvl_item_skipped()
  -- A classified item with nil ilvl (GetItemInfo returned a name but no item
  -- level) must be skipped outright. IsPlayerUpgrade already fails safe on nil
  -- ilvl, but without an early skip the pipeline proceeds into member
  -- evaluation, where the (droppedIlvl - current) delta throws on the nil.
  -- Practically unreachable (ClassifyItem bails on nil GetItemInfo) but the
  -- guard keeps the arithmetic safe.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:nil_ilvl_chest"
  mockItem(link, { "NilIlvlChest", nil, 4, nil, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  local druidGuid = "Player-0-NilIlvlDruid"
  mockMemberGear(druidGuid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_nil" }
  _mockIlvl["item:player_chest_nil"] = 480

  callOnLoot(link, 12399)
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "Item with nil ilvl must be skipped before candidate evaluation")
end

function TestLoot:test_specless_player_drop_ignored()
  -- A local player with no active spec (below level 10, or never chosen) can't
  -- be self-checked: the stat/weapon self-upgrade branches fail closed, which
  -- for the LOCAL player inverts to "not an upgrade for me → offer it away" and
  -- risks giving away the player's own upgrade. With nothing reliable to
  -- compare against, the drop must be ignored outright (no pending entry).
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:specless_trinket"
  mockItem(link, { "SpeclessTrinket", nil, 4, 500, nil, "Armor", "Trinket", nil, "INVTYPE_TRINKET", nil, nil, 4, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 200 }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [13] = "item:pt1", [14] = "item:pt2" }
  _mockIlvl["item:pt1"] = 450
  _mockIlvl["item:pt2"] = 450
  _mockGetSpecialization = 0  -- no active spec

  callOnLoot(link, 55123)
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "A drop must be ignored when the local player has no active spec")
end

function TestLoot:test_unknown_player_spec_drop_ignored()
  -- AUD-502: Blizzard ships a new spec, the addon has not learned it yet. The spec
  -- ID is PRESENT, so the specless guard above passes — but SPEC_TABLE has no entry,
  -- so every stat/weapon self-check fails closed, which for the LOCAL player inverts
  -- to "not an upgrade for me → offer it away". The drop is a genuine +50 upgrade
  -- with a matching stat and must stay with the player: keep it, no pending entry.
  -- (This is how Devourer/1480 arrived in Midnight.)
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:unknownspec_trinket"
  mockItem(link, { "UnknownSpecTrinket", nil, 4, 500, nil, "Armor", "Trinket", nil, "INVTYPE_TRINKET", nil, nil, 4, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 200 }
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [13] = "item:pt1", [14] = "item:pt2" }
  _mockIlvl["item:pt1"] = 450
  _mockIlvl["item:pt2"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 9999  -- a spec SPEC_TABLE has never heard of

  callOnLoot(link, 55124)
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "A drop must be ignored when the local player's spec is unknown to SPEC_TABLE")
end

function TestLoot:test_loot_in_combat_defers_reinspect_until_combat_end()
  -- Loot that lands mid-fight must NOT start the reinspect + 4s scanning window
  -- during combat: CanScanUnit blocks inspects while InCombatLockdown(), so a
  -- window started at loot time expires before members can resolve, dropping
  -- combat-blocked candidates. The scan must be deferred until combat ends.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:combat_deferred_chest"
  mockItem(link, { "CombatChest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })

  local druidGuid = "Player-0-CombatDruid"
  mockMemberGear(druidGuid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade (same-ilvl chest → delta 0 < threshold).
  _mockGearLinks["player"] = { [5] = "item:player_chest_same" }
  _mockIlvl["item:player_chest_same"] = 480

  -- Loot drops WHILE STILL IN COMBAT.
  _mockInCombat = true
  local inspectsBefore = #_notifyInspectCalls
  callOnLoot(link, 12360)
  FirePendingAfterCallbacks()  -- 0-frame defer + tradeable check; combat gate hit

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "In combat: reinspect + pending entry must be deferred, not created at loot time")
  lu.assertEquals(#_notifyInspectCalls, inspectsBefore,
    "In combat: no NotifyInspect may fire (inspects are combat-blocked)")

  -- Combat ends → deferred scan runs and the pipeline proceeds as normal.
  _mockInCombat = false
  LIF.FlushAfterCombatCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 1,
    "After combat: deferred reinspect must create the pending loot entry")
  lu.assertEquals(LIF.pendingLootItems[1].scanningGuids[druidGuid], true,
    "After combat: druid must be queued for reinspect")
end

function TestLoot:test_pending_member_queue_called_at_loot()
  -- At least one PENDING member exists; callOnLoot causes TryQueuePendingMembers to fire
  -- and at least one NotifyInspect call to occur.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local guid = "Player-0-PendingAtLoot"
  LIF.Cache.Add(guid)  -- PENDING state
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade: give them a chest at same ilvl so delta=0 < threshold.
  _mockGearLinks["player"] = { [5] = "item:player_pending_chest" }
  _mockIlvl["item:player_pending_chest"] = 480

  local link = "item:pending_loot_item"
  mockItem(link, { "Item", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local inspectsBefore = #_notifyInspectCalls
  callOnLoot(link, 12347)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → TryQueuePendingMembers → NotifyInspect

  lu.assertTrue(#_notifyInspectCalls > inspectsBefore,
    "At least one NotifyInspect must fire for a PENDING member at loot time")
end

-- ============================================================
-- Plan 03-05: full pipeline tests (TDD — new for this plan)
-- ============================================================

function TestLoot:test_self_upgrade_skip_in_pipeline()
  -- Leather chest ilvl 500, player slot 5 ilvl 460, threshold 10 → delta 40 >= 10 → self-upgrade.
  -- OnPlayerLootReceived must return early; pendingLootItems must NOT be appended.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local link = "item:self_upgrade_chest"
  mockItem(link, { "Chest", nil, 4, 500, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = "item:player_chest_selfup" }
  _mockIlvl["item:player_chest_selfup"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end
  if LIF.IsPlayerUpgrade == nil then
    lu.skip("LIF.IsPlayerUpgrade not yet implemented")
  end

  LIF.OnPlayerLootReceived(link, 99991)

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "Self-upgrade must cause early return; pendingLootItems must remain empty (D-13)")
end

function TestLoot:test_window_expiry_falls_back_to_snapshot()
  -- A candidate that never returns a fresh INSPECT_READY within the scanning
  -- window is resolved against its RETAINED gear snapshot at window expiry (H2)
  -- rather than dropped. Druid chest 460 vs drop 480 → delta 20 → included.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local guid = "Player-0-UnresolvedGuid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade: chest at drop ilvl so delta=0 < threshold.
  _mockGearLinks["player"] = { [5] = "item:player_timer_chest" }
  _mockIlvl["item:player_timer_chest"] = 480

  local link = "item:timer_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates)
    showPopupArgs = { itemData = itemData, candidates = candidates }
  end

  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end

  LIF.OnPlayerLootReceived(link, 99992)
  FirePendingAfterCallbacks()  -- 0-frame defer → entry added, window timer queued

  lu.assertEquals(#LIF.pendingLootItems, 1, "Precondition: one pending loot entry")
  local entry = LIF.pendingLootItems[1]
  lu.assertNil(showPopupArgs,
    "Popup must NOT open before the window expires (member still scannable, awaiting fresh data)")

  FirePendingAfterCallbacks()  -- window expiry → snapshot fallback → popup opens

  lu.assertNotNil(showPopupArgs, "Popup must open at window expiry via snapshot fallback")
  lu.assertEquals(#showPopupArgs.candidates, 1, "Fallback must INCLUDE the unresolved member (not drop it)")
  lu.assertEquals(showPopupArgs.candidates[1].guid, guid, "Included candidate must be the druid")
  local remaining = 0
  for _ in pairs(entry.scanningGuids) do remaining = remaining + 1 end
  lu.assertEquals(remaining, 0, "scanningGuids must be empty after the window timer fires")

  LIF.ShowPopup = _origShowPopup
end

-- ============================================================
-- Cache-fallback + adaptive window (H2/H3, M11/M12)
-- ============================================================

-- Shared setup: a group-active instance with the local player present but not a
-- self-upgrade for the dropped item. Returns nothing; callers add members.
local function _fallbackTestBase()
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"] = "GUID-SELF"
end

function TestLoot:test_dead_candidate_immediate_fallback_opens_popup()
  -- A candidate dead at loot time can't be freshly inspected, so it resolves
  -- against its snapshot IMMEDIATELY (no waiting out the window) and the popup
  -- opens in the same pipeline pass (H3).
  _fallbackTestBase()
  local guid = "Player-0-DeadDruid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460 })
  _mockIsDeadOrGhost["party1"] = true  -- dead → CanScanUnit false

  _mockGearLinks["player"] = { [5] = "item:player_dead_chest" }
  _mockIlvl["item:player_dead_chest"] = 480
  local link = "item:dead_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates) showPopupArgs = { candidates = candidates } end

  LIF.OnPlayerLootReceived(link, 99801)
  FirePendingAfterCallbacks()  -- pipeline runs; immediate fallback opens popup within it

  lu.assertNotNil(showPopupArgs, "Dead candidate must fall back immediately and open the popup (no window wait)")
  lu.assertEquals(#showPopupArgs.candidates, 1, "Dead candidate resolved from snapshot must be included")
  lu.assertEquals(showPopupArgs.candidates[1].guid, guid, "Included candidate must be the dead druid")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_player_dead_all_candidates_immediate_fallback()
  -- If the LOCAL player is dead the whole inspect queue is stalled (CanScanUnit
  -- returns false for everyone), so all candidates fall back immediately rather
  -- than waiting out a window that could never produce fresh data.
  _fallbackTestBase()
  _mockIsDeadOrGhost["player"] = true  -- stalls all inspects

  local dg = "Player-0-PDDruid"
  local rg = "Player-0-PDRogue"
  mockMemberGear(dg, "party1", "DRUID", 103, { [11] = 475, [12] = 480 })  -- lower 475
  mockMemberGear(rg, "party2", "ROGUE", 260, { [11] = 482, [12] = 490 })  -- lower 482

  _mockGearLinks["player"] = { [11] = "item:pd_r1", [12] = "item:pd_r2" }
  _mockIlvl["item:pd_r1"] = 500
  _mockIlvl["item:pd_r2"] = 500
  local link = "item:pd_ring"
  mockItem(link, { "Ring", nil, 4, 500, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates) showPopupArgs = { candidates = candidates } end

  LIF.OnPlayerLootReceived(link, 99802)
  FirePendingAfterCallbacks()

  lu.assertNotNil(showPopupArgs, "Player dead: candidates must fall back immediately")
  lu.assertEquals(#showPopupArgs.candidates, 2, "Both members must be included via snapshot fallback")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_offline_candidate_immediate_fallback()
  -- A disconnected candidate can't be inspected (CanScanUnit → UnitIsConnected),
  -- so it falls back immediately like a dead one.
  _fallbackTestBase()
  local guid = "Player-0-OfflineDruid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 455 })
  _mockIsConnected["party1"] = false  -- offline

  _mockGearLinks["player"] = { [5] = "item:player_off_chest" }
  _mockIlvl["item:player_off_chest"] = 480
  local link = "item:off_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates) showPopupArgs = { candidates = candidates } end

  LIF.OnPlayerLootReceived(link, 99803)
  FirePendingAfterCallbacks()

  lu.assertNotNil(showPopupArgs, "Offline candidate must fall back immediately")
  lu.assertEquals(#showPopupArgs.candidates, 1, "Offline candidate resolved from snapshot must be included")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_no_snapshot_candidate_dropped()
  -- A candidate that was never successfully scanned (no gear snapshot) AND can't
  -- be scanned now (dead) has nothing to fall back on — dropped, no popup.
  _fallbackTestBase()
  local guid = "Player-0-NeverScanned"
  LIF.Cache.Add(guid)  -- PENDING, no gear, never SetComplete
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockIsDeadOrGhost["party1"] = true

  _mockGearLinks["player"] = { [5] = "item:player_ns_chest" }
  _mockIlvl["item:player_ns_chest"] = 480
  local link = "item:ns_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates) showPopupArgs = { candidates = candidates } end

  LIF.OnPlayerLootReceived(link, 99804)
  FirePendingAfterCallbacks()

  lu.assertNil(showPopupArgs, "No snapshot + can't scan → member dropped, no popup opens")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_late_fresh_inspect_after_fallback_no_double_open()
  -- After a dead candidate falls back and the popup opens, a late fresh
  -- INSPECT_READY for the same member must NOT re-open the popup or double-add
  -- (idempotency): they're no longer in scanningGuids.
  _fallbackTestBase()
  local guid = "Player-0-LateFresh"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460 })
  _mockIsDeadOrGhost["party1"] = true

  _mockGearLinks["player"] = { [5] = "item:player_lf_chest" }
  _mockIlvl["item:player_lf_chest"] = 480
  local link = "item:lf_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupCount = 0
  LIF.ShowPopup = function() showPopupCount = showPopupCount + 1 end

  LIF.OnPlayerLootReceived(link, 99805)
  FirePendingAfterCallbacks()  -- immediate fallback opens popup
  lu.assertEquals(showPopupCount, 1, "Popup opens once via fallback")

  -- Member revives and completes a fresh inspect while the entry is still pending.
  _mockIsDeadOrGhost["party1"] = false
  LIF.Cache.SetComplete(guid, { gear = { [5] = { link = "x", ilvl = 470 } }, specID = 103 })
  LIF.OnLootInspectReady(guid)

  lu.assertEquals(showPopupCount, 1,
    "Late fresh inspect must NOT re-open the popup (guid already left scanningGuids)")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_adaptive_window_sizes_by_candidate_count()
  -- Window = min(BASE + N*PER, MAX) = min(2 + N*3, 15). 1 candidate → 5s; a full
  -- 4-candidate party → 14s. Members stay scannable (alive) so none fall back
  -- immediately and all count toward the window.
  _fallbackTestBase()
  for i = 1, 4 do
    local g = "Player-0-Win" .. i
    mockMemberGear(g, "party" .. i, "DRUID", 103, { [11] = 470, [12] = 470 })
  end
  _mockGearLinks["player"] = { [11] = "item:win_r1", [12] = "item:win_r2" }
  _mockIlvl["item:win_r1"] = 500
  _mockIlvl["item:win_r2"] = 500
  local link = "item:win_ring"
  mockItem(link, { "Ring", nil, 4, 500, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })

  LIF.OnPlayerLootReceived(link, 99806)
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 1, "Precondition: one pending entry")
  lu.assertEquals(LIF.pendingLootItems[1].window, 14,
    "4 scannable candidates → window = min(2 + 4*3, 15) = 14s")
end

function TestLoot:test_departed_confirmed_candidate_cleared_on_roster_update()
  -- M11: a member confirmed into an entry (but the popup not yet opened) who then
  -- leaves the group must be removed from confirmedCandidates, so the popup can't
  -- render a row for someone who's gone.
  _fallbackTestBase()
  local leavingGuid = "Player-0-Leaver"
  local stayingGuid = "Player-0-Stayer"
  mockMemberGear(leavingGuid, "party1", "DRUID", 103, { [5] = 460 })
  mockMemberGear(stayingGuid, "party2", "ROGUE", 260, { [5] = 460 })

  -- Entry with the leaver already confirmed, still waiting on the stayer's scan.
  local entry = {
    itemData = { link = "item:m11", ilvl = 480, slotIDs = { 5 }, slotCategory = "armor" },
    scanningGuids = { [stayingGuid] = true },
    confirmedCandidates = { [leavingGuid] = { guid = leavingGuid } },
    popupOpened = false,
  }
  LIF.pendingLootItems = { entry }

  -- Leaver drops out of the roster; stayer remains.
  _mockGuids["party1"] = nil
  _mockExists["party1"] = false
  LIF.OnGroupRosterUpdate()

  lu.assertNil(entry.confirmedCandidates[leavingGuid],
    "Departed member must be cleared from confirmedCandidates (M11)")
end

function TestLoot:test_departure_unblocks_popup_immediately()
  -- 3 candidates: one already confirmed, two still scanning. When the two
  -- scanning members leave the group, the entry is unblocked and the popup opens
  -- immediately (with the confirmed one) instead of waiting out the window.
  _fallbackTestBase()
  local a = "Player-0-DepA"  -- confirmed, stays
  local b = "Player-0-DepB"  -- scanning, leaves
  local c = "Player-0-DepC"  -- scanning, leaves
  mockMemberGear(a, "party1", "DRUID", 103, { [5] = 460 })
  mockMemberGear(b, "party2", "ROGUE", 260, { [5] = 460 })
  mockMemberGear(c, "party3", "MONK",  268, { [5] = 460 })

  local entry = {
    itemData = { link = "item:dep", name = "Dep", ilvl = 480, slotIDs = { 5 }, slotCategory = "armor" },
    scanningGuids = { [b] = true, [c] = true },
    confirmedCandidates = { [a] = { guid = a, unit = "party1", delta = 20 } },
    popupOpened = false,
    cancelled = false,
  }
  LIF.pendingLootItems = { entry }

  local showPopupArgs = nil
  LIF.ShowPopup = function(itemData, candidates) showPopupArgs = { candidates = candidates } end

  -- B and C drop out of the roster; A remains.
  _mockGuids["party2"] = nil; _mockExists["party2"] = false
  _mockGuids["party3"] = nil; _mockExists["party3"] = false
  LIF.OnGroupRosterUpdate()

  lu.assertNotNil(showPopupArgs, "Popup must open once the leavers unblock the entry")
  lu.assertEquals(#showPopupArgs.candidates, 1, "Only the confirmed member remains")
  lu.assertEquals(showPopupArgs.candidates[1].guid, a, "The confirmed druid is shown")
  lu.assertEquals(next(entry.scanningGuids), nil, "scanningGuids must be empty after both leavers cleared")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_loot_reset_cancels_pending_entries_and_neutralizes_timer()
  -- M12: leaving the group / going inactive must clear pending loot state so a
  -- surviving window timer can't open a popup for a group that's gone.
  _fallbackTestBase()
  local guid = "Player-0-ResetDruid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGearLinks["player"] = { [5] = "item:player_reset_chest" }
  _mockIlvl["item:player_reset_chest"] = 480
  local link = "item:reset_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local showPopupCount = 0
  LIF.ShowPopup = function() showPopupCount = showPopupCount + 1 end

  LIF.OnPlayerLootReceived(link, 99807)
  FirePendingAfterCallbacks()  -- entry + window timer queued (member alive → no immediate)
  local entry = LIF.pendingLootItems[1]
  lu.assertNotNil(entry, "Precondition: a pending entry exists")

  LIF.Loot_Reset()
  lu.assertEquals(#LIF.pendingLootItems, 0, "Loot_Reset must clear pendingLootItems")
  lu.assertTrue(entry.cancelled, "Loot_Reset must mark the entry cancelled")

  FirePendingAfterCallbacks()  -- fire the now-orphaned window timer
  lu.assertEquals(showPopupCount, 0, "A cancelled entry's surviving timer must NOT open a popup")

  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_multiple_loot_events_append()
  -- Calling OnPlayerLootReceived twice with different items must append two entries.
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade for either ring: set both ring slots at drop ilvl so delta=0.
  _mockGearLinks["player"] = {
    [11] = "item:player_ring_slot11",
    [12] = "item:player_ring_slot12",
  }
  _mockIlvl["item:player_ring_slot11"] = 480
  _mockIlvl["item:player_ring_slot12"] = 480

  local link1 = "item:multi_loot_1"
  local link2 = "item:multi_loot_2"
  mockItem(link1, { "Ring1", nil, 4, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })
  mockItem(link2, { "Ring2", nil, 4, 480, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })

  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end

  LIF.OnPlayerLootReceived(link1, 99993)
  LIF.OnPlayerLootReceived(link2, 99994)
  -- Fire both 0-frame defers; each adds an entry and registers a 4s timer.
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 2,
    "Two OnPlayerLootReceived calls must append two entries (no overwrite)")
end

function TestLoot:test_popup_stub_is_callable()
  -- LIF.ShowPopup must exist as a callable no-op and not raise on any arg combo
  -- (the loot pipeline runs headless in tests / before ui/popup.lua loads).
  if LIF.ShowPopup == nil then
    lu.skip("ShowPopup stub not yet implemented (Plan 03-05 Task 1)")
  end

  -- No errors on any combination including nil args.
  LIF.ShowPopup({ link = "item:stub_test" }, {})
  LIF.ShowPopup(nil, nil)

  lu.assertTrue(true, "ShowPopup stub callable without error")
end

function TestLoot:test_pending_loot_entry_has_popup_opened_false()
  -- After OnPlayerLootReceived, pendingLootItems[1].popupOpened must be false (set explicitly).
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade: set neck at drop ilvl so delta=0 < threshold.
  _mockGearLinks["player"] = { [2] = "item:player_neck_existing" }
  _mockIlvl["item:player_neck_existing"] = 470

  local link = "item:popup_opened_check"
  mockItem(link, { "Neck", nil, 4, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_NECK", nil, nil, 4, 0, 0 })

  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end

  LIF.OnPlayerLootReceived(link, 99995)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → entry added

  lu.assertEquals(#LIF.pendingLootItems, 1, "One pending entry must exist")
  lu.assertEquals(LIF.pendingLootItems[1].popupOpened, false,
    "pendingLootItems entry must have popupOpened=false at creation (Plan 03-05 pipeline)")
end

function TestLoot:test_show_popup_not_called_from_on_player_loot_received()
  -- ShowPopup must NOT be called from OnPlayerLootReceived — deferred to OnLootInspectReady (D-08).
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade: set back at drop ilvl so delta=0 < threshold.
  _mockGearLinks["player"] = { [15] = "item:player_back_existing" }
  _mockIlvl["item:player_back_existing"] = 470

  local link = "item:no_popup_at_loot"
  mockItem(link, { "Back", nil, 4, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_BACK", nil, nil, 4, 0, 0 })

  local showPopupCallCount = 0
  local origShowPopup = LIF.ShowPopup
  LIF.ShowPopup = function(...)
    showPopupCallCount = showPopupCallCount + 1
    if origShowPopup then origShowPopup(...) end
  end

  if LIF.OnPlayerLootReceived == nil then
    LIF.ShowPopup = origShowPopup
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end

  LIF.OnPlayerLootReceived(link, 99996)
  FirePendingAfterCallbacks()  -- fires 0-frame defer; ShowPopup must still not be called here

  lu.assertEquals(showPopupCallCount, 0,
    "ShowPopup must NOT be called from OnPlayerLootReceived (deferred to OnLootInspectReady per D-08)")

  LIF.ShowPopup = origShowPopup
end

-- ============================================================
-- Phase 3.1: Heirloom test cases (RED — isHeirloomActive not yet implemented)
-- Plan 02 turns these GREEN.
-- ============================================================

function TestLoot:test_heirloom_player_armor_below_cap_not_upgrade()
  -- SC1: player wears heirloom chest (item:11101) at level 50, drop ilvl 400.
  -- IsPlayerUpgrade must return false (heirloom slot active at level ≤ 69).
  local link = "item:11101"
  _mockHeirloomItemIDs[11101] = true
  _mockUnitLevel["player"] = 50
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }  -- Leather-wearing, matches drop's armorType
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local dropLink = "item:11102"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  lu.assertFalse(result, "Player heirloom chest at level 50 → not an upgrade (SC1)")
end

function TestLoot:test_heirloom_player_armor_at_cap_boundary_not_upgrade()
  -- SC1 boundary: same setup at level 69; must still return false.
  local link = "item:11101"
  _mockHeirloomItemIDs[11101] = true
  _mockUnitLevel["player"] = 69
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:11102"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  lu.assertFalse(result, "Player heirloom chest at level 69 → not an upgrade (SC1 boundary)")
end

function TestLoot:test_heirloom_player_armor_above_cap_is_upgrade()
  -- SC5: same setup at level 70; heirloom no longer active → normal delta path → true.
  local link = "item:11101"
  _mockHeirloomItemIDs[11101] = true
  _mockUnitLevel["player"] = 70
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:11102"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  lu.assertTrue(result, "Player heirloom chest at level 70 → normal delta path → upgrade (SC5)")
end

function TestLoot:test_heirloom_player_nil_slot_falls_through()
  -- SC4 (player side): slot returns nil from GetInventoryItemLink.
  -- UnitLevel = 50, but nil slot → heirloom check NOT applied → nil=0 → upgrade.
  _mockUnitLevel["player"] = 50
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = {}  -- slot 5 is nil
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:11103"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  lu.assertTrue(result, "Nil slot falls through to nil=0 path → drop ilvl 400 vs 0 → upgrade (SC4 player)")
end

function TestLoot:test_self_check_armor_type_mismatch_not_upgrade()
  -- Player is a Mage (Cloth-only); a Leather item drops (e.g. an off-type
  -- personal-loot roll). Must NOT read as a self-upgrade, even with a huge
  -- ilvl delta — a Mage cannot equip Leather at all. Mirrors the party-check
  -- armor-type gate (LIF.ARMOR_TYPE[classToken] ~= armorType), which
  -- self-check was missing entirely before this fix.
  _mockUnitClass["player"] = { "Mage", "MAGE" }
  _mockGearLinks["player"] = { [5] = "item:mage_cloth_chest" }
  _mockIlvl["item:mage_cloth_chest"] = 50

  local dropLink = "item:leather_chest_for_mage"
  mockItem(dropLink, { "NewChest", nil, 4, 500, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 500, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  lu.assertFalse(result,
    "Leather drop must not read as a self-upgrade for a Cloth-only Mage, regardless of ilvl delta")
end

function TestLoot:test_heirloom_player_ring_both_slots_heirloom_not_upgrade()
  -- SC3: both slot 11 and slot 12 hold heirloom rings at level 50.
  -- math.huge × 2 → IsRingUpgrade returns false → not an upgrade.
  local link11 = "item:11201"
  local link12 = "item:11202"
  _mockHeirloomItemIDs[11201] = true
  _mockHeirloomItemIDs[11202] = true
  _mockUnitLevel["player"] = 50
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [11] = link11, [12] = link12 }
  _mockIlvl[link11] = 300
  _mockIlvl[link12] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:11203"
  mockItem(dropLink, { "NewRing", nil, 4, 400, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {11, 12}, slotCategory = "ring" }, 10)
  lu.assertFalse(result, "Both ring slots heirloom at level 50 → math.huge → not an upgrade (SC3)")
end

function TestLoot:test_heirloom_player_ring_one_slot_heirloom_uses_other()
  -- SC3 (partial): slot 11 heirloom, slot 12 plain ilvl 300; drop ilvl 400.
  -- math.huge for slot 11; comparison runs against slot 12 (300) → delta 100 >= 10 → true.
  local link11 = "item:11201"
  local link12 = "item:11204"
  _mockHeirloomItemIDs[11201] = true
  _mockUnitLevel["player"] = 50
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [11] = link11, [12] = link12 }
  _mockIlvl[link11] = 300
  _mockIlvl[link12] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:11205"
  mockItem(dropLink, { "NewRing", nil, 4, 400, nil, "Armor", "Miscellaneous", nil, "INVTYPE_FINGER", nil, nil, 4, 0, 0 })

  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {11, 12}, slotCategory = "ring" }, 10)
  lu.assertTrue(result, "Slot 11 heirloom (huge), slot 12 plain 300 → comparison uses slot 12 → upgrade (SC3)")
end

function TestLoot:test_heirloom_guard_c_heirloom_missing()
  -- D-02 guard: C_Heirloom = nil → isHeirloomActive returns false → normal delta path applies.
  -- With C_Heirloom absent, player wearing "heirloom" at level 50 is treated as non-heirloom.
  -- drop ilvl 400 vs slot ilvl 300 → delta 100 >= threshold 10 → callIsPlayerUpgrade returns true.
  local link = "item:33101"
  _mockHeirloomItemIDs[33101] = true
  _mockUnitLevel["player"] = 50
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:33102"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local saved = C_Heirloom
  local result
  local ok, err = pcall(function()
    C_Heirloom = nil
    result = callIsPlayerUpgrade(
      { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  end)
  C_Heirloom = saved  -- restore even if assertion throws

  if not ok then error(err) end
  lu.assertTrue(result, "C_Heirloom=nil guard: short-circuits to false → normal delta path → upgrade (D-02)")
end

function TestLoot:test_heirloom_debug_bypass_skips_check()
  -- /lif heirloom on: debugMode=true + skipHeirloomCheck=true must bypass
  -- isHeirloomActive entirely, same outcome as a non-heirloom item.
  local link = "item:44101"
  _mockHeirloomItemIDs[44101] = true
  _mockUnitLevel["player"] = 50
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:44102"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true, skipHeirloomCheck = true } } }
  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  LootItForward = origGlobal

  lu.assertTrue(result, "debugMode+skipHeirloomCheck both on → heirloom check bypassed → normal delta path → upgrade")
end

function TestLoot:test_heirloom_debug_bypass_inactive_when_debug_off()
  -- skipHeirloomCheck alone (debugMode false) must have no effect — heirloom
  -- check still applies exactly as in production.
  local link = "item:44201"
  _mockHeirloomItemIDs[44201] = true
  _mockUnitLevel["player"] = 50
  mockItem(link, { "HeirloomChest", nil, 7, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = link }
  _mockIlvl[link] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259

  local dropLink = "item:44202"
  mockItem(dropLink, { "NewChest", nil, 4, 400, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = false, skipHeirloomCheck = true } } }
  local result = callIsPlayerUpgrade(
    { link = dropLink, ilvl = 400, slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }, 10)
  LootItForward = origGlobal

  lu.assertFalse(result, "skipHeirloomCheck with debugMode off must have no effect → heirloom check still applies")
end

-- ============================================================
-- AUD-009: minPartySize disables the addon below threshold.
-- The gate moved out of _tryOpenPopup into ShouldBeActive() via the pure helper
-- LIF.GroupMeetsMinPartySize(); these test the helper directly (ShouldBeActive
-- itself lives in the un-harnessed entry file). Bidirectional activation is driven
-- by the existing GROUP_ROSTER_UPDATE re-eval, not tested here.
-- ============================================================

function TestLoot:test_group_meets_min_party_size_false_when_below_threshold()
  local origGlobal, origGroupSize = LootItForward, _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 5 } } }
  _mockGroupSize = 2
  lu.assertFalse(LIF.GroupMeetsMinPartySize(), "groupSize 2 < minPartySize 5 → false")
  LootItForward, _mockGroupSize = origGlobal, origGroupSize
end

function TestLoot:test_group_meets_min_party_size_true_when_at_threshold()
  local origGlobal, origGroupSize = LootItForward, _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 2 } } }
  _mockGroupSize = 2
  lu.assertTrue(LIF.GroupMeetsMinPartySize(), "groupSize 2 >= minPartySize 2 → true")
  LootItForward, _mockGroupSize = origGlobal, origGroupSize
end

function TestLoot:test_group_meets_min_party_size_true_when_above_threshold()
  local origGlobal, origGroupSize = LootItForward, _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 2 } } }
  _mockGroupSize = 5
  lu.assertTrue(LIF.GroupMeetsMinPartySize(), "groupSize 5 >= minPartySize 2 → true")
  LootItForward, _mockGroupSize = origGlobal, origGroupSize
end

function TestLoot:test_group_meets_min_party_size_defaults_to_2_when_absent()
  local origGlobal, origGroupSize = LootItForward, _mockGroupSize
  LootItForward = { db = { profile = {} } }
  _mockGroupSize = 2
  lu.assertTrue(LIF.GroupMeetsMinPartySize(), "absent setting → default 2; groupSize 2 → true")
  _mockGroupSize = 1
  lu.assertFalse(LIF.GroupMeetsMinPartySize(), "absent setting → default 2; groupSize 1 → false")
  LootItForward, _mockGroupSize = origGlobal, origGroupSize
end

-- ============================================================
-- Phase 06.1 Plan 04: D-17 weapon classification + offhand tests
-- ============================================================

-- ---------- GetSlotCategory direct tests (case 3/4) ----------

function TestLoot:test_get_slot_category_holdable_is_offhand()
  -- INVTYPE_HOLDABLE with classID=4, subID=0 → "offhand"
  lu.assertEquals(LIF.GetSlotCategory("INVTYPE_HOLDABLE", 4, 0), "offhand",
    "GetSlotCategory: INVTYPE_HOLDABLE must return 'offhand'")
end

function TestLoot:test_get_slot_category_shield_is_offhand()
  -- INVTYPE_SHIELD with classID=4, subID=6 → "offhand"
  lu.assertEquals(LIF.GetSlotCategory("INVTYPE_SHIELD", 4, 6), "offhand",
    "GetSlotCategory: INVTYPE_SHIELD must return 'offhand'")
end

function TestLoot:test_get_slot_category_offhand_invtype_is_offhand()
  -- INVTYPE_OFFHAND with classID=4, subID=0 → "offhand"
  lu.assertEquals(LIF.GetSlotCategory("INVTYPE_OFFHAND", 4, 0), "offhand",
    "GetSlotCategory: INVTYPE_OFFHAND must return 'offhand'")
end

function TestLoot:test_get_slot_category_weaponoffhand_is_weapon()
  -- INVTYPE_WEAPONOFFHAND with classID=2, subID=7 → "weapon" (classID=2 path, not offhand)
  lu.assertEquals(LIF.GetSlotCategory("INVTYPE_WEAPONOFFHAND", 2, 7), "weapon",
    "GetSlotCategory: INVTYPE_WEAPONOFFHAND must return 'weapon' (classID=2 path)")
end

-- ---------- Unknown weapon subID (D-03, case 13) ----------

function TestLoot:test_unknown_weapon_subid_self_check_false()
  -- callIsPlayerUpgrade with subID=99 weapon → D-03 → returns false.
  local unknownLink = "item:unknown_weapon_self"
  mockItem(unknownLink, { "UnknownWeapon", nil, 4, 470, nil,
    "Weapon", "Unknown", nil, "INVTYPE_WEAPON", nil, nil, 2, 99, 0 })
  _mockItemStats[unknownLink] = { ITEM_MOD_AGILITY_SHORT = 150 }
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Warrior", "WARRIOR" }
  _mockGearLinks["player"] = { [16] = "item:player_mh_unknown" }
  _mockIlvl["item:player_mh_unknown"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 71  -- Arms Warrior (STR)

  local itemData = {
    link         = unknownLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_WEAPON",
    classID      = 2,
    subID        = 99,
    slotIDs      = {16},
    slotCategory = "weapon",
    weaponSubID  = 99,
    primaryStats  = { AGI = true },
  }
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "IsPlayerUpgrade: unknown weapon subID=99 must return false (D-03 fail-safe)")
end

-- ---------- Player self-check offhand (case 12) ----------

function TestLoot:test_self_check_offhand_allowed_class_eligible()
  -- Holdable (classID=4, subID=0, equipLoc=INVTYPE_HOLDABLE), WARLOCK player.
  -- WARLOCK is in ITEM_CLASS_RESTRICT[4][0]; slot 17 lower than drop → upgrade.
  local holdableLink = "item:holdable_selfcheck"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Warlock", "WARLOCK" }
  _mockGearLinks["player"] = { [17] = "item:player_oh_warlock" }
  _mockIlvl["item:player_oh_warlock"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 265  -- Affliction Warlock (INT)

  local itemData = {
    link         = holdableLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
  }
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "WARLOCK player: holdable drop 470 vs slot 17 ilvl 450, threshold 10 → self-upgrade (eligible)")
end

function TestLoot:test_self_check_offhand_disallowed_class_ineligible()
  -- Holdable (subID=0), WARRIOR player.
  -- WARRIOR is NOT in ITEM_CLASS_RESTRICT[4][0] → return false.
  local holdableLink = "item:holdable_warrior_selfcheck"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Warrior", "WARRIOR" }
  _mockGearLinks["player"] = { [17] = "item:player_oh_warrior" }
  _mockIlvl["item:player_oh_warrior"] = 450
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 72  -- Fury Warrior (STR)

  local itemData = {
    link         = holdableLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
  }
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "WARRIOR player: holdable drop must return false (no Warrior spec has holdable in SPEC_TABLE offHandItem)")
end

function TestLoot:test_self_check_offhand_vs_2h_compares_straight_across()
  -- Player on a 2H staff @460; a holdable @465 drops. Under the D-16 cross-config
  -- rule the holdable is compared STRAIGHT against the equipped 2H (460), so at
  -- threshold 10 it does NOT clear (+5) → not a self-upgrade. (Under the old
  -- empty-slot bug it compared against slot 17 = 0 and wrongly read as an upgrade.)
  local holdableLink = "item:holdable_self_2h_gate"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 465, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Warlock", "WARLOCK" }
  local slot16Link = "item:self_2h_gate_slot16"
  _mockItemInfo[slot16Link] = { "TwoHandStaff", nil, 4, 460, nil,
    "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 }
  _mockIlvl[slot16Link] = 460  -- player path reads ilvl via GetDetailedItemLevelInfo
  _mockGearLinks["player"] = { [16] = slot16Link }
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 265  -- Affliction Warlock (INT)

  local itemData = {
    link         = holdableLink,
    ilvl         = 465,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
  }
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "holdable @465 must be compared straight to the equipped 2H @460 (not empty slot 17)")
end

function TestLoot:test_self_check_offhand_beats_2h_is_self_upgrade()
  -- Same player/2H; a holdable @480 clears the equipped 2H @460 by +20 → it IS a
  -- self-upgrade (they'd swap to 1H+holdable), so the popup is suppressed for them.
  local holdableLink = "item:holdable_self_2h_beats"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 480, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Warlock", "WARLOCK" }
  local slot16Link = "item:self_2h_beats_slot16"
  _mockItemInfo[slot16Link] = { "TwoHandStaff", nil, 4, 460, nil,
    "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 }
  _mockIlvl[slot16Link] = 460  -- player path reads ilvl via GetDetailedItemLevelInfo
  _mockGearLinks["player"] = { [16] = slot16Link }
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 265

  local itemData = {
    link         = holdableLink,
    ilvl         = 480,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
  }
  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "a holdable out-ilvling the equipped 2H is a self-upgrade (1H+holdable reconfigure)")
end

function TestLoot:test_self_upgrade_returns_real_basis_not_min()
  -- L1: the self-upgrade delta shown in chat must use the SAME basis the decision
  -- used. Ele Shaman on 1H @200 + off-hand @180 → a 2H is judged against the
  -- AVERAGE (190), not math.min(200,180)=180. IsPlayerUpgrade must SURFACE 190 as
  -- its basis so the "+X ilvl" line reads +5 (matching the decision), not +15.
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Shaman", "SHAMAN" }
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 262  -- Elemental
  local mh, oh = "item:self_mh1h_l1", "item:self_oh_l1"
  _mockItemInfo[mh] = { "OneHandMace", nil, 4, 200, nil, "Weapon", "Maces", nil, "INVTYPE_WEAPON", nil, nil, 2, 4, 0 }
  _mockItemInfo[oh] = { "OffHand", nil, 4, 180, nil, "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 }
  _mockIlvl[mh] = 200
  _mockIlvl[oh] = 180
  _mockGearLinks["player"] = { [16] = mh, [17] = oh }

  local drop = { link = "item:self_2h195_l1", ilvl = 195, equipLoc = "INVTYPE_2HWEAPON",
                 classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16}, weaponSubID = 10 }

  local ok, basis = callIsPlayerUpgrade(drop, 1)
  lu.assertTrue(ok, "2H @195 beats the 1H+off-hand average (190) → self-upgrade")
  lu.assertEquals(basis, 190,
    "self-upgrade basis must be the pair-average the decision used, not math.min(200,180)")
end

-- ============================================================
-- Phase 06.1 Plan 04: Offhand eligibility, 2H gate, Fury Warrior dual-slot
-- ============================================================

-- ---------- Offhand primary stat gate + heirloom gate (F4) ----------
-- The offhand branch never gated on primary stats or heirlooms, unlike
-- ring/trinket/weapon/neck/back. An INT holdable/shield could misread as an
-- upgrade for a STR or AGI class, and a heirloom-equipped offhand slot was
-- never excluded the way every other heirloom-bearing slot is.

function TestLoot:test_self_check_offhand_stat_mismatch_not_upgrade()
  -- Player is Retribution Paladin (STR); an INT holdable drops. Must NOT
  -- read as a self-upgrade, even with a huge ilvl delta.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 70  -- Retribution Paladin (STR)
  _mockUnitClass["player"] = { "Paladin", "PALADIN" }
  _mockGearLinks["player"] = { [17] = "item:self_oh_stat_current" }
  _mockIlvl["item:self_oh_stat_current"] = 50

  local itemData = {
    link         = "item:self_oh_stat_drop",
    ilvl         = 500,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
    primaryStats = { INT = true },
  }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "INT holdable must not read as a self-upgrade for a STR spec, regardless of ilvl delta")
end

function TestLoot:test_self_dual_wield_heirloom_locks_both_hands()
  -- D-17 H2 applies to the LOCAL PLAYER exactly as it does to a member — the rules are not
  -- gated on isPlayer. Frost DK with an heirloom sword in the main hand and a beatable real
  -- weapon in the off-hand: they can wield a second scaling copy, so a 1H drop is not a
  -- self-upgrade. "Not my upgrade" is the RIGHT answer here — it forwards the drop to the
  -- party while the player keeps the heirloom (AUD-001/AUD-004).
  _mockUnitClass["player"] = { "Death Knight", "DEATHKNIGHT" }
  _mockUnitLevel["player"] = 50
  _mockHeirloomItemIDs[77301] = true
  mockItem("item:77301", { "Heirloom Sword", nil, 3, 200, nil, "Weapon", "Swords", nil,
                           "INVTYPE_WEAPON", nil, nil, 2, 7, 1 })
  _mockGearLinks["player"] = { [16] = "item:77301", [17] = "item:77302" }
  _mockIlvl["item:77301"] = 200
  _mockIlvl["item:77302"] = 180
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 251   -- Frost DK (dual-wield)

  local itemData = { link = "item:self_dw_sword", ilvl = 250, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 7, slotIDs = {16}, slotCategory = "weapon",
                     weaponSubID = 7 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "a duplicable heirloom locks both of the player's hands too")
end

function TestLoot:test_self_outlaw_offhand_heirloom_leaves_the_main_hand_open()
  -- D-17 H3, self side. An Outlaw cannot main-hand a dagger, so a copy of their off-hand
  -- heirloom dagger cannot fill the main hand — which stays a real target. A sword that
  -- beats the main hand IS a self-upgrade, and must not be forwarded to the party.
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockUnitLevel["player"] = 50
  _mockHeirloomItemIDs[77303] = true
  mockItem("item:77303", { "Heirloom Dagger", nil, 3, 200, nil, "Weapon", "Daggers", nil,
                           "INVTYPE_WEAPON", nil, nil, 2, 15, 1 })
  _mockGearLinks["player"] = { [16] = "item:77304", [17] = "item:77303" }
  _mockIlvl["item:77304"] = 180   -- real main-hand weapon
  _mockIlvl["item:77303"] = 200
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 260   -- Outlaw

  local itemData = { link = "item:self_outlaw_sword", ilvl = 250, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 7, slotIDs = {16}, slotCategory = "weapon",
                     weaponSubID = 7 }

  lu.assertTrue(callIsPlayerUpgrade(itemData, 10),
    "an Outlaw's main hand takes no dagger copies, so it is still a real self-upgrade target")
end

function TestLoot:test_self_check_offhand_heirloom_equipped_not_upgrade()
  -- Player wears a heirloom holdable in slot 17 at level 50. Must NOT read
  -- as a self-upgrade regardless of ilvl delta.
  _mockUnitClass["player"] = { "Warlock", "WARLOCK" }
  _mockUnitLevel["player"] = 50
  local heirloomLink = "item:33302"
  _mockHeirloomItemIDs[33302] = true
  _mockGearLinks["player"] = { [17] = heirloomLink }
  _mockIlvl[heirloomLink] = 300
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 265  -- Affliction Warlock (INT)

  local itemData = {
    link         = "item:self_oh_heirloom_drop",
    ilvl         = 500,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
  }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "Heirloom-equipped offhand slot must not read as a self-upgrade, regardless of ilvl delta")
end

-- ---------- WEAPONOFFHAND slot 17 regression lock (CR-02) ----------

function TestLoot:test_weaponoffhand_self_check_uses_slot17()
  -- ROGUE with slot16=490, slot17=460; WEAPONOFFHAND dagger drop=490, threshold=10
  -- Correct: reads slot 17 → 490-460=30 >= 10 → true
  -- Buggy (slot 16): 490-490=0 < 10 → false
  local link = "item:woh_dagger"
  mockItem(link, { "Offhand Dagger", nil, 4, 490, nil,
    "Weapon", "Daggers", nil, "INVTYPE_WEAPONOFFHAND", nil, nil, 2, 15, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 150 }
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [16] = "item:woh_player_mh", [17] = "item:woh_player_oh" }
  _mockIlvl["item:woh_player_mh"] = 490
  _mockIlvl["item:woh_player_oh"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local itemData = {
    link        = link,
    ilvl        = 490,
    slotCategory = "weapon",
    slotIDs     = {17},
    equipLoc    = "INVTYPE_WEAPONOFFHAND",
    classID     = 2,
    subID       = 15,
    weaponSubID = 15,
    primaryStats = { AGI = true },
  }

  local result = callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(result, "WEAPONOFFHAND self-check must read slot 17 (460 not 490)")
end

-- ============================================================
-- TestEncounterLootPlayerNameFilter
-- Tests the WR-02 fix: realm suffix is stripped from playerName before
-- comparing against UnitName("player"), which always returns a short name.
-- Logic under test (LootItForward.lua):
--   local shortName = playerName and (playerName:match("^([^%-]+)") or playerName)
--   if shortName ~= UnitName("player") then return end
-- ============================================================
-- ENCOUNTER_LOOT_RECEIVED playerName follows GetUnitName(unit, true) semantics:
-- plain "Name" for same-realm players (always including the local player),
-- "Name-NormalizedRealm" for cross-realm players. The self-filter must accept
-- both forms for the local player and must NEVER strip another player's realm
-- qualifier (a cross-realm "Alesh-OtherRealm" is NOT the local "Alesh").
TestEncounterLootPlayerNameFilter = {}

function TestEncounterLootPlayerNameFilter:setUp()
  ResetMocks()
  _mockUnitNames["player"]  = "Alesh"
  _mockUnitRealms["player"] = "Thrall"
end

function TestEncounterLootPlayerNameFilter:test_plain_self_name_matches()
  lu.assertTrue(LIF.IsLocalPlayerName("Alesh"),
    "plain short name is the documented form for the local player")
end

function TestEncounterLootPlayerNameFilter:test_realm_qualified_self_name_matches()
  lu.assertTrue(LIF.IsLocalPlayerName("Alesh-Thrall"),
    "belt-and-braces: accept the realm-qualified form of the local player too")
end

function TestEncounterLootPlayerNameFilter:test_cross_realm_same_short_name_rejected()
  lu.assertFalse(LIF.IsLocalPlayerName("Alesh-Stormrage"),
    "another realm's Alesh is NOT the local player — stripping would misattribute their loot")
end

function TestEncounterLootPlayerNameFilter:test_other_player_name_rejected()
  lu.assertFalse(LIF.IsLocalPlayerName("Bob"))
  lu.assertFalse(LIF.IsLocalPlayerName("Bob-Thrall"))
end

function TestEncounterLootPlayerNameFilter:test_nil_name_rejected()
  lu.assertFalse(LIF.IsLocalPlayerName(nil))
end

function TestEncounterLootPlayerNameFilter:test_no_realm_available_still_matches_short()
  _mockUnitRealms["player"] = nil
  lu.assertTrue(LIF.IsLocalPlayerName("Alesh"))
  lu.assertFalse(LIF.IsLocalPlayerName("Alesh-Thrall"),
    "without a known local realm, a qualified name cannot be confirmed as self")
end

-- ============================================================
-- TestCloakEquipLoc
-- Regression: WoW API returns INVTYPE_CLOAK (not INVTYPE_BACK) for back items.
-- Both ClassifyItem and EvaluateCandidates must handle it as slotCategory="back".
-- ============================================================
TestCloakEquipLoc = {}

function TestCloakEquipLoc:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.pendingLootItems = {}
end

function TestCloakEquipLoc:test_getslotcategory_cloak_returns_back()
  lu.assertEquals(LIF.GetSlotCategory("INVTYPE_CLOAK", 4, 1), "back",
    "INVTYPE_CLOAK must map to slotCategory 'back'")
end

function TestCloakEquipLoc:test_classify_invtype_cloak_succeeds()
  -- name, _, rarity, ilvl, _, itype, subtype, _, equipLoc, _, _, classID, subID, bindType
  local link = "item:260312"
  mockItem(link, { "Defiant Defender's Drape", nil, 3, 184, nil, "Armor", "Cloth", nil, "INVTYPE_CLOAK", nil, nil, 4, 1, 0 })
  local result = LIF.ClassifyItem(link, 260312)
  lu.assertNotNil(result, "ClassifyItem must not return nil for INVTYPE_CLOAK")
  lu.assertEquals(result.slotCategory, "back")
  lu.assertEquals(result.slotIDs[1], 15)
end

function TestCloakEquipLoc:test_cloak_eligible_for_member_with_lower_back_ilvl()
  local guid = "GUID-SHAM-01"
  local link = "item:260312"
  mockItem(link, { "Defiant Defender's Drape", nil, 3, 184, nil, "Armor", "Cloth", nil, "INVTYPE_CLOAK", nil, nil, 4, 1, 0 })
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [15] = 170 })
  _mockIsInGroup = true

  local itemData = LIF.ClassifyItem(link, 260312)
  local eval = callEvaluate(itemData, 1)
  lu.assertTrue(eval.scanningGuids[guid] ~= nil,
    "Elemental Shaman with ilvl-170 back should be queued for rescan when ilvl-184 cloak drops")
end

-- Primary stat gate: INT cloaks must not pop for STR/AGI specs.
-- Real cloaks report classID=4, subID=1 (Cloth armor subclass) — confirmed
-- in-game via /dump select(13, C_Item.GetItemInfo(link)) on Voidbreaker's
-- Encryption, 2026-07-01. subID=0 was an earlier, incorrect assumption.
-- GetItemPrimaryStats must not exclude neck/back from the stat scan just
-- because their subID happens to fall in the armor subclass range — the
-- armor early-return is keyed on slot category, not raw subID.

function TestCloakEquipLoc:test_int_cloak_primary_stats_returns_int()
  -- GetItemPrimaryStats must return {INT=true} for an INT cloak, regardless
  -- of which armor subID the item happens to report.
  local link = "item:int_cloak_stats"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local stats = LIF.GetItemPrimaryStats(link, "INVTYPE_CLOAK", 4, 0)
  lu.assertNotNil(stats, "GetItemPrimaryStats must return a stat set for INT cloak")
  lu.assertEquals(stats.INT, true)
  lu.assertNil(stats.STR)
  lu.assertNil(stats.AGI)
end

function TestCloakEquipLoc:test_int_cloak_subid_cloth_primary_stats_returns_int()
  -- Real-world value (subID=1, Cloth) must NOT trigger the armor early-return.
  local link = "item:int_cloak_stats_subid1"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local stats = LIF.GetItemPrimaryStats(link, "INVTYPE_CLOAK", 4, 1)
  lu.assertNotNil(stats, "GetItemPrimaryStats must return a stat set for a subID=1 (Cloth) cloak")
  lu.assertEquals(stats.INT, true)
end

function TestCloakEquipLoc:test_int_cloak_self_check_str_spec_not_upgrade()
  -- INT cloak, Ret Paladin (specID=70, STR) → stat mismatch → not a self-upgrade.
  local link = "item:int_cloak_ret"
  local itemData = classifyMockItem(link,
    { "Cloak of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_CLOAK", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [15] = "item:player_cloak_ret" }
  _mockIlvl["item:player_cloak_ret"] = 100
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 70  -- Retribution Paladin (STR)

  local result = callIsPlayerUpgrade(itemData, 1)
  lu.assertFalse(result, "INT cloak must not be a self-upgrade for STR spec (Ret Paladin)")
end

function TestCloakEquipLoc:test_int_cloak_self_check_int_spec_is_upgrade()
  -- INT cloak ilvl 220, Frost Mage (specID=64, INT), wearing ilvl 100 → upgrade.
  local link = "item:int_cloak_mage_self"
  local itemData = classifyMockItem(link,
    { "Cloak of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_CLOAK", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [15] = "item:player_cloak_mage" }
  _mockIlvl["item:player_cloak_mage"] = 100
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 64  -- Frost Mage (INT)

  local result = callIsPlayerUpgrade(itemData, 1)
  lu.assertTrue(result, "INT cloak ilvl 220 vs 100 must be a self-upgrade for INT spec (Frost Mage)")
end

function TestCloakEquipLoc:test_int_cloak_evaluate_excludes_str_spec()
  -- EvaluateCandidates must NOT queue Ret Paladin (specID=70, STR) for an INT cloak.
  local link = "item:int_cloak_eval_ret"
  local itemData = classifyMockItem(link,
    { "Cloak of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_CLOAK", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  local guid = "GUID-RET-PAL-01"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [15] = 150 })
  _mockIsInGroup = true

  local eval = callEvaluate(itemData, 1)
  lu.assertNil(eval.scanningGuids[guid],
    "Ret Paladin (STR) must not be queued for rescan on INT cloak")
end

function TestCloakEquipLoc:test_int_cloak_evaluate_includes_int_spec()
  -- EvaluateCandidates must queue Frost Mage (specID=64, INT) for an INT cloak.
  local link = "item:int_cloak_eval_mage"
  local itemData = classifyMockItem(link,
    { "Cloak of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_CLOAK", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  local guid = "GUID-FROST-MAGE-01"
  mockMemberGear(guid, "party1", "MAGE", 64, { [15] = 100 })
  _mockIsInGroup = true

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[guid],
    "Frost Mage (INT) must be queued for rescan on INT cloak")
end

function TestCloakEquipLoc:test_statless_cloak_evaluate_includes_all_specs()
  -- No _mockItemStats entry → GetItemStats returns {} → primaryStats=nil → ilvl-only.
  -- Both STR and INT specs must be queued.
  local link = "item:statless_cloak_eval"
  local itemData = classifyMockItem(link,
    { "Generic Cloak", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_CLOAK", nil, nil, 4, 0, 0 })
  local palGuid  = "GUID-RET-PAL-02"
  local mageGuid = "GUID-FROST-MAGE-02"
  mockMemberGear(palGuid,  "party1", "PALADIN", 70, { [15] = 150 })
  mockMemberGear(mageGuid, "party2", "MAGE",    64, { [15] = 100 })
  _mockIsInGroup = true

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[palGuid],
    "Ret Paladin must be queued on stat-less cloak (ilvl-only)")
  lu.assertNotNil(eval.scanningGuids[mageGuid],
    "Frost Mage must be queued on stat-less cloak (ilvl-only)")
end

-- ============================================================
-- TestRingStatGate
-- Rings get a primaryStats set from GetItemPrimaryStats and EvaluateCandidates
-- pre-filters on it, but IsPlayerUpgrade and _checkMemberEligibility skipped
-- the gate for rings (unlike trinket/neck/back/weapon) — a primary-stat ring
-- could wrongly suppress the self-popup or wrongly pop for a mismatched
-- party member. Mirrors TestCloakEquipLoc's stat-gate coverage.
-- ============================================================
TestRingStatGate = {}

function TestRingStatGate:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.pendingLootItems = {}
end

function TestRingStatGate:test_int_ring_self_check_str_spec_not_upgrade()
  -- INT ring ilvl 220, Ret Paladin (specID=70, STR), wearing ilvl-100 rings
  -- → stat mismatch must override the ilvl-only comparison.
  local link = "item:int_ring_ret"
  local itemData = classifyMockItem(link,
    { "Ring of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_FINGER", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [11] = "item:player_ring11_ret", [12] = "item:player_ring12_ret" }
  _mockIlvl["item:player_ring11_ret"] = 100
  _mockIlvl["item:player_ring12_ret"] = 100
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 70  -- Retribution Paladin (STR)

  local result = callIsPlayerUpgrade(itemData, 1)
  lu.assertFalse(result, "INT ring must not be a self-upgrade for STR spec (Ret Paladin)")
end

function TestRingStatGate:test_int_ring_self_check_int_spec_is_upgrade()
  -- Same ring/ilvl gap, Frost Mage (specID=64, INT) → stat match, ilvl-only path proceeds.
  local link = "item:int_ring_mage_self"
  local itemData = classifyMockItem(link,
    { "Ring of the Frigid Winds", nil, 3, 220, nil, "Armor", "Miscellaneous", nil,
      "INVTYPE_FINGER", nil, nil, 4, 0, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 200 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [11] = "item:player_ring11_mage", [12] = "item:player_ring12_mage" }
  _mockIlvl["item:player_ring11_mage"] = 100
  _mockIlvl["item:player_ring12_mage"] = 100
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 64  -- Frost Mage (INT)

  local result = callIsPlayerUpgrade(itemData, 1)
  lu.assertTrue(result, "INT ring ilvl 220 vs 100 must be a self-upgrade for INT spec (Frost Mage)")
end

-- ============================================================
-- TestUncachedItemDefer (REV-008)
-- GetItemInfo returns nil for items not yet in the client cache (first kill
-- of a new boss). OnPlayerLootReceived must defer one retry via
-- Item:CreateFromItemLink():ContinueOnItemLoad rather than dropping the loot
-- event, with a re-entry guard against infinite retries.
-- ============================================================
TestUncachedItemDefer = {}

function TestUncachedItemDefer:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.IsItemTradeable = mockIsItemTradeable
end

function TestUncachedItemDefer:test_uncached_item_defers_then_processes()
  local link = "item:990001"
  -- Player already wears a better chest so the drop is NOT a self-upgrade.
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:990002" }
  _mockIlvl["item:990002"] = 300

  -- Item data NOT cached yet: no _mockItemInfo entry.
  LIF.OnPlayerLootReceived(link, 990001)
  lu.assertEquals(#LIF.pendingLootItems, 0,
    "uncached item must not be processed immediately")
  lu.assertEquals(#_pendingItemLoadCallbacks, 1,
    "uncached item must register exactly one ContinueOnItemLoad callback")

  -- Item data arrives; deferred retry runs the full pipeline.
  mockItem(link, { "Fresh Boss Chest", nil, 3, 184, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  FirePendingItemLoads()
  FirePendingAfterCallbacks()  -- fires 0-frame tradeability defer from the retry
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "deferred retry must process the loot event once item data is cached")
end

function TestUncachedItemDefer:test_reset_during_item_load_cancels_the_deferred_pipeline()
  -- AUD-010 (item-load path): a Loot_Reset during the ContinueOnItemLoad wait must
  -- cancel the drop. The re-call would otherwise capture a fresh generation and
  -- proceed against the cleared state (stale chat + orphan pending entry). The
  -- generation captured before Step 0 guards the item-load callback.
  local link = "item:990010"
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:990011" }
  _mockIlvl["item:990011"] = 300

  LIF.OnPlayerLootReceived(link, 990010)   -- uncached → registers ContinueOnItemLoad
  lu.assertEquals(#_pendingItemLoadCallbacks, 1, "precondition: one item-load callback pending")

  mockItem(link, { "Fresh Boss Chest", nil, 3, 184, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  LIF.Loot_Reset()                          -- group disbands during the item-load wait
  FirePendingItemLoads()                    -- callback runs → must bail on the gen change
  FirePendingAfterCallbacks()               -- nothing should have been scheduled to proceed

  lu.assertEquals(#LIF.pendingLootItems, 0,
    "a Loot_Reset during the item-load wait must cancel the deferred pipeline — no orphan entry (AUD-010)")
end

function TestUncachedItemDefer:test_still_uncached_after_load_does_not_loop()
  local link = "item:990003"
  LIF.OnPlayerLootReceived(link, 990003)
  lu.assertEquals(#_pendingItemLoadCallbacks, 1)

  -- Pathological: data still missing when the load callback fires.
  FirePendingItemLoads()
  lu.assertEquals(#_pendingItemLoadCallbacks, 0,
    "retry must not re-defer — one deferral only (re-entry guard)")
  lu.assertEquals(#LIF.pendingLootItems, 0)
end

function TestUncachedItemDefer:test_cached_item_not_deferred()
  local link = "item:990004"
  mockItem(link, { "Cached Chest", nil, 3, 184, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:990005" }
  _mockIlvl["item:990005"] = 300

  LIF.OnPlayerLootReceived(link, 990004)
  lu.assertEquals(#_pendingItemLoadCallbacks, 0,
    "cached items must skip the ItemMixin load deferral (Step 0)")
  FirePendingAfterCallbacks()  -- fires 0-frame tradeability defer
  lu.assertEquals(#LIF.pendingLootItems, 1)
end

-- ============================================================
-- TestBagCacheLag
-- ENCOUNTER_LOOT_RECEIVED can fire before the client's bag cache reflects the
-- fresh drop. If IsItemTradeable fails AND the item isn't in bags AT ALL yet
-- (distinct from "in bags but no trade timer"), OnPlayerLootReceived must
-- retry every TRADE_RETRY_DELAY up to TRADE_RETRY_MAX times instead of
-- permanently skipping a tradeable BoP drop after a single guess — a live
-- occurrence showed the bag cache can still be lagging past one 0.3s retry
-- during a busy moment (loot + roster churn at combat end). Drives the real
-- IsItemTradeable (not the pipeline mock) via _mockContainerItems +
-- _mockScanTooltipLines, matching TestIsItemTradeable.
-- ============================================================
TestBagCacheLag = {}

function TestBagCacheLag:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.pendingLootItems = {}
  LIF.IsItemTradeable = _realIsItemTradeable
end

function TestBagCacheLag:tearDown()
  LIF.IsItemTradeable = mockIsItemTradeable
end

function TestBagCacheLag:test_retries_once_when_bags_catch_up()
  local link = "item:990010"
  mockItem(link, { "Fresh Boss Drop", nil, 3, 200, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_lag" }
  _mockIlvl["item:player_chest_lag"] = 250  -- higher than drop, so not a self-upgrade

  LIF.OnPlayerLootReceived(link, 990010)
  FirePendingAfterCallbacks()  -- first 0-frame check: item not in bags yet
  lu.assertEquals(#LIF.pendingLootItems, 0,
    "must not give up permanently on the first check — bags may just be lagging")

  -- Bag cache catches up before the retry fires.
  _mockContainerItems[0] = { [1] = { hyperlink = link } }
  _mockScanTooltipLines[link] = {
    "Fresh Boss Drop",
    "Soulbound",
    string.format(BIND_TRADE_TIME_REMAINING, "2 hours"),
  }

  FirePendingAfterCallbacks()  -- fires the retry
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "retry must pick up the item once the bag cache reflects it")
end

function TestBagCacheLag:test_retries_multiple_times_before_bags_catch_up()
  -- Bags don't catch up until the 4th attempt — proves the retry is a bounded
  -- loop, not just one extra guess.
  local link = "item:990013"
  mockItem(link, { "Slow Arrival", nil, 3, 200, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_lag4" }
  _mockIlvl["item:player_chest_lag4"] = 250

  LIF.OnPlayerLootReceived(link, 990013)
  FirePendingAfterCallbacks()  -- attempt 0 (initial check): not in bags

  for i = 1, 3 do
    lu.assertEquals(#LIF.pendingLootItems, 0,
      "must keep retrying while bags are still empty (attempt " .. i .. ")")
    FirePendingAfterCallbacks()
  end

  -- Bags catch up in time for this retry.
  _mockContainerItems[0] = { [1] = { hyperlink = link } }
  _mockScanTooltipLines[link] = {
    "Slow Arrival",
    "Soulbound",
    string.format(BIND_TRADE_TIME_REMAINING, "2 hours"),
  }
  FirePendingAfterCallbacks()
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "a later retry within the budget must still pick up the item")
end

function TestBagCacheLag:test_gives_up_after_max_retries_no_infinite_loop()
  local link = "item:990011"
  mockItem(link, { "Never Arrives", nil, 3, 200, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_lag2" }
  _mockIlvl["item:player_chest_lag2"] = 250

  LIF.OnPlayerLootReceived(link, 990011)
  FirePendingAfterCallbacks()  -- attempt 0 (initial check): not in bags
  lu.assertEquals(#LIF.pendingLootItems, 0)

  -- Never appears in bags — burn through the full retry budget.
  for i = 1, 5 do
    FirePendingAfterCallbacks()
  end
  lu.assertEquals(#LIF.pendingLootItems, 0)
  lu.assertEquals(CountPendingAfterCallbacks(), 0,
    "must give up once the retry budget is exhausted — bounded, not infinite")
end

function TestBagCacheLag:test_present_on_first_check_no_retry_needed()
  local link = "item:990012"
  mockItem(link, { "Already In Bags", nil, 3, 200, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 1 })
  _mockGuids["player"] = "GUID-SELF"
  _mockGearLinks["player"] = { [5] = "item:player_chest_lag3" }
  _mockIlvl["item:player_chest_lag3"] = 250
  _mockContainerItems[0] = { [1] = { hyperlink = link } }
  _mockScanTooltipLines[link] = {
    "Already In Bags",
    "Soulbound",
    string.format(BIND_TRADE_TIME_REMAINING, "1 hour"),
  }

  LIF.OnPlayerLootReceived(link, 990012)
  FirePendingAfterCallbacks()
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "item already present on the first check must not be delayed at all")
end

-- ============================================================
-- TestRangedWeaponEquipLoc (REV-001)
-- Bows/guns/crossbows/wands return INVTYPE_RANGEDRIGHT (legacy items:
-- INVTYPE_RANGED); both equip in main-hand slot 16. ClassifyItem must not
-- skip them for lack of an EQUIP_LOC_SLOTS entry.
-- ============================================================
TestRangedWeaponEquipLoc = {}

function TestRangedWeaponEquipLoc:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.pendingLootItems = {}
end

function TestRangedWeaponEquipLoc:test_classify_rangedright_bow_succeeds()
  -- name, _, rarity, ilvl, _, itype, subtype, _, equipLoc, _, _, classID, subID, bindType
  local link = "item:260400"
  mockItem(link, { "Stalker's Longbow", nil, 3, 184, nil, "Weapon", "Bows", nil, "INVTYPE_RANGEDRIGHT", nil, nil, 2, 2, 0 })
  local result = LIF.ClassifyItem(link, 260400)
  lu.assertNotNil(result, "ClassifyItem must not return nil for INVTYPE_RANGEDRIGHT")
  lu.assertEquals(result.slotCategory, "weapon")
  lu.assertEquals(result.slotIDs[1], 16, "Ranged weapons equip in main-hand slot 16")
  lu.assertEquals(result.weaponSubID, 2, "Bow subID must be stored for SPEC_TABLE weapon usability lookup")
end

function TestRangedWeaponEquipLoc:test_classify_legacy_invtype_ranged_succeeds()
  local link = "item:260401"
  mockItem(link, { "Heirloom Recurve", nil, 4, 110, nil, "Weapon", "Bows", nil, "INVTYPE_RANGED", nil, nil, 2, 2, 0 })
  local result = LIF.ClassifyItem(link, 260401)
  lu.assertNotNil(result, "ClassifyItem must not return nil for legacy INVTYPE_RANGED")
  lu.assertEquals(result.slotCategory, "weapon")
  lu.assertEquals(result.slotIDs[1], 16)
end

function TestRangedWeaponEquipLoc:test_bow_drop_queues_hunter_member()
  -- AGI bow drop → Hunter (spec 253, AGI) must land in scanningGuids.
  local guid = "Player-0-BowHunter"
  local link = "item:260400"
  mockItem(link, { "Stalker's Longbow", nil, 3, 184, nil, "Weapon", "Bows", nil, "INVTYPE_RANGEDRIGHT", nil, nil, 2, 2, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 50 }
  mockMemberGear(guid, "party1", "HUNTER", 253, { [16] = 150 })
  _mockIsInGroup = true

  local itemData = LIF.ClassifyItem(link, 260400)
  lu.assertNotNil(itemData, "bow must classify")
  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[guid],
    "Hunter must be queued for rescan when an AGI bow drops")
end

-- ============================================================
-- TestPartialInspectEligibilityGate (REV-002)
-- INSPECT_READY can fire with partial slot data; OnInspectReady leaves the
-- member PENDING (gear still empty after RequestReinspect) and returns.
-- OnLootInspectReady must NOT evaluate eligibility until the member is
-- COMPLETE, and must NOT consume the scanningGuids sentinel on partial fires.
-- ============================================================
TestPartialInspectEligibilityGate = {}

function TestPartialInspectEligibilityGate:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

function TestPartialInspectEligibilityGate:test_pending_member_not_evaluated()
  local guid = "Player-0-PartialScan"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 480, [12] = 485 })
  _mockGuids["player"] = "GUID-SELF"

  -- Loot-time reinspect wipes gear and sets PENDING (production sequence).
  callRequestReinspect(guid)

  local showPopupCalls = 0
  LIF.ShowPopup = function() showPopupCalls = showPopupCalls + 1 end

  local itemData = { link = "item:partial_ring", ilvl = 500, slotID = 11,
                     equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
                     itype = "Armor", subtype = "Miscellaneous" }
  local entry = {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = false,
  }
  table.insert(LIF.pendingLootItems, entry)

  -- Partial INSPECT_READY fire: member still PENDING with empty gear.
  callOnLootInspectReady(guid)

  lu.assertEquals(showPopupCalls, 0,
    "ShowPopup must NOT fire from a partial (PENDING) inspect — empty gear would read as ilvl 0")
  local confirmedCount = 0
  for _ in pairs(entry.confirmedCandidates) do confirmedCount = confirmedCount + 1 end
  lu.assertEquals(confirmedCount, 0,
    "No candidate may be confirmed from partial inspect data")
  lu.assertNotNil(entry.scanningGuids[guid],
    "scanningGuids sentinel must be preserved so the COMPLETE fire re-evaluates")

  LIF.ShowPopup = _origShowPopup
end

function TestPartialInspectEligibilityGate:test_complete_member_evaluated_after_partial()
  local guid = "Player-0-PartialThenDone"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 480, [12] = 485 })
  _mockGuids["player"] = "GUID-SELF"
  callRequestReinspect(guid)

  local showPopupCalls = 0
  local capturedCandidates = nil
  LIF.ShowPopup = function(_, candidates)
    showPopupCalls = showPopupCalls + 1
    capturedCandidates = candidates
  end

  local itemData = { link = "item:partial_ring2", ilvl = 500, slotID = 11,
                     equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
                     itype = "Armor", subtype = "Miscellaneous" }
  local entry = {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = false,
  }
  table.insert(LIF.pendingLootItems, entry)

  -- Partial fire: ignored.
  callOnLootInspectReady(guid)
  lu.assertEquals(showPopupCalls, 0, "partial fire must not open popup")

  -- Inspect completes with real gear (what queue.lua's OnInspectReady does).
  local link11, link12 = "item:" .. guid .. "s11b", "item:" .. guid .. "s12b"
  _mockIlvl[link11], _mockIlvl[link12] = 480, 485
  LIF.Cache.SetComplete(guid, {
    gear = { [11] = { link = link11, ilvl = 480 }, [12] = { link = link12, ilvl = 485 } },
    specID = 103,
  })

  callOnLootInspectReady(guid)
  lu.assertEquals(showPopupCalls, 1, "COMPLETE fire must evaluate and open popup")
  lu.assertEquals(#capturedCandidates, 1)
  lu.assertEquals(capturedCandidates[1].ilvl_current, 480,
    "candidate ilvl must come from real gear, not empty-gear ilvl 0")

  LIF.ShowPopup = _origShowPopup
end

-- ============================================================
-- TestDualWield (REV-010)
-- 1H weapons (INVTYPE_WEAPON) can sit in either hand for dual-wield specs:
-- compare vs min(slot16, slot17), mirroring the ring/trinket lower-slot rule.
-- Non-DW specs keep main-hand-only comparison (their off-hand may hold a
-- shield/holdable, which must never be compared against a weapon).
-- INVTYPE_WEAPONOFFHAND items are equippable ONLY by dual-wield specs.
-- ============================================================
TestDualWield = {}

function TestDualWield:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

-- Drive _checkMemberEligibility through OnLootInspectReady; returns captured candidates or nil.
local function resolveMemberForItem(guid, itemData)
  local captured = nil
  LIF.ShowPopup = function(_, candidates) captured = candidates end
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = false,
  })
  LIF.OnLootInspectReady(guid)
  LIF.ShowPopup = _origShowPopup
  return captured
end

function TestDualWield:test_member_dw_spec_compares_lower_weapon_slot()
  -- Assassination Rogue (dagger-locked, dual-wield): MH 200, OH 100. A dagger
  -- drop ilvl 150 must be eligible against the weaker off-hand (delta +50), not
  -- skipped against the MH.
  local guid = "Player-0-DWRogue"
  mockMemberGear(guid, "party1", "ROGUE", 259, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:dw_dagger", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "DW rogue with weak off-hand must be eligible")
  lu.assertEquals(captured[1].ilvl_current, 100,
    "comparison must use the lower of MH/OH for dual-wield specs")
  lu.assertEquals(captured[1].delta, 50)
  lu.assertEquals(captured[1].slotID, 17)
end

function TestDualWield:test_member_non_dw_spec_ignores_offhand()
  -- Protection Warrior (73, not DW): MH 200 mace, shield 100 in off-hand.
  -- 1H mace drop ilvl 150 must NOT be eligible — never compare vs the shield.
  local guid = "Player-0-ProtWar"
  mockMemberGear(guid, "party1", "WARRIOR", 73, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:dw_mace", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 4,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 4 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "non-DW spec must compare main-hand only; shield ilvl is irrelevant")
end

function TestDualWield:test_offhand_weapon_requires_dual_wield_spec()
  -- INVTYPE_WEAPONOFFHAND dagger: Holy Priest (257) can equip daggers as a
  -- class, but cannot dual-wield — an OH weapon is unusable for them.
  local guid = "Player-0-HolyPriest"
  mockMemberGear(guid, "party1", "PRIEST", 257, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:oh_dagger", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPONOFFHAND", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {17},
                     weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "INVTYPE_WEAPONOFFHAND must be skipped for specs that cannot dual-wield")
end

function TestDualWield:test_offhand_weapon_eligible_for_dw_spec()
  local guid = "Player-0-SubRogue"
  mockMemberGear(guid, "party1", "ROGUE", 261, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:oh_dagger2", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPONOFFHAND", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {17},
                     weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "DW rogue must remain eligible for OH weapons")
  lu.assertEquals(captured[1].ilvl_current, 100)
end

function TestDualWield:test_member_dw_mainhand_heirloom_skips_both_hands()
  -- D-17 H2 (duplication). Frost DK (dual-wield) with an ACTIVE heirloom sword in the main
  -- hand and a beatable normal weapon in the off-hand. Their off-hand takes swords too, so
  -- they can re-create the heirloom from Collections and wield a second scaling copy —
  -- neither hand is a real target, and no weapon drop is wanted at all.
  local guid = "Player-0-FrostDKHeir"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200, [17] = 180 })
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99201", ilvl = 200, equipLoc = "INVTYPE_WEAPON", subID = 7 }
  _mockHeirloomItemIDs[99201] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:dw_1h_sword", ilvl = 200,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  lu.assertNil(resolveMemberForItem(guid, itemData),
    "a duplicable heirloom locks BOTH hands — the off-hand will hold a scaling copy")
end

function TestDualWield:test_member_dw_both_hands_heirloom_skipped()
  -- Both hands hold active heirlooms — neither can be beaten, so an either-hand
  -- 1H drop is correctly skipped (M3 boundary).
  local guid = "Player-0-FrostDKBothHeir"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200, [17] = 200 })
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99202", ilvl = 200 }
  member.gear[17] = { link = "item:99203", ilvl = 200 }
  _mockHeirloomItemIDs[99202] = true
  _mockHeirloomItemIDs[99203] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:dw_1h_sword2", ilvl = 200,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "both hands heirloom → nothing to beat → not a candidate")
end

function TestDualWield:test_member_dw_mainhand_2h_heirloom_blocks_1h_drop()
  -- Frost DK with an active heirloom TWO-HANDER in the main hand and an empty
  -- off-hand. A 1H drop must NOT be eligible: the off-hand can't be filled
  -- without dropping the unbeatable 2H heirloom, so the empty slot 17 is not a
  -- real compare target (M3 regression M3-R1).
  local guid = "Player-0-FrostDK2H"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  -- subID resolved (8 = 2H sword), and the drop must OUT-ILVL the heirloom (250 > 200) —
  -- otherwise the test passes on the plain ilvl compare and never exercises the rule.
  member.gear[16] = { link = "item:99301", ilvl = 200, equipLoc = "INVTYPE_2HWEAPON", subID = 8 }
  _mockHeirloomItemIDs[99301] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:frost_1h", ilvl = 250,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "MH 2H heirloom + 1H drop: off-hand not fillable without dropping the heirloom → not a candidate")
end

function TestDualWield:test_member_titans_grip_2h_heirloom_skips_both_hands()
  -- D-17 H2. Titan's Grip Fury with a 2H heirloom in the main hand and a beatable 2H in the
  -- off-hand. TG wields two-handers in BOTH hands, so the heirloom is duplicable into the
  -- off-hand and the 2H drop is not wanted — even though it out-ilvls what is there.
  -- (H1 does not apply: for TG a 2H occupies one hand, so it displaces nothing.)
  local guid = "Player-0-FuryTG"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 200, [17] = 180 })
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99302", ilvl = 200, equipLoc = "INVTYPE_2HWEAPON", subID = 1 }
  mockItem("item:99302", { "Heirloom Greataxe", nil, 3, 200, nil, "Weapon", "Axes", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 1, 1 })
  _mockHeirloomItemIDs[99302] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fury_2h", ilvl = 210,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 1,
                     slotCategory = "weapon", slotIDs = {16, 17},
                     weaponSubID = 1 }

  lu.assertNil(resolveMemberForItem(guid, itemData),
    "Fury can wield a second copy of its 2H heirloom — skip")
end

function TestDualWield:test_member_titans_grip_single_2h_heirloom_empty_oh_skipped()
  -- Titan's Grip Fury with ONE active 2H heirloom in the main hand and an EMPTY
  -- off-hand. A normal 2H drop must NOT be eligible: a leveling Fury fills the
  -- empty hand with a second (scaling) 2H heirloom, not a random drop, so the
  -- empty slot 17 is not a real compare target. Guards the false positive from
  -- comparing a 2H drop against an ilvl-0 empty hand.
  local guid = "Player-0-FuryTGSingleHeir"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 200 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99304", ilvl = 200, equipLoc = "INVTYPE_2HWEAPON", subID = 1 }
  _mockHeirloomItemIDs[99304] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fury_2h_drop", ilvl = 210,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 1,
                     slotCategory = "weapon", slotIDs = {16, 17},
                     weaponSubID = 1 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "single 2H heirloom + empty off-hand: they'll make a second heirloom → not a candidate")
end

function TestDualWield:test_member_dw_mainhand_1h_heirloom_empty_oh_skipped()
  -- Frost DK (dual-1H) with a 1H heirloom in the main hand and an EMPTY off-hand.
  -- A normal 1H drop must NOT be eligible: they fill the empty hand with a second
  -- scaling heirloom, so comparing against the ilvl-0 empty hand is a false
  -- positive (same empty-hand rule as the TG case, drop type aside).
  local guid = "Player-0-FrostDK1HEmptyOH"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99305", ilvl = 200, equipLoc = "INVTYPE_WEAPON" }
  _mockHeirloomItemIDs[99305] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:frost_1h_drop", ilvl = 210,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "1H heirloom + empty off-hand: they'll make a second heirloom → not a candidate")
end

function TestDualWield:test_member_dw_on_2h_1h_drop_worse_skipped()
  -- AUD-301: Frost DK (dual-wield) currently on a NON-heirloom 2H @400 with an
  -- empty off-hand. A weak 1H @100 drops. The empty off-hand is NOT fillable while
  -- a 2H occupies the main hand, so the 1H must be judged STRAIGHT against the 2H
  -- (400) — not min(16, empty 17=0). @100 loses → not a candidate. (The old
  -- dual-min read the empty slot as ilvl 0 and false-positived every 1H.)
  local guid = "Player-0-FrostDK2HNonHeir"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:fdk2h", ilvl = 400, equipLoc = "INVTYPE_2HWEAPON" }
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fdk_1h_weak", ilvl = 100,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "AUD-301: 1H @100 vs a 2H @400 (empty OH not fillable) must NOT be a candidate")
end

function TestDualWield:test_member_dw_on_2h_1h_drop_better_compares_straight()
  -- AUD-301: same Frost DK on a NON-heirloom 2H @400, empty off-hand. A 1H @405
  -- drops → judged straight vs the 2H (400), clears +5 at threshold 1 → candidate,
  -- basis = the 2H slot 16 @400 (NOT the empty off-hand @0).
  local guid = "Player-0-FrostDK2HNonHeir2"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:fdk2h2", ilvl = 400, equipLoc = "INVTYPE_2HWEAPON" }
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fdk_1h_better", ilvl = 405,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "AUD-301: 1H @405 beats the equipped 2H @400 straight")
  lu.assertEquals(captured[1].slotID, 16,
    "compare against the 2H main-hand slot, not the empty off-hand")
  lu.assertEquals(captured[1].ilvl_current, 400,
    "basis is the 2H ilvl (400), not the empty-slot 0")
end

function TestDualWield:test_self_dw_on_2h_1h_drop_not_self_upgrade()
  -- AUD-301 player mirror: local player is Frost DK (dual-wield) on a NON-heirloom
  -- 2H @400 with an empty off-hand. A 1H @100 drops. It must NOT read as a
  -- self-upgrade (empty off-hand is not fillable under a 2H) — else the popup is
  -- wrongly suppressed and a bogus "+N ilvl" line is emitted. Straight vs the 2H
  -- (400), @100 loses.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 251  -- Frost DK (dual-wield)
  _mockUnitClass["player"] = { "Death Knight", "DEATHKNIGHT" }
  local slot16Link = "item:self_fdk_2h"
  _mockItemInfo[slot16Link] = { "TwoHandBlade", nil, 4, 400, nil,
    "Weapon", "Two-Handed Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  _mockIlvl[slot16Link] = 400
  _mockGearLinks["player"] = { [16] = slot16Link }  -- OH empty

  local itemData = { link = "item:self_fdk_1h", ilvl = 100,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 1),
    "AUD-301: 1H @100 under a 2H @400 must not be a self-upgrade (empty OH not fillable)")
end

function TestDualWield:test_member_titans_grip_empty_oh_2h_drop_fills_hand()
  -- AUD-301 regression guard: the straight-vs-2H rule must NOT catch a Titan's
  -- Grip 2H drop. Fury (72) on a NON-heirloom 2H @200 with an EMPTY off-hand: a
  -- 2H @210 drops → TG dual-wields two-handers, so it fills the empty off-hand and
  -- stays eligible (min-vs-empty is correct here). Only true 1H drops are excluded.
  local guid = "Player-0-FuryTGEmptyOH"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 200 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:furytg2h", ilvl = 200, equipLoc = "INVTYPE_2HWEAPON" }
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fury_2h_fill", ilvl = 210,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 1,
                     slotCategory = "weapon", slotIDs = {16, 17},
                     weaponSubID = 1 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured,
    "AUD-301 guard: TG 2H drop fills the empty off-hand → still a candidate")
  lu.assertEquals(captured[1].slotID, 17,
    "TG 2H drop compares against the empty off-hand it fills")
end

function TestDualWield:test_member_dw_on_2h_coldcache_mh_fails_closed()
  -- AUD-301 hardening (M1): a member's main-hand link is present but its type is
  -- unresolved in the cache (equipLoc nil), so is2HEquipped can't confirm the 2H.
  -- With an empty off-hand, fall closed rather than min-vs-0 and false-positive
  -- every 1H. (An OCCUPIED off-hand proves genuine dual-wield and stays safe.)
  local guid = "Player-0-FrostDKColdMH"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:fdk_cold_mh", ilvl = 400, equipLoc = nil }  -- type unresolved
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fdk_1h_cold", ilvl = 405,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "AUD-301/M1: unresolved main-hand type + empty off-hand must fail closed, not min-vs-0")
end

function TestDualWield:test_member_dw_1h_empty_oh_no_2h_still_eligible()
  -- AUD-301 non-interception guard: a genuine dual-wielder with a non-heirloom 1H
  -- in the main hand and an EMPTY off-hand (NO 2H) — the empty hand IS fillable, so
  -- a 1H drop must stay eligible against it (min-vs-empty), NOT get diverted to a
  -- straight main-hand compare. Locks that the 2H-only branch doesn't over-fire.
  local guid = "Player-0-FrostDK1HEmptyOHNoHeir"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200 })  -- 1H MH, OH empty
  _mockUnitLevel["party1"] = 50
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fdk_1h_fill", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured,
    "AUD-301 guard: 1H fills the empty off-hand of a dual-wielder (no 2H) → candidate")
  lu.assertEquals(captured[1].slotID, 17, "compare against the empty off-hand it fills")
end

function TestDualWield:test_self_dw_on_2h_1h_drop_better_is_self_upgrade()
  -- AUD-301 player positive mirror: player Frost DK on a 2H @400, empty off-hand. A
  -- 1H @405 drops → straight vs the 2H (400), clears +5 → IS a self-upgrade (they'd
  -- swap the 2H for the better 1H), so the popup is suppressed for them.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 251
  _mockUnitClass["player"] = { "Death Knight", "DEATHKNIGHT" }
  local slot16Link = "item:self_fdk_2h_pos"
  _mockItemInfo[slot16Link] = { "TwoHandBlade", nil, 4, 400, nil,
    "Weapon", "Two-Handed Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  _mockIlvl[slot16Link] = 400
  _mockGearLinks["player"] = { [16] = slot16Link }  -- OH empty

  local itemData = { link = "item:self_fdk_1h_pos", ilvl = 405,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }

  lu.assertTrue(callIsPlayerUpgrade(itemData, 1),
    "AUD-301: 1H @405 straight-beats the equipped 2H @400 → self-upgrade")
end

function TestDualWield:test_member_outlaw_offhand_dagger_mh_heirloom_empty_oh_skipped()
  -- AUD-305: Outlaw's off-hand accepts a dagger (its main hand does not), so a
  -- dagger drop takes the single-slot hands=="off" path (weaponSlot 17). With an
  -- active heirloom 1H in the MAIN hand and an EMPTY off-hand, a leveler fills the
  -- empty hand with a duplicate scaling heirloom, not this drop — the same doctrine
  -- the dual path already enforces (AUD-001/M2). Comparing the dagger vs the ilvl-0
  -- empty off-hand is a false positive; must skip.
  local guid = "Player-0-OutlawMHHeir"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 200 })  -- OH empty
  _mockUnitLevel["party1"] = 50
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:99310", ilvl = 200, equipLoc = "INVTYPE_WEAPON" }
  _mockHeirloomItemIDs[99310] = true
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_dagger", ilvl = 50,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16, 17},
                     weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "AUD-305: off-hand dagger + MH heirloom + empty OH → duplicate heirloom fills the hand → not a candidate")
end

function TestDualWield:test_member_outlaw_offhand_dagger_empty_oh_no_heirloom_eligible()
  -- AUD-305 non-interception guard: Outlaw with NO heirloom and an EMPTY off-hand.
  -- An off-hand dagger drop fills the empty hand → still eligible vs ilvl 0. The
  -- heirloom skip must not fire when the main hand isn't an active heirloom.
  local guid = "Player-0-OutlawNoHeir"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 200 })  -- OH empty, non-heirloom MH
  _mockUnitLevel["party1"] = 50
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_dagger2", ilvl = 50,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16, 17},
                     weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured,
    "AUD-305: off-hand dagger fills an empty off-hand (no heirloom) → candidate")
  lu.assertEquals(captured[1].slotID, 17, "compare against the empty off-hand it fills")
end

function TestDualWield:test_self_dw_spec_uses_lower_weapon_slot()
  -- Player is Assassination Rogue (dagger-locked, DW): MH 200, OH 100. A dagger
  -- drop ilvl 150 IS a self-upgrade (fills the weaker hand) — popup suppressed.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockGearLinks["player"] = { [16] = "item:pmh", [17] = "item:poh" }
  _mockIlvl["item:pmh"] = 200
  _mockIlvl["item:poh"] = 100

  local itemData = { link = "item:dw_self", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 15 }

  lu.assertTrue(callIsPlayerUpgrade(itemData, 1),
    "1H drop above the player's weaker hand is a self-upgrade for DW specs")
end

function TestDualWield:test_self_non_dw_spec_uses_mainhand_only()
  -- Player is Protection Warrior (73, not DW): MH 200, shield 100.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 73
  _mockUnitClass["player"] = { "Warrior", "WARRIOR" }
  _mockGearLinks["player"] = { [16] = "item:pmh2", [17] = "item:pshield" }
  _mockIlvl["item:pmh2"] = 200
  _mockIlvl["item:pshield"] = 100

  local itemData = { link = "item:dw_self2", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 4,
                     slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 4 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 1),
    "non-DW player compares main-hand only; shield must not make this an upgrade")
end

-- ============================================================
-- TestMultiPrimaryStat (REV-021)
-- In-game verified 2026-06-12 (Tarnished Dawnlit Warglaive, item 258962):
-- C_Item.GetItemStats returns MULTIPLE single-stat keys simultaneously for
-- multi-primary-stat items (ITEM_MOD_AGILITY_SHORT=27 + ITEM_MOD_INTELLECT_SHORT=128).
-- Qualification must use ALL of an item's primary stats (a stat set), not the
-- first match. Hybrid keys (ITEM_MOD_AGI_INT_SHORT etc.) exist in GlobalStrings
-- and are scanned defensively. Stat-less weapons fall back to ilvl-only with
-- conservative inclusion (matching the stat-less trinket decision).
-- ============================================================
TestMultiPrimaryStat = {}

function TestMultiPrimaryStat:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

-- AGI+INT one-hand axe (subID 0 allows SHAMAN/HUNTER/PALADIN among others).
local function mockMultiStatAxe(link)
  mockItem(link, { "Dawnlit Hatchet", nil, 3, 184, nil, "Weapon", "One-Handed Axes", nil, "INVTYPE_WEAPON", nil, nil, 2, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 27, ITEM_MOD_INTELLECT_SHORT = 128 }
end

function TestMultiPrimaryStat:test_prefilter_includes_every_matching_stat_spec()
  -- By-class stat union on a multi-stat (AGI+INT) 1H axe: a class qualifies iff
  -- some spec of it can wield the axe AND matches EITHER stat (set membership,
  -- not first match). Shaman via Elemental(INT), Hunter via Survival(AGI).
  -- Warrior wields the axe but has no AGI/INT spec → excluded (respec can't help).
  local shamanGuid = "Player-0-ElemSham"   -- Shaman has INT specs (Ele/Resto)
  local hunterGuid = "Player-0-BMHunter"   -- Hunter is AGI; Survival wields axes
  local warGuid    = "Player-0-ArmsWar"    -- Warrior is STR-only, wields axes
  mockMemberGear(shamanGuid, "party1", "SHAMAN",  262, { [16] = 100 })
  mockMemberGear(hunterGuid, "party2", "HUNTER",  253, { [16] = 100 })
  mockMemberGear(warGuid,    "party3", "WARRIOR",  71, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:258900"
  mockMultiStatAxe(link)
  local itemData = LIF.ClassifyItem(link, 258900)
  lu.assertNotNil(itemData)

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[shamanGuid],
    "Shaman must qualify for an AGI+INT axe via an INT spec (set membership, not first match)")
  lu.assertNotNil(eval.scanningGuids[hunterGuid],
    "Hunter must qualify for an AGI+INT axe via an AGI spec (Survival wields axes)")
  lu.assertNil(eval.scanningGuids[warGuid],
    "Warrior must NOT qualify for an AGI+INT axe (no Warrior spec is AGI or INT)")
end

function TestMultiPrimaryStat:test_eligibility_accepts_int_spec_for_agi_int_warglaive()
  -- The verified live case: INT-heavy warglaive must be offerable to a
  -- Devourer DH (1480, INT). Warglaives: subID 9, DEMONHUNTER only.
  local guid = "Player-0-Devourer"
  mockMemberGear(guid, "party1", "DEMONHUNTER", 1480, { [16] = 100, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:258962"
  mockItem(link, { "Tarnished Dawnlit Warglaive", nil, 3, 198, nil, "Weapon", "Warglaives", nil, "INVTYPE_WEAPON", nil, nil, 2, 9, 2 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 27, ITEM_MOD_INTELLECT_SHORT = 128 }
  local itemData = LIF.ClassifyItem(link, 258962)
  lu.assertNotNil(itemData)

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured,
    "Devourer (INT) must be eligible for an AGI+INT warglaive")
  lu.assertEquals(captured[1].delta, 98)
end

function TestMultiPrimaryStat:test_self_check_accepts_int_spec_for_agi_int_weapon()
  -- Player is Devourer (1480, INT, dual-wield): AGI+INT warglaive above both
  -- hands IS a self-upgrade — must not be misclassified as AGI-only mismatch.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 1480
  _mockUnitClass["player"] = { "Demon Hunter", "DEMONHUNTER" }
  _mockGearLinks["player"] = { [16] = "item:dmh", [17] = "item:doh" }
  _mockIlvl["item:dmh"] = 100
  _mockIlvl["item:doh"] = 100

  local link = "item:258963"
  mockItem(link, { "Tarnished Dawnlit Warglaive", nil, 3, 198, nil, "Weapon", "Warglaives", nil, "INVTYPE_WEAPON", nil, nil, 2, 9, 2 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 27, ITEM_MOD_INTELLECT_SHORT = 128 }
  local itemData = LIF.ClassifyItem(link, 258963)

  lu.assertTrue(callIsPlayerUpgrade(itemData, 1),
    "AGI+INT weapon above the INT player's weapons is a self-upgrade")
end

function TestMultiPrimaryStat:test_statless_weapon_prefilter_includes_conservatively()
  -- A weapon with NO primary stats must fall back to ilvl-only inclusion,
  -- matching the documented stat-less trinket decision — today the weapon
  -- pre-filter excludes every known-spec member and the item never pops up.
  local guid = "Player-0-AnyHunter"
  mockMemberGear(guid, "party1", "HUNTER", 253, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:258901"
  mockItem(link, { "Statless Blade", nil, 3, 184, nil, "Weapon", "One-Handed Axes", nil, "INVTYPE_WEAPON", nil, nil, 2, 0, 0 })
  _mockItemStats[link] = {}
  local itemData = LIF.ClassifyItem(link, 258901)

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[guid],
    "stat-less weapon must include members conservatively (ilvl-only fallback)")
end

function TestMultiPrimaryStat:test_hybrid_stat_key_parsed_defensively()
  -- Hybrid GlobalStrings keys were not observed in the live dump but exist;
  -- parse them into the stat set if an item ever reports one.
  local guid = "Player-0-ElemSham2"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:258902"
  mockItem(link, { "Hybrid Hatchet", nil, 3, 184, nil, "Weapon", "One-Handed Axes", nil, "INVTYPE_WEAPON", nil, nil, 2, 0, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGI_INT_SHORT = 100 }
  local itemData = LIF.ClassifyItem(link, 258902)

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[guid],
    "INT spec must qualify via the hybrid AGI_INT stat key")
end

-- ============================================================
-- By-class usability+stat prefilter (weapon/offhand). A member is included
-- iff SOME spec of their live class can wield/use the item's subID AND shares
-- a primary stat with it (statless → usability alone). Respec-proof: uses the
-- live class, never cached member.specID. Exact spec confirmed post-inspect.
-- ============================================================

function TestMultiPrimaryStat:test_weapon_prefilter_excludes_class_that_cannot_wield()
  -- A bow (Hunter-only, subID 2) drops. A Rogue shares the bow's AGI stat but
  -- no Rogue spec can wield a bow, so the Rogue must be excluded from the
  -- prefilter (no wasted inspection). The Hunter must be included.
  local hunterGuid = "Player-0-BowHunter"
  local rogueGuid  = "Player-0-BowRogue"
  mockMemberGear(hunterGuid, "party1", "HUNTER", 253, { [16] = 100 })  -- BM, AGI
  mockMemberGear(rogueGuid,  "party2", "ROGUE",  260, { [16] = 100 })  -- Outlaw, AGI
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:agi_bow_prefilter"
  mockItem(link, { "Dawnlit Bow", nil, 3, 184, nil, "Weapon", "Bows", nil, "INVTYPE_RANGED", nil, nil, 2, 2, 0 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 100 }
  local itemData = LIF.ClassifyItem(link, 900001)

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[hunterGuid], "Hunter must be included for a bow (can wield)")
  lu.assertNil(eval.scanningGuids[rogueGuid],
    "Rogue must be EXCLUDED for a bow (no Rogue spec can wield bows, despite AGI match)")
end

function TestMultiPrimaryStat:test_weapon_prefilter_includes_class_via_offspec_stat()
  -- An INT 1H mace drops. The member is a Ret Paladin (STR) right now, but
  -- Paladins can wield maces and Holy (INT) could use it, so the by-class
  -- prefilter must include them (confirmed precisely after inspect).
  local palaGuid = "Player-0-RetPalaMace"
  mockMemberGear(palaGuid, "party1", "PALADIN", 70, { [16] = 100 })  -- Ret, STR
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:int_mace_prefilter"
  mockItem(link, { "Dawnlit Mace", nil, 3, 184, nil, "Weapon", "One-Handed Maces", nil, "INVTYPE_WEAPON", nil, nil, 2, 4, 0 })
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 100 }
  local itemData = LIF.ClassifyItem(link, 900002)

  local eval = callEvaluate(itemData, 1)
  lu.assertNotNil(eval.scanningGuids[palaGuid],
    "Paladin must be included for an INT mace (Holy could wield it), despite current STR spec")
end

function TestMultiPrimaryStat:test_weapon_prefilter_excludes_class_with_no_matching_stat_spec()
  -- Same INT 1H mace. An Arms Warrior can wield maces, but NO Warrior spec is
  -- INT, so no respec could ever make an INT weapon useful — the Warrior must
  -- be excluded (guards against a pure-usability prefilter that ignores stat).
  local warGuid = "Player-0-ArmsWarMace"
  mockMemberGear(warGuid, "party1", "WARRIOR", 71, { [16] = 100 })  -- Arms, STR
  _mockGuids["player"] = "GUID-SELF"

  local link = "item:int_mace_prefilter2"
  mockItem(link, { "Dawnlit Mace", nil, 3, 184, nil, "Weapon", "One-Handed Maces", nil, "INVTYPE_WEAPON", nil, nil, 2, 4, 0 })
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 100 }
  local itemData = LIF.ClassifyItem(link, 900003)

  local eval = callEvaluate(itemData, 1)
  lu.assertNil(eval.scanningGuids[warGuid],
    "Warrior must be EXCLUDED for an INT mace (no Warrior spec is INT, respec cannot help)")
end

-- ============================================================
-- TestHunterWeaponType
-- Beast Mastery (253) and Marksmanship (254) are non-functional with melee
-- weapons; Survival (255) is non-functional with ranged weapons (bow=2,
-- gun=3, crossbow=18). The ranged/melee split is encoded directly in each
-- Hunter spec's mainHand set in LIF.SPEC_TABLE (BM/MM = {2,3,18}, Survival =
-- melee subIDs). See core/character_data.lua.
-- ============================================================
TestHunterWeaponType = {}

function TestHunterWeaponType:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

function TestHunterWeaponType:test_bm_hunter_eligible_for_bow()
  local guid = "Player-0-BMBow"
  mockMemberGear(guid, "party1", "HUNTER", 253, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:bm_bow", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 2,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 2 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "Beast Mastery must be eligible for a bow upgrade")
end

function TestHunterWeaponType:test_survival_hunter_ineligible_for_bow()
  local guid = "Player-0-SurvBow"
  mockMemberGear(guid, "party1", "HUNTER", 255, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:surv_bow", ilvl = 500,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 2,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 2 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "Survival must NOT be eligible for a bow, even with a huge ilvl delta")
end

function TestHunterWeaponType:test_survival_hunter_eligible_for_polearm()
  local guid = "Player-0-SurvPolearm"
  mockMemberGear(guid, "party1", "HUNTER", 255, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:surv_polearm", ilvl = 150,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 6,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 6 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "Survival must be eligible for a polearm upgrade")
end

function TestHunterWeaponType:test_bm_hunter_ineligible_for_polearm()
  local guid = "Player-0-BMPolearm"
  mockMemberGear(guid, "party1", "HUNTER", 253, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:bm_polearm", ilvl = 500,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 6,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 6 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "Beast Mastery must NOT be eligible for a polearm, even with a huge ilvl delta")
end

function TestHunterWeaponType:test_self_survival_hunter_bow_not_upgrade()
  -- Player is Survival (255) with a weak bow equipped; a much better bow
  -- drops. Must NOT read as a self-upgrade — Survival can't use it at all.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 255
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:surv_self_bow_current" }
  _mockIlvl["item:surv_self_bow_current"] = 50

  local itemData = { link = "item:surv_self_bow_drop", ilvl = 500,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 2,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 2 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 1),
    "Bow drop must not read as a self-upgrade for Survival, regardless of ilvl delta")
end

function TestHunterWeaponType:test_self_bm_hunter_polearm_not_upgrade()
  -- Player is Beast Mastery (253) with a weak polearm equipped (e.g. for
  -- transmog); a much better polearm drops. Must NOT read as a self-upgrade.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 253
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:bm_self_polearm_current" }
  _mockIlvl["item:bm_self_polearm_current"] = 50

  local itemData = { link = "item:bm_self_polearm_drop", ilvl = 500,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 6,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 6 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 1),
    "Polearm drop must not read as a self-upgrade for Beast Mastery, regardless of ilvl delta")
end

function TestHunterWeaponType:test_survival_hunter_ineligible_for_fist_weapon()
  -- Fist Weapons (subID 13) are Hunter class-proficient, but Survival's
  -- abilities don't function with them — a known Blizzard quirk, confirmed
  -- via Blizzard forums bug reports. Must be excluded despite not being a
  -- ranged weapon.
  local guid = "Player-0-SurvFist"
  mockMemberGear(guid, "party1", "HUNTER", 255, { [16] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:surv_fist", ilvl = 500,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 13,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 13 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNil(captured,
    "Survival must NOT be eligible for a Fist Weapon, even with a huge ilvl delta")
end

function TestHunterWeaponType:test_self_survival_hunter_fist_weapon_not_upgrade()
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 255
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:surv_self_fist_current" }
  _mockIlvl["item:surv_self_fist_current"] = 50

  local itemData = { link = "item:surv_self_fist_drop", ilvl = 500,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 13,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 13 }

  lu.assertFalse(callIsPlayerUpgrade(itemData, 1),
    "Fist Weapon drop must not read as a self-upgrade for Survival, regardless of ilvl delta")
end

function TestHunterWeaponType:test_survival_hunter_offhand_weapon_eligible()
  -- Survival is a valid dual-wield spec (current PvE guides: dual-wield is
  -- the optimal Survival playstyle). An off-hand weapon must be eligible,
  -- same as any other dual-wield spec.
  local guid = "Player-0-SurvOH"
  mockMemberGear(guid, "party1", "HUNTER", 255, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:surv_oh_dagger", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPONOFFHAND", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {17}, weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "Survival must be eligible for off-hand weapons (valid dual-wield spec)")
  lu.assertEquals(captured[1].ilvl_current, 100)
end

function TestHunterWeaponType:test_survival_hunter_1h_weapon_compares_lower_slot()
  local guid = "Player-0-SurvDW"
  mockMemberGear(guid, "party1", "HUNTER", 255, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:surv_dw_dagger", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "1H drop above Survival's weaker hand must be eligible")
  lu.assertEquals(captured[1].ilvl_current, 100)
  lu.assertEquals(captured[1].delta, 50)
  lu.assertEquals(captured[1].slotID, 17)
end

function TestHunterWeaponType:test_self_survival_hunter_1h_weapon_uses_lower_slot()
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 255
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:surv_self_mh", [17] = "item:surv_self_oh" }
  _mockIlvl["item:surv_self_mh"] = 200
  _mockIlvl["item:surv_self_oh"] = 100

  local itemData = { link = "item:surv_self_dw_drop", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 15 }

  lu.assertTrue(callIsPlayerUpgrade(itemData, 1),
    "1H drop above the weaker hand is a self-upgrade for dual-wield Survival")
end

-- ============================================================
-- TestWarboundUntilEquipped (REV-023)
-- "Warbound until equipped" items report bindType=2 — identical to tradeable
-- BoE (in-game verified 2026-06-13: WuE bow 264911 AND BoE longbow both
-- dump bindType 2). The discriminator is C_Item.IsItemBindToAccountUntilEquip
-- (link-accepting; verified true for WuE, false for BoE). WuE items cannot be
-- traded to other players in ANY context → skip unconditionally.
-- ============================================================
TestWarboundUntilEquipped = {}

function TestWarboundUntilEquipped:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.IsItemTradeable = mockIsItemTradeable
end

-- Shared fixture: an AGI bow that is NOT a self-upgrade for the player.
local function setupWuEBowDrop(link)
  mockItem(link, { "Forest Hunter's Arc", nil, 3, 220, nil, "Weapon", "Bows", nil, "INVTYPE_RANGED", nil, nil, 2, 2, 2 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 65 }
  -- Player: BM Hunter with a better weapon so the drop is not a self-upgrade.
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:player_bow" }
  _mockIlvl["item:player_bow"] = 240
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 253
  -- Hunter party member who WOULD be eligible if the item were tradeable.
  mockMemberGear("Player-0-WuEHunter", "party1", "HUNTER", 253, { [16] = 150 })
end

function TestWarboundUntilEquipped:test_wue_item_skipped_in_open_world()
  _mockIsInInstance = { false, "none" }
  local link = "item:264911"
  setupWuEBowDrop(link)
  -- WuE items have no trade timer → mark as non-tradeable in mock.
  _mockNonTradeableItems[264911] = true

  LIF.OnPlayerLootReceived(link, 264911)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → IsItemTradeable false → skip
  lu.assertEquals(#LIF.pendingLootItems, 0,
    "warbound-until-equipped item must be skipped (no trade timer) despite bindType=2")
end

function TestWarboundUntilEquipped:test_wue_item_skipped_in_dungeon()
  _mockIsInInstance = { true, "party" }
  local link = "item:264912"
  setupWuEBowDrop(link)
  _mockNonTradeableItems[264912] = true

  LIF.OnPlayerLootReceived(link, 264912)
  FirePendingAfterCallbacks()
  lu.assertEquals(#LIF.pendingLootItems, 0,
    "WuE skip is unconditional — dungeon context does not make warbound items tradeable")
end

function TestWarboundUntilEquipped:test_account_bound_enum_values_skipped()
  -- Account-bound items (bindType=7/8/9) have no trade timer and are never player-tradeable.
  _mockIsInInstance = { false, "none" }
  local link = "item:264914"
  mockItem(link, { "Account Bow", nil, 3, 220, nil, "Weapon", "Bows", nil, "INVTYPE_RANGED", nil, nil, 2, 2, 7 })
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 65 }
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Hunter", "HUNTER" }
  _mockGearLinks["player"] = { [16] = "item:player_bow2" }
  _mockIlvl["item:player_bow2"] = 240
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 253
  mockMemberGear("Player-0-AcctHunter", "party1", "HUNTER", 253, { [16] = 150 })
  _mockNonTradeableItems[264914] = true

  LIF.OnPlayerLootReceived(link, 264914)
  FirePendingAfterCallbacks()
  lu.assertEquals(#LIF.pendingLootItems, 0,
    "Account-bound (bindType=7) items have no trade timer and must be skipped")
end

function TestWarboundUntilEquipped:test_boe_item_with_same_bindtype_still_processed()
  _mockIsInInstance = { false, "none" }
  local link = "item:264913"
  setupWuEBowDrop(link)  -- bindType 2, NOT warbound — a real tradeable BoE
  -- _mockNonTradeableItems[264913] not set → IsItemTradeable returns true

  LIF.OnPlayerLootReceived(link, 264913)
  FirePendingAfterCallbacks()  -- fires 0-frame defer → tradeable → entry added
  lu.assertEquals(#LIF.pendingLootItems, 1,
    "tradeable BoE (bindType=2, not WuE) must still be evaluated")
end

-- ============================================================
-- TestChatNotifications: chat output for loot scan results
-- Covers: self-upgrade in group, self-upgrade solo, party candidates,
-- no candidates, and no-party gate (hadPartyMembers=false).
-- ============================================================
TestChatNotifications = {}

-- Returns true if any _chatMessages entry contains substr (plain string match).
local function hasChatMsg(substr)
  for _, msg in ipairs(_chatMessages) do
    if msg:find(substr, 1, true) then return true end
  end
  return false
end

function TestChatNotifications:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
  LIF.IsItemTradeable = mockIsItemTradeable
  -- LootItForward = nil → LIF.Log "info" failsafe: show=true (Pitfall 3)
end

function TestChatNotifications:test_self_upgrade_in_group_emits_notif()
  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end
  _mockIsInInstance  = { true, "party" }
  _mockIsInGroup     = true
  -- _mockGroupSize = 5 (default) → GetNumGroupMembers() > 0 → gate passes

  local link = "item:cn_su_chest"
  mockItem(link, { "Chest of Test", nil, 4, 500, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"]           = "GUID-SELF"
  _mockUnitClass["player"]       = { "Rogue", "ROGUE" }
  _mockGearLinks["player"]       = { [5] = "item:cn_player_chest" }
  _mockIlvl["item:cn_player_chest"] = 460
  _mockGetSpecialization         = 1
  _mockSpecializationInfo[1]     = 259  -- Assassination Rogue (AGI)

  LIF.OnPlayerLootReceived(link, 88801)

  lu.assertTrue(hasChatMsg("upgrade for you"),
    "Self-upgrade in group must emit 'upgrade for you' notification")
  lu.assertTrue(hasChatMsg("+40 ilvl"),
    "Notification must include exact ilvl delta (+40 = 500-460)")
end

function TestChatNotifications:test_self_upgrade_solo_no_notif()
  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end
  _mockIsInInstance  = { true, "party" }
  _mockIsInGroup     = true
  _mockGroupSize     = 0  -- GetNumGroupMembers()=0 → notification gate fails

  local link = "item:cn_su_chest_solo"
  mockItem(link, { "Solo Chest", nil, 4, 500, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"]                = "GUID-SELF"
  _mockUnitClass["player"]            = { "Rogue", "ROGUE" }
  _mockGearLinks["player"]            = { [5] = "item:cn_player_solo_chest" }
  _mockIlvl["item:cn_player_solo_chest"] = 460
  _mockGetSpecialization              = 1
  _mockSpecializationInfo[1]          = 259

  LIF.OnPlayerLootReceived(link, 88802)

  lu.assertFalse(hasChatMsg("upgrade for you"),
    "Self-upgrade with GetNumGroupMembers()=0 must NOT emit notification")
end

function TestChatNotifications:test_party_eligible_emits_item_and_member_lines()
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local druidGuid = "Player-0-ChatDruid"
  mockMemberGear(druidGuid, "party1", "DRUID", 103, { [5] = 200 })
  -- specName is stored by queue.lua's inspect path; mockMemberGear bypasses that — patch it
  LIF.Cache.GetMember(druidGuid).specName = "Balance"
  _mockUnitNames["party1"] = "Leafcaller"
  _mockGuids["player"]     = "GUID-SELF"

  local itemData = {
    link         = "item:cn_notif_chest",
    name         = "Chest of Green",
    ilvl         = 300,
    equipLoc     = "INVTYPE_CHEST",
    slotIDs      = {5},
    slotCategory = "armor",
    armorType    = "Leather",
    itype        = "Armor",
    subtype      = "Leather",
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [druidGuid] = true },
    popupOpened         = false,
    hadPartyMembers     = true,
    chatNotifEmitted    = false,
  })

  LIF.OnLootInspectReady(druidGuid)

  -- No redundant "not an upgrade for you" header — the drop-time line already
  -- announced the item; resolution reports the per-member outcome only.
  lu.assertFalse(hasChatMsg("not an upgrade for you"),
    "Resolution summary must NOT repeat the drop-time 'not an upgrade for you' header")
  -- Member line: "  Leafcaller (Balance Druid): armor +100 (200→300)"
  lu.assertTrue(hasChatMsg("Leafcaller"),
    "Notification must include party member name")
  lu.assertTrue(hasChatMsg("Balance Druid"),
    "Notification must show 'Spec Class' format (specName + CLASS_SHORT)")
  lu.assertTrue(hasChatMsg("armor +100"),
    "Notification must include slot category and delta (300-200=100)")
  lu.assertTrue(hasChatMsg("(200→300)"),
    "Notification must include ilvl progression (curr→drop)")
end

function TestChatNotifications:test_party_no_candidates_emits_no_upgrades_line()
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  -- Warrior cannot wear Leather → _checkMemberEligibility returns false → no candidates
  local warriorGuid = "Player-0-ChatWarrior"
  mockMemberGear(warriorGuid, "party1", "WARRIOR", 72, { [5] = 200 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = {
    link         = "item:cn_notif_helm",
    name         = "Helm of Quiet",
    ilvl         = 300,
    equipLoc     = "INVTYPE_HEAD",
    slotIDs      = {1},
    slotCategory = "armor",
    armorType    = "Leather",
    itype        = "Armor",
    subtype      = "Leather",
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [warriorGuid] = true },
    popupOpened         = false,
    hadPartyMembers     = true,
    chatNotifEmitted    = false,
  })

  LIF.OnLootInspectReady(warriorGuid)

  lu.assertTrue(hasChatMsg("Helm of Quiet — no party upgrades found"),
    "Must emit an item-named 'no party upgrades found' line when all members are ineligible")
  lu.assertFalse(hasChatMsg("not an upgrade for you"),
    "Resolution summary must NOT repeat the drop-time header")
end

function TestChatNotifications:test_drop_line_plural_candidate_count()
  if LIF.OnPlayerLootReceived == nil then lu.skip("not yet implemented") end
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"]     = "GUID-SELF"
  _mockUnitClass["player"] = { "Warrior", "WARRIOR" }  -- plate → leather chest is not a self-upgrade
  mockMemberGear("Player-0-Cd1", "party1", "DRUID", 103, { [5] = 200 })
  mockMemberGear("Player-0-Cd2", "party2", "ROGUE", 260, { [5] = 200 })

  local link = "item:cd_plural_chest"
  mockItem(link, { "Verdant Vest", nil, 4, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  LIF.OnPlayerLootReceived(link, 88810)
  FirePendingAfterCallbacks()

  lu.assertTrue(hasChatMsg("Verdant Vest dropped — 2 possible candidates. Inspecting..."),
    "Drop line must announce the item and PLURAL candidate count with 'Inspecting...'")
end

function TestChatNotifications:test_drop_line_singular_candidate_count()
  if LIF.OnPlayerLootReceived == nil then lu.skip("not yet implemented") end
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"]     = "GUID-SELF"
  _mockUnitClass["player"] = { "Warrior", "WARRIOR" }
  mockMemberGear("Player-0-Cd3", "party1", "DRUID", 103, { [5] = 200 })

  local link = "item:cd_singular_chest"
  mockItem(link, { "Lone Leather", nil, 4, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  LIF.OnPlayerLootReceived(link, 88811)
  FirePendingAfterCallbacks()

  lu.assertTrue(hasChatMsg("Lone Leather dropped — 1 possible candidate. Inspecting..."),
    "Drop line must use SINGULAR 'candidate' for exactly one")
  lu.assertFalse(hasChatMsg("1 possible candidates"),
    "Must not use the plural form for a single candidate")
end

function TestChatNotifications:test_drop_line_zero_candidates_no_inspecting()
  if LIF.OnPlayerLootReceived == nil then lu.skip("not yet implemented") end
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGuids["player"]     = "GUID-SELF"
  _mockUnitClass["player"] = { "Druid", "DRUID" }  -- leather → plate chest not a self-upgrade
  mockMemberGear("Player-0-Cd4", "party1", "DRUID", 103, { [5] = 200 })  -- druid can't wear plate

  local link = "item:cd_zero_chest"
  mockItem(link, { "Plate Wall", nil, 4, 300, nil, "Armor", "Plate", nil, "INVTYPE_CHEST", nil, nil, 4, 4, 0 })

  LIF.OnPlayerLootReceived(link, 88812)
  FirePendingAfterCallbacks()

  lu.assertTrue(hasChatMsg("Plate Wall dropped — 0 possible candidates."),
    "Drop line must fire with zero count")
  lu.assertFalse(hasChatMsg("Inspecting"),
    "'Inspecting...' must NOT be appended when there are no candidates")
end

function TestChatNotifications:test_no_party_at_loot_time_no_notif()
  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true
  _mockGroupSize    = 5
  _mockGuids["player"]     = "GUID-SELF"
  -- Neck at same ilvl as drop → delta 0 < threshold 1 → NOT self-upgrade → enters pipeline
  _mockGearLinks["player"] = { [2] = "item:cn_player_neck" }
  _mockIlvl["item:cn_player_neck"] = 470

  local link = "item:cn_no_party_neck"
  mockItem(link, { "Neck of Absence", nil, 4, 470, nil, "Armor", "Miscellaneous", nil, "INVTYPE_NECK", nil, nil, 4, 0, 0 })

  -- Cache is empty (setUp called Cache.Clear()) → EvaluateCandidates returns scanningGuids={}
  LIF.OnPlayerLootReceived(link, 88805)
  -- Fire 0-frame tradeability defer → IsItemTradeable true → entry added, 4s timer queued.
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 1,
    "Precondition: pending entry must be created")
  lu.assertFalse(LIF.pendingLootItems[1].hadPartyMembers,
    "Precondition: hadPartyMembers must be false when no cache members")

  -- The drop-time line still fires (0 possible candidates) — it announces that LIF
  -- saw the drop. Fire the window timer → _tryOpenPopup → the RESOLUTION summary
  -- ("no party upgrades found" / member lines) must NOT fire (gated on hadPartyMembers).
  lu.assertTrue(hasChatMsg("Neck of Absence dropped — 0 possible candidates."),
    "Drop line fires even with no candidates")
  FirePendingAfterCallbacks()

  lu.assertFalse(hasChatMsg("no party upgrades found"),
    "Resolution summary must NOT fire when hadPartyMembers=false (no party members at loot time)")
end

-- ============================================================
-- TestIsItemTradeable: unit tests for the real tooltip-scan implementation.
-- These restore the real LIF.IsItemTradeable (not the mock override) and drive
-- it via _mockContainerItems + _mockScanTooltipLines.
-- ============================================================
TestIsItemTradeable = {}

function TestIsItemTradeable:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.pendingLootItems = {}
  -- Use the real implementation (not the pipeline mock).
  LIF.IsItemTradeable = _realIsItemTradeable
end

function TestIsItemTradeable:tearDown()
  -- Restore the mock so subsequent test classes use it.
  LIF.IsItemTradeable = mockIsItemTradeable
end

function TestIsItemTradeable:test_item_in_bag_with_trade_timer_returns_true()
  -- Item 12345 in bag 0 slot 1 with a trade-timer tooltip line → tradeable.
  local hyperlink = "item:12345::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = hyperlink } }
  _mockScanTooltipLines[hyperlink] = {
    "Chest of Test",
    "Soulbound",
    string.format(BIND_TRADE_TIME_REMAINING, "1 hour"),
  }

  lu.assertTrue(LIF.IsItemTradeable("item:12345::::::::::0", 12345),
    "Item with trade-timer tooltip line must be tradeable")
end

function TestIsItemTradeable:test_item_in_bag_no_trade_timer_returns_false()
  -- Item in bags but tooltip has no BIND_TRADE_TIME_REMAINING line → not tradeable.
  local hyperlink = "item:99999::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = hyperlink } }
  _mockScanTooltipLines[hyperlink] = {
    "Chest of Bind",
    "Soulbound",
  }

  lu.assertFalse(LIF.IsItemTradeable("item:99999::::::::::0", 99999),
    "Item in bags without trade-timer line must not be tradeable")
end

function TestIsItemTradeable:test_item_not_in_bags_returns_false()
  -- Bags are empty → item not found → not tradeable.
  lu.assertFalse(LIF.IsItemTradeable("item:77777::::::::::0", 77777),
    "Item not found in any bag must not be tradeable")
end

function TestIsItemTradeable:test_count_tradeable_slots_two_copies()
  -- AUD-310: two tradeable copies of the same itemID (D-03 stacked drop). Presence
  -- alone can't tell a completed trade of one copy from a cancel; the COUNT can.
  local link = "item:55501::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = link }, [2] = { hyperlink = link } }
  _mockScanTooltipLines[link] = {
    "Duplicate Drop", "Soulbound", string.format(BIND_TRADE_TIME_REMAINING, "2 hours"),
  }
  lu.assertEquals(LIF.CountTradeableSlots(55501), 2,
    "both tradeable copies of the same itemID must be counted")
end

function TestIsItemTradeable:test_count_tradeable_slots_ignores_untimed_copy()
  -- One tradeable copy + one owned (no timer) copy of the same itemID → count 1.
  local timed   = "item:55502::::::::::0"
  local untimed = "item:55502::::::::::1"   -- same itemID, different instance, no timer
  _mockContainerItems[0] = { [1] = { hyperlink = timed }, [2] = { hyperlink = untimed } }
  _mockScanTooltipLines[timed]   = { "Fresh", "Soulbound", string.format(BIND_TRADE_TIME_REMAINING, "2 hours") }
  _mockScanTooltipLines[untimed] = { "Owned", "Soulbound" }
  lu.assertEquals(LIF.CountTradeableSlots(55502), 1,
    "only the copy with an active trade timer is counted")
end

function TestIsItemTradeable:test_count_tradeable_slots_none()
  lu.assertEquals(LIF.CountTradeableSlots(55503), 0,
    "no tradeable copies in bags → 0")
end

function TestIsItemTradeable:test_count_item_in_bags_ignores_timers()
  -- AUD-402: plain copy count regardless of trade timer — used to detect an untimed
  -- BoE trade's completion by decrease. Two copies (one timered, one not) → 2.
  local timed   = "item:56001::::::::::0"
  local untimed = "item:56001::::::::::1"
  _mockContainerItems[0] = { [1] = { hyperlink = timed }, [2] = { hyperlink = untimed } }
  _mockScanTooltipLines[timed] = { "Fresh", string.format(BIND_TRADE_TIME_REMAINING, "2 hours") }
  lu.assertEquals(LIF.CountItemInBags(56001), 2,
    "counts every copy of the itemID, timered or not")
end

function TestIsItemTradeable:test_count_item_in_bags_none()
  lu.assertEquals(LIF.CountItemInBags(56002), 0,
    "no copies in bags → 0")
end

function TestIsItemTradeable:test_count_item_in_bags_decrease_detects_trade()
  -- The completion signal for an untimed BoE: baseline before, one fewer after.
  local link = "item:56003::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = link } }
  local baseline = LIF.CountItemInBags(56003)
  lu.assertEquals(baseline, 1)
  _mockContainerItems[0] = {}  -- item left the bags (traded)
  lu.assertTrue(LIF.CountItemInBags(56003) < baseline, "a traded copy decreases the count")
end

function TestIsItemTradeable:test_quest_bound_item_not_tradeable()
  -- bindType 4 (Quest) is definitively untradeable — the fast-path must skip
  -- it, never fall through the "not BoP → tradeable" branch. No bag copy set:
  -- if the bindType skip fails, the tooltip scan finds nothing and this would
  -- only accidentally pass, so assert directly against the bindType branch.
  local link = "item:33333::::::::::0"
  mockItem(link, { "Quest Relic", nil, 3, 200, nil, "Armor", "Plate", nil, "INVTYPE_CHEST", nil, nil, 4, 0, 4 })
  lu.assertFalse(LIF.IsItemTradeable(link, 33333),
    "Quest-bound (bindType 4) items are never player-tradeable")
end

function TestIsItemTradeable:test_on_use_bound_item_stays_tradeable()
  -- Boundary guard for the quest-bound fix: bindType 3 (Bind-on-Use) is
  -- tradeable while unbound, exactly like BoE — the fix must skip only 4.
  local link = "item:33334::::::::::0"
  mockItem(link, { "On-Use Cloak", nil, 3, 200, nil, "Armor", "Cloth", nil, "INVTYPE_CLOAK", nil, nil, 4, 1, 3 })
  lu.assertTrue(LIF.IsItemTradeable(link, 33334),
    "Bind-on-Use (bindType 3) items are tradeable while unbound")
end

function TestIsItemTradeable:test_item_found_in_later_bag_slot()
  -- Item 55555 is in bag 2 slot 3 (not bag 0 slot 1).
  local hyperlink = "item:55555::::::::::0"
  _mockContainerItems[2] = { [3] = { hyperlink = hyperlink } }
  _mockScanTooltipLines[hyperlink] = {
    "Late Bag Chest",
    string.format(BIND_TRADE_TIME_REMAINING, "30 min"),
  }

  lu.assertTrue(LIF.IsItemTradeable("item:55555::::::::::0", 55555),
    "IsItemTradeable must scan all bags and slots, not just bag 0 slot 1")
end

function TestIsItemTradeable:test_fresh_copy_scanned_when_old_copy_present()
  -- Old copy in bag 0 (no trade timer); fresh drop in bag 1 (has timer).
  -- Different hyperlinks (different bonus IDs) but same extracted itemID.
  -- The scan must not stop at the first slot with no timer.
  local oldLink = "item:12345:0:0:0:0:0:0:0:0"
  local newLink = "item:12345:1:0:0:0:0:0:0:0"
  _mockContainerItems[0] = { [1] = { hyperlink = oldLink } }
  _mockScanTooltipLines[oldLink] = { "Forest Hunter's Arc", "Soulbound" }
  _mockContainerItems[1] = { [1] = { hyperlink = newLink } }
  _mockScanTooltipLines[newLink] = {
    "Forest Hunter's Arc",
    "Soulbound",
    string.format(BIND_TRADE_TIME_REMAINING, "2 hours"),
  }
  lu.assertTrue(LIF.IsItemTradeable("item:12345:1:0:0:0:0:0:0:0", 12345),
    "fresh copy with trade timer must be found even if old copy in earlier bag has none")
end

-- FindTradeableSlot: returns (bag, slot) of the tradeable copy, not just the first slot.
function TestIsItemTradeable:test_find_tradeable_slot_returns_coordinates()
  local oldLink = "item:77777:0:0:0:0:0:0:0:0"
  local newLink = "item:77777:1:0:0:0:0:0:0:0"
  _mockContainerItems[0] = { [1] = { hyperlink = oldLink } }
  _mockScanTooltipLines[oldLink] = { "Some Helmet", "Soulbound" }
  _mockContainerItems[1] = { [2] = { hyperlink = newLink } }
  _mockScanTooltipLines[newLink] = {
    "Some Helmet",
    string.format(BIND_TRADE_TIME_REMAINING, "1 hour"),
  }
  local bag, slot = LIF.FindTradeableSlot(77777)
  lu.assertEquals(bag,  1, "tradeable copy is in bag 1")
  lu.assertEquals(slot, 2, "tradeable copy is in slot 2")
end

function TestIsItemTradeable:test_find_tradeable_slot_returns_nil_when_no_timer()
  local hyperlink = "item:88888::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = hyperlink } }
  _mockScanTooltipLines[hyperlink] = { "Old Chestpiece", "Soulbound" }
  local bag, slot = LIF.FindTradeableSlot(88888)
  lu.assertNil(bag,  "no tradeable copy → bag should be nil")
  lu.assertNil(slot, "no tradeable copy → slot should be nil")
end

-- FindItemInBags: simple first-slot scan, no tooltip check.
function TestIsItemTradeable:test_find_item_in_bags_returns_first_slot()
  _mockContainerItems[2] = { [3] = { hyperlink = "item:44444::::::::::0" } }
  local bag, slot = LIF.FindItemInBags(44444)
  lu.assertEquals(bag,  2, "item is in bag 2")
  lu.assertEquals(slot, 3, "item is in slot 3")
end

function TestIsItemTradeable:test_find_item_in_bags_returns_nil_when_absent()
  local bag, slot = LIF.FindItemInBags(99999)
  lu.assertNil(bag,  "absent item → bag should be nil")
  lu.assertNil(slot, "absent item → slot should be nil")
end

-- BoE / WuE / account-bound: bindType fast path, no tooltip scan.
function TestIsItemTradeable:test_boe_item_is_tradeable_without_tooltip_scan()
  local link = "item:10001::::::::::0"
  _mockItemInfo[link] = { [14] = 2 }  -- BoE
  -- No container or tooltip setup — scan must not be reached.
  lu.assertTrue(LIF.IsItemTradeable(link, 10001),
    "BoE item must be tradeable without tooltip scan")
end

function TestIsItemTradeable:test_wue_item_is_not_tradeable()
  local link = "item:10002::::::::::0"
  _mockItemInfo[link] = { [14] = 2 }  -- bindType 2, looks BoE
  _mockWuEItems[link] = true
  lu.assertFalse(LIF.IsItemTradeable(link, 10002),
    "WuE item must not be tradeable")
end

function TestIsItemTradeable:test_account_bound_item_is_not_tradeable()
  local link = "item:10003::::::::::0"
  _mockItemInfo[link] = { [14] = 7 }  -- bindType 7 (Warbound)
  lu.assertFalse(LIF.IsItemTradeable(link, 10003),
    "account-bound (bindType 7) item must not be tradeable")
end

-- Locale anchor: %s at start → fall back to suffix anchor.
function TestIsItemTradeable:test_suffix_only_locale_matches_trade_timer()
  local saved = BIND_TRADE_TIME_REMAINING
  BIND_TRADE_TIME_REMAINING = "%s remaining to trade this item."
  local hyperlink = "item:11111::::::::::0"
  _mockContainerItems[0] = { [1] = { hyperlink = hyperlink } }
  _mockScanTooltipLines[hyperlink] = { "Some Sword", "2 hours remaining to trade this item." }
  lu.assertTrue(LIF.IsItemTradeable("item:11111::::::::::0", 11111),
    "locale with %%s at start must match via suffix anchor")
  BIND_TRADE_TIME_REMAINING = saved
end

-- Locale anchor: no discriminating text → assert (broken environment).
function TestIsItemTradeable:test_undiscriminable_locale_throws()
  local saved = BIND_TRADE_TIME_REMAINING
  BIND_TRADE_TIME_REMAINING = "%s"
  lu.assertError(function() LIF.IsItemTradeable("item:22222::::::::::0", 22222) end)
  BIND_TRADE_TIME_REMAINING = saved
end

function TestIsItemTradeable:test_missing_wue_api_fails_loud()
  -- Fail-loud, not fail-open: C_Item.IsItemBindToAccountUntilEquip has existed
  -- since 11.0 on every supported client, so its absence is a structural
  -- break, not a runtime condition. Silently falling through would treat an
  -- untradeable WuE item as tradeable (fail-open) — assert instead, matching
  -- the C_Container/anchor asserts already in this function.
  local link = "item:990020"
  mockItem(link, { "Old-Client Item", nil, 3, 200, nil, "Armor", "Cloth", nil,
    "INVTYPE_CHEST", nil, nil, 4, 2, 2 })
  local saved = C_Item.IsItemBindToAccountUntilEquip
  C_Item.IsItemBindToAccountUntilEquip = nil
  local ok = pcall(LIF.IsItemTradeable, link, 990020)
  C_Item.IsItemBindToAccountUntilEquip = saved
  lu.assertFalse(ok,
    "IsItemTradeable must fail loud when C_Item.IsItemBindToAccountUntilEquip is unavailable")
end

-- ============================================================
-- TestSpecFormFinal
-- Spec-form data-validation pass (Midnight 12.0.x). Each per-spec mainHand /
-- offHandWeapon / offHandItem set was validated against authoritative sources
-- (warcraft.wiki.gg proficiency matrix + current spec mechanics), replacing the
-- mechanically-derived class-level baseline. Every test pins one concrete spec
-- fact so a future edit that regresses it fails loudly. Drops are statless, so
-- only weapon/off-hand usability + ilvl decide eligibility. Members carry both
-- weapon slots at ilvl 100; the ilvl-150 drop clears the +1 threshold whenever
-- the spec can actually use it.
-- ============================================================
TestSpecFormFinal = {}

function TestSpecFormFinal:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

-- Statless weapon drop for subID / equipLoc (default main-hand INVTYPE_WEAPON).
local function sffWeapon(subID, equipLoc)
  return { link = "item:sffw" .. subID .. (equipLoc or ""), ilvl = 150,
           equipLoc = equipLoc or "INVTYPE_WEAPON", classID = 2, subID = subID,
           slotCategory = "weapon", slotIDs = {16}, weaponSubID = subID }
end

-- Statless off-hand item drop (shield 6 → INVTYPE_SHIELD, else holdable 0).
local function sffOffhand(subID)
  return { link = "item:sffo" .. subID, ilvl = 150,
           equipLoc = (subID == 6) and "INVTYPE_SHIELD" or "INVTYPE_HOLDABLE",
           classID = 4, subID = subID,
           slotCategory = "offhand", slotIDs = {17}, offhandSubID = subID }
end

-- Resolve one member (both weapon slots @100) against a drop; captured or nil.
local function sffResolve(classToken, specID, itemData)
  local guid = "Player-0-sff" .. specID .. "-" .. tostring(itemData.subID) .. tostring(itemData.equipLoc)
  mockMemberGear(guid, "party1", classToken, specID, { [16] = 100, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"
  return resolveMemberForItem(guid, itemData)
end

-- ---------- Main-hand: 2H-only melee specs reject 1H (and vice versa) ----------

function TestSpecFormFinal:test_arms_warrior_rejects_1h_mace()
  lu.assertNil(sffResolve("WARRIOR", 71, sffWeapon(4)),
    "Arms is 2H-only (Midnight): a 1H mace is never a main-hand upgrade")
end

function TestSpecFormFinal:test_arms_warrior_accepts_2h_sword()
  lu.assertNotNil(sffResolve("WARRIOR", 71, sffWeapon(8, "INVTYPE_2HWEAPON")),
    "Arms wields 2H swords")
end

function TestSpecFormFinal:test_ret_paladin_rejects_1h_sword()
  lu.assertNil(sffResolve("PALADIN", 70, sffWeapon(7)),
    "Retribution is 2H-only: a 1H sword is not an upgrade")
end

function TestSpecFormFinal:test_ret_paladin_accepts_2h_mace()
  lu.assertNotNil(sffResolve("PALADIN", 70, sffWeapon(5, "INVTYPE_2HWEAPON")),
    "Retribution wields 2H maces")
end

function TestSpecFormFinal:test_blood_dk_rejects_1h_axe()
  lu.assertNil(sffResolve("DEATHKNIGHT", 250, sffWeapon(0)),
    "Blood DK is 2H-only: a 1H axe is not an upgrade")
end

function TestSpecFormFinal:test_unholy_dk_rejects_1h_sword()
  lu.assertNil(sffResolve("DEATHKNIGHT", 252, sffWeapon(7)),
    "Unholy DK is 2H-only: a 1H sword is not an upgrade")
end

function TestSpecFormFinal:test_frost_dk_accepts_1h_axe_offhand()
  lu.assertNotNil(sffResolve("DEATHKNIGHT", 251, sffWeapon(0, "INVTYPE_WEAPONOFFHAND")),
    "Frost DK dual-wields 1H axes in the off-hand")
end

function TestSpecFormFinal:test_feral_druid_rejects_1h_mace()
  lu.assertNil(sffResolve("DRUID", 103, sffWeapon(4)),
    "Feral is 2H-only (post-Legion): a 1H mace is not an upgrade")
end

function TestSpecFormFinal:test_feral_druid_accepts_2h_mace()
  lu.assertNotNil(sffResolve("DRUID", 103, sffWeapon(5, "INVTYPE_2HWEAPON")),
    "Feral wields 2H maces")
end

function TestSpecFormFinal:test_guardian_druid_rejects_dagger()
  lu.assertNil(sffResolve("DRUID", 104, sffWeapon(15)),
    "Guardian is 2H-only: a dagger is not an upgrade")
end

-- ---------- Main-hand: 1H specs keep 1H, reject 2H ----------

function TestSpecFormFinal:test_prot_warrior_accepts_1h_sword()
  lu.assertNotNil(sffResolve("WARRIOR", 73, sffWeapon(7)),
    "Protection Warrior wields 1H swords")
end

function TestSpecFormFinal:test_prot_warrior_rejects_2h_axe()
  lu.assertNil(sffResolve("WARRIOR", 73, sffWeapon(1, "INVTYPE_2HWEAPON")),
    "Protection Warrior is 1H+shield: a 2H axe is not a main-hand upgrade")
end

-- ---------- Caster 1H-sword proficiency (Midnight) ----------

function TestSpecFormFinal:test_fire_mage_accepts_1h_sword()
  lu.assertNotNil(sffResolve("MAGE", 63, sffWeapon(7)),
    "Mages can wield 1H swords in Midnight")
end

function TestSpecFormFinal:test_affliction_warlock_accepts_1h_sword()
  lu.assertNotNil(sffResolve("WARLOCK", 265, sffWeapon(7)),
    "Warlocks can wield 1H swords in Midnight")
end

-- ---------- Demon Hunter proficiency correction (+1H sword, +1H axe) ----------

function TestSpecFormFinal:test_havoc_dh_accepts_1h_sword()
  lu.assertNotNil(sffResolve("DEMONHUNTER", 577, sffWeapon(7)),
    "Havoc DH can wield 1H swords")
end

function TestSpecFormFinal:test_havoc_dh_accepts_1h_axe()
  lu.assertNotNil(sffResolve("DEMONHUNTER", 577, sffWeapon(0)),
    "Havoc DH can wield 1H axes")
end

-- Midnight grants the dagger weapon skill to Devourer ONLY (INT caster spec);
-- Havoc/Vengeance physical abilities remain dagger-incompatible.

function TestSpecFormFinal:test_devourer_dh_accepts_dagger()
  lu.assertNotNil(sffResolve("DEMONHUNTER", 1480, sffWeapon(15)),
    "Devourer DH can dual-wield daggers (Midnight INT dagger skill)")
end

function TestSpecFormFinal:test_devourer_dh_accepts_offhand_dagger()
  lu.assertNotNil(sffResolve("DEMONHUNTER", 1480, sffWeapon(15, "INVTYPE_WEAPONOFFHAND")),
    "Devourer DH takes a dagger in the off-hand (native dual-wield)")
end

function TestSpecFormFinal:test_havoc_dh_rejects_dagger()
  lu.assertNil(sffResolve("DEMONHUNTER", 577, sffWeapon(15)),
    "Havoc DH cannot use daggers (physical abilities require warglaives/swords)")
end

function TestSpecFormFinal:test_vengeance_dh_rejects_dagger()
  lu.assertNil(sffResolve("DEMONHUNTER", 581, sffWeapon(15)),
    "Vengeance DH cannot use daggers")
end

-- ---------- Shaman weapon list correction (no sword; +dagger) ----------

function TestSpecFormFinal:test_elemental_shaman_rejects_1h_sword()
  lu.assertNil(sffResolve("SHAMAN", 262, sffWeapon(7)),
    "Shamans cannot use swords in Midnight")
end

function TestSpecFormFinal:test_elemental_shaman_accepts_dagger()
  lu.assertNotNil(sffResolve("SHAMAN", 262, sffWeapon(15)),
    "Shamans can wield daggers")
end

function TestSpecFormFinal:test_enhancement_shaman_accepts_dagger_offhand()
  lu.assertNotNil(sffResolve("SHAMAN", 263, sffWeapon(15, "INVTYPE_WEAPONOFFHAND")),
    "Enhancement dual-wields daggers in the off-hand")
end

-- ---------- Rogue main-hand / off-hand asymmetry ----------

function TestSpecFormFinal:test_assassination_rogue_rejects_1h_sword()
  lu.assertNil(sffResolve("ROGUE", 259, sffWeapon(7)),
    "Assassination is dagger-locked: a 1H sword is not an upgrade")
end

function TestSpecFormFinal:test_outlaw_rogue_rejects_mainhand_only_dagger()
  -- A main-hand-RESTRICTED dagger (INVTYPE_WEAPONMAINHAND) is rejected: Outlaw's
  -- main-hand excludes daggers (Dispatch scales off slow weapons). An either-hand
  -- dagger (INVTYPE_WEAPON) is a different case — it fills the off-hand and IS
  -- accepted (see test_outlaw_dagger_invtype_weapon_fills_offhand).
  lu.assertNil(sffResolve("ROGUE", 260, sffWeapon(15, "INVTYPE_WEAPONMAINHAND")),
    "Outlaw main-hand excludes daggers")
end

function TestSpecFormFinal:test_outlaw_rogue_accepts_offhand_dagger()
  lu.assertNotNil(sffResolve("ROGUE", 260, sffWeapon(15, "INVTYPE_WEAPONOFFHAND")),
    "Outlaw can take a dagger in the off-hand")
end

function TestSpecFormFinal:test_subtlety_rogue_rejects_offhand_sword()
  lu.assertNil(sffResolve("ROGUE", 261, sffWeapon(7, "INVTYPE_WEAPONOFFHAND")),
    "Subtlety is dagger-locked in BOTH hands: a 1H sword off-hand is not an upgrade")
end

-- ---------- Off-hand item: dual-wield / 2H specs have no free off-hand ----------

function TestSpecFormFinal:test_fury_warrior_rejects_shield()
  lu.assertNil(sffResolve("WARRIOR", 72, sffOffhand(6)),
    "Fury dual-wields (Titan's Grip): no free off-hand for a shield")
end

function TestSpecFormFinal:test_ret_paladin_rejects_holdable()
  lu.assertNil(sffResolve("PALADIN", 70, sffOffhand(0)),
    "Retribution wields a 2H: no free off-hand for a holdable")
end

function TestSpecFormFinal:test_feral_druid_rejects_holdable()
  lu.assertNil(sffResolve("DRUID", 103, sffOffhand(0)),
    "Feral wields a 2H: no free off-hand for a holdable")
end

function TestSpecFormFinal:test_enhancement_shaman_rejects_shield()
  lu.assertNil(sffResolve("SHAMAN", 263, sffOffhand(6)),
    "Enhancement dual-wields: no free off-hand for a shield")
end

function TestSpecFormFinal:test_havoc_dh_rejects_holdable()
  lu.assertNil(sffResolve("DEMONHUNTER", 577, sffOffhand(0)),
    "Demon Hunters dual-wield: no free off-hand for a holdable")
end

function TestSpecFormFinal:test_brewmaster_monk_rejects_holdable()
  lu.assertNil(sffResolve("MONK", 268, sffOffhand(0)),
    "Brewmaster dual-wields (or 2H staff): no free off-hand for a holdable")
end

function TestSpecFormFinal:test_prot_paladin_rejects_holdable()
  lu.assertNil(sffResolve("PALADIN", 66, sffOffhand(0)),
    "Protection Paladin uses a shield, never a holdable")
end

-- ---------- Off-hand item: shield/holdable specs keep theirs ----------

function TestSpecFormFinal:test_prot_warrior_accepts_shield()
  lu.assertNotNil(sffResolve("WARRIOR", 73, sffOffhand(6)),
    "Protection Warrior uses a shield")
end

function TestSpecFormFinal:test_holy_paladin_accepts_holdable()
  lu.assertNotNil(sffResolve("PALADIN", 65, sffOffhand(0)),
    "Holy Paladin can use a holdable (or shield)")
end

function TestSpecFormFinal:test_elemental_shaman_accepts_shield()
  lu.assertNotNil(sffResolve("SHAMAN", 262, sffOffhand(6)),
    "Elemental Shaman can use a shield (or holdable)")
end

function TestSpecFormFinal:test_mistweaver_monk_accepts_holdable()
  lu.assertNotNil(sffResolve("MONK", 270, sffOffhand(0)),
    "Mistweaver uses 1H + holdable")
end

-- ---------- Accept pins for reject-only specs (deletion/typo guards) ----------
-- Because a missing/typo'd specID fails closed, an assertNil test also passes if
-- the entry is deleted. These positive pins ensure the entry still EXISTS and
-- carries the expected form for specs otherwise seen only as rejects above.

function TestSpecFormFinal:test_blood_dk_accepts_2h_sword()
  lu.assertNotNil(sffResolve("DEATHKNIGHT", 250, sffWeapon(8, "INVTYPE_2HWEAPON")),
    "Blood DK wields 2H swords")
end

function TestSpecFormFinal:test_unholy_dk_accepts_2h_axe()
  lu.assertNotNil(sffResolve("DEATHKNIGHT", 252, sffWeapon(1, "INVTYPE_2HWEAPON")),
    "Unholy DK wields 2H axes")
end

function TestSpecFormFinal:test_guardian_druid_accepts_2h_mace()
  lu.assertNotNil(sffResolve("DRUID", 104, sffWeapon(5, "INVTYPE_2HWEAPON")),
    "Guardian wields 2H maces")
end

function TestSpecFormFinal:test_subtlety_rogue_accepts_dagger()
  lu.assertNotNil(sffResolve("ROGUE", 261, sffWeapon(15)),
    "Subtlety wields daggers")
end

function TestSpecFormFinal:test_ret_paladin_accepts_polearm()
  lu.assertNotNil(sffResolve("PALADIN", 70, sffWeapon(6, "INVTYPE_2HWEAPON")),
    "Retribution wields polearms (medium-confidence datum — pin it)")
end

function TestSpecFormFinal:test_prot_paladin_accepts_shield()
  lu.assertNotNil(sffResolve("PALADIN", 66, sffOffhand(6)),
    "Protection Paladin uses a shield")
end

function TestSpecFormFinal:test_holy_paladin_accepts_shield()
  lu.assertNotNil(sffResolve("PALADIN", 65, sffOffhand(6)),
    "Holy Paladin can use a shield (as well as a holdable)")
end

-- A few more reject pins for facts that are otherwise unguarded.

function TestSpecFormFinal:test_enhancement_shaman_rejects_staff()
  lu.assertNil(sffResolve("SHAMAN", 263, sffWeapon(10, "INVTYPE_2HWEAPON")),
    "Enhancement dual-wields 1H: a 2H staff is not usable")
end

function TestSpecFormFinal:test_mistweaver_monk_rejects_shield()
  lu.assertNil(sffResolve("MONK", 270, sffOffhand(6)),
    "Mistweaver uses a holdable, never a shield")
end

function TestSpecFormFinal:test_fire_mage_rejects_1h_mace()
  lu.assertNil(sffResolve("MAGE", 63, sffWeapon(4)),
    "Mages cannot use maces in Midnight (sword/staff/dagger/wand only)")
end

-- ---------- Outlaw off-hand dagger via the COMMON either-hand shape ----------
-- Nearly all modern daggers drop as INVTYPE_WEAPON (either-hand), not the rare
-- INVTYPE_WEAPONOFFHAND. Outlaw's main-hand excludes daggers but its off-hand
-- allows them, so an INVTYPE_WEAPON dagger must be evaluated against the off-hand
-- slot — the usability check must consult offHandWeapon, not mainHand alone.

function TestSpecFormFinal:test_outlaw_dagger_invtype_weapon_fills_offhand()
  -- Outlaw MH sword 200 / OH dagger 100. An INVTYPE_WEAPON dagger @150 fills the
  -- weaker off-hand (+50) — eligible, compared against slot 17 (not the MH).
  local guid = "Player-0-OutlawDaggerOH"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_oh_dagger", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 15 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured,
    "Outlaw must be eligible for an either-hand dagger that fills the off-hand")
  lu.assertEquals(captured[1].slotID, 17,
    "an off-hand-only weapon must be compared against slot 17")
  lu.assertEquals(captured[1].ilvl_current, 100)
  lu.assertEquals(captured[1].delta, 50)
end

function TestSpecFormFinal:test_outlaw_dagger_offhand_only_ignores_stronger_mainhand()
  -- Outlaw MH sword 100 / OH dagger 200. The same 150 dagger can ONLY replace the
  -- 200 off-hand (it can't main-hand for Outlaw) → NOT an upgrade. Guards against
  -- a naive min(16,17) that would wrongly compare against the 100 main-hand.
  local guid = "Player-0-OutlawDaggerMHstrong"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 100, [17] = 200 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_oh_dagger2", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 15,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 15 }

  lu.assertNil(resolveMemberForItem(guid, itemData),
    "an off-hand-only dagger must compare against slot 17 only, never the stronger main-hand")
end

function TestSpecFormFinal:test_outlaw_sword_either_hand_uses_min_compare()
  -- A 1H sword IS valid in both of Outlaw's hands, so it keeps the dual-wield
  -- min(16,17) comparison. MH 200 / OH 100, sword @150 → eligible vs the OH.
  local guid = "Player-0-OutlawSwordBoth"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_sword", ilvl = 150,
                     equipLoc = "INVTYPE_WEAPON", classID = 2, subID = 7,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 7 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "Outlaw either-hand sword fills the weaker hand")
  lu.assertEquals(captured[1].slotID, 17)
end

-- ---------- Fury Titan's-Grip 2H is data-driven (no specID hardcode) ----------

function TestSpecFormFinal:test_fury_2h_offhand_is_data_driven_dual_slot()
  -- Fury MH 2H-axe 200 / OH 2H-axe 100. A 2H axe @150 fills the weaker off-hand
  -- (+50) via Titan's Grip — the dual-slot compare must come from the data
  -- (2H subID present in BOTH mainHand and offHandWeapon), not a specID==72 branch.
  local guid = "Player-0-FuryTG"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 200, [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:fury_2h_axe", ilvl = 150,
                     equipLoc = "INVTYPE_2HWEAPON", classID = 2, subID = 1,
                     slotCategory = "weapon", slotIDs = {16}, weaponSubID = 1 }

  local captured = resolveMemberForItem(guid, itemData)
  lu.assertNotNil(captured, "Fury 2H off-hand upgrade must be eligible (Titan's Grip)")
  lu.assertEquals(captured[1].slotID, 17,
    "Fury 2H must dual-slot compare against the weaker off-hand")
  lu.assertEquals(captured[1].delta, 50)
end

-- ============================================================
-- TestCrossConfigWeapon (D-16)
-- Flexible specs (casters, Frost DK) can run either a 2H or a 1H+off-hand.
-- A drop that only helps in the config they're NOT currently wearing is still
-- judged, by the locked rule:
--   * member in 1H+off-hand, a 2H drops   → compare the 2H vs the AVERAGE of
--     their main-hand + off-hand ilvls (the 2H displaces both).
--   * member in a 2H, a 1H or off-hand item drops → compare the drop STRAIGHT
--     across to the 2H (main-hand slot).
-- Self-gating: the average path only fires when an off-hand is actually equipped
-- (slot 17 > 0), which only flexible specs ever have; a pure-2H spec (Arms)
-- can't hold an off-hand, so it's never affected.
-- ============================================================
TestCrossConfigWeapon = {}

function TestCrossConfigWeapon:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

-- Turn the member's slot-16 item (created by mockMemberGear) into a real 2H, so
-- is2HEquipped() is true and its live ilvl is `ilvl`.
local function equipMember2H(guid, ilvl)
  _mockItemInfo["item:" .. guid .. "s16"] = { "TwoHandStaff", nil, 4, ilvl, nil,
    "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 }
  -- Reflect the 2H in the cached inspect snapshot: production caches equipLoc
  -- per slot at inspect time and is2HEquipped reads that, not live GetItemInfo (M1).
  local m = LIF.Cache.GetMember(guid)
  if m and m.gear and m.gear[16] then m.gear[16].equipLoc = "INVTYPE_2HWEAPON" end
end

local function twoHandStaffDrop(link, ilvl)
  return { link = link, ilvl = ilvl, equipLoc = "INVTYPE_2HWEAPON", classID = 2,
           subID = 10, slotCategory = "weapon", slotIDs = {16}, weaponSubID = 10 }
end

local function oneHandMaceDrop(link, ilvl)
  return { link = link, ilvl = ilvl, equipLoc = "INVTYPE_WEAPON", classID = 2,
           subID = 4, slotCategory = "weapon", slotIDs = {16}, weaponSubID = 4 }
end

local function offhandHoldableDrop(link, ilvl)
  return { link = link, ilvl = ilvl, equipLoc = "INVTYPE_HOLDABLE", classID = 4,
           subID = 0, slotCategory = "offhand", slotIDs = {17}, offhandSubID = 0 }
end

-- ---------- 2H drop vs a 1H+off-hand member → average ----------

function TestCrossConfigWeapon:test_2h_drop_vs_1h_offhand_member_uses_average_eligible()
  -- Ele Shaman running 1H mace 200 + shield 180 (avg 190). A 2H staff @195 clears
  -- the average by +5 → eligible, reported against slot 16 at the averaged ilvl.
  local guid = "Player-0-EleAvgElig"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 200, [17] = 180 })
  _mockGuids["player"] = "GUID-SELF"

  local captured = resolveMemberForItem(guid, twoHandStaffDrop("item:staff195", 195))
  lu.assertNotNil(captured, "2H @195 vs a 1H+off-hand avg of 190 is an upgrade")
  lu.assertEquals(captured[1].ilvl_current, 190, "2H must compare against the average of both slots")
  lu.assertEquals(captured[1].slotID, 16)
  lu.assertEquals(captured[1].delta, 5)
end

function TestCrossConfigWeapon:test_2h_drop_vs_1h_offhand_member_uses_average_ineligible()
  -- Same member (avg 190). A 2H staff @190 does not clear the +1 threshold.
  local guid = "Player-0-EleAvgInelig"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 200, [17] = 180 })
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, twoHandStaffDrop("item:staff190", 190)),
    "2H @190 does not beat the 1H+off-hand average of 190")
end

function TestCrossConfigWeapon:test_2h_drop_vs_2h_member_compares_straight()
  -- Member already on a 2H staff @200 (off-hand empty) → a 2H drop compares
  -- straight across, NOT against a (200+0)/2 average.
  local guid = "Player-0-Ele2HStraight"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 200 })
  equipMember2H(guid, 200)
  _mockGuids["player"] = "GUID-SELF"

  local captured = resolveMemberForItem(guid, twoHandStaffDrop("item:staff205", 205))
  lu.assertNotNil(captured, "2H @205 beats an equipped 2H @200")
  lu.assertEquals(captured[1].ilvl_current, 200,
    "2H-vs-2H compares straight to the equipped 2H, not a halved average")
end

-- ---------- Cross-config displacing an ACTIVE heirloom → heirlooms win (M2) ----------

function TestCrossConfigWeapon:test_2h_drop_displacing_heirloom_offhand_skipped()
  -- Ele Shaman on 1H + an ACTIVE heirloom off-hand (level ≤69). A 2H displaces
  -- BOTH hands, forcing off the unbeatable heirloom. Heirlooms win (M2): skip,
  -- rather than average the heirloom's low scaling ilvl into the basis — which
  -- would false-positive ((200+60)/2 = 130, so any 2H >130 looks like an upgrade).
  local guid = "Player-0-EleHeirOH"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 200, [17] = 60 })
  _mockUnitLevel["party1"] = 50
  LIF.Cache.GetMember(guid).gear[17] = { link = "item:88017", ilvl = 60, equipLoc = "INVTYPE_HOLDABLE" }
  _mockHeirloomItemIDs[88017] = true
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, twoHandStaffDrop("item:staff195h", 195)),
    "2H displacing an active heirloom off-hand must be skipped (heirlooms win)")
end

function TestCrossConfigWeapon:test_offhand_item_displacing_heirloom_2h_skipped()
  -- Warlock on an ACTIVE heirloom 2H (level ≤69). A holdable that out-ilvls the
  -- 2H would normally cross-config as eligible (switch to 1H+holdable), but
  -- taking it means dropping the unbeatable heirloom 2H. Heirlooms win (M2): skip.
  local guid = "Player-0-LockHeir2H"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 200 })
  _mockUnitLevel["party1"] = 50
  LIF.Cache.GetMember(guid).gear[16] = { link = "item:88016", ilvl = 200, equipLoc = "INVTYPE_2HWEAPON" }
  _mockHeirloomItemIDs[88016] = true
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, offhandHoldableDrop("item:hold210h", 210)),
    "off-hand item displacing an active heirloom 2H must be skipped (heirlooms win)")
end

-- ---------- Off-hand item / 1H drop vs a 2H member → straight across ----------

function TestCrossConfigWeapon:test_offhand_item_vs_2h_member_compares_straight_eligible()
  -- Warlock on a 2H staff @200. A holdable @210 out-ilvls the 2H → eligible
  -- (they could switch to 1H+holdable); compared straight against slot 16.
  local guid = "Player-0-Lock2HOffhandElig"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 200 })
  equipMember2H(guid, 200)
  _mockGuids["player"] = "GUID-SELF"

  local captured = resolveMemberForItem(guid, offhandHoldableDrop("item:hold210", 210))
  lu.assertNotNil(captured, "holdable @210 beats an equipped 2H @200")
  lu.assertEquals(captured[1].ilvl_current, 200, "off-hand item vs a 2H compares straight to the 2H")
  lu.assertEquals(captured[1].slotID, 16)
end

function TestCrossConfigWeapon:test_offhand_item_vs_2h_member_ineligible_below_2h()
  -- Same member. A holdable @195 is below the 2H @200 → NOT an upgrade. Guards
  -- against the old bug that compared against an empty slot 17 (ilvl 0).
  local guid = "Player-0-Lock2HOffhandInelig"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 200 })
  equipMember2H(guid, 200)
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, offhandHoldableDrop("item:hold195", 195)),
    "holdable @195 must lose to the equipped 2H @200 (not compare against empty)")
end

function TestCrossConfigWeapon:test_offhand_is2h_reads_cached_equiploc_not_live()
  -- is2HEquipped must read the cached equipLoc (M1), not re-call GetItemInfo
  -- live. Cache says slot 16 is a 2H @200 but the item is NOT in the local
  -- GetItemInfo cache (no _mockItemInfo) — mimicking a loot-time cold cache. A
  -- holdable @195 below the 2H must lose, proving it compared against the 2H and
  -- not an empty off-hand (a live read would return nil → is2HEquipped false →
  -- false positive vs slot 17 = 0).
  local guid = "Player-0-Lock2HColdCache"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 200 })
  LIF.Cache.GetMember(guid).gear[16].equipLoc = "INVTYPE_2HWEAPON"  -- cache only; no _mockItemInfo
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, offhandHoldableDrop("item:hold195c", 195)),
    "cold-cache 2H: holdable @195 must lose to the 2H (is2HEquipped read from cache)")
end

function TestCrossConfigWeapon:test_offhand_unresolved_mainhand_fails_closed()
  -- Main-hand item present but equipLoc unresolved even at inspect time (cached
  -- equipLoc nil): we can't tell if it's a 2H, so the off-hand drop is skipped
  -- rather than compared against an empty off-hand slot (M1 fail-closed).
  local guid = "Player-0-LockUnresolvedMH"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 200 })
  LIF.Cache.GetMember(guid).gear[16].equipLoc = nil  -- unresolved
  _mockGuids["player"] = "GUID-SELF"

  lu.assertNil(resolveMemberForItem(guid, offhandHoldableDrop("item:hold300u", 300)),
    "unresolved main-hand type → off-hand drop skipped (fail closed)")
end

function TestCrossConfigWeapon:test_1h_drop_vs_2h_member_compares_straight()
  -- Member on a 2H staff @200. A 1H mace @205 out-ilvls it straight across → eligible.
  local guid = "Player-0-Ele2H1HDrop"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 200 })
  equipMember2H(guid, 200)
  _mockGuids["player"] = "GUID-SELF"

  local captured = resolveMemberForItem(guid, oneHandMaceDrop("item:mace205", 205))
  lu.assertNotNil(captured, "1H @205 beats an equipped 2H @200 straight across")
  lu.assertEquals(captured[1].ilvl_current, 200)
  lu.assertEquals(captured[1].slotID, 16)
end

-- ---------- Off-hand item vs a 1H+off-hand member → normal slot-17 (unchanged) ----------

function TestCrossConfigWeapon:test_offhand_item_vs_1h_offhand_member_uses_slot17()
  -- Holy Paladin running 1H 200 + shield 180. A shield @190 replaces the off-hand
  -- (slot 17) as before — the cross-config rule doesn't touch the same-config path.
  local guid = "Player-0-HolyPal1HOff"
  mockMemberGear(guid, "party1", "PALADIN", 65, { [16] = 200, [17] = 180 })
  _mockGuids["player"] = "GUID-SELF"

  local shield = { link = "item:shield190", ilvl = 190, equipLoc = "INVTYPE_SHIELD",
                   classID = 4, subID = 6, slotCategory = "offhand", slotIDs = {17}, offhandSubID = 6 }
  local captured = resolveMemberForItem(guid, shield)
  lu.assertNotNil(captured, "shield @190 beats the equipped off-hand @180")
  lu.assertEquals(captured[1].ilvl_current, 180)
  lu.assertEquals(captured[1].slotID, 17)
end

-- ============================================================
-- Member eligibility (AUD-311): direct rule-level tests of the exposed
-- LIF.CheckMemberEligibility seam. Asserts the actual verdict + candidate fields
-- (delta/slotID/ilvl_current) on the eligible path and the specific skip REASON on
-- the ineligible path. The pipeline integration (OnLootInspectReady → _tryOpenPopup
-- → ShowPopup) stays covered by the resolveMemberForItem-based TestDualWield suite.
-- ============================================================
TestMemberEligibility = {}

function TestMemberEligibility:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  LIF.pendingLootItems = {}
  LIF.ShowPopup             = _origShowPopup
end

-- Direct call into the exposed eligibility seam using the same member/unit the
-- production OnLootInspectReady path resolves. Returns (eligible, candidate, reason).
local function checkMember(guid, itemData, threshold)
  return LIF.CheckMemberEligibility(itemData, LIF.Cache.GetMember(guid), LIF.GuidToUnit(guid), threshold or 1)
end

-- ---------- ring / trinket ----------

function TestMemberEligibility:test_ring_statless_lower_of_two()
  -- Statless ring compares against the lower of the two equipped rings (slot 11 @460).
  local guid = "Player-0-RingElig"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 460, [12] = 475 })
  local itemData = { link = "item:ring_party", ilvl = 470, slotID = 11,
                     equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
                     itype = "Armor", subtype = "Miscellaneous" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "statless ring beats the lower equipped ring")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 11)
  lu.assertEquals(cand.ilvl_current, 460)
  lu.assertEquals(cand.delta, 10)
end

function TestMemberEligibility:test_trinket_stat_mismatch()
  -- AGI trinket vs an INT spec (Disc Priest 256) → stat gate rejects.
  local guid = "Player-0-IntTrinket"
  mockMemberGear(guid, "party1", "PRIEST", 256, { [13] = 450, [14] = 450 })
  _mockItemStats["item:agi_trinket"] = { ITEM_MOD_AGILITY_SHORT = 150 }
  local itemData = { link = "item:agi_trinket", ilvl = 470, slotID = 13,
                     equipLoc = "INVTYPE_TRINKET", slotIDs = {13, 14}, slotCategory = "trinket",
                     itype = "Armor", subtype = "Trinket", primaryStats = { AGI = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "AGI trinket is not usable by an INT spec")
  lu.assertNil(cand)
  lu.assertEquals(reason, "stat mismatch (AGI/INT)")
end

function TestMemberEligibility:test_trinket_statless_ilvl_only()
  -- Secondary-stat-only trinket → ilvl-only, lower of two (slot 13 @450).
  local guid = "Player-0-SecTrinket"
  mockMemberGear(guid, "party1", "DRUID", 103, { [13] = 450, [14] = 460 })
  _mockItemStats["item:sec_trinket_party"] = { ITEM_MOD_HASTE_RATING_SHORT = 120 }
  local itemData = { link = "item:sec_trinket_party", ilvl = 470, slotID = 13,
                     equipLoc = "INVTYPE_TRINKET", slotIDs = {13, 14}, slotCategory = "trinket",
                     itype = "Armor", subtype = "Trinket" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "statless trinket falls back to ilvl-only lower-of-two")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 13)
  lu.assertEquals(cand.ilvl_current, 450)
  lu.assertEquals(cand.delta, 20)
end

-- ---------- neck/back + primary-stat ring: stat gate ----------

function TestMemberEligibility:test_back_stat_mismatch()
  -- INT cloak vs a STR spec (Ret Paladin 70) → back stat gate rejects.
  local guid = "Player-0-RetPalaCloak"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [15] = 150 })
  local itemData = { link = "item:int_cloak", ilvl = 220, equipLoc = "INVTYPE_CLOAK",
                     slotIDs = {15}, slotCategory = "back", primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "INT cloak not usable by a STR spec")
  lu.assertNil(cand)
  lu.assertEquals(reason, "stat mismatch (INT/STR)")
end

function TestMemberEligibility:test_back_stat_match()
  -- INT cloak vs an INT spec (Frost Mage 64) → stat gate passes.
  local guid = "Player-0-FrostMageCloak"
  mockMemberGear(guid, "party1", "MAGE", 64, { [15] = 100 })
  local itemData = { link = "item:int_cloak_match", ilvl = 220, equipLoc = "INVTYPE_CLOAK",
                     slotIDs = {15}, slotCategory = "back", primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "INT cloak usable by an INT spec")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 15)
  lu.assertEquals(cand.ilvl_current, 100)
  lu.assertEquals(cand.delta, 120)
end

function TestMemberEligibility:test_ring_stat_mismatch()
  -- INT ring vs a STR spec (Ret Paladin 70) → ring stat gate rejects.
  local guid = "Player-0-RetPalaRing"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [11] = 150, [12] = 150 })
  local itemData = { link = "item:int_ring", ilvl = 220, equipLoc = "INVTYPE_FINGER",
                     slotIDs = {11, 12}, slotCategory = "ring", primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "INT ring not usable by a STR spec")
  lu.assertNil(cand)
  lu.assertEquals(reason, "stat mismatch (INT/STR)")
end

function TestMemberEligibility:test_ring_stat_match()
  -- INT ring vs an INT spec (Frost Mage 64) → stat gate passes, lower slot 11.
  local guid = "Player-0-FrostMageRing"
  mockMemberGear(guid, "party1", "MAGE", 64, { [11] = 100, [12] = 100 })
  local itemData = { link = "item:int_ring_match", ilvl = 220, equipLoc = "INVTYPE_FINGER",
                     slotIDs = {11, 12}, slotCategory = "ring", primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "INT ring usable by an INT spec")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 11)
  lu.assertEquals(cand.ilvl_current, 100)
  lu.assertEquals(cand.delta, 120)
end

-- ---------- armor + heirloom ----------

function TestMemberEligibility:test_armor_type_mismatch()
  -- Leather chest dropped for a Plate-wearing Warrior → armor-type gate rejects.
  local guid = "Player-0-PlateWarrior"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [5] = 460 })
  local itemData = { link = "item:leather_chest", ilvl = 480,
                     slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "Leather is not the Warrior's armor type")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "armor type mismatch")
end

function TestMemberEligibility:test_armor_heirloom_slot_excludes()
  -- Candidate wears an active heirloom chest at level 50 → excluded (SC2).
  local guid = "Player-0-HeirloomArmor"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockUnitLevel["party1"] = 50
  _mockHeirloomItemIDs[22201] = true
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, { gear = { [5] = { link = "item:22201", ilvl = 300 } }, specID = 103 })
  local itemData = { link = "item:22202", ilvl = 400,
                     slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "active heirloom armor slot is unbeatable")
  lu.assertNil(cand)
  lu.assertEquals(reason, "heirloom")
end

function TestMemberEligibility:test_armor_nil_slot_falls_through()
  -- Empty gear (nil slot) → heirloom check skipped, nil=0 ilvl → eligible (SC4).
  local guid = "Player-0-NilSlotArmor"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockUnitLevel["party1"] = 50
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, { gear = {}, specID = 103 })
  local itemData = { link = "item:22203", ilvl = 400,
                     slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "empty slot falls through to the nil=0 ilvl path")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 5)
  lu.assertEquals(cand.ilvl_current, 0)
  lu.assertEquals(cand.delta, 400)
end

-- ---------- weapon usability + stat + slot ----------

function TestMemberEligibility:test_weapon_uses_cached_ilvl_not_wiped_live_read()
  -- ClearInspectPlayer wipes the live slot-16 read; the compare must use the
  -- cached snapshot (ilvl 70), not the wiped live read (0) that fabricates +220.
  local guid = "Player-0-CacheWeapon"
  mockMemberGear(guid, "party1", "DRUID", 102, { [16] = 70 })
  _mockGearLinks["party1"][16] = nil
  local link = "item:cache_weapon_dagger"
  local itemData = classifyMockItem(link,
    { "INTDagger", nil, 4, 220, nil, "Weapon", "Daggers", nil, "INVTYPE_WEAPON", nil, nil, 2, 15, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 190 })
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "INT dagger beats the cached MH")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 16)
  lu.assertEquals(cand.ilvl_current, 70, "must read the cached MH ilvl, not the wiped live read")
  lu.assertEquals(cand.delta, 150)
end

function TestMemberEligibility:test_weapon_warglaive_shaman_not_usable()
  -- Warglaive (subID 9) is DEMONHUNTER-only → Enhancement Shaman (263) not usable.
  local guid = "Player-0-ShamanWarglaive"
  mockMemberGear(guid, "party1", "SHAMAN", 263, { [16] = 450 })
  local link = "item:warglaive_shaman"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 9, slotIDs = {16}, slotCategory = "weapon",
                     weaponSubID = 9, primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "warglaive not usable by a Shaman spec")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "weapon not usable by spec")
end

function TestMemberEligibility:test_weapon_warglaive_demonhunter_usable()
  -- Warglaive (subID 9) IS usable by a Devourer DH (1480, INT) — the usability
  -- gate the Shaman failed. DH warglaives are dual-wield ("both" hands), so with
  -- an empty off-hand the drop fills slot 17 (compare vs the empty slot, ilvl 0).
  local guid = "Player-0-DHWarglaive"
  mockMemberGear(guid, "party1", "DEMONHUNTER", 1480, { [16] = 450 })
  local link = "item:warglaive_dh"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 9, slotIDs = {16}, slotCategory = "weapon",
                     weaponSubID = 9, primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "warglaive usable by Devourer DH with matching INT")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17, "dual-wielder fills the empty off-hand")
  lu.assertEquals(cand.ilvl_current, 0)
  lu.assertEquals(cand.delta, 470)
end

function TestMemberEligibility:test_weapon_unknown_subid_not_usable()
  -- Unknown weapon subID 99 → SpecWeaponHands nil (D-03 fail-safe) → not usable.
  local guid = "Player-0-UnknownSubID"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 450 })
  local link = "item:unknown_weapon"
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 150 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 99, slotIDs = {16}, slotCategory = "weapon",
                     weaponSubID = 99, primaryStats = { AGI = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "unknown weapon subID fails closed")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "weapon not usable by spec")
end

function TestMemberEligibility:test_weaponoffhand_targets_slot17()
  -- WEAPONOFFHAND dagger (Assassination Rogue 259): must compare slot 17 (460),
  -- not slot 16 (490) — regression lock CR-02.
  local guid = "Player-0-WOHRogue"
  mockMemberGear(guid, "party1", "ROGUE", 259, { [16] = 490, [17] = 460 })
  local link = "item:woh_dagger_member"
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 150 }
  local itemData = { link = link, ilvl = 490, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 15, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 15, primaryStats = { AGI = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "off-hand dagger beats the weaker off-hand")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17, "must target slot 17, not 16")
  lu.assertEquals(cand.ilvl_current, 460)
  lu.assertEquals(cand.delta, 30)
end

-- ---------- AUD-401: WEAPONOFFHAND drop (hands=="off") vs an equipped 2H ----------
-- Frost DK/Survival/BrM/WW list a 1H subID in offHandWeapon, so an
-- INVTYPE_WEAPONOFFHAND drop resolves hands=="off" (weaponSlot 17, no dual compare).
-- When the spec is currently on a 2H, slot 17 is empty ONLY because the 2H fills
-- both hands — the real basis is the 2H (slot 16), not an ilvl-0 empty off-hand.

function TestMemberEligibility:test_weaponoffhand_vs_equipped_2h_straight_compare_skip()
  -- Frost DK (251, STR) on a 2H @400, empty off-hand. A WEAPONOFFHAND axe @100 must
  -- compare STRAIGHT vs the 2H (slot 16) — not the empty off-hand — so it's no upgrade.
  local guid = "Player-0-FrostDKWOH2H"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })  -- OH empty
  equipMember2H(guid, 400)
  local link = "item:woh_axe_fdk_low"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 200 }
  local itemData = { link = link, ilvl = 100, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 0, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 0, primaryStats = { STR = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "WEAPONOFFHAND @100 vs an equipped 2H @400 is not an upgrade")
  lu.assertNil(cand)
  lu.assertEquals(reason, "ilvl")
end

function TestMemberEligibility:test_weaponoffhand_vs_equipped_2h_straight_compare_eligible()
  -- Same Frost DK on a 2H @400: a WEAPONOFFHAND axe @405 clears +5 straight vs the
  -- 2H (slot 16) → eligible, delta 5 (NOT delta 405 against an empty off-hand).
  local guid = "Player-0-FrostDKWOH2HUp"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })  -- OH empty
  equipMember2H(guid, 400)
  local link = "item:woh_axe_fdk_up"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 210 }
  local itemData = { link = link, ilvl = 405, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 0, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 0, primaryStats = { STR = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "WEAPONOFFHAND @405 straight-beats the equipped 2H @400")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 16, "compare against the 2H in slot 16, not the empty off-hand")
  lu.assertEquals(cand.ilvl_current, 400)
  lu.assertEquals(cand.delta, 5)
end

function TestMemberEligibility:test_weaponoffhand_coldcache_mh_fails_closed()
  -- Cold cache (M1): main-hand link present but equipLoc nil, empty off-hand. A
  -- WEAPONOFFHAND drop must fail closed — a real 2H can't be confirmed, so comparing
  -- vs the ilvl-0 empty off-hand would false-positive.
  local guid = "Player-0-FrostDKWOHCold"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 400 })  -- OH empty
  local member = LIF.Cache.GetMember(guid)
  member.gear[16] = { link = "item:fdk_woh_cold_mh", ilvl = 400, equipLoc = nil }
  local link = "item:woh_axe_fdk_cold"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 200 }
  local itemData = { link = link, ilvl = 405, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 0, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 0, primaryStats = { STR = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "unresolved main-hand type + empty off-hand must fail closed")
  lu.assertNil(cand)
  lu.assertEquals(reason, "main-hand type unresolved")
end

function TestMemberEligibility:test_weaponoffhand_outlaw_empty_oh_no_2h_still_eligible()
  -- Non-regression: Outlaw (260, AGI) has a 1H main hand and an EMPTY off-hand (no
  -- 2H possible). A WEAPONOFFHAND dagger fills the empty off-hand → still eligible
  -- against it (is2HEquipped false → falls through to the slot-17 empty compare).
  local guid = "Player-0-OutlawWOHEmptyOH"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 490 })  -- 1H MH (default equipLoc), OH empty
  local link = "item:woh_dagger_outlaw_fill"
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 150 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 15, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 15, primaryStats = { AGI = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "Outlaw fills its empty off-hand with a WEAPONOFFHAND drop")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17, "targets the empty off-hand it fills")
  lu.assertEquals(cand.ilvl_current, 0)
  lu.assertEquals(cand.delta, 470)
end

function TestMemberEligibility:test_self_weaponoffhand_vs_equipped_2h_not_upgrade()
  -- Player mirror: local Frost DK on a 2H @400, empty off-hand. A WEAPONOFFHAND axe
  -- @100 must NOT read as a self-upgrade (it would if compared vs the empty off-hand),
  -- otherwise forwarding is wrongly suppressed and a bogus "+100 ilvl" line is sent.
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 251
  _mockUnitClass["player"] = { "Death Knight", "DEATHKNIGHT" }
  local slot16Link = "item:self_fdk_2h_woh"
  _mockItemInfo[slot16Link] = { "TwoHandBlade", nil, 4, 400, nil,
    "Weapon", "Two-Handed Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  _mockIlvl[slot16Link] = 400
  _mockGearLinks["player"] = { [16] = slot16Link }  -- OH empty
  local link = "item:self_fdk_woh_low"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 200 }
  local itemData = { link = link, ilvl = 100, equipLoc = "INVTYPE_WEAPONOFFHAND",
                     classID = 2, subID = 0, slotIDs = {17}, slotCategory = "weapon",
                     weaponSubID = 0, primaryStats = { STR = true } }
  lu.assertFalse(callIsPlayerUpgrade(itemData, 10),
    "WEAPONOFFHAND @100 vs the player's own 2H @400 is not a self-upgrade")
end

-- ---------- weapon: Fury Titan's-Grip dual-slot 2H (min of both hands) ----------

function TestMemberEligibility:test_fury_2h_dual_slot_eligible()
  -- Fury Warrior (72): a 2H compares against min(slot16=460, slot17=455)=455.
  local guid = "Player-0-Fury2H"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 460, [17] = 455 })
  local link = "item:2h_axe_fury"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 300 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 1, slotIDs = {16, 17}, slotCategory = "weapon",
                     weaponSubID = 1, primaryStats = { STR = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "2H beats the lower of both Titan's-Grip hands")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17)
  lu.assertEquals(cand.ilvl_current, 455)
  lu.assertEquals(cand.delta, 15)
end

function TestMemberEligibility:test_fury_2h_dual_slot_below_threshold()
  -- Fury Warrior (72): 2H drop @460 vs min(455,458)=455 → delta 5 < 10 → ilvl skip.
  local guid = "Player-0-Fury2HLow"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 455, [17] = 458 })
  local link = "item:2h_axe_fury_low"
  _mockItemStats[link] = { ITEM_MOD_STRENGTH_SHORT = 280 }
  local itemData = { link = link, ilvl = 460, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 1, slotIDs = {16, 17}, slotCategory = "weapon",
                     weaponSubID = 1, primaryStats = { STR = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "2H delta below threshold")
  lu.assertNil(cand)
  lu.assertEquals(reason, "ilvl")
end

-- ---------- offhand: usability, stat gate, heirloom, ilvl, cross-config ----------

function TestMemberEligibility:test_offhand_holdable_usable()
  -- Holdable usable by Affliction Warlock (265); slot 17 @450, drop 470 → eligible.
  local guid = "Player-0-WarlockHold"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 450 })
  local itemData = { link = "item:holdable_warlock", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "holdable usable by a Warlock")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17)
  lu.assertEquals(cand.ilvl_current, 450)
  lu.assertEquals(cand.delta, 20)
end

function TestMemberEligibility:test_offhand_holdable_not_usable_by_warrior()
  -- No Arms Warrior (71) spec lists holdable → not usable.
  local guid = "Player-0-WarriorHold"
  mockMemberGear(guid, "party1", "WARRIOR", 71, { [17] = 450 })
  local itemData = { link = "item:holdable_warrior", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "Arms Warrior cannot use a holdable")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "offhand not usable by spec")
end

function TestMemberEligibility:test_offhand_shield_usable_by_prot_warrior()
  -- Shield usable by Protection Warrior (73); slot 17 @450, drop 470 → eligible.
  local guid = "Player-0-WarriorShield"
  mockMemberGear(guid, "party1", "WARRIOR", 73, { [17] = 450 })
  local itemData = { link = "item:shield_warrior", ilvl = 470, equipLoc = "INVTYPE_SHIELD",
                     classID = 4, subID = 6, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 6 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "shield usable by Protection Warrior")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17)
  lu.assertEquals(cand.ilvl_current, 450)
  lu.assertEquals(cand.delta, 20)
end

function TestMemberEligibility:test_offhand_shield_not_usable_by_mage()
  -- No Fire Mage (63) spec lists shield → not usable.
  local guid = "Player-0-MageShield"
  mockMemberGear(guid, "party1", "MAGE", 63, { [17] = 450 })
  local itemData = { link = "item:shield_mage", ilvl = 470, equipLoc = "INVTYPE_SHIELD",
                     classID = 4, subID = 6, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 6 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "Mage cannot use a shield")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "offhand not usable by spec")
end

function TestMemberEligibility:test_offhand_ilvl_below_threshold()
  -- Usable holdable, but slot 17 @465 vs drop 470 → delta 5 < 10 → ilvl skip.
  local guid = "Player-0-WarlockLow"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 465 })
  local itemData = { link = "item:holdable_low", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "offhand delta below threshold")
  lu.assertNil(cand)
  lu.assertEquals(reason, "ilvl")
end

function TestMemberEligibility:test_offhand_stat_mismatch()
  -- Offhand stat gate: an INT shield vs a STR spec (Protection Paladin 66) is
  -- rejected on the stat even though the slot is far below the drop's ilvl. Uses
  -- a shield (usable by Prot Paladin) so the stat gate is actually reached — the
  -- old test used a holdable, which a Paladin can't equip at all, so it hit the
  -- usability gate instead and never exercised the stat gate (AUD-311).
  local guid = "Player-0-ProtPalaShield"
  mockMemberGear(guid, "party1", "PALADIN", 66, { [17] = 100 })
  local link = "item:shield_int_stat"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_SHIELD",
                     classID = 4, subID = 6, slotIDs = {17}, slotCategory = "offhand",
                     offhandSubID = 6, primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "INT shield not usable by a STR spec")
  lu.assertNil(cand)
  lu.assertEquals(reason, "stat mismatch (INT/STR)")
end

function TestMemberEligibility:test_offhand_stat_match()
  -- INT holdable vs an INT spec (Affliction Warlock 265) → stat gate passes.
  local guid = "Player-0-WarlockStat"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 100 })
  local link = "item:holdable_int_match"
  _mockItemStats[link] = { ITEM_MOD_INTELLECT_SHORT = 200 }
  local itemData = { link = link, ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand",
                     offhandSubID = 0, primaryStats = { INT = true } }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "INT holdable usable by an INT spec")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17)
  lu.assertEquals(cand.ilvl_current, 100)
  lu.assertEquals(cand.delta, 370)
end

function TestMemberEligibility:test_offhand_heirloom_slot_excludes()
  -- Active heirloom holdable in slot 17 at level 50 → excluded regardless of ilvl.
  local guid = "Player-0-OffhandHeirloom"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Warlock", "WARLOCK" }
  _mockUnitLevel["party1"] = 50
  _mockHeirloomItemIDs[33301] = true
  _mockIlvl["item:33301"] = 300
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, { gear = { [17] = { link = "item:33301", ilvl = 300 } }, specID = 265 })
  local itemData = { link = "item:holdable_heirloom", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "active heirloom off-hand is unbeatable")
  lu.assertNil(cand)
  lu.assertEquals(reason, "heirloom")
end

function TestMemberEligibility:test_offhand_vs_2h_straight_across()
  -- Warlock on a 2H staff @460 (cross-config D-16): a holdable @470 out-ilvls it
  -- straight across (they could switch to 1H+holdable) → eligible vs slot 16.
  local guid = "Player-0-Warlock2H"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 460 })
  LIF.Cache.GetMember(guid).gear[16].equipLoc = "INVTYPE_2HWEAPON"
  local itemData = { link = "item:holdable_2h_gate", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "holdable beats the equipped 2H straight across")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 16)
  lu.assertEquals(cand.ilvl_current, 460)
  lu.assertEquals(cand.delta, 10)
end

function TestMemberEligibility:test_offhand_no_slot16_no_2h_gate()
  -- No slot 16 equipped → 2H gate skipped → normal off-hand compare (slot 17 @450).
  local guid = "Player-0-WarlockNoMH"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 450 })
  local itemData = { link = "item:holdable_no_mh", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertTrue(eligible, "empty main hand skips the 2H gate")
  lu.assertEquals(reason, "eligible")
  lu.assertEquals(cand.slotID, 17)
  lu.assertEquals(cand.ilvl_current, 450)
  lu.assertEquals(cand.delta, 20)
end

function TestMemberEligibility:test_offhand_usability_gate_precedes_cross_config()
  -- Protection Paladin (66, shield-only off-hand) wielding a 2H: a holdable is
  -- never usable, so the usability gate rejects before the D-16 ilvl compare.
  local guid = "Player-0-Pala2HGate"
  mockMemberGear(guid, "party1", "PALADIN", 66, { [16] = 460 })
  local slot16Link = "item:Player-0-Pala2HGates16"
  _mockItemInfo[slot16Link] = { "Ashkandur", nil, 4, 460, nil,
    "Weapon", "Two-Handed Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  local itemData = { link = "item:holdable_d16_gate", ilvl = 470, equipLoc = "INVTYPE_HOLDABLE",
                     classID = 4, subID = 0, slotIDs = {17}, slotCategory = "offhand", offhandSubID = 0 }
  local eligible, cand, reason = checkMember(guid, itemData, 10)
  lu.assertFalse(eligible, "shield-only spec rejected for a holdable before cross-config")
  lu.assertNil(cand)
  lu.assertStrContains(reason, "offhand not usable by spec")
end

-- ============================================================
-- AUD-404: LIF.PlayerWeaponCompareSlot — the popup header hover's weapon
-- compare slot must mirror the slot eligibility actually used for the player
-- (weaker of a dual-wield pair / off-hand-only / the equipped 2H), not always
-- the main hand.
-- ============================================================
TestPlayerWeaponCompareSlot = {}

function TestPlayerWeaponCompareSlot:setUp()
  ResetMocks()
  _mockUnitClass["player"] = { "Death Knight", "DEATHKNIGHT" }
  _mockUnitLevel["player"] = 70
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 251  -- Frost DK: 2H or dual 1H
end

-- Equip the player's weapon slots: gear = { [slot] = {ilvl=, equipLoc=, heirloomID=} }.
local function equipPlayerWeapons(gear)
  _mockGearLinks["player"] = {}
  for slot, g in pairs(gear) do
    local link = "item:player_w" .. slot
    _mockGearLinks["player"][slot] = link
    _mockIlvl[link] = g.ilvl
    _mockItemInfo[link] = { "W", nil, 4, g.ilvl, nil, "Weapon", "Swords",
      nil, g.equipLoc or "INVTYPE_WEAPON", nil, nil, 2, 7, 0 }
    if g.heirloomID then
      _mockItemInfo[link][1] = "H"
      _mockGearLinks["player"][slot] = "item:" .. g.heirloomID
      _mockIlvl["item:" .. g.heirloomID] = g.ilvl
      _mockItemInfo["item:" .. g.heirloomID] = { "H", nil, 4, g.ilvl, nil, "Weapon",
        "Swords", nil, g.equipLoc or "INVTYPE_WEAPON", nil, nil, 2, 7, 0 }
      _mockHeirloomItemIDs[g.heirloomID] = true
    end
  end
end

local function sword1H() return { link = "item:drop_1h", equipLoc = "INVTYPE_WEAPON",
  weaponSubID = 7, slotIDs = {16}, slotCategory = "weapon" } end

function TestPlayerWeaponCompareSlot:test_dual_wield_returns_lower_ilvl_slot()
  -- Dual 1H: MH 460 / OH 455 → compare against the weaker off-hand (17).
  equipPlayerWeapons({ [16] = { ilvl = 460 }, [17] = { ilvl = 455 } })
  lu.assertEquals(LIF.PlayerWeaponCompareSlot(sword1H()), 17,
    "dual-wield header must show the weaker hand (off-hand @455)")
end

function TestPlayerWeaponCompareSlot:test_dual_wield_returns_lower_when_mainhand_weaker()
  -- Dual 1H: MH 455 / OH 460 → compare against the weaker main hand (16).
  equipPlayerWeapons({ [16] = { ilvl = 455 }, [17] = { ilvl = 460 } })
  lu.assertEquals(LIF.PlayerWeaponCompareSlot(sword1H()), 16,
    "dual-wield header shows the weaker hand (main @455)")
end

function TestPlayerWeaponCompareSlot:test_on_2h_empty_offhand_returns_mainhand()
  -- Frost DK on a 2H (slot 16), empty off-hand → straight compare vs the 2H (16),
  -- not the empty off-hand (AUD-301/AUD-401 mirrored in the header).
  equipPlayerWeapons({ [16] = { ilvl = 400, equipLoc = "INVTYPE_2HWEAPON" } })
  lu.assertEquals(LIF.PlayerWeaponCompareSlot(sword1H()), 16,
    "on a 2H with empty off-hand, header shows the 2H (slot 16)")
end

function TestPlayerWeaponCompareSlot:test_offhand_only_drop_returns_offhand()
  -- Outlaw off-hand-only dagger drop (hands=="off") with an occupied off-hand → slot 17.
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockSpecializationInfo[1] = 260  -- Outlaw
  equipPlayerWeapons({ [16] = { ilvl = 490 }, [17] = { ilvl = 460 } })
  local drop = { link = "item:drop_woh", equipLoc = "INVTYPE_WEAPONOFFHAND",
    weaponSubID = 15, slotIDs = {17}, slotCategory = "weapon" }
  lu.assertEquals(LIF.PlayerWeaponCompareSlot(drop), 17,
    "off-hand-only drop compares against the off-hand (17)")
end

function TestPlayerWeaponCompareSlot:test_unusable_weapon_returns_nil()
  -- A warglaive (DH-only subID 9) is not usable by Frost DK → nil (caller falls back).
  equipPlayerWeapons({ [16] = { ilvl = 460 }, [17] = { ilvl = 455 } })
  local drop = { link = "item:drop_wg", equipLoc = "INVTYPE_WEAPON",
    weaponSubID = 9, slotIDs = {16}, slotCategory = "weapon" }
  lu.assertNil(LIF.PlayerWeaponCompareSlot(drop),
    "a weapon the spec can't use yields nil")
end

function TestPlayerWeaponCompareSlot:test_active_heirloom_hand_excluded()
  -- Active heirloom in the main hand (level ≤69), non-heirloom off-hand @455 → the
  -- heirloom hand never wins the low side, so compare against the off-hand (17).
  _mockUnitLevel["player"] = 50
  equipPlayerWeapons({ [16] = { ilvl = 300, heirloomID = 55501 }, [17] = { ilvl = 455 } })
  lu.assertEquals(LIF.PlayerWeaponCompareSlot(sword1H()), 17,
    "active heirloom main hand is excluded; compare the off-hand")
end

-- ============================================================
-- Decision-logging formatters (verbose per-drop record). Pure-function tests
-- of FormatDropHeader / FormatDecisionGear plus integration checks that the
-- cmp / self-check / prefilter log lines carry class, spec, and equipped gear.
-- ============================================================
TestDecisionFormatters = {}

function TestDecisionFormatters:setUp()
  ResetMocks()
end

function TestDecisionFormatters:test_drop_header_2h_weapon()
  local h = LIF.FormatDropHeader(
    { name = "Test 2H", ilvl = 500, slotCategory = "weapon",
      equipLoc = "INVTYPE_2HWEAPON", primaryStats = { STR = true } },
    nil, 12345)
  lu.assertStrContains(h, "ilvl=500")
  lu.assertStrContains(h, "cat=weapon")
  lu.assertStrContains(h, "hand=2h")
  lu.assertStrContains(h, "stats=STR")
  lu.assertStrContains(h, "id=12345")   -- nil link → id fallback
end

function TestDecisionFormatters:test_drop_header_statless_armor_no_hand()
  local h = LIF.FormatDropHeader(
    { name = "Plain Chest", ilvl = 200, slotCategory = "armor",
      equipLoc = "INVTYPE_CHEST", primaryStats = nil },
    nil, 999)
  lu.assertStrContains(h, "stats=none")
  lu.assertNil(h:find("hand=", 1, true), "armor drop has no hand= tag")
end

function TestDecisionFormatters:test_gear_ring_both_slots()
  local char = {
    level = 60,
    getSlotIlvl     = function(s) return ({ [11] = 460, [12] = 475 })[s] or 0 end,
    getLiveSlotIlvl = function(s) return 0 end,
    getSlotLink     = function() return nil end,   -- nil link → isHeirloomActive false → hl:n
    getLiveSlotLink = function() return nil end,
  }
  lu.assertEquals(
    LIF.FormatDecisionGear(char, "ring", { slotIDs = { 11, 12 } }),
    "s11:460 hl:n  s12:475 hl:n")
end

function TestDecisionFormatters:test_gear_weapon_uses_live_accessors_mh_oh()
  local char = {
    level = 60,
    getSlotIlvl     = function(s) return 0 end,
    getLiveSlotIlvl = function(s) return ({ [16] = 642, [17] = 0 })[s] or 0 end,
    getSlotLink     = function() return nil end,
    getLiveSlotLink = function() return nil end,
  }
  lu.assertEquals(
    LIF.FormatDecisionGear(char, "weapon", {}),
    "mh:642 hl:n  oh:0 hl:n")
end

function TestDecisionFormatters:test_gear_single_slot_armor()
  local char = {
    level = 60,
    getSlotIlvl     = function(s) return ({ [5] = 630 })[s] or 0 end,
    getLiveSlotIlvl = function(s) return 0 end,
    getSlotLink     = function() return nil end,
    getLiveSlotLink = function() return nil end,
  }
  lu.assertEquals(
    LIF.FormatDecisionGear(char, "armor", { slotIDs = { 5 } }),
    "s5:630 hl:n")
end

function TestDecisionFormatters:test_gear_heirloom_flag_y()
  -- An active heirloom in the equipped slot (level ≤69) renders hl:y — exercises
  -- isHeirloomActive(getLink(slot), char.level) with real link + level args.
  local origGlobal = LootItForward
  LootItForward = nil   -- isolate from any leaked skipHeirloomCheck bypass
  _mockHeirloomItemIDs[55501] = true
  local char = {
    level = 50,
    getSlotIlvl     = function(s) return ({ [5] = 120 })[s] or 0 end,
    getLiveSlotIlvl = function(s) return 0 end,
    getSlotLink     = function(s) return (s == 5) and "item:55501" or nil end,
    getLiveSlotLink = function() return nil end,
  }
  local gear = LIF.FormatDecisionGear(char, "armor", { slotIDs = { 5 } })
  LootItForward = origGlobal
  lu.assertEquals(gear, "s5:120 hl:y")
end

function TestDecisionFormatters:test_self_check_log_enriched()
  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true } } }
  LIF.InitLog({ entries = {} }, "test")
  -- Rogue (Leather, AGI): a leather chest drop @480 beats the equipped @460.
  local link = "item:leather_chest_selfcheck"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["player"] = { "Rogue", "ROGUE" }
  _mockUnitLevel["player"] = 60
  _mockGearLinks["player"] = { [5] = "item:player_chest_sc" }
  _mockIlvl["item:player_chest_sc"] = 460
  _mockGetSpecialization = 1
  _mockSpecializationInfo[1] = 259  -- Assassination Rogue (AGI)

  local itemData = LIF.ClassifyItem(link)
  LIF.IsPlayerUpgrade(itemData, 1)
  LootItForward = origGlobal

  local found
  for _, e in ipairs(LIF.GetLog()) do
    if e.msg:find("^self%-check ") then found = e.msg end
  end
  lu.assertNotNil(found, "a self-check line was logged")
  lu.assertStrContains(found, "ROGUE")
  lu.assertStrContains(found, "equip=[s5:460")
  lu.assertStrContains(found, "result=")
end

-- ---------- unknown member spec (AUD-502) ----------

function TestMemberEligibility:test_unknown_member_spec_is_skipped()
  -- AUD-502, member side. A member on a spec SPEC_TABLE has not learned yet cannot be
  -- reasoned about, so they must be skipped. The stat gate does NOT catch this on its
  -- own: StatGateStatus returns "ok" for a STATLESS drop, so a statless neck would sail
  -- past every spec check and the member would be offered an item we cannot evaluate.
  local guid = "Player-0-UnknownSpec"
  mockMemberGear(guid, "party1", "DRUID", 9999, { [2] = 400 })
  _mockGuids["player"] = "GUID-SELF"

  -- slotCategory "neck", as the real ClassifyItem maps INVTYPE_NECK. Filing it under
  -- "armor" would route it to the armor branch's CLASS gate and get the member skipped
  -- for the wrong reason, hiding the statless bypass this test exists to reproduce.
  local itemData = { link = "item:neck_statless", ilvl = 480, slotID = 2,
                     equipLoc = "INVTYPE_NECK", slotIDs = {2}, slotCategory = "neck",
                     itype = "Armor", subtype = "Miscellaneous" }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a member on a spec unknown to SPEC_TABLE must be skipped")
  lu.assertNil(cand)
  lu.assertNotNil(reason:find("spec", 1, true), "the skip must say the spec is unknown; got: " .. tostring(reason))
end

-- ---------- heirloom weapon policy matrix (D-17) ----------
--
-- Two rules, in order:
--   H1 DISPLACEMENT — the drop would push an active heirloom out of a slot → skip.
--   H2 DUPLICATION  — an active heirloom sits in one hand and SPEC_TABLE says the OTHER
--                     hand takes that weapon type, so it will hold a scaling copy → skip.
--   H3 otherwise    — the heirloom blocks nothing; compare against the non-heirloom hand.
--
-- Outlaw is the interesting spec and needs no special case: their off-hand takes daggers
-- and their main hand does not, so an off-hand heirloom dagger is NOT duplicable into the
-- main hand, and the main hand stays a real target.

-- Give a member an active heirloom in `slot`, with its type resolved.
local function equipHeirloom(guid, slot, itemID, ilvl, equipLoc, subID)
  local m = LIF.Cache.GetMember(guid)
  m.gear[slot] = { link = "item:" .. itemID, ilvl = ilvl, equipLoc = equipLoc, subID = subID }
  _mockHeirloomItemIDs[itemID] = true
end

function TestMemberEligibility:test_outlaw_offhand_heirloom_dagger_leaves_the_main_hand_open()
  -- H3. The heirloom dagger cannot be copied into an Outlaw's main hand, so the main hand
  -- is still a genuine target: a sword drop that beats it must be offered.
  local guid = "Player-0-OutlawOHHeir"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 180, [17] = 200 })
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 17, 88801, 200, "INVTYPE_WEAPON", 15)   -- 15 = dagger
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_sword", ilvl = 200, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 7, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "an Outlaw's main hand takes no daggers, so it is still beatable")
  lu.assertEquals(cand.slotID, 16, "compare against the non-heirloom main hand")
  lu.assertEquals(cand.ilvl_current, 180)
end

function TestMemberEligibility:test_outlaw_offhand_heirloom_dagger_with_empty_main_hand()
  -- The bug the old blanket rule had: "heirloom in one hand + other hand EMPTY → skip"
  -- assumed the empty hand gets a duplicate. For Outlaw it cannot, so an empty main hand is
  -- a real 0-item-level target and any usable main-hand weapon is an upgrade.
  local guid = "Player-0-OutlawEmptyMH"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [17] = 200 })   -- main hand EMPTY
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 17, 88802, 200, "INVTYPE_WEAPON", 15)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_sword2", ilvl = 150, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 7, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 7 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "an empty main hand an Outlaw cannot fill with a dagger copy is a real target")
  lu.assertEquals(cand.slotID, 16)
  lu.assertEquals(cand.ilvl_current, 0)
end

function TestMemberEligibility:test_outlaw_dagger_drop_into_the_heirloom_offhand_is_blocked()
  -- H1. A dagger can ONLY go in an Outlaw's off-hand, which is where the heirloom is — so
  -- taking it would displace the heirloom.
  local guid = "Player-0-OutlawDaggerDrop"
  mockMemberGear(guid, "party1", "ROGUE", 260, { [16] = 180, [17] = 200 })
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 17, 88803, 200, "INVTYPE_WEAPON", 15)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:outlaw_dagger", ilvl = 300, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 15, slotCategory = "weapon", slotIDs = {17},
                     weaponSubID = 15 }
  local eligible, _, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a dagger can only land where the heirloom already is")
  lu.assertEquals(reason, "heirloom")
end

function TestMemberEligibility:test_2h_drop_loses_to_a_heirloom_in_either_hand()
  -- H1. A 2H takes BOTH hands (Titan's Grip aside), so it displaces a heirloom in either.
  for _, slot in ipairs({ 16, 17 }) do
    local guid = "Player-0-2HvsHeirloom" .. slot
    mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 180, [17] = 180 })
    _mockUnitLevel["party1"] = 50
    equipHeirloom(guid, slot, 88810 + slot, 180, "INVTYPE_WEAPON", 4)   -- 4 = 1H mace
    _mockGuids["player"] = "GUID-SELF"

    local itemData = { link = "item:big_staff", ilvl = 400, equipLoc = "INVTYPE_2HWEAPON",
                       classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                       weaponSubID = 10 }
    local eligible, _, reason = checkMember(guid, itemData, 1)
    lu.assertFalse(eligible,
      ("a 2H displaces both hands, so a heirloom in slot %d blocks it"):format(slot))
    lu.assertEquals(reason, "heirloom")
  end
end

function TestMemberEligibility:test_equipped_2h_heirloom_blocks_a_1h_drop()
  -- H1 from the EQUIPPED side. A leveling Windwalker on a heirloom STAFF with an empty
  -- off-hand: a 1H drop lands in a hand the heirloom does not occupy, but a 2H fills both
  -- hands, so taking it forces the heirloom off. Comparing the drop against the heirloom's
  -- low scaling ilvl (it wins easily) is a false positive.
  local guid = "Player-0-WWStaffHeir"
  mockMemberGear(guid, "party1", "MONK", 269, { [16] = 150 })   -- off-hand empty
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 16, 88840, 150, "INVTYPE_2HWEAPON", 10)   -- 10 = staff
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:ww_1h", ilvl = 250, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 0, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 0 }
  local eligible, _, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a 1H drop that forces off an equipped 2H heirloom is not an upgrade")
  lu.assertEquals(reason, "heirloom")
end

function TestMemberEligibility:test_a_heirloom_holdable_does_not_block_main_hand_drops()
  -- subIDs only mean anything within an item class. A holdable is subID 0 — the same number
  -- as a 1H axe — and an Ele Shaman's main hand takes axes. Running the equipped item's
  -- subID through the WEAPON truth table without checking its equipLoc would report the
  -- holdable as "duplicable into the main hand" and block every main-hand drop forever.
  local guid = "Player-0-EleHoldable"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 100, [17] = 200 })
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 17, 88850, 200, "INVTYPE_HOLDABLE", 0)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:ele_mace", ilvl = 200, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 4, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 4 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "a holdable is nobody's duplicate — the main hand is still beatable")
  lu.assertEquals(cand.slotID, 16)
  lu.assertEquals(cand.ilvl_current, 100)
end

function TestMemberEligibility:test_a_heirloom_main_hand_does_not_block_a_shield()
  -- H2 cannot apply across item classes: a mace cannot be copied into a shield slot, and the
  -- shield does not displace the mace. A Prot Paladin with an heirloom mace still wants a
  -- better shield.
  local guid = "Player-0-ProtPally"
  mockMemberGear(guid, "party1", "PALADIN", 66, { [16] = 200, [17] = 180 })
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 16, 88820, 200, "INVTYPE_WEAPON", 5)
  LIF.Cache.GetMember(guid).gear[17].equipLoc = "INVTYPE_SHIELD"
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:better_shield", ilvl = 220, equipLoc = "INVTYPE_SHIELD",
                     classID = 4, subID = 6, slotCategory = "offhand", slotIDs = {17},
                     offhandSubID = 6 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "an heirloom weapon must not block an off-hand ITEM upgrade")
  lu.assertEquals(cand.slotID, 17)
end

function TestMemberEligibility:test_unresolved_heirloom_type_fails_closed()
  -- We cannot tell whether the other hand is a real target without knowing the heirloom's
  -- weapon type. Skip rather than guess.
  local guid = "Player-0-HeirloomNoType"
  mockMemberGear(guid, "party1", "DEATHKNIGHT", 251, { [16] = 200, [17] = 180 })
  _mockUnitLevel["party1"] = 50
  equipHeirloom(guid, 16, 88830, 200, "INVTYPE_WEAPON", nil)   -- subID never resolved
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:dw_axe", ilvl = 250, equipLoc = "INVTYPE_WEAPON",
                     classID = 2, subID = 0, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 0 }
  local eligible, _, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "an unresolved heirloom type must fail closed")
  lu.assertNotNil(reason:find("unresolved", 1, true), "got: " .. tostring(reason))
end

-- ---------- unresolved (cold-cache) equipped ilvl — AUD-509 / AUD-530 ----------

-- queue.lua caches a gear entry whenever the slot HOLDS an item, even if the item was
-- cold in the client cache and its ilvl could not be resolved (link set, ilvl nil).
-- An EMPTY slot gets no entry at all. The two must not be confused: empty = 0 = "any
-- item is an upgrade"; unresolved = unknown = skip the member.

-- Item still cold at LOOT time too: the cached ilvl is nil AND the link will not resolve.
local function coldSlotIlvl(guid, slotID)
  local m = LIF.Cache.GetMember(guid)
  m.gear[slotID].ilvl = nil          -- inspect-time resolve failed
  _mockIlvl[m.gear[slotID].link] = nil  -- and the item is STILL not in the client cache
end

-- Cached ilvl is nil, but the item HAS loaded into the client cache since the inspect.
local function staleSlotIlvl(guid, slotID)
  local m = LIF.Cache.GetMember(guid)
  m.gear[slotID].ilvl = nil          -- link stays, and _mockIlvl still resolves it
end

function TestMemberEligibility:test_2h_drop_cold_offhand_ilvl_fails_closed()
  -- Ele Shaman on 1H mace @180 + a HIGHER off-hand @220 → true pair average 200.
  -- A 2H @190 loses to that average, so it must NOT be offered. Reading the unresolved
  -- off-hand as 0 drops it out of the pair-average branch and judges the 2H against the
  -- raw main hand (190 - 180 = +10) — a FALSE POSITIVE. Fail closed instead.
  local guid = "Player-0-ColdOH"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 180, [17] = 220 })
  coldSlotIlvl(guid, 17)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:staff190", ilvl = 190, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 10 }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "an unresolved off-hand ilvl must not be judged against the main hand alone")
  lu.assertNil(cand)
  -- plain find: "-" and "(" are pattern metacharacters to a Lua matcher.
  lu.assertNotNil(reason:find("unresolved", 1, true),
    "the skip must state WHY, like its sibling M1 guards; got: " .. tostring(reason))
end

function TestMemberEligibility:test_cold_ilvl_recovers_when_the_item_has_since_loaded()
  -- The cached ilvl is nil, but the item has loaded into the client cache since the
  -- inspect. Re-resolve from the cached link rather than skipping the member: the true
  -- pair average is 200, and a 2H @210 beats it by +10.
  local guid = "Player-0-StaleOH"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 180, [17] = 220 })
  staleSlotIlvl(guid, 17)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:staff210", ilvl = 210, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 10 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "a nil cached ilvl that re-resolves must not skip the member")
  lu.assertEquals(cand.ilvl_current, 200, "and it must compare against the recovered pair average")
end

function TestMemberEligibility:test_cold_main_hand_ilvl_fails_closed()
  -- AUD-509 only ever covered slot 17. A cold MAIN hand is the same false positive:
  -- MH reads 0, so the pair average of a 300 off-hand collapses to 150 and a 160 2H
  -- looks like an upgrade when the member is wearing far better.
  local guid = "Player-0-ColdMH"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 300, [17] = 300 })
  coldSlotIlvl(guid, 16)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:staff160", ilvl = 160, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 10 }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a cold main hand must not read as ilvl 0")
  lu.assertNil(cand)
  lu.assertNotNil(reason:find("unresolved", 1, true), "got: " .. tostring(reason))
end

function TestMemberEligibility:test_cold_armor_ilvl_fails_closed()
  -- The hole is not weapon-specific: every category compares `dropped - current`.
  local guid = "Player-0-ColdChest"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [5] = 300 })
  coldSlotIlvl(guid, 5)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:chest160", ilvl = 160, equipLoc = "INVTYPE_CHEST",
                     classID = 4, subID = 3, armorType = "Mail",
                     slotCategory = "armor", slotIDs = {5} }
  local eligible, _, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a cold chest slot must not read as ilvl 0")
  lu.assertNotNil(reason:find("unresolved", 1, true), "got: " .. tostring(reason))
end

function TestMemberEligibility:test_cold_ring_ilvl_fails_closed()
  -- Ring/trinket take the LOWER of the two slots, so one cold slot reads 0 and becomes
  -- the basis — the worst version of the bug.
  local guid = "Player-0-ColdRing"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [11] = 300, [12] = 300 })
  coldSlotIlvl(guid, 11)
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:ring160", ilvl = 160, equipLoc = "INVTYPE_FINGER",
                     classID = 4, subID = 0, slotCategory = "ring", slotIDs = {11, 12} }
  local eligible, _, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible, "a cold ring slot must not become the lower-of-two basis")
  lu.assertNotNil(reason:find("unresolved", 1, true), "got: " .. tostring(reason))
end

function TestMemberEligibility:test_unresolved_heirloom_offhand_still_blocks_the_2h()
  -- The gate exempts a slot holding an active heirloom (a heirloom wins on its link alone
  -- and needs no ilvl). That exemption must not let the member fall through to a bare
  -- main-hand compare: the pair-average branch owns the "a 2H displaces the heirloom
  -- off-hand, so it is not an upgrade" rule (M2), and that branch is only reached if its
  -- occupancy test sees the off-hand. Test occupancy by LINK — an unresolved heirloom's
  -- ilvl reads 0, so an `ilvl > 0` test would skip the branch and offer the 2H.
  local guid = "Player-0-HeirloomColdOH"
  _mockGuids["party1"] = guid
  _mockGuids["player"] = "GUID-SELF"
  _mockUnitClass["party1"] = { "Shaman", "SHAMAN" }
  _mockUnitLevel["party1"] = 50
  _mockHeirloomItemIDs[44401] = true
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, { specID = 262, gear = {
    [16] = { link = "item:44400", ilvl = 180, equipLoc = "INVTYPE_WEAPON" },
    -- heirloom off-hand, and its ilvl never resolved (cold at inspect AND at loot time)
    [17] = { link = "item:44401", ilvl = nil, equipLoc = "INVTYPE_WEAPONOFFHAND" },
  } })

  local itemData = { link = "item:staff190", ilvl = 190, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 10 }
  local eligible, cand, reason = checkMember(guid, itemData, 1)
  lu.assertFalse(eligible,
    "a 2H that displaces an active heirloom off-hand is not an upgrade, resolved ilvl or not")
  lu.assertNil(cand)
  lu.assertEquals(reason, "heirloom")
end

function TestMemberEligibility:test_an_empty_slot_still_reads_as_zero()
  -- The other half of the rule, and the reason this is not a blanket "nil-guard every 0":
  -- an EMPTY slot (no cache entry at all) genuinely IS ilvl 0, and ANY item is an upgrade
  -- for it. The fail-closed gate must not touch that case.
  local guid = "Player-0-BareNeck"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 100 })   -- slot 2 (neck) empty
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:neck160", ilvl = 160, equipLoc = "INVTYPE_NECK",
                     classID = 4, subID = 0, slotCategory = "neck", slotIDs = {2} }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible, "an empty slot must stay an upgrade for anything")
  lu.assertEquals(cand.ilvl_current, 0)
end

function TestMemberEligibility:test_2h_drop_resolved_offhand_still_averages()
  -- Complement: with slot 17 resolved, the pair-average path is unchanged.
  -- 1H @180 + off-hand @220 → avg 200. A 2H @210 clears it by +10.
  local guid = "Player-0-WarmOH"
  mockMemberGear(guid, "party1", "SHAMAN", 262, { [16] = 180, [17] = 220 })
  _mockGuids["player"] = "GUID-SELF"

  local itemData = { link = "item:staff210", ilvl = 210, equipLoc = "INVTYPE_2HWEAPON",
                     classID = 2, subID = 10, slotCategory = "weapon", slotIDs = {16},
                     weaponSubID = 10 }
  local eligible, cand = checkMember(guid, itemData, 1)
  lu.assertTrue(eligible)
  lu.assertEquals(cand.ilvl_current, 200, "still compares against the average of both slots")
end

-- Member cmp-line enrichment: uses the existing TestMemberEligibility harness
-- (checkMember helper + mockMemberGear), asserting the logged cmp line carries
-- class, the both-slot gear summary, and the verdict on both paths.
function TestMemberEligibility:test_cmp_log_enriched_eligible()
  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true } } }
  LIF.InitLog({ entries = {} }, "test")
  local guid = "Player-0-CmpElig"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 460, [12] = 475 })
  local itemData = { link = "item:ring_cmp", ilvl = 470, equipLoc = "INVTYPE_FINGER",
                     slotIDs = { 11, 12 }, slotCategory = "ring" }
  checkMember(guid, itemData, 1)
  LootItForward = origGlobal

  local found
  for _, e in ipairs(LIF.GetLog()) do
    if e.msg:find("^cmp ") then found = e.msg end
  end
  lu.assertNotNil(found, "an eligible cmp line was logged")
  lu.assertStrContains(found, "DRUID")            -- class token
  lu.assertStrContains(found, "equip=[s11:460")   -- both-slot gear summary
  lu.assertStrContains(found, "-> eligible")
end

function TestMemberEligibility:test_cmp_log_enriched_skip_has_gear()
  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true } } }
  LIF.InitLog({ entries = {} }, "test")
  local guid = "Player-0-CmpSkip"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [11] = 150, [12] = 150 })
  local itemData = { link = "item:int_ring_cmp", ilvl = 220, equipLoc = "INVTYPE_FINGER",
                     slotIDs = { 11, 12 }, slotCategory = "ring", primaryStats = { INT = true } }
  checkMember(guid, itemData, 1)
  LootItForward = origGlobal

  local found
  for _, e in ipairs(LIF.GetLog()) do
    if e.msg:find("^cmp ") then found = e.msg end
  end
  lu.assertNotNil(found, "a skip cmp line was logged")
  lu.assertStrContains(found, "PALADIN")
  lu.assertStrContains(found, "equip=[s11:150")   -- gear present even on the skip path
  lu.assertStrContains(found, "-> skip(stat mismatch")
end

-- Prefilter-exclusion logging: a member dropped BEFORE reinspect must still
-- log a "prefilter skip" line so the decision record shows who was considered.
function TestMemberEligibility:test_prefilter_logs_excluded_member()
  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true } } }
  LIF.InitLog({ entries = {} }, "test")
  -- A Mage (Cloth) cannot use a Plate armor drop → excluded at prefilter.
  local guid = "Player-0-PrefMage"
  mockMemberGear(guid, "party1", "MAGE", 64, { [5] = 100 })
  local itemData = { link = "item:plate_chest_pref", ilvl = 200, equipLoc = "INVTYPE_CHEST",
                     slotIDs = { 5 }, slotCategory = "armor", armorType = "Plate" }
  LIF.EvaluateCandidates(itemData, 1)
  LootItForward = origGlobal

  local found
  for _, e in ipairs(LIF.GetLog()) do
    if e.msg:find("^prefilter skip ") then found = e.msg end
  end
  lu.assertNotNil(found, "an excluded member logs a prefilter-skip line")
  lu.assertStrContains(found, "MAGE")
  lu.assertStrContains(found, "armor type mismatch")
end

-- ============================================================
-- Run suite
-- ============================================================
os.exit(lu.LuaUnit.run())
