-- tests/test_scan.lua
-- luaunit test suite for Phase 2 scan system requirements.
-- Run: lua tests/test_scan.lua  (from project root)
--
-- Expected state for Wave 0 (this plan): most tests FAIL because queue.lua
-- TODO bodies are not yet filled. That is intentional — these tests are the
-- RED gate that Wave 2 (02-02) turns GREEN.
--
-- Tests that can pass against the current skeleton:
--   - Queue_StopAndReset resets state
--   - Tests with unimplemented functions skip cleanly via lu.skip()

-- ============================================================
-- Setup: path and mocks
-- ============================================================
-- Add both: tests/ (for mock_wow_api when run from project root) and ../ (for luaunit).
package.path = package.path .. ";./tests/?.lua;../?.lua;../tests/?.lua"

-- Load WoW API stubs into global scope before loading addon modules.
require("mock_wow_api")

-- Build the LIF namespace and load modules into it.
-- Determine core path: if running from project root the core dir is "core/",
-- if running from tests/ the core dir is "../core". Use arg[0] to detect.
local LIF = {}
local _coreDir = "core"
if arg and arg[0] then
  -- If the script path contains "tests/" we are in that directory.
  local scriptPath = arg[0]:match("(.+)/[^/]+$") or "."
  if scriptPath == "." or scriptPath == "tests" then
    -- Running from project root (lua tests/test_scan.lua) or from tests/ dir.
    -- When run as "lua tests/test_scan.lua" from root, cwd is project root.
    -- When run as "lua test_scan.lua" from tests/, cwd is tests/.
    -- Detect by checking if "core/cache.lua" exists from cwd.
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

local lu = require("luaunit")

-- ============================================================
-- Helpers
-- ============================================================

-- Set up a mock roster with a single party member and return their GUID.
local function setupParty1(guid)
  guid = guid or "Player-0-P1"
  _mockGuids["party1"] = guid
  _mockGuids["player"] = "GUID-SELF"
  return guid
end

-- Trigger OnGroupRosterUpdate if available; skip test if not yet implemented.
local function callRosterUpdate()
  if LIF.OnGroupRosterUpdate == nil then
    lu.skip("LIF.OnGroupRosterUpdate not yet implemented")
  end
  LIF.OnGroupRosterUpdate()
end

-- ============================================================
-- Test class
-- ============================================================
TestQueue = {}

function TestQueue:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
end

