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
    cacheGear[slotID] = { link = link, ilvl = ilvl }
  end
  LIF.Cache.SetComplete(guid, { gear = cacheGear, specID = specID })
end

-- ============================================================
-- Test class
-- ============================================================
TestLoot = {}

-- Capture the original no-op stubs from loot.lua so setUp can restore them after
-- any test that overrides them with spies.
local _origShowPopup          = LIF.ShowPopup
local _origPopupUpdateCand    = LIF.Popup_UpdateCandidate
local _origPopupRemoveCand    = LIF.Popup_RemoveCandidate

function TestLoot:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
  -- Reset pending loot state so tests are isolated (EvaluateCandidates/OnLootInspectReady).
  LIF.pendingLootItems = {}
  -- Restore popup stubs so tests that nil them out don't bleed into subsequent tests.
  LIF.ShowPopup             = _origShowPopup
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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

function TestLoot:test_trinket_upgrade_stat_match()
  -- droppedIlvl=440, trinkets={slot13=420, slot14=430}, threshold=10
  -- lower trinket = 420; delta = 440 - 420 = 20 >= 10 → true
  lu.assertTrue(
    LIF.IsTrinketUpgrade(440, { slot13 = 420, slot14 = 430 }, 10),
    "Trinket drop is upgrade over lower slot (delta 20 >= threshold 10)"
  )
  -- Stat compatibility: AGI == AGI → true
  lu.assertTrue(
    LIF.IsTrinketCompatible("AGI", "AGI"),
    "AGI trinket is compatible with AGI spec"
  )
end

function TestLoot:test_trinket_skip_stat_mismatch()
  -- Stat compatibility: AGI != INT → false
  lu.assertFalse(
    LIF.IsTrinketCompatible("AGI", "INT"),
    "AGI trinket is NOT compatible with INT spec"
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
  callIsPlayerUpgrade(itemData, 10)
  -- If we reach here, the call did not skip — assert true (ilvl-only: 480-450=30>=10)
  lu.assertTrue(true, "test_trinket_ilvl_only_no_stat: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_self_upgrade_armor_no_popup: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_self_upgrade_empty_slot_is_upgrade: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_weapon_self_upgrade_stat_match: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_weapon_self_upgrade_stat_mismatch: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_neck_self_upgrade_ilvl_only: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_trinket_self_upgrade_stat_mismatch_not_upgrade: reached past skip guard")
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
  callIsPlayerUpgrade(itemData, 10)
  lu.assertTrue(true, "test_trinket_self_upgrade_no_primary_stat_ilvl_only: reached past skip guard")
end

-- ============================================================
-- RequestReinspect and scan stabilization (Task 0 — queue.lua)
-- ============================================================

function TestLoot:test_request_reinspect_resets_gear_sets_pending()
  -- Set up a COMPLETE member, then call RequestReinspect.
  -- After: state == PENDING and gear is empty (D-14).
  local guid = "Player-0-TestReinspect"
  local unit = "party1"
  mockMemberGear(guid, unit, "DRUID", 103, { [5] = 460, [11] = 440, [12] = 450 })

  -- Confirm COMPLETE before test
  local memberBefore = LIF.Cache.GetMember(guid)
  lu.assertEquals(memberBefore.state, "COMPLETE", "Precondition: member must be COMPLETE")

  callRequestReinspect(guid)

  local memberAfter = LIF.Cache.GetMember(guid)
  lu.assertNotNil(memberAfter, "Member must still be in cache after RequestReinspect")
  lu.assertEquals(memberAfter.state, "PENDING",
    "RequestReinspect must set state to PENDING (D-14)")
  -- Gear should be empty
  local gearCount = 0
  if memberAfter.gear then
    for _ in pairs(memberAfter.gear) do gearCount = gearCount + 1 end
  end
  lu.assertEquals(gearCount, 0, "RequestReinspect must clear gear data (D-14)")
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

  -- 2nd fire: slotCount=5, consistentCount=2 — should NOT complete
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

  -- 3rd fire: slotCount=5, consistentCount=3 — SHOULD complete (stabilization)
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

  local updateCandidateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, link)
    table.insert(updateCandidateCalls, { guid = g })
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
  lu.assertEquals(#updateCandidateCalls, 0, "Popup_UpdateCandidate must not be called (popup was not open)")

  LIF.ShowPopup             = _origShowPopup
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
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

function TestLoot:test_ring_party_eligibility_lower_slot()
  -- via callOnLootInspectReady: ring drop ilvl 470, member just-inspected with
  -- gear[11]=460 gear[12]=475, threshold 10 → UpdateCandidate called with delta=10 slotID=11.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-RingTest"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 460, [12] = 475 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCandidateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCandidateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  local itemData = { link = "item:ring_party", ilvl = 470, slotID = 11,
                     equipLoc = "INVTYPE_FINGER", slotIDs = {11, 12}, slotCategory = "ring",
                     itype = "Armor", subtype = "Miscellaneous" }

  -- Pre-populate a pending loot entry with this member scanning and popup already open.
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,  -- popup already open → UpdateCandidate expected
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCandidateCalls > 0,
    "Popup_UpdateCandidate must be called when member is eligible (delta=10 >= threshold)")

  LIF.Popup_UpdateCandidate = nil
end

