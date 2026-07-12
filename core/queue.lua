local _, LIF = ...

local function PlayerLabel(unit)
  local name, realm = UnitFullName(unit)
  name = name or UnitName(unit)
  if not name or name == "Unknown" then return unit end
  if realm and realm ~= "" then return name .. "-" .. realm end
  return name
end

local currentlyInspecting = nil
-- Monotonic per-inspect id. Each StartInspect bumps it and its SCAN_TIMEOUT
-- closure captures the value; the timeout only acts if it's still the current
-- generation. Guards against a stale timer from an abandoned attempt firing
-- against a newer in-flight inspect of the SAME guid — e.g. a member who dies
-- and is battle-rezzed (and re-inspected) inside the 2s window (L5).
local inspectGeneration = 0
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

-- MIN_HARVEST_SPACING (M7): minimum seconds between two INSPECT_READY fires that
-- are allowed to advance the D-15 stabilization counter. D-15's "3 consecutive
-- identical slot counts" was designed around LIF's own ~2s serialized retry
-- cadence, but harvested foreign reads feed the same counters and are UNPACED —
-- a mouseover-inspect addon can land 3 fires for one guid in well under a second,
-- and partial slot data won't have grown between fires that close, so 3 identical
-- PARTIAL counts would prematurely COMPLETE a member with missing slots. Requiring
-- a spacing floor between COUNTED fires makes stabilization reflect real settling
-- time rather than a burst. Not a user-facing setting. Only gates the
-- below-MIN_SLOTS path; a full (>= MIN_SLOTS) read still accepts immediately.
local MIN_HARVEST_SPACING = 0.75

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
-- Exported so the loot pipeline can decide, at loot time, whether a candidate
-- can be freshly inspected right now or must fall back to its cached snapshot.
LIF.CanScanUnit = CanScanUnit

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

-- Clear a departed member's guid from every pending-loot scan window: drop it from
-- the outstanding-scan set and any confirmed candidacy, then re-check whether the
-- entry can now open (the leaver may have been the last scan we were waiting on).
-- Shared by the roster-diff removal and the two queue departure paths (a nil
-- guid→unit at INSPECT_READY or queue-pop time), so a member who leaves right
-- before our GROUP_ROSTER_UPDATE fires can't stay stuck in scanningGuids and stall
-- the popup until the window expires (WR-03 / M11 / AUD-303).
local function PruneDepartedFromPendingLoot(guid)
  for _, entry in ipairs(LIF.pendingLootItems or {}) do
    if entry.scanningGuids then entry.scanningGuids[guid] = nil end
    if entry.confirmedCandidates then entry.confirmedCandidates[guid] = nil end
    if LIF.Loot_TryOpenPopup then LIF.Loot_TryOpenPopup(entry) end
  end
end

-- Forward declaration so TryQueuePendingMembers can call StartNextInspect.
local StartNextInspect

-- Append guid to the back of the scan queue unless it is already present. The queue
-- must never hold two copies of one guid (AUD-007/REV-016): duplicates waste the
-- NotifyInspect throttle and, if a member leaves and rejoins before a stale entry
-- drains, silently accumulate. Shared by all three back-insert sites (AUD-403). The
-- loot-time reinspect front-insert (RequestReinspect) is a distinct move-to-front.
local function EnqueueUnique(guid)
  for _, qguid in ipairs(scanQueue) do
    if qguid == guid then return end
  end
  table.insert(scanQueue, guid)
end