-- ------------------------------------------------------------
-- test_stop_and_reset
-- Verifies that Queue_StopAndReset clears in-flight state.
-- This already passes because Queue_StopAndReset is implemented.
-- ------------------------------------------------------------
function TestQueue:test_stop_and_reset()
  -- After a full reset the cache is empty and no inspect is in flight.
  lu.assertNil(LIF.Cache.GetMember("Player-0-P1"))
  -- Queue_StopAndReset is the only public function fully implemented in the skeleton;
  -- calling it again should be a no-op.
  LIF.Queue_StopAndReset()
  lu.assertEquals(#_notifyInspectCalls, 0)
end

-- ------------------------------------------------------------
-- test_preflight_blocks_npc (REQ-inspect-preflight-guard)
-- CanScanUnit must reject non-player units; NotifyInspect must NOT be called.
-- Tests via roster update that adds a non-player slot.
-- ------------------------------------------------------------
function TestQueue:test_preflight_blocks_npc()
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party1"] = "Player-0-P1"
  _mockIsPlayer["party1"] = false  -- NPC follower

  callRosterUpdate()

  lu.assertEquals(#_notifyInspectCalls, 0,
    "NotifyInspect must NOT be called for non-player unit")
end

-- ------------------------------------------------------------
-- test_sentinel_blocks_concurrent (REQ-scan-queue-sequential)
-- Only one inspect must run at a time; second member waits in queue.
-- ------------------------------------------------------------
function TestQueue:test_sentinel_blocks_concurrent()
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party1"] = "Player-0-P1"
  _mockGuids["party2"] = "GUID-P2"

  callRosterUpdate()

  -- Only the first member should have triggered NotifyInspect.
  lu.assertEquals(#_notifyInspectCalls, 1,
    "Only one NotifyInspect call expected while sentinel is held")
end

-- ------------------------------------------------------------
-- test_roster_diff_adds_pending (REQ-party-scan-on-entry)
-- New group member should appear in cache as PENDING after roster update.
-- ------------------------------------------------------------
function TestQueue:test_roster_diff_adds_pending()
  local guid = setupParty1("Player-0-P1")

  callRosterUpdate()

  local member = LIF.Cache.GetMember(guid)
  lu.assertNotNil(member, "Cache entry must exist after roster update")
  lu.assertEquals(member.state, "PENDING",
    "New member must be PENDING after roster diff")
end

-- ------------------------------------------------------------
-- test_roster_diff_removes_departed (REQ-party-scan-on-entry)
-- Members no longer in the roster must be removed from cache.
-- ------------------------------------------------------------
function TestQueue:test_roster_diff_removes_departed()
  -- Pre-populate cache with GUID-P1 as if they had been scanned.
  LIF.Cache.Add("Player-0-P1")

  -- Now the roster has no party1 mapping — GUID-P1 departed.
  _mockGuids["player"] = "GUID-SELF"
  -- party1 is absent from _mockGuids

  callRosterUpdate()

  lu.assertNil(LIF.Cache.GetMember("Player-0-P1"),
    "Departed member must be removed from cache")
end

-- ------------------------------------------------------------
-- test_inspect_ready_departure_prunes_pending_loot (AUD-303)
-- If a member's guid→unit mapping is gone by the time INSPECT_READY processes it,
-- the guid is removed from cache on that path — but the pending-loot prune
-- (scanningGuids clear + Loot_TryOpenPopup) previously lived ONLY in
-- OnGroupRosterUpdate. If that roster fire hasn't run yet, the departed guid stays
-- in scanningGuids and blocks the popup until the adaptive window expires. The
-- prune must run on the OnInspectReady departure path too.
-- ------------------------------------------------------------
function TestQueue:test_inspect_ready_departure_prunes_pending_loot()
  local guid = "Player-0-Gone"
  LIF.Cache.Add(guid)  -- PENDING; no _mockGuids mapping → GuidToUnit(guid) == nil

  local entry = {
    itemData            = { link = "item:x", ilvl = 100, slotCategory = "armor" },
    scanningGuids       = { [guid] = true },
    confirmedCandidates = {},
    popupOpened         = false,
  }
  LIF.pendingLootItems = { entry }

  local opened = false
  local origTryOpen = LIF.Loot_TryOpenPopup
  LIF.Loot_TryOpenPopup = function(e) if e == entry then opened = true end end

  LIF.OnInspectReady(guid)

  LIF.Loot_TryOpenPopup = origTryOpen

  lu.assertNil(entry.scanningGuids[guid],
    "AUD-303: departed guid must be pruned from scanningGuids on the INSPECT_READY path")
  lu.assertTrue(opened,
    "AUD-303: pruning the last outstanding scan must trigger Loot_TryOpenPopup")
end

-- ------------------------------------------------------------
-- test_start_next_inspect_departure_prunes_pending_loot (AUD-303)
-- The queue-pop departure path (StartNextInspect finds a nil guid→unit) must prune
-- pending loot too. Driven via RequestReinspect, which front-queues the guid and
-- kicks StartNextInspect when nothing is in flight.
-- ------------------------------------------------------------
function TestQueue:test_start_next_inspect_departure_prunes_pending_loot()
  local guid = "Player-0-GoneQueue"
  LIF.Cache.Add(guid)  -- PENDING; no _mockGuids mapping → GuidToUnit(guid) == nil

  local entry = {
    itemData            = { link = "item:y", ilvl = 100, slotCategory = "armor" },
    scanningGuids       = { [guid] = true },
    confirmedCandidates = {},
    popupOpened         = false,
  }
  LIF.pendingLootItems = { entry }

  local opened = false
  local origTryOpen = LIF.Loot_TryOpenPopup
  LIF.Loot_TryOpenPopup = function(e) if e == entry then opened = true end end

  LIF.RequestReinspect(guid)  -- currentlyInspecting is nil → kicks StartNextInspect

  LIF.Loot_TryOpenPopup = origTryOpen

  lu.assertNil(entry.scanningGuids[guid],
    "AUD-303: departed guid must be pruned on the StartNextInspect (queue-pop) path")
  lu.assertTrue(opened,
    "AUD-303: queue-pop prune of the last scan must trigger Loot_TryOpenPopup")
end

-- ------------------------------------------------------------
-- test_guid_stability_survives_slot_change (REQ-cache-key-by-guid)
-- GUID-keyed cache must survive slot reassignment without data loss.
-- ------------------------------------------------------------
function TestQueue:test_guid_stability_survives_slot_change()
  -- GUID-P1 was in party1 and is now COMPLETE.
  LIF.Cache.Add("Player-0-P1")
  LIF.Cache.SetComplete("Player-0-P1", { gear = {}, specID = 256 })

  -- Simulate slot change: GUID-P1 is now in party3 instead of party1.
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party3"] = "Player-0-P1"
  -- party1 is gone — no mapping.

  callRosterUpdate()

  local member = LIF.Cache.GetMember("Player-0-P1")
  lu.assertNotNil(member, "GUID-P1 entry must still exist after slot reassignment")
  lu.assertEquals(member.state, "COMPLETE",
    "Cache state must survive slot reassignment (GUID stability)")
end

-- ------------------------------------------------------------
-- test_inspect_ready_guid_guard (REQ-scan-queue-sequential)
-- OnInspectReady must ignore GUIDs that don't match currentlyInspecting.
-- When no inspect is in flight, any GUID must be silently rejected.
-- ------------------------------------------------------------
function TestQueue:test_inspect_ready_guid_guard()
  -- No inspect is in flight (fresh reset). Fire INSPECT_READY for a foreign GUID.
  LIF.OnInspectReady("GUID-FOREIGN")

  lu.assertEquals(_clearInspectCount, 0,
    "ClearInspectPlayer must NOT be called for a foreign GUID")
  lu.assertEquals(#_notifyInspectCalls, 0,
    "No NotifyInspect must be triggered by a rejected INSPECT_READY")
end

-- ------------------------------------------------------------
-- test_inspect_ready_completes_member (REQ-scan-queue-sequential)
-- OnInspectReady for the correct GUID must mark the member COMPLETE.
-- ------------------------------------------------------------
function TestQueue:test_inspect_ready_completes_member()
  local guid = setupParty1("Player-0-P1")

  -- Set up mock gear so OnInspectReady can read it.
  -- Populate slots 1-16: maps to 15 SLOT_IDS entries (slot 4 and 17 are not in the
  -- SLOT_NAMES list), giving slotCount=15 which exceeds MIN_SLOTS=14.
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (12000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415
  end
  _mockSpecID["party1"] = 256

  -- Trigger roster update to queue the inspect and start it.
  callRosterUpdate()

  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  -- Fire INSPECT_READY with the correct GUID.
  LIF.OnInspectReady(guid)

  local member = LIF.Cache.GetMember(guid)
  lu.assertNotNil(member, "Cache entry must still exist after inspect")
  lu.assertEquals(member.state, "COMPLETE",
    "Member must be COMPLETE after OnInspectReady with matching GUID")
end

-- ------------------------------------------------------------
-- test_capture_prefers_getiteminfo_for_member_scaled_ilvl (REV-003)
-- GetDetailedItemLevelInfo evaluates scaling items at the LOCAL player's level;
-- GetItemInfo respects the linkLevel in the member's hyperlink (their level).
-- The inspect capture must store the GetItemInfo value so a lower-level member's
-- scaling gear isn't over-reported — the loot compare trusts this cached value.
-- ------------------------------------------------------------
function TestQueue:test_capture_prefers_getiteminfo_for_member_scaled_ilvl()
  local guid = setupParty1("Player-0-Scaling")

  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (12000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415  -- GetDetailedItemLevelInfo fallback for most slots
  end
  -- Main-hand (slot 16): GetItemInfo says 102 (member-scaled), while
  -- GetDetailedItemLevelInfo says 220 (local-player context — the WRONG source).
  local mhLink = "item:12016"
  _mockIlvl[mhLink] = 220
  _mockItemInfo[mhLink] = { "Scaling Greatblade", nil, 3, 102, nil,
    "Weapon", "One-Handed Axes", nil, "INVTYPE_WEAPON", nil, nil, 2, 0, 1 }
  _mockSpecID["party1"] = 256

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  LIF.OnInspectReady(guid)

  local member = LIF.Cache.GetMember(guid)
  lu.assertNotNil(member, "Cache entry must exist after inspect")
  lu.assertEquals(member.gear[16].ilvl, 102,
    "captured main-hand ilvl must come from GetItemInfo (102, member level), not GetDetailedItemLevelInfo (220)")
end

-- ------------------------------------------------------------
-- test_timeout_requeues_member (REQ-scan-queue-sequential, REQ-mid-scan-failure-handling)
-- When the 4-second timeout fires, the member must stay PENDING and
-- a new inspect attempt must start (second NotifyInspect call).
-- ------------------------------------------------------------
function TestQueue:test_timeout_requeues_member()
  local guid = setupParty1("Player-0-P1")

  callRosterUpdate()

  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  local callsBefore = #_notifyInspectCalls

  -- Fire the pending After callback (the 4-second timeout).
  FirePendingAfterCallbacks()

  local member = LIF.Cache.GetMember(guid)
  lu.assertNotNil(member, "GUID-P1 must still be in cache after timeout")
  lu.assertEquals(member.state, "PENDING",
    "Member must remain PENDING after timeout (not dropped)")
  lu.assertTrue(#_notifyInspectCalls > callsBefore,
    "Timeout must trigger a second inspect attempt (NotifyInspect called again)")
end

-- ------------------------------------------------------------
-- test_mid_scan_death_clears_sentinel (REQ-mid-scan-failure-handling)
-- When the target dies mid-scan, sentinel must be cleared.
-- A second NotifyInspect for the dead unit must NOT be called.
-- ------------------------------------------------------------
function TestQueue:test_mid_scan_death_clears_sentinel()
  if LIF.OnUnitHealthChanged == nil then
    lu.skip("LIF.OnUnitHealthChanged not yet implemented")
  end

  local guid = setupParty1("Player-0-P1")
  callRosterUpdate()

  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  local callsBefore = #_notifyInspectCalls

  -- Unit dies mid-scan.
  _mockIsDeadOrGhost["party1"] = true
  LIF.OnUnitHealthChanged("party1")

  -- CanScanUnit will fail for the dead unit, so the queue may advance but
  -- NotifyInspect must NOT be called for GUID-P1 again.
  lu.assertEquals(#_notifyInspectCalls, callsBefore,
    "NotifyInspect must NOT be called again for a dead unit")
end

-- ------------------------------------------------------------
-- test_mid_scan_disconnect_clears_sentinel (REQ-mid-scan-failure-handling)
-- Disconnect mid-scan must clear the sentinel; member stays PENDING.
-- ------------------------------------------------------------
function TestQueue:test_mid_scan_disconnect_clears_sentinel()
  if LIF.OnUnitDisconnect == nil then
    lu.skip("LIF.OnUnitDisconnect not yet implemented")
  end

  local guid = setupParty1("Player-0-P1")
  callRosterUpdate()

  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  local callsBefore = #_notifyInspectCalls

  -- Simulate disconnect.
  _mockIsConnected["party1"] = false
  LIF.OnUnitDisconnect("party1")

  -- The member must remain in cache (will retry on reconnect event).
  local member = LIF.Cache.GetMember(guid)
  lu.assertNotNil(member, "Disconnected member must remain in cache")
  -- No second inspect should fire immediately (CanScanUnit fails for disconnected).
  lu.assertEquals(#_notifyInspectCalls, callsBefore,
    "NotifyInspect must NOT fire again for disconnected unit")
end

-- ------------------------------------------------------------
-- test_self_not_queued (REQ-inspect-preflight-guard, Pitfall 9)
-- The player's own character must never appear in NotifyInspect calls.
-- Self is added to cache but not inspected.
-- ------------------------------------------------------------
function TestQueue:test_self_not_queued()
  _mockGuids["player"] = "GUID-SELF"
  -- No party members — solo player.

  callRosterUpdate()

  for _, unit in ipairs(_notifyInspectCalls) do
    lu.assertNotEquals(unit, "player",
      "NotifyInspect must never be called for 'player'")
    -- Also check that the called unit isn't the player via GUID.
    lu.assertNotEquals(UnitGUID(unit), "GUID-SELF",
      "Self-GUID must never be inspected")
  end
end

-- ------------------------------------------------------------
-- test_try_queue_respects_can_scan (REQ-inspect-preflight-guard)
-- A PENDING member that fails CanScanUnit (CanInspect=false) must
-- not trigger NotifyInspect.
-- ------------------------------------------------------------
function TestQueue:test_try_queue_respects_can_scan()
  setupParty1("Player-0-P1")
  _mockCanInspect["party1"] = false

  callRosterUpdate()

  lu.assertEquals(#_notifyInspectCalls, 0,
    "NotifyInspect must not be called when CanInspect returns false")
end

-- ------------------------------------------------------------
-- test_preflight_allows_not_visible_but_inspectable (cross-zone group inspect)
-- A party member in another zone (UnitIsVisible false) but still inspectable
-- per Blizzard's own CanInspect gate (confirmed live: manual party-frame
-- Inspect succeeds cross-zone) must still be scanned. UnitIsVisible is not
-- part of the preflight gate.
-- ------------------------------------------------------------
function TestQueue:test_preflight_allows_not_visible_but_inspectable()
  setupParty1("Player-0-P1")
  _mockIsVisible["party1"] = false  -- other zone / not loaded, but CanInspect still true

  callRosterUpdate()

  lu.assertEquals(#_notifyInspectCalls, 1,
    "NotifyInspect must be attempted for a non-visible-but-inspectable unit")
end

-- ------------------------------------------------------------
-- test_harvest_foreign_inspect_ready_completes_other_pending_member
-- (REQ-inspect-slot-sharing) A different addon's NotifyInspect can deliver
-- an INSPECT_READY for a party member we're independently waiting on (they
-- share the single client-wide inspect slot). LIF must accept that data for
-- any PENDING member, not just currentlyInspecting, and must NOT release
-- the inspect slot (ClearInspectPlayer) or touch currentlyInspecting since
-- the request wasn't ours.
-- ------------------------------------------------------------
function TestQueue:test_harvest_foreign_inspect_ready_completes_other_pending_member()
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party1"] = "Player-0-P1"
  _mockGuids["party2"] = "Player-0-P2"

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  -- Cache iteration order (pairs()) is not guaranteed, so whichever of the
  -- two members became currentlyInspecting first is not deterministic —
  -- pick the OTHER one as the harvested (still-queued, PENDING) target.
  local ownGuid = LIF.GetDebugInfo().currentlyInspecting
  lu.assertNotNil(ownGuid, "one member must be currentlyInspecting after roster update")
  local otherGuid = (ownGuid == "Player-0-P1") and "Player-0-P2" or "Player-0-P1"
  local otherUnit = (otherGuid == "Player-0-P1") and "party1" or "party2"

  -- Populate gear for the other member as if some other addon's NotifyInspect resolved it.
  _mockGearLinks[otherUnit] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (14000 + slotID)
    _mockGearLinks[otherUnit][slotID] = link
    _mockIlvl[link] = 415
  end
  _mockSpecID[otherUnit] = 256

  local clearCountBefore = _clearInspectCount

  LIF.OnInspectReady(otherGuid)

  lu.assertEquals(LIF.Cache.GetMember(otherGuid).state, "COMPLETE",
    "harvested foreign INSPECT_READY must complete a PENDING member")
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, ownGuid,
    "harvesting another member's data must not disturb our own in-flight inspect")
  lu.assertEquals(_clearInspectCount, clearCountBefore,
    "ClearInspectPlayer must NOT be called for a harvested (not-ours) inspect")