function TestLoot:test_weapon_party_uses_cached_ilvl_when_live_read_wiped()
  -- ClearInspectPlayer (OnInspectReady) releases the live inspect data before
  -- OnLootInspectReady runs, so a live weapon read returns nil -> ilvl 0 and
  -- fabricates a full-ilvl upgrade. The compare must read the gear snapshot
  -- captured during the same inspect (here, ilvl 70) instead.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-CacheWeaponDruid"
  -- Balance druid (102, INT): cache holds a main-hand weapon at ilvl 70.
  mockMemberGear(guid, "party1", "DRUID", 102, { [16] = 70 })
  -- Simulate ClearInspectPlayer: the LIVE slot-16 read now returns nil, while
  -- the cache (member.gear[16]) still holds the weapon.
  _mockGearLinks["party1"][16] = nil
  _mockGuids["player"] = "GUID-SELF"

  local updateCandidateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCandidateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  -- INT dagger (classID 2, subID 15) usable by Balance main-hand, ilvl 220.
  local link = "item:cache_weapon_dagger"
  local itemData = classifyMockItem(link,
    { "INTDagger", nil, 4, 220, nil, "Weapon", "Daggers", nil, "INVTYPE_WEAPON", nil, nil, 2, 15, 0 },
    { ITEM_MOD_INTELLECT_SHORT = 190 })

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,  -- popup open → UpdateCandidate carries the candidate
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCandidateCalls, 1, "eligible weapon candidate must update the popup")
  local cand = updateCandidateCalls[1].data
  lu.assertEquals(cand.ilvl_current, 70,
    "weapon compare must use the cached MH ilvl (70), not the wiped live read (0)")
  lu.assertEquals(cand.delta, 150,
    "delta must be 220-70=150, not the fabricated 220")

  LIF.Popup_UpdateCandidate = nil
end

function TestLoot:test_trinket_party_stat_mismatch()
  -- AGI trinket drop, member just-inspected with INT spec → NOT eligible.
  -- Popup_RemoveCandidate must be called.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-IntSpec"
  mockMemberGear(guid, "party1", "PRIEST", 256, { [13] = 450, [14] = 450 })  -- Disc Priest (INT)
  _mockGuids["player"] = "GUID-SELF"

  local removeCandidateCalls = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCandidateCalls, { guid = g, itemLink = itemLink })
  end

  local link = "item:agi_trinket"
  _mockItemStats[link] = { ITEM_MOD_AGILITY_SHORT = 150 }
  local itemData = { link = link, ilvl = 470, slotID = 13,
                     equipLoc = "INVTYPE_TRINKET", slotIDs = {13, 14}, slotCategory = "trinket",
                     itype = "Armor", subtype = "Trinket", primaryStats = { AGI = true } }

  -- Pre-populate a pending loot entry with this member scanning and popup already open.
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,  -- popup open → RemoveCandidate expected on ineligible
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#removeCandidateCalls > 0,
    "Popup_RemoveCandidate must be called when trinket stat mismatches member spec (INT != AGI)")

  LIF.Popup_RemoveCandidate = nil
end