local function TryQueuePendingMembers()
  for guid, member in pairs(LIF.Cache.GetAll()) do
    if member.state == "PENDING" then
      local unit = GuidToUnit(guid)
      -- Never queue the player's own unit (Pitfall 9).
      if unit and unit ~= "player" and CanScanUnit(unit) then
        EnqueueUnique(guid)
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
  local genAtReassert = inspectGeneration
  LIF.Log("clobber detected guid=" .. guidAtReassert:sub(-6) .. " — reasserting in " .. REASSERT_DELAY .. "s")
  C_Timer.After(REASSERT_DELAY, function()
    -- Generation guard (AUD-006, same class as L5's SCAN_TIMEOUT guard): a stale
    -- reassert for an ABANDONED attempt must not re-issue NotifyInspect against a
    -- NEWER in-flight inspect of the same guid (die → battle-rez → new StartInspect
    -- within REASSERT_DELAY, where currentlyInspecting == guidAtReassert holds for
    -- both attempts). The generation distinguishes them.
    if currentlyInspecting == guidAtReassert and genAtReassert == inspectGeneration then
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
    PruneDepartedFromPendingLoot(guid)
    StartNextInspect()
    return
  end

  if not CanScanUnit(unit) then
    StartNextInspect()
    return
  end

  currentlyInspecting = guid
  inspectGeneration = inspectGeneration + 1
  currentReassertCount = 0
  LIF.Log("inspecting " .. PlayerLabel(unit))
  NotifyInspect(unit)

  -- Capture GUID and generation as locals so the closure is not affected by later
  -- changes to currentlyInspecting (Pitfall 6). The generation check ensures a
  -- stale timer from an ABANDONED attempt can't clobber a newer in-flight inspect
  -- of the same guid — the guid alone can't distinguish the two (L5).
  local inspectingGuid = guid
  local inspectGen = inspectGeneration
  C_Timer.After(SCAN_TIMEOUT, function()
    if currentlyInspecting == inspectingGuid and inspectGen == inspectGeneration then
      currentlyInspecting = nil
      ClearInspectPlayer()  -- release the inspect slot for other addons
      -- Dedup before requeue (AUD-007): a loot-time RequestReinspect can front-
      -- insert this guid while the attempt is still in flight (the L8 no-interrupt
      -- path), so it may already be queued. EnqueueUnique matches the other sites.
      EnqueueUnique(inspectingGuid)
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
  -- Release the shared client-wide inspect slot if we were holding it — there is
  -- no replacement inspect after a teardown, so without this the slot stays
  -- held for other addons (L7).
  if currentlyInspecting then ClearInspectPlayer() end
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
      if currentlyInspecting == guid then
        -- We were inspecting the member who just left; abandon and release the
        -- shared slot (the end-of-function StartNextInspect may find no
        -- replacement, so don't rely on it to reclaim the slot) (L7).
        ClearInspectPlayer()
        currentlyInspecting = nil
      end
      local unit = GuidToUnit(guid)
      LIF.Log("remove " .. (unit and PlayerLabel(unit) or guid:sub(-6)))
      LIF.Cache.Remove(guid)
      -- Clear departed member from any pending loot scan windows so _tryOpenPopup
      -- is not blocked waiting for a member who will never complete (WR-03), and
      -- drop any already-confirmed candidacy so a not-yet-open popup doesn't render
      -- a row for a member who left (M11). Popup_OnRosterUpdate handles the case
      -- where the popup is already open.
      PruneDepartedFromPendingLoot(guid)
    end
  end

  -- Add new party members as PENDING. Never add self.
  local addedNewMember = false
  for guid in pairs(currentGuids) do
    if guid ~= selfGuid and not LIF.Cache.GetMember(guid) then
      local unit = currentGuids[guid]
      LIF.Log("queue " .. PlayerLabel(unit))
      LIF.Cache.Add(guid)
      -- Dedup against any stale entry left by a leave→rejoin before it drained
      -- (AUD-403): departure removes the member from the cache but not the queue.
      EnqueueUnique(guid)
      addedNewMember = true
    end
  end

  TryQueuePendingMembers()
  -- Arm the ticker whenever a member still needs scanning. A new member (or
  -- initial formation) re-enters the fast phase; an already-PENDING member with
  -- the ticker stopped (e.g. after a disable/re-enable that kept the cache, or a
  -- loot-time reinspect) arms it at the normal cadence. EnsureScanTickerRunning
  -- no-ops when the ticker is already running, so this does NOT churn on the
  -- frequent no-membership-change fires (those leave everyone COMPLETE →
  -- HasPendingMembers() is false → nothing arms). Passing fast only for a new
  -- member avoids repeatedly re-entering the fast phase on those fires.
  if addedNewMember or HasPendingMembers() then
    EnsureScanTickerRunning(addedNewMember)
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
    PruneDepartedFromPendingLoot(guid)
    if isOwnTarget then
      ClearInspectPlayer()  -- release the inspect slot (AUD-008), matching teardown
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
      -- equipLoc is captured from the SAME call and cached per slot so eval-time
      -- weapon-config checks (is2HEquipped, D-16 off-hand) never re-call
      -- GetItemInfo live at loot time — which returns nil for an item that has
      -- since aged out of the local cache, misreading a 2H as not-2H (M1). It
      -- may still be nil here on a cold cache; consumers fail closed on nil.
      local _, _, _, itemIlvl, _, _, _, _, equipLoc = GetItemInfo(link)
      local actualIlvl = itemIlvl or C_Item.GetDetailedItemLevelInfo(link)
      gearData[slotID] = { link = link, ilvl = actualIlvl, equipLoc = equipLoc }
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
  --
  -- A CHANGED count always resets (slot data grew/shrank — meaningful). An
  -- unchanged count advances the counter only if it's a full read (>= MIN_SLOTS,
  -- where the counter is moot because it accepts immediately) or the fire is at
  -- least MIN_HARVEST_SPACING after the last COUNTED fire (M7). An unchanged
  -- partial count arriving in a foreign burst (too soon) is ignored for
  -- stabilization — it neither advances nor resets — so a rapid mouseover sweep
  -- can't fast-track a partial read to COMPLETE with missing slots.
  if member then
    local now = GetTime()
    if slotCount ~= member.lastSlotCount then
      member.lastSlotCount = slotCount
      member.consistentCount = 1
      member.lastCountedTime = now
    elseif slotCount >= MIN_SLOTS
        or (now - (member.lastCountedTime or 0)) >= MIN_HARVEST_SPACING then
      member.consistentCount = (member.consistentCount or 0) + 1
      member.lastCountedTime = now
    end
  end

  -- A wholly zero-slot read stabilizes like any other count — there is deliberately no
  -- >0 floor (M8, reviewed across audits and left as-is; see .development audit findings
  -- before re-flagging). The realistic zero-read trigger recovers via the reinspect queue.
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
  -- Normalize a lost/unknown spec's nil name to "?" so it OVERWRITES a stale prior
  -- specName instead of being dropped from SetComplete's merge (AUD-313 — the
  -- specName sibling of the AUD-013 specID normalization below).
  specName = specName or "?"
  local specTag = specID and (specID .. "(" .. specName .. ")") or "nil"

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
    member.lastCountedTime = nil
  end

  local playerLevel = UnitLevel(unit) or "?"
  local inspectIlvl = C_PaperDollInfo.GetInspectItemLevel(unit)
  local ilvlTag = (inspectIlvl and inspectIlvl > 0) and math.floor(inspectIlvl) or "?"

  -- Normalize specID to 0 so a member with no selected spec (nil/0 from
  -- GetInspectSpecialization) is stored as 0 and evaluated as "unknown spec →
  -- ignored", never leaving a stale prior specID behind via SetComplete's merge
  -- (AUD-013). A nil here would omit the key and resurrect the old spec.
  LIF.Cache.SetComplete(guid, { gear = gearData, specID = specID or 0, specName = specName, lvl = playerLevel, ilvl = ilvlTag })
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
    ClearInspectPlayer()  -- release the inspect slot (AUD-008), matching teardown
    currentlyInspecting = nil
    StartNextInspect()
  end
end

function LIF.OnUnitDisconnect(unitToken)
  if currentlyInspecting == nil then return end
  local guid = UnitGUID(unitToken)
  if guid == nil then return end
  if guid == currentlyInspecting then
    ClearInspectPlayer()  -- release the inspect slot (AUD-008), matching teardown
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

-- LIF.RequestReinspect(guid)  (D-14, revised for cache-fallback)
-- Forces a fresh loot-time inspect for a specific party member: moves them to
-- PENDING and front-queues the GUID. RETAINS the last COMPLETE gear as a
-- fallback snapshot — if this fresh inspect can't finish (member dead/offline,
-- or the scanning window expires), the loot pipeline evaluates against the
-- retained gear rather than dropping the member. SetComplete overwrites
-- member.gear wholesale when the fresh scan lands, and OnLootInspectReady's
-- COMPLETE gate ignores the stale gear until then, so keeping it is safe.
function LIF.RequestReinspect(guid)
  local member = LIF.Cache.GetMember(guid)
  if not member then return end  -- member left group

  -- Retain member.gear as the fallback snapshot; only flip state to PENDING.
  member.state = "PENDING"

  -- Reset stabilization counters so next set of INSPECT_READY fires counts fresh.
  member.lastSlotCount  = nil
  member.consistentCount = nil
  member.lastCountedTime = nil

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
  -- If we're ALREADY inspecting this same guid, we deliberately do NOT interrupt
  -- and restart it (L8): the in-flight request will deliver an INSPECT_READY that
  -- satisfies this reinspect. That response can be up to SCAN_TIMEOUT (2s) older
  -- than "now", so the D-14 "fresh loot-time scan" guarantee is really "at most
  -- SCAN_TIMEOUT stale" in this narrow overlap. Accepted: gear rarely changes in a
  -- 2s window, cancelling an in-flight inspect to restart it wastes the shared
  -- inspect slot + NotifyInspect throttle, and combat-gating makes the overlap
  -- rare anyway (inspects are suppressed in combat and loot lands right after).
  if currentlyInspecting == nil then
    StartNextInspect()
  end
end

-- Expose scanQueue for tests that need to inspect queue state.
LIF.scanQueue = scanQueue