end

-- ------------------------------------------------------------
-- test_harvest_ignores_non_pending_foreign_guid
-- A foreign INSPECT_READY for a GUID that is already COMPLETE must be a
-- no-op — harvesting only applies to PENDING members. Gives GUID-DONE a
-- real resolvable unit + fresh gear data so the test actually exercises the
-- state=="PENDING" guard (not just the "unit doesn't resolve" early-out).
-- ------------------------------------------------------------
function TestQueue:test_harvest_ignores_non_pending_foreign_guid()
  _mockGuids["party3"] = "GUID-DONE"
  LIF.Cache.Add("GUID-DONE")
  local originalGear = { [1] = { link = "item:1", ilvl = 200 } }
  LIF.Cache.SetComplete("GUID-DONE", { gear = originalGear, specID = 256 })

  -- Simulate a foreign addon delivering (different) fresh gear for this
  -- already-COMPLETE member — if the PENDING guard were missing, this would
  -- overwrite originalGear.
  _mockGearLinks["party3"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (15000 + slotID)
    _mockGearLinks["party3"][slotID] = link
    _mockIlvl[link] = 450
  end
  _mockSpecID["party3"] = 256

  local clearCountBefore = _clearInspectCount
  LIF.OnInspectReady("GUID-DONE")

  local member = LIF.Cache.GetMember("GUID-DONE")
  lu.assertEquals(member.state, "COMPLETE", "member must remain COMPLETE, not reprocessed")
  lu.assertEquals(member.gear, originalGear,
    "gear must be untouched — a COMPLETE member must not be re-harvested")
  lu.assertEquals(_clearInspectCount, clearCountBefore,
    "ClearInspectPlayer must NOT be called for an already-COMPLETE foreign GUID")
end

-- ------------------------------------------------------------
-- test_clobber_detected_triggers_reassert (REQ-inspect-slot-sharing)
-- If another addon calls NotifyInspect on a different unit while ours is
-- in flight, the client's single inspect slot is reassigned to them and our
-- request is effectively dead. LIF must detect this via hooksecurefunc and
-- re-issue NotifyInspect on its own target rather than waiting the full
-- SCAN_TIMEOUT.
-- ------------------------------------------------------------
function TestQueue:test_clobber_detected_triggers_reassert()
  _mockGuids["player"]  = "GUID-SELF"
  _mockGuids["party1"]  = "Player-0-P1"
  _mockGuids["raid5"]   = "GUID-OTHER"  -- some unrelated unit another addon inspects

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  local callsBefore = #_notifyInspectCalls
  local pendingBefore = CountPendingAfterCallbacks()  -- the standing SCAN_TIMEOUT callback

  -- Simulate another addon (e.g. a mouseover-tooltip addon) stealing the slot.
  NotifyInspect("raid5")

  lu.assertEquals(#_notifyInspectCalls, callsBefore + 1,
    "the foreign call itself is the only synchronous NotifyInspect call — no reassert yet")
  lu.assertTrue(CountPendingAfterCallbacks() > pendingBefore,
    "a NEW reassert callback must be scheduled via C_Timer.After, on top of the standing SCAN_TIMEOUT")

  -- Fire only short-delay callbacks (the reassert) — the 2s SCAN_TIMEOUT must
  -- stay pending, since the whole point is the reassert beats it.
  FirePendingAfterCallbacksUpTo(1)

  lu.assertEquals(#_notifyInspectCalls, callsBefore + 2,
    "reassert must re-issue NotifyInspect for our own target")
  lu.assertEquals(_notifyInspectCalls[#_notifyInspectCalls], "party1",
    "reassert must target our own unit, not the clobbering unit")
  lu.assertEquals(CountPendingAfterCallbacks(), pendingBefore,
    "the original SCAN_TIMEOUT callback must still be pending, untouched by the reassert")
end

-- ------------------------------------------------------------
-- test_own_notify_inspect_does_not_self_trigger_reassert
-- The hooksecurefunc hook fires for LIF's own NotifyInspect calls too
-- (it's a global wrap). A call for our own currentlyInspecting guid must
-- never be treated as a clobber.
-- ------------------------------------------------------------
function TestQueue:test_own_notify_inspect_does_not_self_trigger_reassert()
  local guid = setupParty1("Player-0-P1")
  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  lu.assertEquals(CountPendingAfterCallbacks(), 1,
    "only the SCAN_TIMEOUT callback should be pending, no self-triggered reassert")
end

-- ------------------------------------------------------------
-- test_reassert_capped
-- Repeated clobbers against the same in-flight inspect must not schedule
-- unbounded reasserts (would spam NotifyInspect and waste its own throttle).
-- ------------------------------------------------------------
function TestQueue:test_reassert_capped()
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party1"] = "Player-0-P1"
  _mockGuids["raid5"]  = "GUID-OTHER"

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  local pendingBaseline = CountPendingAfterCallbacks()  -- the standing SCAN_TIMEOUT callback

  -- Hammer the slot with foreign clobbers far more than any reasonable cap.
  for _ = 1, 10 do
    NotifyInspect("raid5")
  end

  local newlyScheduled = CountPendingAfterCallbacks() - pendingBaseline
  lu.assertEquals(newlyScheduled, 2,
    "exactly MAX_REASSERTS (2) reasserts must be scheduled for 10 clobbers, not one-per-clobber")
end

-- ------------------------------------------------------------
-- test_stale_reassert_does_not_fire_against_reinspect_of_same_guid (AUD-006)
-- A clobber schedules a reassert for attempt N of guid G. If G is re-inspected
-- (die → battle-rez within REASSERT_DELAY) before the reassert fires, the
-- reassert guards only on guid — (currentlyInspecting == G) is true for the NEW
-- attempt too — so it would re-issue a NotifyInspect against the newer inspect,
-- burning a throttle credit. A generation guard (as L5 added for SCAN_TIMEOUT)
-- must make the stale reassert a no-op.
-- ------------------------------------------------------------
function TestQueue:test_stale_reassert_does_not_fire_against_reinspect_of_same_guid()
  _mockGuids["player"] = "GUID-SELF"
  _mockGuids["party1"] = "Player-0-Reassert"
  _mockGuids["raid5"]  = "GUID-OTHER"
  local guid = setupParty1("Player-0-Reassert")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (19000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 300
  end
  _mockSpecID["party1"] = 256
  _mockCanInspect["party1"] = true

  callRosterUpdate()                   -- StartInspect(G): gen 1, SCAN_TIMEOUT#1 (idx 1)
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: inspecting G")

  NotifyInspect("raid5")               -- foreign clobber → reassert scheduled (gen 1, idx 2)

  LIF.OnInspectReady(guid)             -- 16 slots → COMPLETE, currentlyInspecting cleared
  LIF.RequestReinspect(guid)           -- re-PENDING + StartInspect(G): gen 2 (SCAN_TIMEOUT#2 idx 3)
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid,
    "precondition: freshly re-inspecting G (generation 2)")

  local callsBefore = #_notifyInspectCalls
  -- Fire ONLY the stale gen-1 reassert (scheduled at index 2, after SCAN_TIMEOUT#1).
  lu.assertTrue(FirePendingAfterCallbackAt(2), "precondition: a stale reassert was pending")
  lu.assertEquals(#_notifyInspectCalls, callsBefore,
    "stale reassert must not re-issue NotifyInspect against the newer inspect of the same guid (AUD-006)")
end

-- ------------------------------------------------------------
-- test_timeout_requeue_dedups_against_pending_reinspect (AUD-007)
-- A loot-time RequestReinspect front-inserts guid G while our own inspect of G
-- is still in flight (the L8 no-interrupt path), so G is already queued. When
-- the in-flight attempt times out, its requeue must not append a SECOND copy —
-- the other two enqueue sites dedup; this one must too.
-- ------------------------------------------------------------
local function _countInScanQueue(g)
  local n = 0
  for _, q in ipairs(LIF.scanQueue) do if q == g then n = n + 1 end end
  return n
end

function TestQueue:test_timeout_requeue_dedups_against_pending_reinspect()
  local guid = setupParty1("Player-0-Dedup")
  _mockGearLinks["party1"] = { [1] = "item:20001" }  -- partial → stays PENDING
  _mockIlvl["item:20001"] = 300
  _mockSpecID["party1"] = 256
  _mockCanInspect["party1"] = true

  callRosterUpdate()                   -- StartInspect(G): SCAN_TIMEOUT scheduled (idx 1)
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: inspecting G")

  LIF.RequestReinspect(guid)           -- front-inserts G; does NOT interrupt (L8)
  lu.assertEquals(_countInScanQueue(guid), 1, "precondition: G queued exactly once by the reinspect")

  -- Fire the in-flight attempt's SCAN_TIMEOUT (guid+gen match). Without dedup it
  -- appends a second G; StartNextInspect then re-pops one, leaving a stale copy.
  lu.assertTrue(FirePendingAfterCallbackAt(1), "precondition: the SCAN_TIMEOUT was pending")
  lu.assertEquals(_countInScanQueue(guid), 0,
    "timeout requeue must not leave a duplicate G in the queue (AUD-007)")
end

function TestQueue:test_new_member_rejoin_does_not_duplicate_in_queue()
  -- AUD-403: a member queued behind an in-flight inspect who leaves and rejoins
  -- before their stale queue entry drains must not be enqueued twice. Departure
  -- doesn't purge scanQueue, so the stale entry is still there on rejoin — the
  -- new-member enqueue must dedup against it like the other append sites do.
  _mockGuids["player"]  = "GUID-SELF"
  _mockGuids["party1"]  = "Player-0-P1"
  _mockGuids["party2"]  = "Player-0-P2"
  _mockCanInspect["party1"] = true
  _mockCanInspect["party2"] = true

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  -- One member holds the inspect sentinel; the OTHER waits in the queue. Which is
  -- which depends on pairs() order, so pick the queued (non-inspecting) member
  -- dynamically rather than assuming — the test must not depend on iteration order.
  local inspecting = LIF.GetDebugInfo().currentlyInspecting
  local queuedGuid = (inspecting == "Player-0-P1") and "Player-0-P2" or "Player-0-P1"
  local queuedUnit = (queuedGuid == "Player-0-P2") and "party2" or "party1"
  lu.assertEquals(_countInScanQueue(queuedGuid), 1, "precondition: the queued member is in once")

  -- The queued member leaves (departure removes it from the cache, not the queue).
  _mockGuids[queuedUnit] = nil
  callRosterUpdate()
  lu.assertNil(LIF.Cache.GetMember(queuedGuid), "precondition: queued member removed from cache on leave")
  lu.assertEquals(_countInScanQueue(queuedGuid), 1, "precondition: stale entry still in queue")

  -- It rejoins before the stale entry drains (the other member is still inspecting).
  _mockGuids[queuedUnit] = queuedGuid
  callRosterUpdate()
  lu.assertEquals(_countInScanQueue(queuedGuid), 1,
    "new-member enqueue must dedup against the stale queue entry (AUD-403)")
end

-- ------------------------------------------------------------
-- AUD-008: the death / disconnect / unit-nil abandonment paths drop
-- currentlyInspecting but must ALSO ClearInspectPlayer() to release the shared
-- inspect slot (courtesy), matching the teardown paths. With an empty queue the
-- slot would otherwise stay held until the next NotifyInspect.
-- ------------------------------------------------------------
function TestQueue:test_mid_scan_death_releases_inspect_slot()
  local guid = setupParty1("Player-0-Death")
  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: inspecting G")

  local before = _clearInspectCount
  _mockIsDeadOrGhost["party1"] = true
  LIF.OnUnitHealthChanged("party1")
  lu.assertNil(LIF.GetDebugInfo().currentlyInspecting, "slot sentinel cleared on death")
  lu.assertTrue(_clearInspectCount > before,
    "death abandonment must ClearInspectPlayer to release the slot (AUD-008)")
end

-- ------------------------------------------------------------
-- test_setcomplete_merges_absent_keys (AUD-013)
-- SetComplete MERGES — a key absent from `data` keeps its previous value. This
-- is the trap: a partial refresh that omits specID (e.g. a nil from the API,
-- which drops the key from the table literal) would silently keep a stale spec.
-- The sole caller normalizes specID to 0 so a lost spec is stored explicitly.
-- ------------------------------------------------------------
function TestQueue:test_setcomplete_merges_absent_keys()
  local guid = "Player-0-Merge"
  LIF.Cache.Add(guid)
  LIF.Cache.SetComplete(guid, { specID = 256, ilvl = 300 })
  lu.assertEquals(LIF.Cache.GetMember(guid).specID, 256, "precondition: spec stored")

  -- Partial refresh WITHOUT specID → the stale spec persists (merge, not replace).
  LIF.Cache.SetComplete(guid, { ilvl = 310 })
  lu.assertEquals(LIF.Cache.GetMember(guid).specID, 256,
    "SetComplete merges: an omitted specID keeps its previous value (the AUD-013 trap)")

  -- Explicit specID (as the normalized call site passes) DOES replace it.
  LIF.Cache.SetComplete(guid, { specID = 0 })
  lu.assertEquals(LIF.Cache.GetMember(guid).specID, 0,
    "an explicit specID (0 for a lost spec) overwrites the stale value")
end

-- ------------------------------------------------------------
-- test_inspect_complete_normalizes_stale_specname (AUD-313)
-- The specID resurrection is closed (AUD-013), but its sibling specName was left
-- half-applied: GetSpecializationInfoByID(0) returns a nil name for a lost spec, so
-- the key was omitted and SetComplete's merge kept the previous specName. A member
-- who respecs into "no spec" (specID 0) would keep displaying their old spec name.
-- The completion must pass a normalized specName so it overwrites, not merge-keeps.
-- ------------------------------------------------------------
function TestQueue:test_inspect_complete_normalizes_stale_specname()
  local guid = setupParty1("Player-0-Respec")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (13000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 400
  end
  _mockSpecID["party1"] = 0   -- lost/unknown spec → GetSpecializationInfoByID(0) → nil name

  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end

  -- Simulate a stale spec name left from a prior COMPLETE inspect.
  LIF.Cache.GetMember(guid).specName = "Frost"

  LIF.OnInspectReady(guid)

  lu.assertEquals(LIF.Cache.GetMember(guid).specName, "?",
    "AUD-313: a completion with an unknown spec (0) must overwrite a stale specName, not merge-keep it")
end

-- ------------------------------------------------------------
-- test_initlog_keeps_session_header_within_cap (AUD-314)
-- InitLog trimmed to <= LOG_MAX and THEN appended the session header, overflowing
-- to LOG_MAX+1. It must make room for the header so the buffer never exceeds the cap.
-- ------------------------------------------------------------
function TestQueue:test_initlog_keeps_session_header_within_cap()
  local LOG_MAX = 500
  local entries = {}
  for i = 1, LOG_MAX do entries[i] = { t = "0", msg = "old " .. i } end

  LIF.InitLog({ entries = entries }, "test")

  lu.assertEquals(#LIF.GetLog(), LOG_MAX,
    "AUD-314: InitLog must fit the session header within LOG_MAX, not overflow to 501")
end

-- ------------------------------------------------------------
-- test_log_while_caps_oversized_buffer (AUD-314)
-- LIF.Log removed only ONE entry per insert, so any excess above LOG_MAX (e.g. a
-- legacy 501-entry SavedVariable, or the old InitLog overflow) never recovered. It
-- must while-cap like RecordInspect.
-- ------------------------------------------------------------
function TestQueue:test_log_while_caps_oversized_buffer()
  local LOG_MAX = 500
  LIF.InitLog({ entries = {} }, "test")   -- logEntries = { header }
  local log = LIF.GetLog()
  for i = 1, LOG_MAX + 1 do table.insert(log, { t = "0", msg = "x" }) end  -- force oversized

  local origGlobal = LootItForward
  LootItForward = { db = { char = { debugMode = true } } }
  LIF.Log("trigger")
  LootItForward = origGlobal

  lu.assertEquals(#LIF.GetLog(), LOG_MAX,
    "AUD-314: a single Log insert must while-cap an oversized buffer back to LOG_MAX")
end

function TestQueue:test_mid_scan_disconnect_releases_inspect_slot()
  local guid = setupParty1("Player-0-Disc")
  callRosterUpdate()
  if #_notifyInspectCalls == 0 then
    lu.skip("OnGroupRosterUpdate does not start inspects yet (TODO)")
  end
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: inspecting G")

  local before = _clearInspectCount
  _mockIsConnected["party1"] = false
  LIF.OnUnitDisconnect("party1")
  lu.assertNil(LIF.GetDebugInfo().currentlyInspecting, "slot sentinel cleared on disconnect")
  lu.assertTrue(_clearInspectCount > before,
    "disconnect abandonment must ClearInspectPlayer to release the slot (AUD-008)")
end

-- ============================================================
-- Scan reconciliation job (REV-006)
-- Two-phase ticker: 5s base tick; fast phase acts on EVERY tick for 60s
-- (12 ticks) after group formation / member join; steady phase acts every
-- 6th tick (30s) indefinitely while anyone is scannable-but-not-COMPLETE.
-- No give-up cap. Resurrect/reconnect trigger immediate targeted retries.
-- ============================================================
TestScanReconciliation = {}

function TestScanReconciliation:setUp()
  ResetMocks()
  LIF.Cache.Clear()
  LIF.Queue_StopAndReset()
end

function TestScanReconciliation:test_fast_phase_acts_on_every_tick()
  setupParty1("Player-0-P1")
  _mockCanInspect["party1"] = false  -- not yet scannable

  callRosterUpdate()
  lu.assertEquals(#_notifyInspectCalls, 0, "no inspect while not scannable")
  local ticker = LastMockTicker()
  lu.assertNotNil(ticker, "roster update must start the reconciliation ticker")

  -- Member becomes scannable; very next fast tick must scan them.
  _mockCanInspect["party1"] = true
  ticker:Fire()
  lu.assertEquals(#_notifyInspectCalls, 1,
    "fast phase must attempt the scan on the very next 5s tick")
end

function TestScanReconciliation:test_steady_phase_acts_every_sixth_tick()
  setupParty1("Player-0-P1")
  _mockCanInspect["party1"] = false

  callRosterUpdate()
  local ticker = LastMockTicker()

  -- Exhaust the 12-tick fast phase while still not scannable.
  for _ = 1, 12 do ticker:Fire() end
  lu.assertEquals(#_notifyInspectCalls, 0, "no inspects while not scannable")

  -- Now scannable, but in steady phase: ticks 1-5 must NOT act...
  _mockCanInspect["party1"] = true
  for _ = 1, 5 do ticker:Fire() end
  lu.assertEquals(#_notifyInspectCalls, 0,
    "steady phase must throttle to every 6th tick (30s)")

  -- ...the 6th tick acts.
  ticker:Fire()
  lu.assertEquals(#_notifyInspectCalls, 1,
    "steady phase must attempt the scan on its 6th tick")
end

function TestScanReconciliation:test_no_giveup_long_after_old_five_minute_cap()
  setupParty1("Player-0-P1")
  _mockCanInspect["party1"] = false

  callRosterUpdate()
  local ticker = LastMockTicker()

  -- 12 fast + 72 steady ticks not scannable = 7 simulated minutes (> old 5-min cap).
  for _ = 1, 84 do ticker:Fire() end
  lu.assertEquals(#_notifyInspectCalls, 0)
  lu.assertFalse(ticker.cancelled,
    "job must NOT give up while a PENDING member exists (old 5-min cap removed)")

  -- Member finally scannable; within the next 6 ticks they get scanned.
  _mockCanInspect["party1"] = true
  for _ = 1, 6 do ticker:Fire() end
  lu.assertEquals(#_notifyInspectCalls, 1,
    "member who becomes scannable after a long time must still be scanned")
end

function TestScanReconciliation:test_ticker_stops_when_all_complete()
  local guid = setupParty1("Player-0-P1")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (12000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415
  end
  _mockSpecID["party1"] = 256

  callRosterUpdate()
  local ticker = LastMockTicker()
  LIF.OnInspectReady(guid)
  lu.assertEquals(LIF.Cache.GetMember(guid).state, "COMPLETE")

  ticker:Fire()
  lu.assertTrue(ticker.cancelled,
    "job must stop once every member is COMPLETE (restarts on roster change/loot)")
end

function TestScanReconciliation:test_inspect_caches_equiploc_per_slot()
  -- equipLoc is captured per slot at inspect time and stored in the snapshot so
  -- eval never re-calls GetItemInfo live at loot time (M1).
  local guid = setupParty1("Player-0-EquipLocCache")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (16000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415
  end
  -- Slot 16 is a two-hander; its equipLoc must land in the cached snapshot.
  _mockItemInfo["item:" .. (16000 + 16)] = { "Greatblade", nil, 4, 415, nil,
    "Weapon", "Swords", nil, "INVTYPE_2HWEAPON", nil, nil, 2, 8, 0 }
  _mockSpecID["party1"] = 72

  callRosterUpdate()
  LIF.OnInspectReady(guid)  -- 16 slots >= MIN_SLOTS → COMPLETE in one fire

  local member = LIF.Cache.GetMember(guid)
  lu.assertEquals(member.state, "COMPLETE", "16-slot read completes immediately")
  lu.assertEquals(member.gear[16] and member.gear[16].equipLoc, "INVTYPE_2HWEAPON",
    "equipLoc is cached per slot at inspect time (M1)")
end

function TestScanReconciliation:test_stabilization_pacing_floor_blocks_burst()
  -- A foreign INSPECT_READY burst (multiple fires < MIN_HARVEST_SPACING apart)
  -- must NOT fast-track a PARTIAL read to COMPLETE: slot data can't have grown
  -- between fires that close, so 3 identical partial counts in a burst would
  -- otherwise stabilize a member with missing slots (M7). Spaced fires still work.
  local guid = setupParty1("Player-0-PacingBurst")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 5 do                    -- 5-slot partial read (< MIN_SLOTS=14)
    local link = "item:" .. (17000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 200
  end
  _mockSpecID["party1"] = 256

  callRosterUpdate()
  _mockTime = 100

  -- Burst: 5 identical partial fires all within 0.5s of each other.
  for _ = 1, 5 do
    LIF.OnInspectReady(guid)
    _mockTime = _mockTime + 0.1           -- < 0.75 → must not advance the counter
  end
  lu.assertNotEquals(LIF.Cache.GetMember(guid).state, "COMPLETE",
    "an unpaced burst of identical partial reads must not stabilize to COMPLETE")

  -- Two adequately-spaced fires (≥0.75s from the last COUNTED fire, which is
  -- still the very first one at t=100) advance the counter to 3 → COMPLETE.
  _mockTime = _mockTime + 1               -- counted fire #2
  LIF.OnInspectReady(guid)
  _mockTime = _mockTime + 1               -- counted fire #3 → stabilized
  LIF.OnInspectReady(guid)
  lu.assertEquals(LIF.Cache.GetMember(guid).state, "COMPLETE",
    "spaced partial reads still stabilize once 3 counted fires accumulate")
end

function TestScanReconciliation:test_stale_timeout_does_not_clobber_reinspect_of_same_guid()
  -- L5: a member is inspected (timer T1 scheduled), completes, then a loot-time
  -- reinspect starts a FRESH inspect of the SAME guid (timer T2) — the classic
  -- die + battle-rez-within-2s shape. The stale T1 guards only on guid, so
  -- (currentlyInspecting == guid) is true for BOTH attempts and T1 would
  -- ClearInspectPlayer the newer in-flight inspect. A generation counter must
  -- make T1 a no-op.
  local guid = setupParty1("Player-0-StaleTimer")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (18000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 300
  end
  _mockSpecID["party1"] = 256
  _mockCanInspect["party1"] = true

  callRosterUpdate()                 -- StartInspect(G): T1 (gen 1)
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: inspecting G")

  LIF.OnInspectReady(guid)           -- 16 slots → COMPLETE, currentlyInspecting cleared
  LIF.RequestReinspect(guid)         -- re-PENDING + StartInspect(G): T2 (gen 2)
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: freshly re-inspecting G")

  -- Fire ONLY the stale T1 (first pending After callback). It must not touch the
  -- current (gen-2) inspect.
  local clearsBefore = _clearInspectCount
  lu.assertTrue(FirePendingAfterCallbackAt(1), "precondition: a stale timer was pending")
  lu.assertEquals(_clearInspectCount, clearsBefore,
    "stale timeout must not ClearInspectPlayer the newer inspect of the same guid (L5)")
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid,
    "stale timeout must leave the fresh inspect of G intact")
end

function TestScanReconciliation:test_no_ticker_restart_without_new_member()
  -- GROUP_ROSTER_UPDATE fires far more often than real roster changes (e.g. per-item
  -- loot/skin eligibility syncs). Once the ticker has stopped, a roster-update call
  -- with no new/departed member must NOT spin up a fresh one — only an actual
  -- membership change (or the loot pipeline / reconnect-recovery paths) should.
  local guid = setupParty1("Player-0-P1")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (13000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415
  end
  _mockSpecID["party1"] = 256

  callRosterUpdate()
  local ticker = LastMockTicker()
  LIF.OnInspectReady(guid)
  ticker:Fire()  -- all COMPLETE → ticker stops itself
  lu.assertFalse(LIF.GetDebugInfo().tickerRunning, "precondition: ticker must have stopped")

  local tickerCountBefore = #_mockTickers
  callRosterUpdate()  -- same roster, no new/departed member — simulates loot-noise fire

  lu.assertEquals(#_mockTickers, tickerCountBefore,
    "no-op roster update must not create a new ticker")
  lu.assertFalse(LIF.GetDebugInfo().tickerRunning,
    "ticker must stay stopped when nothing actually changed")
end

function TestScanReconciliation:test_roster_update_arms_ticker_for_pending_member()
  -- After a disable/re-enable (ticker stopped, cache retains members) or any
  -- path that leaves a member PENDING with the ticker stopped, a roster update
  -- must (re)arm the scan ticker so the member still gets scanned — even though
  -- no NEW member was added. Regression guard for L6.
  local guid = setupParty1("Player-0-P1")
  _mockGearLinks["party1"] = {}
  for slotID = 1, 16 do
    local link = "item:" .. (14000 + slotID)
    _mockGearLinks["party1"][slotID] = link
    _mockIlvl[link] = 415
  end
  _mockSpecID["party1"] = 256

  callRosterUpdate()
  local ticker = LastMockTicker()
  LIF.OnInspectReady(guid)
  ticker:Fire()  -- member COMPLETE → ticker stops itself
  lu.assertFalse(LIF.GetDebugInfo().tickerRunning, "precondition: ticker stopped after member COMPLETE")

  -- Member returns to PENDING (e.g. a loot-time reinspect) but nothing arms the
  -- ticker — RequestReinspect only drives a single immediate inspect.
  LIF.RequestReinspect(guid)
  lu.assertFalse(LIF.GetDebugInfo().tickerRunning, "precondition: RequestReinspect must not arm the ticker")

  callRosterUpdate()  -- same roster, no new member, but a PENDING member exists

  lu.assertTrue(LIF.GetDebugInfo().tickerRunning,
    "roster update must arm the ticker when a member is PENDING")
end

function TestScanReconciliation:test_stop_and_reset_releases_inspect_slot()
  -- Tearing down the queue while an inspect is in flight must release the
  -- shared client-wide inspect slot, not leave it held for other addons (L7).
  setupParty1("Player-0-P1")
  _mockSpecID["party1"] = 256
  callRosterUpdate()
  lu.assertNotNil(LIF.GetDebugInfo().currentlyInspecting, "precondition: an inspect is in flight")

  local before = _clearInspectCount
  LIF.Queue_StopAndReset()
  lu.assertTrue(_clearInspectCount > before,
    "Queue_StopAndReset must ClearInspectPlayer to release the shared inspect slot")
end

function TestScanReconciliation:test_departing_inflight_member_releases_slot()
  -- When the member we are currently inspecting leaves the group, their inspect
  -- is abandoned — release the shared slot rather than hold it (L7).
  local guid = setupParty1("Player-0-P1")
  _mockSpecID["party1"] = 256
  callRosterUpdate()
  lu.assertEquals(LIF.GetDebugInfo().currentlyInspecting, guid, "precondition: party1 in flight")

  _mockGuids["party1"] = nil  -- party1 leaves the group
  local before = _clearInspectCount
  callRosterUpdate()
  lu.assertTrue(_clearInspectCount > before,
    "a departing in-flight member must release the shared inspect slot")
end

function TestScanReconciliation:test_resurrect_triggers_immediate_retry()
  setupParty1("Player-0-P1")
  _mockIsDeadOrGhost["party1"] = true  -- dead at join

  callRosterUpdate()
  lu.assertEquals(#_notifyInspectCalls, 0, "dead member must not be inspected")

  -- Member resurrects; UNIT_HEALTH recovery path retries without waiting for a tick.
  _mockIsDeadOrGhost["party1"] = nil
  LIF.OnUnitMaybeScannable("party1")
  lu.assertEquals(#_notifyInspectCalls, 1,
    "resurrected PENDING member must be scanned immediately")
end

function TestScanReconciliation:test_reconnect_triggers_immediate_retry()
  setupParty1("Player-0-P1")
  _mockIsConnected["party1"] = false  -- offline at join

  callRosterUpdate()
  lu.assertEquals(#_notifyInspectCalls, 0, "disconnected member must not be inspected")

  _mockIsConnected["party1"] = nil
  LIF.OnUnitMaybeScannable("party1")
  lu.assertEquals(#_notifyInspectCalls, 1,
    "reconnected PENDING member must be scanned immediately")
end

function TestScanReconciliation:test_maybe_scannable_ignores_complete_members()
  local guid = setupParty1("Player-0-P1")
  LIF.Cache.SetComplete(guid, { gear = {}, specID = 256 })

  LIF.OnUnitMaybeScannable("party1")
  lu.assertEquals(#_notifyInspectCalls, 0,
    "COMPLETE members must not be rescanned by recovery events")
end

-- ============================================================
-- Run suite
-- ============================================================
os.exit(lu.LuaUnit.run())