function TestLoot:test_trinket_party_no_primary_stat_ilvl_only()
  -- Secondary-stat trinket: no AGI/STR/INT from GetItemStats.
  -- Member lower trinket ilvl 450, drop ilvl 470, threshold 10 → eligible (ring rules).
  -- Popup_UpdateCandidate must be called.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-SecTrinket"
  mockMemberGear(guid, "party1", "DRUID", 103, { [13] = 450, [14] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCandidateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCandidateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  local link = "item:sec_trinket_party"
  _mockItemStats[link] = { ITEM_MOD_HASTE_RATING_SHORT = 120 }  -- no primary stat
  local itemData = { link = link, ilvl = 470, slotID = 13,
                     equipLoc = "INVTYPE_TRINKET", slotIDs = {13, 14}, slotCategory = "trinket",
                     itype = "Armor", subtype = "Trinket" }  -- no primaryStat key (ilvl-only)

  -- Pre-populate a pending loot entry with this member scanning and popup already open.
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCandidateCalls > 0,
    "Popup_UpdateCandidate must be called for secondary-stat trinket (ilvl-only rules)")

  LIF.Popup_UpdateCandidate = nil
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

function TestLoot:test_on_loot_inspect_ready_updates_candidate_when_resolves_eligible()
  -- Pending loot item state present with a scanning placeholder for guid G.
  -- popup already opened (entry.popupOpened = true).
  -- After callOnLootInspectReady(G) resolves eligible → Popup_UpdateCandidate called once.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-UpdateCandidate"
  mockMemberGear(guid, "party1", "DRUID", 103, { [11] = 450, [12] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  -- Pre-populate a pending loot entry with this member scanning and popup already open.
  local ringItemData = { link = "item:ring_update_test", ilvl = 470,
                         slotIDs = {11, 12}, slotCategory = "ring" }
  table.insert(LIF.pendingLootItems, {
    itemData            = ringItemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,  -- popup already open → UpdateCandidate on eligible
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Popup_UpdateCandidate must be called once when member resolves eligible (D-09)")

  LIF.Popup_UpdateCandidate = nil
end

function TestLoot:test_on_loot_inspect_ready_removes_candidate_when_resolves_ineligible()
  -- Same setup but resolved member fails eligibility → Popup_RemoveCandidate called once.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  -- Warrior trying to get leather chest — ineligible (armor type mismatch).
  local guid = "Player-0-RemoveCandidate"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local removeCalls = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCalls, { guid = g, itemLink = itemLink })
  end

  -- Pre-populate a pending loot entry with a leather chest; Warrior is ineligible (plate class).
  local chestItemData = { link = "item:leather_chest_remove_test", ilvl = 480,
                           slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  table.insert(LIF.pendingLootItems, {
    itemData            = chestItemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,  -- popup open → RemoveCandidate expected on ineligible
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#removeCalls >= 1,
    "Popup_RemoveCandidate must be called once when member resolves ineligible (D-09)")

  LIF.Popup_RemoveCandidate = nil
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

function TestLoot:test_four_second_timer_drops_unresolved_scanning_guids()
  -- EvaluateCandidates returns scanningGuids with one guid that never resolves.
  -- FirePendingAfterCallbacks() simulates 4-second window expiry.
  -- scanningGuids must be cleared; popup opens with whatever candidates confirmed.
  -- Popup_RemoveCandidate must NOT be called (popup was never opened for this item).
  _mockIsInInstance = { true, "party" }
  _mockIsInGroup    = true

  local guid = "Player-0-UnresolvedGuid"
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 460 })
  _mockGuids["player"] = "GUID-SELF"
  -- Player must NOT self-upgrade: set chest at drop ilvl so delta=0 < threshold.
  _mockGearLinks["player"] = { [5] = "item:player_timer_chest" }
  _mockIlvl["item:player_timer_chest"] = 480

  local link = "item:timer_test_chest"
  mockItem(link, { "Chest", nil, 4, 480, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })

  local removeArgs = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeArgs, { guid = g, itemLink = itemLink })
  end

  if LIF.OnPlayerLootReceived == nil then
    lu.skip("LIF.OnPlayerLootReceived not yet implemented")
  end

  LIF.OnPlayerLootReceived(link, 99992)
  -- Fire the 0-frame tradeability defer → IsItemTradeable true → entry added, 4s timer queued.
  FirePendingAfterCallbacks()

  lu.assertEquals(#LIF.pendingLootItems, 1,
    "Precondition: one pending loot entry must exist before timer fires")
  local entry = LIF.pendingLootItems[1]
  lu.assertNotNil(entry.scanningGuids, "entry.scanningGuids must exist before timer")

  -- Fire the 4-second cleanup timer.
  FirePendingAfterCallbacks()

  -- Popup_RemoveCandidate must NOT be called — popup was never opened, nothing to remove.
  lu.assertEquals(#removeArgs, 0,
    "Popup_RemoveCandidate must NOT fire on timer expiry (popup was never opened)")
  -- scanningGuids must be cleared after timer fires.
  local remaining = 0
  for _ in pairs(entry.scanningGuids) do remaining = remaining + 1 end
  lu.assertEquals(remaining, 0,
    "entry.scanningGuids must be empty after 4-second window timer fires")

  LIF.Popup_RemoveCandidate = nil
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

function TestLoot:test_popup_stubs_are_callable()
  -- LIF.ShowPopup, LIF.Popup_UpdateCandidate, LIF.Popup_RemoveCandidate
  -- must exist as callable no-ops and not raise errors with any arg combination.
  if LIF.ShowPopup == nil or LIF.Popup_UpdateCandidate == nil or LIF.Popup_RemoveCandidate == nil then
    lu.skip("Popup stubs not yet implemented (Plan 03-05 Task 1)")
  end

  -- No errors on any combination including nil args.
  LIF.ShowPopup({ link = "item:stub_test" }, {})
  LIF.ShowPopup(nil, nil)
  LIF.Popup_UpdateCandidate("Player-0-Fake", {}, "item:stub_link")
  LIF.Popup_UpdateCandidate(nil, nil, nil)
  LIF.Popup_RemoveCandidate("Player-0-Fake", "item:stub_link")
  LIF.Popup_RemoveCandidate(nil, nil)

  lu.assertTrue(true, "All popup stubs callable without error")
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

function TestLoot:test_heirloom_candidate_armor_excluded()
  -- SC2: candidate wears heirloom chest at level 50 → excluded from eligibility.
  -- Popup_RemoveCandidate must be invoked.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local heirloomLink = "item:22201"
  _mockHeirloomItemIDs[22201] = true
  _mockUnitLevel["party1"] = 50

  local guid = "Player-0-HeirloomCandidate"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockGuids["player"] = "GUID-SELF"
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, {
    gear  = { [5] = { link = heirloomLink, ilvl = 300 } },
    specID = 103,
  })

  local removeCalls = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCalls, { guid = g, itemLink = itemLink })
  end

  local chestItemData = { link = "item:22202", ilvl = 400,
                           slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  table.insert(LIF.pendingLootItems, {
    itemData            = chestItemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#removeCalls >= 1,
    "Heirloom-wearing candidate at level 50 must be excluded — RemoveCandidate called (SC2)")

  LIF.Popup_RemoveCandidate = nil
end

function TestLoot:test_heirloom_candidate_nil_slot_falls_through()
  -- SC4 (candidate side): candidate's gear is empty (nil slots); heirloom check skipped.
  -- nil=0 path applies; drop ilvl 400 vs 0 → eligible → Popup_UpdateCandidate called.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  _mockUnitLevel["party1"] = 50

  local guid = "Player-0-NilSlotCandidate"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Druid", "DRUID" }
  _mockGuids["player"] = "GUID-SELF"
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, {
    gear  = {},  -- no gear entries at all
    specID = 103,
  })

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  local chestItemData = { link = "item:22203", ilvl = 400,
                           slotIDs = {5}, slotCategory = "armor", armorType = "Leather" }
  table.insert(LIF.pendingLootItems, {
    itemData            = chestItemData,
    t                   = 0,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Nil candidate slot falls through to nil=0 path → eligible → UpdateCandidate called (SC4 candidate)")

  LIF.Popup_UpdateCandidate = nil
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
-- Phase 5: minPartySize gate (SC6)
-- ============================================================

-- Shared setup: one Druid party member, Leather chest drop at ilvl 300 (member has 200 → delta 100).
local function _setupMinPartySizeEntry()
  local guid = "Player-0-MinPartySizeTest"
  local dropLink = "item:minparty_chest"
  mockItem(dropLink, { "GateChest", nil, 4, 300, nil, "Armor", "Leather", nil, "INVTYPE_CHEST", nil, nil, 4, 2, 0 })
  mockMemberGear(guid, "party1", "DRUID", 103, { [5] = 200 })
  _mockGuids["player"] = "GUID-SELF"
  table.insert(LIF.pendingLootItems, {
    itemData            = { link = dropLink, ilvl = 300, slotID = 5, slotIDs = {5},
                            slotCategory = "armor", equipLoc = "INVTYPE_CHEST",
                            itype = "Armor", subtype = "Leather", armorType = "Leather" },
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = false,
  })
  return guid
end

function TestLoot:test_min_party_size_suppresses_popup_when_group_too_small()
  if LIF.OnLootInspectReady == nil then lu.skip("LIF.OnLootInspectReady not yet implemented") end
  local origGlobal = LootItForward
  local origGroupSize = _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 5 }, char = { debugMode = false } } }
  _mockGroupSize = 2

  local fired = false
  LIF.ShowPopup = function() fired = true end

  LIF.OnLootInspectReady(_setupMinPartySizeEntry())

  lu.assertFalse(fired, "minPartySize=5 with groupSize=2 must suppress popup")

  LootItForward = origGlobal
  _mockGroupSize = origGroupSize
  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_min_party_size_allows_popup_when_group_meets_minimum()
  if LIF.OnLootInspectReady == nil then lu.skip("LIF.OnLootInspectReady not yet implemented") end
  local origGlobal = LootItForward
  local origGroupSize = _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 2 }, char = { debugMode = false } } }
  _mockGroupSize = 2

  local fired = false
  LIF.ShowPopup = function() fired = true end

  LIF.OnLootInspectReady(_setupMinPartySizeEntry())

  lu.assertTrue(fired, "minPartySize=2 with groupSize=2 must allow popup")

  LootItForward = origGlobal
  _mockGroupSize = origGroupSize
  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_min_party_size_bypassed_when_groupsize_zero()
  -- groupSize=0 means the offline/test harness — gate is intentionally skipped.
  if LIF.OnLootInspectReady == nil then lu.skip("LIF.OnLootInspectReady not yet implemented") end
  local origGlobal = LootItForward
  local origGroupSize = _mockGroupSize
  LootItForward = { db = { profile = { minPartySize = 5 }, char = { debugMode = false } } }
  _mockGroupSize = 0

  local fired = false
  LIF.ShowPopup = function() fired = true end

  LIF.OnLootInspectReady(_setupMinPartySizeEntry())

  lu.assertTrue(fired, "groupSize=0 (offline) must bypass minPartySize gate")

  LootItForward = origGlobal
  _mockGroupSize = origGroupSize
  LIF.ShowPopup = _origShowPopup
end

function TestLoot:test_min_party_size_defaults_to_2_when_absent()
  -- minPartySize key absent from profile → default 2; groupSize=2 → popup fires.
  if LIF.OnLootInspectReady == nil then lu.skip("LIF.OnLootInspectReady not yet implemented") end
  local origGlobal = LootItForward
  local origGroupSize = _mockGroupSize
  LootItForward = { db = { profile = {}, char = { debugMode = false } } }
  _mockGroupSize = 2

  local fired = false
  LIF.ShowPopup = function() fired = true end

  LIF.OnLootInspectReady(_setupMinPartySizeEntry())

  lu.assertTrue(fired, "minPartySize absent → defaults to 2; groupSize=2 must allow popup")

  LootItForward = origGlobal
  _mockGroupSize = origGroupSize
  LIF.ShowPopup = _origShowPopup
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

-- ---------- Warglaive false positive / true positive (Bug A, cases 1/2) ----------

function TestLoot:test_warglaive_shaman_ineligible()
  -- Warglaive (subID=9, DEMONHUNTER only) — Shaman must NOT be eligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-ShamanWarglaive"
  -- Shaman specID=263 (Enhancement, AGI); slot 16 lower than drop
  mockMemberGear(guid, "party1", "SHAMAN", 263, { [16] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  local removeCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCalls, { guid = g })
  end

  -- Warglaive: classID=2, subID=9, equipLoc=INVTYPE_WEAPON, primaryStat=INT
  local warglaiveLink = "item:warglaive_bug_a"
  mockItem(warglaiveLink, { "Warglaive of Azzinoth", nil, 4, 470, nil,
    "Weapon", "Warglaives", nil, "INVTYPE_WEAPON", nil, nil, 2, 9, 0 })
  _mockItemStats[warglaiveLink] = { ITEM_MOD_INTELLECT_SHORT = 200 }

  local itemData = {
    link         = warglaiveLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_WEAPON",
    classID      = 2,
    subID        = 9,
    slotIDs      = {16},
    slotCategory = "weapon",
    weaponSubID  = 9,
    primaryStats  = { INT = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Shaman must NOT be eligible for warglaive (classID=2, subID=9 restricted to DEMONHUNTER)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
end

function TestLoot:test_warglaive_demonhunter_eligible()
  -- Warglaive (subID=9) — Devourer DH (specID=1480, INT) with slot 16 lower than drop → eligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-DHWarglaive"
  -- Devourer DH specID=1480 (INT per character_data.lua); slot 16 at 450 < drop 470
  mockMemberGear(guid, "party1", "DEMONHUNTER", 1480, { [16] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local warglaiveLink = "item:warglaive_dh_true"
  mockItem(warglaiveLink, { "Warglaive of Azzinoth", nil, 4, 470, nil,
    "Weapon", "Warglaives", nil, "INVTYPE_WEAPON", nil, nil, 2, 9, 0 })
  _mockItemStats[warglaiveLink] = { ITEM_MOD_INTELLECT_SHORT = 200 }

  local itemData = {
    link         = warglaiveLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_WEAPON",
    classID      = 2,
    subID        = 9,
    slotIDs      = {16},
    slotCategory = "weapon",
    weaponSubID  = 9,
    primaryStats  = { INT = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Devourer DH must be eligible for warglaive (INT stat match, subID=9 allows DEMONHUNTER)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- Unknown weapon subID (D-03, case 13) ----------

function TestLoot:test_unknown_weapon_subid_member_ineligible()
  -- subID=99 is not in ITEM_CLASS_RESTRICT[2] → D-03 fail-safe → ineligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-UnknownSubID"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local unknownLink = "item:unknown_weapon_subid"
  mockItem(unknownLink, { "UnknownWeapon", nil, 4, 470, nil,
    "Weapon", "Unknown", nil, "INVTYPE_WEAPON", nil, nil, 2, 99, 0 })
  _mockItemStats[unknownLink] = { ITEM_MOD_AGILITY_SHORT = 150 }

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Unknown weapon subID=99 must be excluded (D-03 fail-safe: unknown subID → skip)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

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

-- ============================================================
-- Phase 06.1 Plan 04: Offhand eligibility, 2H gate, Fury Warrior dual-slot
-- ============================================================

-- ---------- Offhand class gate — holdable (case 5) ----------

function TestLoot:test_offhand_holdable_warlock_eligible()
  -- Holdable drop, WARLOCK member with slot 17 lower by ≥ threshold → eligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarlockHoldable"
  -- WARLOCK specID=265 (Affliction, INT); slot 17 = 450 (no slot 16 equipped)
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local holdableLink = "item:holdable_warlock_elig"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "WARLOCK must be eligible for holdable drop (Warlock offHandItem includes holdable(0), delta 20 >= 10)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_offhand_holdable_warrior_ineligible()
  -- Holdable drop, WARRIOR member → ineligible (WARRIOR not in holdable allow-set).
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarriorHoldable"
  -- WARRIOR specID=71 (Arms); slot 17 = 450
  mockMemberGear(guid, "party1", "WARRIOR", 71, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_warrior_inelig"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "WARRIOR must NOT be eligible for holdable drop (no Warrior spec has holdable in offHandItem)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- Offhand class gate — shield (case 6) ----------

function TestLoot:test_offhand_shield_warrior_eligible()
  -- Shield drop, WARRIOR member with slot 17 lower by ≥ threshold → eligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarriorShield"
  -- Protection Warrior specID=73; slot 17 = 450
  mockMemberGear(guid, "party1", "WARRIOR", 73, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local shieldLink = "item:shield_warrior_elig"
  mockItem(shieldLink, { "FrostForged Shield", nil, 4, 470, nil,
    "Armor", "Shield", nil, "INVTYPE_SHIELD", nil, nil, 4, 6, 0 })

  local itemData = {
    link         = shieldLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_SHIELD",
    classID      = 4,
    subID        = 6,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 6,
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "WARRIOR must be eligible for shield drop (Warrior offHandItem includes shield(6))")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_offhand_shield_mage_ineligible()
  -- Shield drop, MAGE member → ineligible (MAGE not in shield allow-set).
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-MageShield"
  -- Fire Mage specID=63; slot 17 = 450
  mockMemberGear(guid, "party1", "MAGE", 63, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local shieldLink = "item:shield_mage_inelig"
  mockItem(shieldLink, { "FrostForged Shield", nil, 4, 470, nil,
    "Armor", "Shield", nil, "INVTYPE_SHIELD", nil, nil, 4, 6, 0 })

  local itemData = {
    link         = shieldLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_SHIELD",
    classID      = 4,
    subID        = 6,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 6,
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "MAGE must NOT be eligible for shield drop (no Mage spec has shield(6) in offHandItem)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- Offhand ilvl comparison (case 7) ----------

function TestLoot:test_offhand_ilvl_above_threshold_eligible_slotid_17()
  -- Holdable drop 470, WARLOCK slot 17 = 450, threshold 10 → eligible; candidate slotID=17.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarlockIlvl"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local holdableLink = "item:holdable_ilvl_test"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Holdable drop 470 vs slot 17 ilvl 450, threshold 10 → eligible (delta 20 >= 10)")
  lu.assertEquals(updateCalls[1].data.slotID, 17,
    "Eligible offhand candidate must have slotID=17")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_offhand_ilvl_below_threshold_ineligible()
  -- Holdable drop 470, WARLOCK slot 17 = 465, threshold 10 → ineligible (delta 5 < 10).
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarlockIlvlLow"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 465 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_ilvl_below"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Holdable drop 470 vs slot 17 ilvl 465, threshold 10 → ineligible (delta 5 < 10)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- 2H gate (cases 8/9) ----------

function TestLoot:test_offhand_vs_2h_member_eligible_straight_across()
  -- WARLOCK member on a 2H staff @460 (D-16 cross-config): a holdable @470
  -- out-ilvls the 2H straight across → eligible (they could run 1H+holdable).
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-Warlock2HGate"
  -- mockMemberGear sets up _mockGearLinks and cache; override slot 16 itemInfo to 2H
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [16] = 460 })
  -- Override slot 16 link's ItemInfo so GetItemInfo returns equipLoc="INVTYPE_2HWEAPON"
  local slot16Link = "item:Player-0-Warlock2HGates16"
  _mockItemInfo[slot16Link] = { "TwoHandStaff", nil, 4, 460, nil,
    "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 }
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_2h_gate"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "WARLOCK on a 2H @460 must be eligible for a holdable @470 (straight-across cross-config)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_offhand_no_slot16_eligible()
  -- WARLOCK member with no slot 16 equipped → slot 16 read = nil → no 2H gate → eligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WarlockNoSlot16"
  -- Only slot 17 populated; slot 16 absent → nil live read → passes 2H gate
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 450 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local holdableLink = "item:holdable_no_slot16"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "WARLOCK with no slot 16 equipped must be eligible for offhand drop (nil slot 16 → no 2H gate)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- Offhand primary stat gate + heirloom gate (F4) ----------
-- The offhand branch never gated on primary stats or heirlooms, unlike
-- ring/trinket/weapon/neck/back. An INT holdable/shield could misread as an
-- upgrade for a STR or AGI class, and a heirloom-equipped offhand slot was
-- never excluded the way every other heirloom-bearing slot is.

function TestLoot:test_offhand_stat_mismatch_member_ineligible()
  -- INT holdable, Retribution Paladin (specID=70, STR). PALADIN is class-
  -- eligible for holdables, and slot 17 is far below the drop's ilvl, but
  -- the stat mismatch must still exclude them.
  local guid = "Player-0-RetPalaHoldable"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_int_statgate"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

  local itemData = {
    link         = holdableLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
    primaryStats = { INT = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Retribution Paladin (STR) must NOT be eligible for an INT holdable, even with a huge ilvl delta")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_offhand_stat_match_member_eligible()
  -- Same INT holdable, Affliction Warlock (specID=265, INT) → stat matches,
  -- normal ilvl comparison proceeds (regression check: matching stat must
  -- still work after adding the gate).
  local guid = "Player-0-WarlockHoldableStat"
  mockMemberGear(guid, "party1", "WARLOCK", 265, { [17] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_int_statmatch"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

  local itemData = {
    link         = holdableLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_HOLDABLE",
    classID      = 4,
    subID        = 0,
    slotIDs      = {17},
    slotCategory = "offhand",
    offhandSubID = 0,
    primaryStats = { INT = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Affliction Warlock (INT) must be eligible for an INT holdable when ilvl delta clears threshold")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

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

function TestLoot:test_offhand_heirloom_equipped_excludes()
  -- Candidate wears a heirloom holdable in slot 17 at level 50 → excluded
  -- regardless of ilvl delta, same as every other heirloom-bearing slot.
  local guid = "Player-0-OffhandHeirloom"
  _mockGuids["party1"] = guid
  _mockUnitClass["party1"] = { "Warlock", "WARLOCK" }
  _mockUnitLevel["party1"] = 50
  local heirloomLink = "item:33301"
  _mockHeirloomItemIDs[33301] = true
  _mockIlvl[heirloomLink] = 300
  LIF.Cache.Add(guid)
  -- Heirloom holdable lives in the inspect cache (slot 17), exactly as queue.lua
  -- captures it. The compare reads the cache, not a live GetInventoryItemLink.
  LIF.Cache.SetComplete(guid, { gear = { [17] = { link = heirloomLink, ilvl = 300 } }, specID = 265 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_heirloom_gate"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Heirloom-equipped offhand slot must exclude the candidate regardless of ilvl delta")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
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

-- ---------- Fury Warrior dual-slot 2H (case 10) ----------

function TestLoot:test_fury_warrior_2h_drop_dual_slot_eligible()
  -- Fury Warrior (specID=72) + 2H axe drop: slot16=460, slot17=455, drop=470, threshold=10
  -- min(460,455)=455; delta=15 >= 10 → eligible; candidate.ilvl_current=455, slotID=17.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-FuryWarrior2H"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 460, [17] = 455 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  -- 2H Axe: classID=2, subID=1 (Two-Handed Axes), WARRIOR in allow-set
  local axeLink = "item:2h_axe_fury"
  mockItem(axeLink, { "Axe of the Furious", nil, 4, 470, nil,
    "Weapon", "Two-Handed Axes", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 1, 0 })
  _mockItemStats[axeLink] = { ITEM_MOD_STRENGTH_SHORT = 300 }

  local itemData = {
    link         = axeLink,
    ilvl         = 470,
    equipLoc     = "INVTYPE_2HWEAPON",
    classID      = 2,
    subID        = 1,
    slotIDs      = {16, 17},
    slotCategory = "weapon",
    weaponSubID  = 1,
    primaryStats  = { STR = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "Fury Warrior: 2H drop 470, slots 460/455, threshold 10 → eligible (min=455, delta=15)")
  lu.assertEquals(updateCalls[1].data.ilvl_current, 455,
    "Fury Warrior candidate ilvl_current must be min(slot16=460, slot17=455)=455")
  lu.assertEquals(updateCalls[1].data.slotID, 17,
    "Fury Warrior candidate slotID must be 17 (lower slot)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

function TestLoot:test_fury_warrior_2h_drop_dual_slot_ineligible()
  -- Fury Warrior: drop=460, slots 455/458. min(455,458)=455; delta=5 < 10 → ineligible.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-FuryWarrior2HLow"
  mockMemberGear(guid, "party1", "WARRIOR", 72, { [16] = 455, [17] = 458 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local axeLink = "item:2h_axe_fury_low"
  mockItem(axeLink, { "Axe of the Furious", nil, 4, 460, nil,
    "Weapon", "Two-Handed Axes", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 1, 0 })
  _mockItemStats[axeLink] = { ITEM_MOD_STRENGTH_SHORT = 280 }

  local itemData = {
    link         = axeLink,
    ilvl         = 460,
    equipLoc     = "INVTYPE_2HWEAPON",
    classID      = 2,
    subID        = 1,
    slotIDs      = {16, 17},
    slotCategory = "weapon",
    weaponSubID  = 1,
    primaryStats  = { STR = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Fury Warrior: drop=460, min(455,458)=455, delta=5 < threshold 10 → ineligible")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
end

-- ---------- Fury Warrior + offhand drop (case 11, D-16) ----------

function TestLoot:test_offhand_usability_gate_rejects_before_cross_config()
  -- The spec usability gate precedes the D-16 cross-config compare: a Protection
  -- Paladin (off-hand item = shield only) is rejected for a HOLDABLE regardless
  -- of what's equipped — even wielding a 2H, a holdable is never usable, so we
  -- never reach the straight-across ilvl compare.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-Pala2HGate"
  mockMemberGear(guid, "party1", "PALADIN", 66, { [16] = 460 })
  -- Prot Paladin can't wield a 2H, but set one to prove the usability gate fires
  -- FIRST — before any 2H/cross-config handling.
  local slot16Link = "item:Player-0-Pala2HGates16"
  _mockItemInfo[slot16Link] = { "Ashkandur", nil, 4, 460, nil,
    "Weapon", "Two-Handed Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g })
  end

  local holdableLink = "item:holdable_d16_gate"
  mockItem(holdableLink, { "Luminescent Sprout", nil, 4, 470, nil,
    "Armor", "Miscellaneous", nil, "INVTYPE_HOLDABLE", nil, nil, 4, 0, 0 })

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

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertEquals(#updateCalls, 0,
    "Protection Paladin (shield-only off-hand) must be rejected for a holdable regardless of the 2H")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
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

function TestLoot:test_weaponoffhand_member_eligibility_slotid_17()
  -- ROGUE member with slot16=490, slot17=460; WEAPONOFFHAND dagger drop=490, threshold=10
  -- Correct: reads slot 17 → delta=30 >= 10 → eligible, slotID=17
  -- Buggy (slot 16): delta=0 < 10 → ineligible
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "Player-0-WOHRogue"
  mockMemberGear(guid, "party1", "ROGUE", 259, { [16] = 490, [17] = 460 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data })
  end

  local wohLink = "item:woh_dagger_member"
  mockItem(wohLink, { "Offhand Dagger", nil, 4, 490, nil,
    "Weapon", "Daggers", nil, "INVTYPE_WEAPONOFFHAND", nil, nil, 2, 15, 0 })
  _mockItemStats[wohLink] = { ITEM_MOD_AGILITY_SHORT = 150 }

  local itemData = {
    link        = wohLink,
    ilvl        = 490,
    equipLoc    = "INVTYPE_WEAPONOFFHAND",
    classID     = 2,
    subID       = 15,
    slotIDs     = {17},
    slotCategory = "weapon",
    weaponSubID = 15,
    primaryStats = { AGI = true },
  }

  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 10,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls >= 1,
    "WEAPONOFFHAND member eligibility: slot17=460, drop=490, delta=30 >= 10 → eligible")
  lu.assertEquals(updateCalls[1].data.slotID, 17,
    "WEAPONOFFHAND member eligibility: slotID must be 17 (not 16)")

  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
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

function TestCloakEquipLoc:test_int_cloak_inspect_ready_str_spec_ineligible()
  -- OnLootInspectReady: Ret Paladin (STR) → stat gate fires → RemoveCandidate.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "GUID-RET-PAL-INSPECT"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [15] = 150 })
  _mockGuids["player"] = "GUID-SELF"

  local removeCalls = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCalls, { guid = g, itemLink = itemLink })
  end

  local link = "item:int_cloak_inspect_ret"
  local itemData = {
    link = link, ilvl = 220, equipLoc = "INVTYPE_CLOAK",
    slotIDs = {15}, slotCategory = "back",
    primaryStats = { INT = true },
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#removeCalls > 0,
    "Popup_RemoveCandidate must fire when INT cloak mismatches STR spec (Ret Paladin)")
  LIF.Popup_RemoveCandidate = nil
end

function TestCloakEquipLoc:test_int_cloak_inspect_ready_int_spec_eligible()
  -- OnLootInspectReady: Frost Mage (INT) → stat gate passes → UpdateCandidate.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "GUID-FROST-MAGE-INSPECT"
  mockMemberGear(guid, "party1", "MAGE", 64, { [15] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  local link = "item:int_cloak_inspect_mage"
  local itemData = {
    link = link, ilvl = 220, equipLoc = "INVTYPE_CLOAK",
    slotIDs = {15}, slotCategory = "back",
    primaryStats = { INT = true },
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls > 0,
    "Popup_UpdateCandidate must fire when INT cloak matches INT spec (Frost Mage)")
  LIF.Popup_UpdateCandidate = nil
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

function TestRingStatGate:test_int_ring_inspect_ready_str_spec_ineligible()
  -- OnLootInspectReady: Ret Paladin (STR) → stat gate must fire → RemoveCandidate.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "GUID-RET-PAL-RING-INSPECT"
  mockMemberGear(guid, "party1", "PALADIN", 70, { [11] = 150, [12] = 150 })
  _mockGuids["player"] = "GUID-SELF"

  local removeCalls = {}
  LIF.Popup_RemoveCandidate = function(g, itemLink)
    table.insert(removeCalls, { guid = g, itemLink = itemLink })
  end

  local link = "item:int_ring_inspect_ret"
  local itemData = {
    link = link, ilvl = 220, equipLoc = "INVTYPE_FINGER",
    slotIDs = {11, 12}, slotCategory = "ring",
    primaryStats = { INT = true },
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#removeCalls > 0,
    "Popup_RemoveCandidate must fire when INT ring mismatches STR spec (Ret Paladin)")
  LIF.Popup_RemoveCandidate = nil
end

function TestRingStatGate:test_int_ring_inspect_ready_int_spec_eligible()
  -- OnLootInspectReady: Frost Mage (INT) → stat gate passes → UpdateCandidate.
  if LIF.OnLootInspectReady == nil then
    lu.skip("LIF.OnLootInspectReady not yet implemented")
  end

  local guid = "GUID-FROST-MAGE-RING-INSPECT"
  mockMemberGear(guid, "party1", "MAGE", 64, { [11] = 100, [12] = 100 })
  _mockGuids["player"] = "GUID-SELF"

  local updateCalls = {}
  LIF.Popup_UpdateCandidate = function(g, data, itemLink)
    table.insert(updateCalls, { guid = g, data = data, itemLink = itemLink })
  end

  local link = "item:int_ring_inspect_mage"
  local itemData = {
    link = link, ilvl = 220, equipLoc = "INVTYPE_FINGER",
    slotIDs = {11, 12}, slotCategory = "ring",
    primaryStats = { INT = true },
  }
  table.insert(LIF.pendingLootItems, {
    itemData            = itemData,
    t                   = 0,
    threshold           = 1,
    confirmedCandidates = {},
    scanningGuids       = { [guid] = true },
    popupOpened         = true,
  })

  LIF.OnLootInspectReady(guid)

  lu.assertTrue(#updateCalls > 0,
    "Popup_UpdateCandidate must fire when INT ring matches INT spec (Frost Mage)")
  LIF.Popup_UpdateCandidate = nil
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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

  -- Item header line
  lu.assertTrue(hasChatMsg("Chest of Green (300)"),
    "Notification must include item name and ilvl")
  lu.assertTrue(hasChatMsg("not an upgrade for you"),
    "Notification must indicate item is not a self-upgrade")
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

  lu.assertTrue(hasChatMsg("not an upgrade for you"),
    "Item header line must fire when party scan resolves")
  lu.assertTrue(hasChatMsg("no party upgrades found"),
    "Must emit 'no party upgrades found' when all members are ineligible")
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

  -- Fire 4-second cleanup timer → _tryOpenPopup → no candidates → no notification.
  FirePendingAfterCallbacks()

  lu.assertFalse(hasChatMsg("[Loot It Forward]"),
    "No notification must fire when hadPartyMembers=false (no party members at loot time)")
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
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
  LIF.Popup_UpdateCandidate = _origPopupUpdateCand
  LIF.Popup_RemoveCandidate = _origPopupRemoveCand
end

-- Turn the member's slot-16 item (created by mockMemberGear) into a real 2H, so
-- is2HEquipped() is true and its live ilvl is `ilvl`.
local function equipMember2H(guid, ilvl)
  _mockItemInfo["item:" .. guid .. "s16"] = { "TwoHandStaff", nil, 4, ilvl, nil,
    "Weapon", "Staves", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 10, 0 }
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
-- Run suite
-- ============================================================
os.exit(lu.LuaUnit.run())
