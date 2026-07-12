local _, LIF = ...

-- ============================================================
-- equipLoc → numeric slot ID list (matches LIF.SLOT_IDS in queue.lua)
-- ============================================================
local EQUIP_LOC_SLOTS = {
  INVTYPE_HEAD          = {1},
  INVTYPE_NECK          = {2},
  INVTYPE_SHOULDER      = {3},
  INVTYPE_CHEST         = {5},
  INVTYPE_ROBE          = {5},   -- same slot as INVTYPE_CHEST
  INVTYPE_WAIST         = {6},
  INVTYPE_LEGS          = {7},
  INVTYPE_FEET          = {8},
  INVTYPE_WRIST         = {9},
  INVTYPE_HAND          = {10},
  INVTYPE_FINGER        = {11, 12},
  INVTYPE_TRINKET       = {13, 14},
  INVTYPE_BACK          = {15},
  INVTYPE_CLOAK         = {15},   -- WoW API uses INVTYPE_CLOAK for back items
  INVTYPE_WEAPON        = {16},
  INVTYPE_WEAPONMAINHAND = {16},  -- main-hand-only weapons (SpecWeaponHands handles them)
  INVTYPE_RANGED        = {16},   -- legacy ranged items (bows); MH slot since MoP
  INVTYPE_RANGEDRIGHT   = {16},   -- bows, guns, crossbows, wands; MH slot since MoP
  INVTYPE_2HWEAPON      = {16, 17},
  INVTYPE_WEAPONOFFHAND = {17},
  INVTYPE_OFFHAND       = {17},
  INVTYPE_SHIELD        = {17},
  INVTYPE_HOLDABLE      = {17},
}

-- Armor subclassID → human-readable type string (locale-safe, spike 011)
-- Only valid when classID == 4 (Armor). Holdable uses subID=0, shield uses subID=6 — neither is in SUBCLASS_ARMOR (classID=4 only), so they skip this table.
local SUBCLASS_ARMOR = {[1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate"}
-- Exposed for the AUD-005 drift guard: the armor gate (below) compares values from
-- this table against LIF.ARMOR_TYPE (armor_data.lua) by raw equality, so a test
-- asserts the two vocabularies stay identical.
LIF.SUBCLASS_ARMOR = SUBCLASS_ARMOR

-- Primary stat keys for GetItemStats scanning (REV-021).
-- Multi-primary-stat items return MULTIPLE single-stat keys simultaneously —
-- verified in-game 2026-06-12: Tarnished Dawnlit Warglaive (item 258962)
-- reported ITEM_MOD_AGILITY_SHORT=27 AND ITEM_MOD_INTELLECT_SHORT=128 in one
-- table. The hybrid GlobalStrings keys (AGI_STR etc.) were not observed live
-- but exist; scanned defensively.
local PRIMARY_STAT_KEYS = {
  { key = "ITEM_MOD_AGILITY_SHORT",     stats = { "AGI" } },
  { key = "ITEM_MOD_STRENGTH_SHORT",    stats = { "STR" } },
  { key = "ITEM_MOD_INTELLECT_SHORT",   stats = { "INT" } },
  { key = "ITEM_MOD_AGI_STR_SHORT",     stats = { "AGI", "STR" } },
  { key = "ITEM_MOD_AGI_INT_SHORT",     stats = { "AGI", "INT" } },
  { key = "ITEM_MOD_STR_INT_SHORT",     stats = { "STR", "INT" } },
  { key = "ITEM_MOD_AGI_STR_INT_SHORT", stats = { "AGI", "STR", "INT" } },
}

-- "STR+INT"-style label for log lines.
local function statSetLabel(set)
  if set == nil then return "none" end
  local parts = {}
  for _, s in ipairs({ "STR", "AGI", "INT" }) do
    if set[s] then parts[#parts + 1] = s end
  end
  return table.concat(parts, "+")
end


-- Builds a wowhead.com URL from an item hyperlink, including bonus IDs for
-- scaled items. Omits https:// since in-game chat can't hyperlink them.
-- Returns nil if link is not a valid item hyperlink.
local function itemWowheadURL(link)
  if not link then return nil end
  local itemStr = link:match("|Hitem:([^|]+)|h")
  if not itemStr then return nil end
  local parts = {}
  for p in (itemStr .. ":"):gmatch("([^:]*):") do parts[#parts+1] = p end
  local id = parts[1]
  if not id or id == "" then return nil end
  -- Field 13 (1-indexed) = numBonusIDs; bonus IDs follow immediately after.
  local n = tonumber(parts[13]) or 0
  local bonus = {}
  for i = 1, n do
    local b = parts[13 + i]
    if b and b ~= "" and tonumber(b) then bonus[#bonus+1] = b end
  end
  return "wowhead.com/item=" .. id .. (#bonus > 0 and ("?bonus=" .. table.concat(bonus, ":")) or "")
end

-- ============================================================
-- Verbose decision-logging formatters. Produce compact, stable key=value
-- strings so a post-run SavedVariables read reconstructs every input to an
-- eligibility decision. Reused by the drop header, the per-member cmp line,
-- and the player self-check line.
-- ============================================================

-- Dropped weapon/off-hand hand label from equipLoc; nil for non-weapon slots,
-- so the header omits "hand=" for armor/neck/back/ring/trinket.
local WEAPON_HAND_LABEL = {
  INVTYPE_2HWEAPON       = "2h",
  INVTYPE_WEAPON         = "1h",
  INVTYPE_WEAPONMAINHAND = "mh",
  INVTYPE_WEAPONOFFHAND  = "oh",
  INVTYPE_RANGED         = "ranged",
  INVTYPE_RANGEDRIGHT    = "ranged",
  INVTYPE_SHIELD         = "shield",
  INVTYPE_HOLDABLE       = "held",
}

-- One-line header for a classified drop: name, ilvl, category, weapon hand-type,
-- the dropped item's primary-stat set, and a wowhead URL (falls back to
-- id=<itemID> when the link is unavailable).
function LIF.FormatDropHeader(itemData, itemLink, itemID)
  local hand = WEAPON_HAND_LABEL[itemData.equipLoc]
  return "item " .. tostring(itemData.name)
    .. " ilvl=" .. tostring(itemData.ilvl)
    .. " cat=" .. tostring(itemData.slotCategory)
    .. (hand and (" hand=" .. hand) or "")
    .. " stats=" .. statSetLabel(itemData.primaryStats)
    .. " " .. (itemWowheadURL(itemLink) or ("id=" .. tostring(itemID)))
end

-- FormatDecisionGear (the per-slot equipped-gear summary) lives lower in this
-- file, after isHeirloomActive, since it depends on that module-local.

-- ============================================================
-- LIF.IsLocalPlayerName(playerName)
-- Self-filter for ENCOUNTER_LOOT_RECEIVED. Its playerName follows
-- GetUnitName(unit, true) semantics (warcraft.wiki.gg): same-realm players —
-- which always includes the local player — get the plain "Name"; cross-realm
-- players get "Name-NormalizedRealm". So the local player's loot arrives with
-- the plain name, and a plain compare is correct.
--
-- We additionally accept "Name-<ourRealm>" as a belt-and-braces guard in case
-- the event ever realm-qualifies the local name. We must NEVER strip the realm
-- from playerName instead: a cross-realm member with our short name
-- ("Alesh-OtherRealm" vs local "Alesh") would have their loot misattributed
-- to us, producing a popup for an item we never received (REV-004; supersedes
-- the 06-REVIEW WR-02 strip approach).
-- ============================================================
function LIF.IsLocalPlayerName(playerName)
  if playerName == nil then return false end
  local name, realm = UnitFullName("player")
  name = name or UnitName("player")
  if playerName == name then return true end
  if realm and realm ~= "" and playerName == (name .. "-" .. realm) then return true end
  return false
end

-- ============================================================
-- Pending loot item state (exported for queue.lua's departed-member prune and the test harness)
-- Each entry: { itemData = {...}, t = time(), confirmedCandidates = {}, scanningGuids = {} }
-- ============================================================
LIF.pendingLootItems = {}

-- Bumped by Loot_Reset to cancel in-flight pre-entry work (AUD-010). The
-- tradeability phase runs in raw C_Timer.After closures that Loot_Reset cannot
-- reach through pendingLootItems; each captures this generation and bails if a
-- reset changed it. Same closure-vs-reset pattern as queue.lua's inspectGeneration.
LIF._lootGeneration = 0

-- ============================================================
-- LIF.GetSlotCategory(equipLoc, classID, subID)
-- Returns: "armor" | "ring" | "trinket" | "weapon" | "offhand" | "neck" | "back" | "skip"
-- ("offhand" is the D-07 shield/holdable/off-hand category, distinct from "weapon".)
-- ============================================================
local function GetSlotCategory(equipLoc, classID, subID)
  if not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_NON_EQUIP_IGNORE" then
    return "skip"
  end
  if equipLoc == "INVTYPE_FINGER" then return "ring"    end
  if equipLoc == "INVTYPE_TRINKET" then return "trinket" end
  if equipLoc == "INVTYPE_NECK"    then return "neck"    end
  if equipLoc == "INVTYPE_BACK"    then return "back"    end
  if equipLoc == "INVTYPE_CLOAK"   then return "back"    end
  -- Offhand slot types (D-07): must precede classID==2 check so INVTYPE_WEAPONOFFHAND
  -- (classID=2) still falls through to "weapon" below (RESEARCH Pitfall 1).
  if equipLoc == "INVTYPE_HOLDABLE" then return "offhand" end
  if equipLoc == "INVTYPE_OFFHAND"  then return "offhand" end
  if equipLoc == "INVTYPE_SHIELD"   then return "offhand" end
  if classID == 2 then return "weapon" end  -- also catches INVTYPE_WEAPONOFFHAND
  if classID == 4 and subID and subID >= 1 and subID <= 4 then return "armor" end
  return "skip"
end
LIF.GetSlotCategory = GetSlotCategory

-- ============================================================
-- SPEC_TABLE accessors — character-centric usability lookups (positive facts
-- only; omission or an unknown/nil specID = not usable / fail closed).
--   SpecPrimaryStat(specID)                        → "STR"|"AGI"|"INT"|nil
--   SpecWeaponUsable(specID, equipLoc, weaponSubID)→ bool (mainHand slot 16, or
--                                                    offHandWeapon for WEAPONOFFHAND)
--   SpecOffHandItemUsable(specID, itemSubID)       → bool (shield 6 / holdable 0)
--   SpecIsDualWield(specID)                        → bool (offHandWeapon non-empty)
-- ============================================================
local function SpecEntry(specID)
  return specID and LIF.SPEC_TABLE and LIF.SPEC_TABLE[specID] or nil
end

local function SpecPrimaryStat(specID)
  local e = SpecEntry(specID)
  return e and e.primaryStat or nil
end
LIF.SpecPrimaryStat = SpecPrimaryStat

-- SpecWeaponHands(specID, equipLoc, weaponSubID) → "main" | "off" | "both" | nil
-- Which hand(s) a dropped weapon can occupy for this spec, from the truth table
-- and what the equipLoc physically allows:
--   INVTYPE_WEAPONOFFHAND  → off-hand slot only  (check offHandWeapon)
--   INVTYPE_WEAPONMAINHAND → main-hand slot only (check mainHand)
--   everything else (INVTYPE_WEAPON 1H either-hand, INVTYPE_2HWEAPON, ranged) →
--     usable in whichever hand(s) list the subID. Consulting BOTH sets is what
--     lets an Outlaw dagger (off-hand only) and a Fury 2H (Titan's Grip, both
--     hands) resolve purely from data — no per-spec special-casing.
-- nil = not usable (also unknown/nil spec → fail closed).
local function SpecWeaponHands(specID, equipLoc, weaponSubID)
  local e = SpecEntry(specID)
  if not e then return nil end
  local inMain = (e.mainHand and e.mainHand[weaponSubID]) == true
  local inOff  = (e.offHandWeapon and e.offHandWeapon[weaponSubID]) == true
  if equipLoc == "INVTYPE_WEAPONOFFHAND"  then return inOff  and "off"  or nil end
  if equipLoc == "INVTYPE_WEAPONMAINHAND" then return inMain and "main" or nil end
  if inMain and inOff then return "both" end
  if inMain then return "main" end
  if inOff  then return "off"  end
  return nil
end

-- Prefilter predicate: usable in ANY hand (the exact slot is resolved later).
local function SpecWeaponUsable(specID, equipLoc, weaponSubID)
  return SpecWeaponHands(specID, equipLoc, weaponSubID) ~= nil
end

local function SpecOffHandItemUsable(specID, itemSubID)
  local e = SpecEntry(specID)
  return (e and e.offHandItem and e.offHandItem[itemSubID] == true) or false
end

local function SpecIsDualWield(specID)
  local e = SpecEntry(specID)
  return (e and e.offHandWeapon and next(e.offHandWeapon) ~= nil) or false
end
LIF.SpecIsDualWield = SpecIsDualWield

-- ============================================================
-- LIF.GetPlayerPrimaryStat()
-- Two-call pattern: GetSpecialization() → GetSpecializationInfo() → SPEC_TABLE lookup.
-- Returns "STR" | "AGI" | "INT" | nil. Never crashes on missing data.
-- Per D-13: player's own spec — GetSpecialization is accurate, no Hero Talent ambiguity.
-- ============================================================
local function GetPlayerPrimaryStat()
  local specIndex = GetSpecialization()
  if not specIndex or specIndex == 0 then return nil end
  local specID = GetSpecializationInfo(specIndex)
  if not specID then return nil end
  return SpecPrimaryStat(specID)
end
LIF.GetPlayerPrimaryStat = GetPlayerPrimaryStat

-- ============================================================
-- LIF.GetItemPrimaryStats(itemLink, equipLoc, classID, subID)
-- Returns a stat set { STR=true, AGI=true, INT=true } (any subset) or nil
-- when the item carries no primary stats (REV-021: ALL of an item's primary
-- stats qualify candidates, not the first match).
-- Armor slots: nil (armor-type filter applied instead, not primary stat).
-- Ring / neck / back / trinket / weapon: GetItemStats scan; nil if no
-- primary stat keys present (some rings/necks/backs are secondary-only).
-- ============================================================
local function GetItemPrimaryStats(itemLink, equipLoc, classID, subID)
  -- Armor slots only: no primary stat check (armor-type filter is the
  -- correct restriction). Keyed on slot category, not raw classID/subID —
  -- necks and cloaks share armor's classID=4 and can share its subID range
  -- too (real cloaks report subID=1/Cloth, confirmed in-game 2026-07-01),
  -- so a raw subID check would wrongly exclude them from the stat scan.
  if GetSlotCategory(equipLoc, classID, subID) == "armor" then return nil end
  -- All non-armor equippable slots: scan for primary stat keys.
  -- If the item has none (e.g. a ring with only secondary stats), returns nil
  -- and the caller falls back to ilvl-only comparison.
  -- C_Item.GetItemStats only: the bare GetItemStats global was removed from retail, so a
  -- fallback to it is unreachable in-game and would only ever be taken by a stale mock.
  if equipLoc ~= "" and equipLoc ~= nil then
    local getStatsFn = C_Item and C_Item.GetItemStats
    if not getStatsFn then return nil end
    local ok, stats = pcall(getStatsFn, itemLink)
    if not ok then
      LIF.Log("stat-scan error: " .. tostring(stats):sub(1, 80))
      return nil
    end
    if not stats then return nil end
    local set = nil
    for _, entry in ipairs(PRIMARY_STAT_KEYS) do
      local v = stats[entry.key]
      if v and v ~= 0 then
        set = set or {}
        for _, s in ipairs(entry.stats) do set[s] = true end
      end
    end
    return set
  end
  return nil
end
LIF.GetItemPrimaryStats = GetItemPrimaryStats

-- ============================================================
-- LIF.ClassifyItem(itemLink, itemID)
-- Returns a fully-populated itemData table or nil if the item should be skipped.
-- Uses validated GetItemInfo destructuring from spike 006.
-- ============================================================
local function ClassifyItem(itemLink, itemID)
  local name, _, rarity, ilvl, _, itype, subtype, _, equipLoc, _, _, classID, subID, bindType =
    GetItemInfo(itemLink)

  if name == nil then
    LIF.Log("classify warn: GetItemInfo nil for " .. tostring(itemLink))
    return nil
  end

  local slotCategory = GetSlotCategory(equipLoc, classID, subID)
  if slotCategory == "skip" then return nil end

  local slotIDs = EQUIP_LOC_SLOTS[equipLoc]
  if slotIDs == nil then
    LIF.Log("classify skip: no slotIDs for equipLoc=" .. tostring(equipLoc))
    return nil
  end

  local armorType = (classID == 4 and subID and subID >= 1 and subID <= 4)
    and SUBCLASS_ARMOR[subID] or nil

  local primaryStats = GetItemPrimaryStats(itemLink, equipLoc, classID, subID)

  -- D-05: store weapon/offhand subID for SPEC_TABLE usability lookups.
  local weaponSubID  = (classID == 2) and subID or nil
  local offhandSubID = (slotCategory == "offhand") and subID or nil

  return {
    link         = itemLink,
    id           = itemID,
    name         = name,
    ilvl         = ilvl,
    equipLoc     = equipLoc,
    classID      = classID,
    subID        = subID,
    bindType     = bindType,
    armorType    = armorType,
    primaryStats = primaryStats,  -- stat set or nil (REV-021)
    slotIDs      = slotIDs,
    slotCategory = slotCategory,
    weaponSubID  = weaponSubID,
    offhandSubID = offhandSubID,
  }
end
LIF.ClassifyItem = ClassifyItem

-- ============================================================
-- Popup callback stub (D-09). ui/popup.lua overrides LIF.ShowPopup by
-- reassignment; this no-op keeps the loot pipeline safe to run headless (tests,
-- pre-UI load). Defensive against nil/non-nil args via tostring().
-- ============================================================
function LIF.ShowPopup(itemData, candidates)
  LIF.Log("popup stub: ShowPopup item=" .. tostring(itemData and itemData.link)
    .. " candidates=" .. tostring(candidates and #candidates or 0))
end

-- Party slot order for tie-breaking (D-12): party1=1 … party4=4.
local function _partyOrder(u)
  if u == "party1" then return 1
  elseif u == "party2" then return 2
  elseif u == "party3" then return 3
  elseif u == "party4" then return 4
  end
  return 99
end

local readPlayerSlotIlvl  -- defined below; forward-declared for OnPlayerLootReceived
-- Resolves a candidate against its retained gear snapshot when a fresh loot-time
-- inspect isn't possible/didn't finish. Forward-declared here (needs
-- _checkMemberEligibility, defined far below) and used by OnPlayerLootReceived.
local _resolveCandidateFallback

-- Resolution-time chat summary. The drop-time line (OnPlayerLootReceived Step 4b)
-- already announced the item + that it's being forwarded, so this doesn't repeat
-- the "not an upgrade for you" header — it just reports the outcome.
local function _emitLootChatNotif(itemData, sorted)
  if #sorted == 0 then
    LIF.Log(itemData.name .. " — no party upgrades found.", "info")
  else
    for _, c in ipairs(sorted) do
      local member = LIF.Cache.GetMember(c.guid)
      local specName = member and member.specName
      local classShort = LIF.CLASS_SHORT and LIF.CLASS_SHORT[c.class or ""]
      local spec = specName and classShort and (specName .. " " .. classShort)
               or specName or classShort
      local label = spec and (c.name .. " (" .. spec .. ")") or c.name
      LIF.Log("  " .. label .. ": " .. itemData.slotCategory
        .. " +" .. c.delta .. " (" .. c.ilvl_current .. "→" .. c.ilvl_dropped .. ")", "info")
    end
  end
end

-- Whether the current group is at or above the configured minimum party size
-- (AUD-009). Lives here (a harness-loaded core module) so it is unit-testable;
-- ShouldBeActive() in the entry file calls it to disable the addon below threshold.
-- Nil-safe: absent GetNumGroupMembers (offline) reads as 0, absent setting as 2.
function LIF.GroupMeetsMinPartySize()
  local minSize = (LootItForward and LootItForward.db and LootItForward.db.profile and LootItForward.db.profile.minPartySize) or 2
  local groupSize = GetNumGroupMembers and GetNumGroupMembers() or 0
  return groupSize >= minSize
end

-- Opens the popup for `entry` once ALL scans have resolved and ≥1 candidate is confirmed.
-- Called after every scan resolve and from the adaptive scanning-window timer.
local function _tryOpenPopup(entry)
  if entry.cancelled then return end  -- entry was reset on an inactive transition (M12)
  if entry.popupOpened then return end
  if next(entry.scanningGuids) then return end  -- still waiting for scans
  local sorted = {}
  for _, c in pairs(entry.confirmedCandidates or {}) do
    table.insert(sorted, c)
  end
  if #sorted > 0 then
    table.sort(sorted, function(a, b)
      if a.delta ~= b.delta then return a.delta > b.delta end
      return _partyOrder(a.unit) < _partyOrder(b.unit)
    end)
  end
  if not entry.chatNotifEmitted and entry.hadPartyMembers then
    entry.chatNotifEmitted = true
    _emitLootChatNotif(entry.itemData, sorted)
  end
  if #sorted == 0 then return end
  -- minPartySize is enforced upstream in ShouldBeActive(), not here — do not re-add
  -- a popup-only gate (AUD-009).
  if LIF.ShowPopup then
    LIF.ShowPopup(entry.itemData, sorted)
  end
  entry.popupOpened = true
end
-- Exported so queue.lua can open the popup the moment a departing member unblocks
-- an entry (all remaining candidates resolved) instead of waiting out the window.
LIF.Loot_TryOpenPopup = _tryOpenPopup

-- Bag-cache-lag retry budget for OnPlayerLootReceived's tradeability check
-- (see confirmTradeableAndProceed below). This retry runs BEFORE the pending-loot
-- entry (and its scanning window) is created, so it races no window timer at all —
-- the only bound is user-visible latency plus the Loot_Reset generation cancel.
local TRADE_RETRY_DELAY = 0.3
local TRADE_RETRY_MAX   = 5

-- Adaptive scanning window (D-10, revised for cache-fallback). The inspect queue
-- is serial and throttled, so N candidates need proportionally more time to
-- return fresh data before we stop waiting and fall back to snapshots. Sized by
-- the number of candidates still awaiting a fresh inspect (after immediate
-- fallbacks). A full party is at most 4 candidates → 14s worst case.
local WINDOW_BASE          = 2   -- seconds, floor
local WINDOW_PER_CANDIDATE = 3   -- seconds added per candidate still scanning

-- ============================================================
-- Bag scanning utilities
--
-- LIF.FindItemInBags(itemID)    → bag, slot | nil, nil
--   First slot containing itemID; no tooltip check.
--   Used by TRADE_CLOSED to confirm the item left bags.
--
-- LIF.FindTradeableSlot(itemID) → bag, slot | nil, nil
--   First slot with an active BIND_TRADE_TIME_REMAINING line.
--   Scans ALL matching slots — the fresh drop may sit behind an
--   existing owned copy (no timer) in an earlier slot.
--   Used by TRADE_SHOW to pick up the correct copy for trading.
--
-- LIF.IsItemTradeable(itemID)   → bool
--   Loot-pipeline gate; wraps FindTradeableSlot with policy logs.
-- ============================================================
local _scanTooltip

local function getScanTooltip()
  if not _scanTooltip then
    _scanTooltip = CreateFrame("GameTooltip", "LIFScanTooltip", UIParent, "GameTooltipTemplate")
    _scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  end
  return _scanTooltip
end

function LIF.FindItemInBags(itemID)
  if not C_Container then return nil, nil end
  for bag = 0, 4 do
    local numSlots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, numSlots do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.hyperlink then
        if tonumber(info.hyperlink:match("item:(%d+)")) == itemID then
          return bag, slot
        end
      end
    end
  end
  return nil, nil
end

-- LIF.CountItemInBags(itemID) → number of bag slots holding a copy of itemID,
-- ignoring trade timers. The popup's trade-completion check uses this for an
-- UNTIMED tradeable item — a BoE/BoU that IsItemTradeable clears via the fast path
-- with no BIND_TRADE_TIME_REMAINING line. FindTradeableSlot can never see such a
-- copy, so a presence-by-timer check reads "completed" vacuously on a CANCELLED
-- trade; a DECREASE in this plain count between TRADE_SHOW and TRADE_CLOSED
-- distinguishes a real trade (AUD-402), mirroring the timered CountTradeableSlots
-- decrease (AUD-310).
function LIF.CountItemInBags(itemID)
  if not C_Container then return 0 end
  local count = 0
  for bag = 0, 4 do
    local numSlots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, numSlots do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.hyperlink
         and tonumber(info.hyperlink:match("item:(%d+)")) == itemID then
        count = count + 1
      end
    end
  end
  return count
end

-- Returns the plain-text anchor to search for in tooltip lines.
-- Derives a SHORT prefix (first 5 words) from BIND_TRADE_TIME_REMAINING so
-- the match is resilient to different GlobalString lengths/versions.
-- Falls back to the suffix half when %s is at the start of the string.
local function getTradeAnchor()
  if not BIND_TRADE_TIME_REMAINING then return nil end
  local full = BIND_TRADE_TIME_REMAINING:match("^(.-)%%s") or ""
  if full == "" then
    full = BIND_TRADE_TIME_REMAINING:match("%%s(.+)") or ""
  end
  if full == "" then return nil end
  local words, n = {}, 0
  for w in full:gmatch("%S+") do
    n = n + 1
    words[n] = w
    if n == 5 then break end
  end
  local anchor = table.concat(words, " ")
  return anchor ~= "" and anchor or nil
end

function LIF.FindTradeableSlot(itemID)
  if not C_Container then return nil, nil end
  local anchor = getTradeAnchor()
  if not anchor then return nil, nil end
  local tip = getScanTooltip()
  local diag = {}   -- per-slot tooltip dumps, emitted only if NO slot matches (AUD-411)
  for bag = 0, 4 do
    local numSlots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, numSlots do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.hyperlink then
        if tonumber(info.hyperlink:match("item:(%d+)")) == itemID then
          tip:ClearLines()
          tip:SetBagItem(bag, slot)
          local lines = {}
          for _, region in ipairs({tip:GetRegions()}) do
            if region:GetObjectType() == "FontString" then
              local lineText = region:GetText()
              if lineText then
                lines[#lines + 1] = lineText
                if lineText:find(anchor, 1, true) then
                  return bag, slot
                end
              end
            end
          end
          -- No trade-timer line on this matching-itemID slot. Buffer its tooltip
          -- rather than logging now: a LATER slot may still match (a fresh drop
          -- behind an owned timerless copy is the documented success layout), and
          -- dumping on the success path evicts the capped debug log (AUD-411).
          diag[#diag + 1] = { bag = bag, slot = slot, lines = lines }
        end
      end
    end
  end
  -- Reached only when NO slot carried the trade-timer line: emit the buffered dumps
  -- so a genuine BIND_TRADE_TIME_REMAINING anchor mismatch can be diagnosed.
  if #diag > 0 then
    LIF.Log("trade-scan: anchor=«" .. anchor .. "» BIND_TRADE_TIME_REMAINING=«"
      .. tostring(BIND_TRADE_TIME_REMAINING) .. "»")
    for _, d in ipairs(diag) do
      for i, l in ipairs(d.lines) do
        LIF.Log("trade-scan bag" .. d.bag .. " slot" .. d.slot .. " line[" .. i .. "]: " .. l:sub(1, 120))
      end
    end
  end
  return nil, nil
end

-- LIF.CountTradeableSlots(itemID) → number of bag slots holding a tradeable
-- (active BIND_TRADE_TIME_REMAINING) copy of itemID. The popup's trade-completion
-- check uses this for the D-03 stacked-drop case: with two tradeable copies of the
-- same itemID, FindTradeableSlot still finds the second after one is traded, so
-- presence can't tell "completed" from "cancelled" — a DECREASE in this count
-- between TRADE_SHOW and TRADE_CLOSED can (AUD-310). Kept separate from
-- FindTradeableSlot so that load-bearing path is untouched; omits its per-slot
-- diagnostic logging to avoid spam on repeated counts.
function LIF.CountTradeableSlots(itemID)
  if not C_Container then return 0 end
  local anchor = getTradeAnchor()
  if not anchor then return 0 end
  local tip = getScanTooltip()
  local count = 0
  for bag = 0, 4 do
    local numSlots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, numSlots do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.hyperlink
         and tonumber(info.hyperlink:match("item:(%d+)")) == itemID then
        tip:ClearLines()
        tip:SetBagItem(bag, slot)
        for _, region in ipairs({tip:GetRegions()}) do
          if region:GetObjectType() == "FontString" then
            local lineText = region:GetText()
            if lineText and lineText:find(anchor, 1, true) then
              count = count + 1
              break
            end
          end
        end
      end
    end
  end
  return count
end

function LIF.IsItemTradeable(itemLink, itemID)
  local bindType = select(14, GetItemInfo(itemLink))

  if bindType then
    -- Account-bound: never player-tradeable.
    if bindType == 7 or bindType == 8 or bindType == 9 then
      LIF.Log("loot skip: account-bound itemID=" .. tostring(itemID))
      return false
    end

    -- Quest-bound (4): never player-tradeable. Must be caught before the
    -- "not BoP → tradeable" fast-path below, which would otherwise wave it
    -- through. (Bind-on-Use (3) is genuinely tradeable while unbound, so it
    -- is deliberately NOT skipped here.)
    if bindType == 4 then
      LIF.Log("loot skip: quest-bound itemID=" .. tostring(itemID))
      return false
    end

    -- WuE: bindType 2 but not player-tradeable. C_Item.IsItemBindToAccountUntilEquip
    -- has existed since 11.0 on every supported client — its absence is a
    -- structural break, not a runtime condition; fail loud rather than
    -- silently falling through to "tradeable" for an item that can never be
    -- traded (fail-open is wrong for impossible states — see IsItemTradeable's
    -- other asserts below).
    assert(C_Item and C_Item.IsItemBindToAccountUntilEquip,
      "LIF: C_Item.IsItemBindToAccountUntilEquip unavailable")
    if C_Item.IsItemBindToAccountUntilEquip(itemLink) then
      LIF.Log("loot skip: WuE itemID=" .. tostring(itemID))
      return false
    end

    -- BoE / unbound: always tradeable; no tooltip scan needed.
    if bindType ~= 1 then
      LIF.Log("tradeable: BoE/unbound itemID=" .. tostring(itemID))
      return true
    end
    -- bindType == 1 (BoP): fall through to tooltip scan.
  end

  -- BoP requires the post-boss trade window; confirm via tooltip.
  assert(C_Container, "LIF: C_Container unavailable")
  local anchor = getTradeAnchor()
  assert(anchor, "LIF: BIND_TRADE_TIME_REMAINING has no discriminating text")
  local bag, slot = LIF.FindTradeableSlot(itemID)
  if bag then
    LIF.Log("tradeable: trade timer found itemID=" .. tostring(itemID)
      .. " bag=" .. bag .. " slot=" .. slot)
    return true
  end
  LIF.Log("loot skip: no tradeable copy of itemID=" .. tostring(itemID) .. " found in bags")
  return false
end

-- ============================================================
-- Deferred-until-combat-ends callbacks.
-- Loot can land while combat is still active (lingering adds / multi-pull), but
-- party inspects are combat-blocked (queue.lua CanScanUnit → InCombatLockdown),
-- so a reinspect + scanning window started at loot time cannot resolve until
-- combat drops. RunAfterCombat queues that work; PLAYER_REGEN_ENABLED drains it
-- via LIF.FlushAfterCombatCallbacks after its post-combat settle delay.
-- ============================================================
LIF._afterCombatCallbacks = {}

function LIF.RunAfterCombat(fn)
  if not InCombatLockdown() then
    fn()  -- not in combat → run immediately (defensive; callers pre-check)
    return
  end
  table.insert(LIF._afterCombatCallbacks, fn)
end

function LIF.FlushAfterCombatCallbacks()
  local cbs = LIF._afterCombatCallbacks
  LIF._afterCombatCallbacks = {}
  for _, fn in ipairs(cbs) do fn() end
end

-- ============================================================
-- LIF.Loot_Reset()
-- Clears all in-flight loot state on an inactive transition (leaving the group,
-- zoning into excluded content, addon disable). Marks each pending entry
-- `cancelled` so its still-live window timer no-ops when it fires (the timer and
-- _tryOpenPopup both check the flag), empties the entry so nothing can be shown,
-- then drops the list and any deferred after-combat callbacks. Without this a
-- surviving window timer could open a popup for a group that's already gone, or a
-- stale after-combat callback could replay the pipeline on the next combat (M12).
-- ============================================================
function LIF.Loot_Reset()
  -- Invalidate any in-flight tradeability-phase closures (AUD-010): they run in
  -- raw C_Timer.After timers not tracked by pendingLootItems / _afterCombatCallbacks.
  LIF._lootGeneration = (LIF._lootGeneration or 0) + 1
  for _, entry in ipairs(LIF.pendingLootItems or {}) do
    entry.cancelled = true
    entry.scanningGuids = {}
    entry.confirmedCandidates = {}
  end
  LIF.pendingLootItems = {}
  LIF._afterCombatCallbacks = {}
end

-- ============================================================
-- LIF.OnPlayerLootReceived(itemLink, itemID[, opts])
-- Entry point for ENCOUNTER_LOOT_RECEIVED (wired in Plan 03-05).
-- Full pipeline: classify → self-upgrade check → one-frame defer →
-- tradeability check → queue PENDING members → EvaluateCandidates →
-- append pendingLootItems entry → adaptive scanning-window timer.
-- NOTE: ShowPopup is NOT called here — deferred to OnLootInspectReady (D-08).
-- opts (optional, for /lif force-loot debug command):
--   skipSelfCheck: bool  — bypass IsPlayerUpgrade check
--   threshold: number    — override the default delta > 0 threshold for both self and member checks
-- ============================================================
function LIF.OnPlayerLootReceived(itemLink, itemID, opts)
  -- Capture the loot generation for the WHOLE pipeline (AUD-010). Taken before
  -- Step 0 so a Loot_Reset landing during the async item-load wait below also
  -- cancels this drop, not just the later tradeability timers.
  local lootGen = LIF._lootGeneration

  -- Step 0: defer if item data is not yet cached (REV-008).
  -- GetItemInfo returns nil for items the client hasn't seen (e.g. first kill
  -- of a new boss) — exactly the drops worth evaluating. Defer ONE retry via
  -- ItemMixin; opts._retried guards against loops if data never loads.
  if itemLink and GetItemInfo(itemLink) == nil and not (opts and opts._retried) then
    if Item and Item.CreateFromItemLink then
      local item = Item:CreateFromItemLink(itemLink)
      if item and not item:IsItemEmpty() then
        LIF.Log("loot defer: item data not cached " .. tostring(itemLink))
        item:ContinueOnItemLoad(function()
          -- Bail if a reset happened during the item-load wait (AUD-010): the
          -- re-call would otherwise capture a fresh generation and proceed against
          -- the cleared state. The re-call itself captures its own current gen.
          if LIF._lootGeneration ~= lootGen then
            LIF.Log("loot cancel: pipeline reset during item-load for " .. tostring(itemLink))
            return
          end
          local retryOpts = { _retried = true }
          if opts then
            for k, v in pairs(opts) do retryOpts[k] = v end
            retryOpts._retried = true
          end
          LIF.OnPlayerLootReceived(itemLink, itemID, retryOpts)
        end)
        return
      end
    end
  end

  -- Step 1: classify item.
  local itemData = ClassifyItem(itemLink, itemID)
  if not itemData then
    LIF.Log("loot skip: classification nil for " .. tostring(itemLink))
    return
  end
  -- ilvl underpins every downstream comparison (self-check delta, member
  -- eval's droppedIlvl arithmetic, the chat concat). ClassifyItem normally
  -- bails before this on a nil GetItemInfo, but if a name arrives without an
  -- item level, skip rather than proceed into nil arithmetic.
  if itemData.ilvl == nil then
    LIF.Log("loot skip: nil ilvl for " .. tostring(itemLink))
    return
  end
  LIF.Log(LIF.FormatDropHeader(itemData, itemLink, itemID))

  -- A local player with no active spec (below level 10, or spec never chosen)
  -- can't be self-checked: the stat/weapon self-upgrade branches fail closed,
  -- which for the LOCAL player inverts to "not an upgrade for me → offer it
  -- away" and risks giving away the player's own upgrade. Nothing reliable to
  -- compare against, so ignore the drop rather than guess. (Skipped when the
  -- caller explicitly bypasses the self-check.)
  if not (opts and opts.skipSelfCheck) then
    local specIndex = GetSpecialization and GetSpecialization()
    local playerSpecID = specIndex and specIndex > 0 and GetSpecializationInfo(specIndex)
    if not playerSpecID then
      LIF.Log("loot skip: local player has no active spec")
      return
    end
  end

  -- Step 2: self-upgrade check (D-13).
  local threshold = (opts and opts.threshold ~= nil and opts.threshold) or 1
  if not (opts and opts.skipSelfCheck) then
    local isSelfUpgrade, selfBasis = LIF.IsPlayerUpgrade(itemData, threshold)
    if isSelfUpgrade then
      LIF.Log("loot self-upgrade skip " .. tostring(itemLink))
      -- Use the basis the decision actually used, not a fresh min recompute, so
      -- the chat delta matches the decision (L1). selfBasis is always set on the
      -- upgrade path, but guard defensively.
      if GetNumGroupMembers and GetNumGroupMembers() > 0 and selfBasis then
        LIF.Log(itemData.name .. " (" .. itemData.ilvl .. ") — upgrade for you (+"
          .. (itemData.ilvl - selfBasis) .. " ilvl)", "info")
      end
      return
    end
  end

  -- Steps 3-7: defer one frame so bags settle, then confirm tradeability before
  -- committing to candidate scanning and the pending loot entry.
  -- confirmTradeableAndProceed(attempt): the bag cache can lag behind
  -- ENCOUNTER_LOOT_RECEIVED by more than one frame, and a single 0.3s retry
  -- was observed in live play to be too short during a busy moment (loot +
  -- roster churn right at combat end) — the item genuinely wasn't in bags
  -- yet on either check. If IsItemTradeable fails AND the item isn't in bags
  -- AT ALL yet (distinct from "in bags but no trade timer" — a real
  -- untradeable result), retry every TRADE_RETRY_DELAY up to
  -- TRADE_RETRY_MAX times before giving up.
  local function confirmTradeableAndProceed(attempt)
    -- Bail if a Loot_Reset happened since this pipeline started (AUD-010): the
    -- group disbanded / went inactive, so proceeding would emit a stale chat line
    -- and append an orphan pending entry. Covers all re-entry paths (initial
    -- defer, bag-cache retry, combat-defer). lootGen is captured at the top of
    -- OnPlayerLootReceived (above Step 0).
    if LIF._lootGeneration ~= lootGen then
      LIF.Log("loot cancel: pipeline reset before tradeability for " .. tostring(itemData.name))
      return
    end
    attempt = attempt or 0
    if not LIF.IsItemTradeable(itemLink, itemID) then
      local stillArriving = C_Container and LIF.FindItemInBags(itemID) == nil
      if stillArriving and attempt < TRADE_RETRY_MAX then
        C_Timer.After(TRADE_RETRY_DELAY, function() confirmTradeableAndProceed(attempt + 1) end)
        return
      end
      local reason = stillArriving and "never appeared in bags" or "no trade timer found"
      LIF.Log("loot skip: " .. tostring(itemData.name) .. " — not tradeable (" .. reason .. ")")
      return
    end

    -- Reinspects can't run during combat (CanScanUnit → InCombatLockdown), and
    -- starting the scanning window now would let it expire before combat
    -- drops, dropping members whose inspect never got to run. Defer the whole
    -- scan + window until combat ends by re-entering this function post-combat;
    -- the tradeability recheck then is cheap and also catches an item removed
    -- mid-fight, and the retry budget is preserved.
    if InCombatLockdown() then
      LIF.Log("loot defer: in combat — reinspect for " .. tostring(itemData.name)
        .. " deferred to combat end")
      LIF.RunAfterCombat(function() confirmTradeableAndProceed(attempt) end)
      return
    end

    -- Step 3: scan-before-popup setup (REQ-scan-before-popup).
    LIF.TryQueuePendingMembers()
    LIF.EnsureScanTickerRunning()

    -- Step 4: evaluate candidates — queues fresh rescans, always returns candidates={}.
    local eval = LIF.EvaluateCandidates(itemData, threshold)
    local scanningGuids = eval.scanningGuids or {}

    -- Step 4b: announce the drop + prefilter candidate count (info chat line, so
    -- the player knows LIF saw the drop and is working). Count is the prefilter
    -- total, before any fallback resolves. "Inspecting..." only when there's work.
    local candidateCount = 0
    for _ in pairs(scanningGuids) do candidateCount = candidateCount + 1 end
    if candidateCount > 0 then
      LIF.Log(itemData.name .. " dropped — " .. candidateCount .. " possible "
        .. (candidateCount == 1 and "candidate" or "candidates") .. ". Inspecting...", "info")
    else
      LIF.Log(itemData.name .. " dropped — 0 possible candidates.", "info")
    end

    -- Step 5: build and append pending loot entry.
    -- threshold is stored so OnLootInspectReady uses the same value (not re-read from db).
    local entry = {
      itemData            = itemData,
      t                   = time(),
      threshold           = threshold,
      confirmedCandidates = {},
      scanningGuids       = scanningGuids,
      popupOpened         = false,
      cancelled           = false,
      hadPartyMembers     = next(scanningGuids) ~= nil,
      chatNotifEmitted    = false,
    }
    table.insert(LIF.pendingLootItems, entry)

    -- Step 5b: immediate cache-fallback. A candidate we can't freshly inspect
    -- right now — dead, offline, or the local player is dead (which stalls the
    -- entire inspect queue) — would only fall back at window expiry anyway.
    -- Resolve it against its snapshot now to avoid a pointless wait. Two-pass
    -- (collect then resolve) because the resolve mutates scanningGuids.
    local unscannable = {}
    for guid in pairs(scanningGuids) do
      local u = LIF.GuidToUnit(guid)
      if not (u and LIF.CanScanUnit(u)) then
        unscannable[#unscannable + 1] = guid
      end
    end
    for _, guid in ipairs(unscannable) do
      _resolveCandidateFallback(entry, guid)
    end
    if #unscannable > 0 then _tryOpenPopup(entry) end

    -- Step 6: adaptive scanning window timer (D-10). Sized by the candidates
    -- still awaiting a fresh inspect (after the immediate fallbacks above). On
    -- expiry, any member that never re-completed resolves against its snapshot,
    -- then the popup opens. Local-capture pattern (matching queue.lua) prevents
    -- upvalue mutation issues.
    local remainingCount = 0
    for _ in pairs(entry.scanningGuids) do remainingCount = remainingCount + 1 end
    local window = WINDOW_BASE + remainingCount * WINDOW_PER_CANDIDATE
    entry.window = window  -- diagnostic: how long we waited for fresh data
    local capturedEntry = entry
    C_Timer.After(window, function()
      if not capturedEntry.cancelled and capturedEntry.scanningGuids then
        local remaining = {}
        for guid in pairs(capturedEntry.scanningGuids) do remaining[#remaining + 1] = guid end
        for _, guid in ipairs(remaining) do
          _resolveCandidateFallback(capturedEntry, guid)
        end
        capturedEntry.scanningGuids = {}
        _tryOpenPopup(capturedEntry)
      end
      for i = #LIF.pendingLootItems, 1, -1 do
        if LIF.pendingLootItems[i] == capturedEntry then
          table.remove(LIF.pendingLootItems, i)
          break
        end
      end
    end)

    -- Step 7: final pipeline log.
    LIF.Log("loot pipeline " .. tostring(itemLink)
      .. " candidates=" .. remainingCount .. " window=" .. window .. "s")
  end
  C_Timer.After(0, confirmTradeableAndProceed)
end

-- ============================================================
-- readPlayerSlotIlvl(slotID) — module-local helper
-- Returns the ilvl of the player's item in slotID, or 0 for empty slots.
-- Empty slot (GetInventoryItemLink returns nil) → treat as ilvl 0 (Pitfall 7).
-- ============================================================
readPlayerSlotIlvl = function(slotID)
  local link = GetInventoryItemLink("player", slotID)
  if link == nil then return 0 end
  local ilvl = C_Item.GetDetailedItemLevelInfo(link)
  return ilvl or 0
end

-- ============================================================
-- isHeirloomActive(link, level) — module-local helper (Phase 3.1)
-- Returns true iff the item in `link` is an active heirloom for a unit at `level`.
--
-- Decision references:
--   D-01: C_Heirloom.IsItemHeirloom is the sole detection mechanism.
--   D-02: Guard against missing C_Heirloom or IsItemHeirloom (future-patch safety).
--   D-05: Nil link short-circuits to false; existing nil=0 ilvl path proceeds.
--
-- Level cap: 69 (literal). Heirlooms scale up to and including level 69;
-- at level 70 the item behaves as a normal static-ilvl piece (D-03/D-04).
-- Use `level > 69` (not `level < 70`) to keep the intent explicit.
--
-- Debug bypass: /lif heirloom on (only while debugMode is also on) forces this to
-- always report false, so heirloom-wearing candidates are no longer skipped — lets
-- testing in low-level/timewalking groups (where most candidates wear heirlooms)
-- exercise the rest of the pipeline. No effect while debug mode is off.
-- ============================================================
local function isHeirloomActive(link, level)
  if LootItForward and LootItForward.db and LootItForward.db.char.debugMode
     and LootItForward.db.char.skipHeirloomCheck then
    return false
  end
  if link == nil then return false end
  if level == nil or level > 69 then return false end
  if not (C_Heirloom and C_Heirloom.IsItemHeirloom) then return false end
  local itemID = tonumber(string.match(link, "item:(%d+)"))
  if not itemID then return false end
  return C_Heirloom.IsItemHeirloom(itemID)
end

-- ============================================================
-- StatGateStatus(primaryStats, specStat)
-- Shared primary-stat gate for ring/trinket/weapon/neck/back, used by both
-- the self-check and party-candidate paths (REV-021: multi-stat items
-- qualify on any of their stats).
-- Returns "ok" (including statless items — ilvl-only fallback) |
-- "unknown_spec" | "mismatch".
-- ============================================================
local function StatGateStatus(primaryStats, specStat)
  if primaryStats == nil then return "ok" end
  if specStat == nil then return "unknown_spec" end
  if not primaryStats[specStat] then return "mismatch" end
  return "ok"
end

-- ============================================================
-- HeirloomAdjustedIlvl(link, level, ilvl)
-- Shared ring/trinket heirloom substitution: an active heirloom in a slot
-- reads as math.huge so it never wins the lower-of-two comparison (SC3).
-- ============================================================
local function HeirloomAdjustedIlvl(link, level, ilvl)
  if isHeirloomActive(link, level) then return math.huge end
  return ilvl
end
-- Exposed so the popup header's ring/trinket compare (ui/popup.lua) can pick the same
-- heirloom-adjusted lower-of-two slot the eligibility engine used (AUD-308).
LIF.HeirloomAdjustedIlvl = HeirloomAdjustedIlvl

-- The equipped slot(s) a category's comparison reads, with display labels.
-- Paired categories return both slots (the decision uses both); single-slot
-- categories return the item's target slot from slotIDs.
local function decisionSlots(cat, itemData)
  if cat == "ring"    then return { { 11, "s11" }, { 12, "s12" } } end
  if cat == "trinket" then return { { 13, "s13" }, { 14, "s14" } } end
  if cat == "weapon" or cat == "offhand" then return { { 16, "mh" }, { 17, "oh" } } end
  local s = (itemData.slotIDs and itemData.slotIDs[1]) or 0
  return { { s, "s" .. s } }
end

-- "<label>:<ilvl> hl:<y|n>" per compared slot, space-joined, for the verbose
-- decision log. Weapon/off-hand slots read the live accessors (player: live
-- gear; member: the live accessors collapse onto the cache), every other slot
-- the standard accessor, matching EvaluateItemForCharacter so the logged basis
-- equals the decision basis.
function LIF.FormatDecisionGear(char, cat, itemData)
  local weaponCat = (cat == "weapon" or cat == "offhand")
  local getLink = weaponCat and char.getLiveSlotLink or char.getSlotLink
  local getIlvl = weaponCat and char.getLiveSlotIlvl or char.getSlotIlvl
  local parts = {}
  for _, slot in ipairs(decisionSlots(cat, itemData)) do
    local slotID, label = slot[1], slot[2]
    local hl = isHeirloomActive(getLink(slotID), char.level) and "y" or "n"
    parts[#parts + 1] = label .. ":" .. tostring(getIlvl(slotID)) .. " hl:" .. hl
  end
  return table.concat(parts, "  ")
end

-- ============================================================
-- ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, getIlvl, mhHeirloomActive, ohHeirloomActive)
-- Shared weapon dual-slot arithmetic (REV-010/D-15): non-dual-wield specs
-- always compare against weaponSlot; dual-wield specs (or Fury+2H) compare
-- against the weaker of MH/OH. If ONE hand holds an active heirloom, judge
-- against the OTHER (non-heirloom) hand only — an active heirloom never loses a
-- comparison it can't win anyway (M3). Both-hands-heirloom is filtered by the
-- caller before this runs. getIlvl(slotID) abstracts live (player) vs cached
-- (party member) reads. Returns (compareSlotID, compareIlvl). Tie → slot 16.
-- ============================================================
local function ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, getIlvl, mhHeirloomActive, ohHeirloomActive)
  if not dualSlotCompare then
    return weaponSlot, getIlvl(weaponSlot)
  end
  if ohHeirloomActive then
    return 16, getIlvl(16)
  end
  if mhHeirloomActive then
    return 17, getIlvl(17)
  end
  local ilvl16, ilvl17 = getIlvl(16), getIlvl(17)
  if ilvl16 <= ilvl17 then return 16, ilvl16 end
  return 17, ilvl17
end

-- ============================================================
-- Is2HWeaponEquipped(unit)
-- D-11: an off-hand item can never be an upgrade for a unit currently
-- wielding a two-handed weapon (nothing to hold it in). Shared by the
-- self-check and party-candidate offhand branches (both must gate on it).
-- AUD-301b deferred: matches only INVTYPE_2HWEAPON, not an equipped ranged
-- weapon (bow/gun) that also occupies both hands. Currently unreachable — the
-- only ranged-equipping specs (BM/MM Hunter) have an empty offHandWeapon and a
-- ranged-only mainHand, so they never take a dual/off-hand drop path, and
-- Survival can't equip ranged. Latent robustness only; see .development findings.
-- ============================================================
local function Is2HWeaponEquipped(unit)
  local link = GetInventoryItemLink(unit, 16)
  if link == nil then return false end
  local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
  return equipLoc == "INVTYPE_2HWEAPON"
end

-- ============================================================
-- PlayerWeaponCompareSlot(itemData) → slotID | nil
-- The local player's authoritative weapon compare slot for the popup header
-- hover (AUD-404). Mirrors the slot EvaluateItemForCharacter's weapon branch
-- picks for the player, so the hover shows the piece eligibility actually
-- compared against: the weaker hand of a dual-wield pair, the off-hand for an
-- off-hand-only drop, or the equipped 2H when the empty off-hand isn't fillable
-- (AUD-301/AUD-401). Returns nil when the item isn't a weapon the player's
-- spec can use (caller falls back to slotIDs[1]).
-- ============================================================
local function PlayerWeaponCompareSlot(itemData)
  local specIndex = GetSpecialization()
  local specID = specIndex and specIndex > 0 and GetSpecializationInfo(specIndex)
  local hands = specID and SpecWeaponHands(specID, itemData.equipLoc, itemData.weaponSubID)
  if not hands then return nil end
  local weaponSlot = (hands == "off") and 17 or 16
  local dualSlotCompare = (hands == "both")
  local level = UnitLevel("player")
  local mhHeirloomActive = isHeirloomActive(GetInventoryItemLink("player", 16), level)
  local ohHeirloomActive = isHeirloomActive(GetInventoryItemLink("player", 17), level)
  -- On a 2H with an empty off-hand, the empty slot isn't a beatable target — the
  -- compare is straight against the 2H (slot 16), matching the eligibility branch.
  if (dualSlotCompare or hands == "off") and itemData.equipLoc ~= "INVTYPE_2HWEAPON"
     and GetInventoryItemLink("player", 17) == nil and Is2HWeaponEquipped("player") then
    return 16
  end
  local function rawIlvl(slot)
    local link = GetInventoryItemLink("player", slot)
    return link and (C_Item.GetDetailedItemLevelInfo(link) or 0) or 0
  end
  local slot = ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, rawIlvl, mhHeirloomActive, ohHeirloomActive)
  return slot
end
LIF.PlayerWeaponCompareSlot = PlayerWeaponCompareSlot

-- ============================================================
-- EvaluateItemForCharacter(itemData, threshold, char)
-- Single source of truth: is this item a genuine, usable upgrade for this
-- character? Used identically for the player (LIF.IsPlayerUpgrade) and for
-- party members (_checkMemberEligibility) — the only real difference
-- between "me" and "a party member" is where gear/spec data comes from,
-- which `char` abstracts away.
--
-- char fields:
--   classToken, specID, level  - character identity (specID/classToken may be nil)
--   getSlotIlvl(slot)          - ilvl at slot (0 if empty)
--   getSlotLink(slot)          - item link at slot (nil if empty)
--   getLiveSlotIlvl(slot)      - ilvl read for gear-swap-sensitive slots
--   getLiveSlotLink(slot)      - link read for gear-swap-sensitive slots
--   is2HEquipped()             - true if slot 16 holds a two-handed weapon
-- The getSlot/getLiveSlot split exists for the PLAYER, whose own gear can change
-- at any instant, so weapon/offhand checks read live. A party member has no live
-- gear source distinct from the inspect (GetInventoryItemLink for a unit is
-- inspect data, released before this runs), so every accessor reads the
-- inspect-cached member.gear snapshot, refreshed by the loot-time reinspect.
--
-- Returns: eligible (bool), ilvlCurrent (number|nil), slotID (number|nil),
-- reason (string, for logging — "eligible" when true)
-- ============================================================
local function EvaluateItemForCharacter(itemData, threshold, char)
  local cat         = itemData.slotCategory
  local droppedIlvl = itemData.ilvl

  if cat == "armor" then
    -- Armor-type filter: the dropped item's type must match this character's
    -- class (moot for the player's own currently-equipped gear, but not for
    -- the drop itself — an off-type BoE can still drop for the wrong class).
    if char.classToken == nil or LIF.ARMOR_TYPE[char.classToken] ~= itemData.armorType then
      return false, nil, nil,
        "armor type mismatch (need " .. tostring(itemData.armorType)
        .. ", wears " .. tostring(char.classToken and LIF.ARMOR_TYPE[char.classToken]) .. ")"
    end
    local slotID = (itemData.slotIDs and itemData.slotIDs[1]) or 0
    if isHeirloomActive(char.getSlotLink(slotID), char.level) then
      return false, nil, slotID, "heirloom"
    end
    local current = char.getSlotIlvl(slotID)
    if (droppedIlvl - current) < threshold then return false, current, slotID, "ilvl" end
    return true, current, slotID, "eligible"

  elseif cat == "neck" or cat == "back" then
    local slotID = itemData.slotIDs and itemData.slotIDs[1]
    if not slotID then return false, nil, nil, "no_slot" end
    -- Primary stat gate: INT cloaks/necks are not upgrades for STR/AGI specs.
    -- Falls through to ilvl-only when the item has no primary stats.
    local memberStat = itemData.primaryStats and SpecPrimaryStat(char.specID)
    local statStatus = StatGateStatus(itemData.primaryStats, memberStat)
    if statStatus == "unknown_spec" then return false, nil, slotID, "spec unknown" end
    if statStatus == "mismatch" then
      return false, nil, slotID, "stat mismatch (" .. statSetLabel(itemData.primaryStats) .. "/" .. tostring(memberStat) .. ")"
    end
    if isHeirloomActive(char.getSlotLink(slotID), char.level) then
      return false, nil, slotID, "heirloom"
    end
    local current = char.getSlotIlvl(slotID)
    if (droppedIlvl - current) < threshold then return false, current, slotID, "ilvl" end
    return true, current, slotID, "eligible"

  elseif cat == "ring" then
    local ilvl11 = HeirloomAdjustedIlvl(char.getSlotLink(11), char.level, char.getSlotIlvl(11))
    local ilvl12 = HeirloomAdjustedIlvl(char.getSlotLink(12), char.level, char.getSlotIlvl(12))
    -- Primary-stat ring: character's spec stat must be in the item's stat set
    -- (REV-021: multi-stat items qualify on any of their stats). Statless
    -- rings fall through to ilvl-only (lower-of-two).
    local memberStat = itemData.primaryStats and SpecPrimaryStat(char.specID)
    local statStatus = StatGateStatus(itemData.primaryStats, memberStat)
    if statStatus == "unknown_spec" then return false, nil, nil, "spec unknown" end
    if statStatus == "mismatch" then
      return false, nil, nil, "stat mismatch (" .. statSetLabel(itemData.primaryStats) .. "/" .. tostring(memberStat) .. ")"
    end
    if not LIF.IsRingUpgrade(droppedIlvl, { slot11 = ilvl11, slot12 = ilvl12 }, threshold) then
      return false, nil, nil, "ilvl"
    end
    local lowerSlotID = (ilvl11 <= ilvl12) and 11 or 12
    local lowerIlvl   = (ilvl11 <= ilvl12) and ilvl11 or ilvl12
    return true, lowerIlvl, lowerSlotID, "eligible"

  elseif cat == "trinket" then
    local ilvl13 = HeirloomAdjustedIlvl(char.getSlotLink(13), char.level, char.getSlotIlvl(13))
    local ilvl14 = HeirloomAdjustedIlvl(char.getSlotLink(14), char.level, char.getSlotIlvl(14))
    -- Primary-stat trinket: character's spec stat must be in the item's stat
    -- set (REV-021). Statless trinkets fall back to ring rules (ilvl-only).
    local memberStat = itemData.primaryStats and SpecPrimaryStat(char.specID)
    local statStatus = StatGateStatus(itemData.primaryStats, memberStat)
    if statStatus == "unknown_spec" then return false, nil, nil, "spec unknown" end
    if statStatus == "mismatch" then
      return false, nil, nil, "stat mismatch (" .. statSetLabel(itemData.primaryStats) .. "/" .. tostring(memberStat) .. ")"
    end
    if not LIF.IsTrinketUpgrade(droppedIlvl, { slot13 = ilvl13, slot14 = ilvl14 }, threshold) then
      return false, nil, nil, "ilvl"
    end
    local lowerSlotID = (ilvl13 <= ilvl14) and 13 or 14
    local lowerIlvl   = (ilvl13 <= ilvl14) and ilvl13 or ilvl14
    return true, lowerIlvl, lowerSlotID, "eligible"

  elseif cat == "weapon" then
    -- Usability (SPEC_TABLE): resolve which hand(s) this weapon can occupy for
    -- the spec — main-hand, off-hand, or either. Consults BOTH mainHand and
    -- offHandWeapon so an Outlaw dagger (off-hand only) and a Fury 2H (Titan's
    -- Grip, both hands) both resolve from data. One lookup subsumes the old
    -- class-proficiency gate, the dual-wield gate, and the Hunter ranged/melee
    -- gate. nil hands (incl. unknown/nil spec) = not usable (fail closed).
    local hands = SpecWeaponHands(char.specID, itemData.equipLoc, itemData.weaponSubID)
    if not hands then
      return false, nil, nil, "weapon not usable by spec (spec=" .. tostring(char.specID)
        .. " subID=" .. tostring(itemData.weaponSubID) .. " " .. tostring(itemData.equipLoc) .. ")"
    end
    -- Primary stat gate (D-13) — applies to every weapon comparison path.
    local memberStat = itemData.primaryStats and SpecPrimaryStat(char.specID)
    local statStatus = StatGateStatus(itemData.primaryStats, memberStat)
    if statStatus == "unknown_spec" then return false, nil, nil, "spec unknown" end
    if statStatus == "mismatch" then
      return false, nil, nil, "stat mismatch (" .. statSetLabel(itemData.primaryStats) .. "/" .. tostring(memberStat) .. ")"
    end
    -- Slot targeting from the truth table (no per-spec hardcode): a weapon usable
    -- in BOTH hands (either-hand 1H for a dual-wielder, or a Titan's Grip 2H) gets
    -- the min(16,17) dual-slot compare; one usable only in the off-hand (an Outlaw
    -- dagger) targets slot 17; otherwise the main-hand (slot 16). Slot reads go
    -- through the char accessors (live for the player, cached for a member).
    local weaponSlot = (hands == "off") and 17 or 16
    local dualSlotCompare = (hands == "both")
    local mhHeirloomActive = isHeirloomActive(char.getLiveSlotLink(16), char.level)
    local ohHeirloomActive = isHeirloomActive(char.getLiveSlotLink(17), char.level)
    if dualSlotCompare then
      -- An active heirloom in ONE hand doesn't block the drop when the OTHER hand
      -- holds a beatable non-heirloom weapon — the drop can replace that (M3).
      -- Skip only when neither hand is a beatable target:
      --  * both hands hold active heirlooms, OR
      --  * one hand holds an active heirloom and the other is EMPTY. This is the
      --    "heirlooms always win" invariant (see M2) applied to a slot that is
      --    ABOUT to hold a heirloom rather than one that already does: while
      --    leveling, an empty hand beside an active heirloom gets filled with a
      --    duplicate heirloom (free to create from the collection, and scaling),
      --    not a random drop. Comparing the drop against that empty hand (ilvl 0)
      --    is therefore a false positive.
      --
      -- Applies UNIFORMLY — do NOT gate on isPlayer or 2H (AUD-001/AUD-004,
      -- working-as-intended):
      --  * dualSlotCompare is reached only by Titan's-Grip 2H (Fury) or an
      --    either-hand 1H dual-wielder; both can make a second copy of the
      --    equipped heirloom, so the rule holds for 1H and 2H alike. A 1H+off-hand
      --    setup (e.g. a mage's weapon + frill) is NOT dualSlotCompare and never
      --    reaches this branch.
      --  * For the local PLAYER, EvaluateItemForCharacter returning false means
      --    "not my upgrade → offer to the party", which is CORRECT here: the player
      --    fills the empty hand with a duplicate heirloom, not this drop — the
      --    empty-hand fill is NOT a 0→N self-upgrade (AUD-001/AUD-004).
      -- This reads only links/heirloom state, never equipLoc, so it is immune to
      -- the M1 cold-cache is2HEquipped gap.
      local ohEmpty = char.getLiveSlotLink(17) == nil
      local mhEmpty = char.getLiveSlotLink(16) == nil
      if (mhHeirloomActive and ohHeirloomActive)
         or (mhHeirloomActive and ohEmpty)
         or (ohHeirloomActive and mhEmpty) then
        return false, nil, 16, "heirloom"
      end
    elseif isHeirloomActive(char.getLiveSlotLink(weaponSlot), char.level) then
      -- Single-slot weapon: an active heirloom in the target slot is unbeatable.
      return false, nil, weaponSlot, "heirloom"
    elseif weaponSlot == 17 and mhHeirloomActive and char.getLiveSlotLink(17) == nil then
      -- Off-hand-only drop (an Outlaw dagger: the main hand can't hold it) into an
      -- EMPTY off-hand beside an active MAIN-hand heirloom. Same duplicate-heirloom
      -- rule as the dual path (AUD-001/M2): the empty hand fills with a scaling
      -- heirloom copy, not this drop, so comparing vs the ilvl-0 empty slot is a
      -- false positive.
      return false, nil, 17, "heirloom"
    end
    -- Cross-config (D-16): a 2H that REPLACES a current 1H+off-hand setup is
    -- judged against the AVERAGE of the two slots it displaces. Self-gating —
    -- only fires when an off-hand is actually equipped (slot 17 > 0) and the
    -- member isn't already on a 2H, i.e. exactly the 1H+off-hand config; a
    -- pure-2H spec (Arms) never has an off-hand to average. Fury's Titan's-Grip
    -- 2H is the dual-slot (min) case above, not this one.
    if itemData.equipLoc == "INVTYPE_2HWEAPON" and not dualSlotCompare
       and not char.is2HEquipped() and char.getLiveSlotIlvl(17) > 0 then
      -- Heirlooms win (M2): a 2H displaces BOTH hands, so an active heirloom in
      -- the off-hand it forces off is an unbeatable item the member would lose —
      -- not a real upgrade. Skip rather than average the heirloom's low scaling
      -- ilvl into the basis (which drags it down and false-positives). A heirloom
      -- MAIN hand is already caught by the single-slot gate above (weaponSlot 16).
      if ohHeirloomActive then return false, nil, 16, "heirloom" end
      local pairAvg = math.floor((char.getLiveSlotIlvl(16) + char.getLiveSlotIlvl(17)) / 2)
      if (droppedIlvl - pairAvg) < threshold then return false, pairAvg, 16, "ilvl" end
      return true, pairAvg, 16, "eligible"
    end
    -- Cross-config (D-16): a spec CURRENTLY on a two-hander cannot fill its
    -- off-hand — a 2H occupies both hands, so the empty slot 17 is not a beatable
    -- target. Comparing against it (ilvl 0) false-positives every 1H drop. A true
    -- 1H/off-hand-weapon drop must be judged STRAIGHT against the 2H it would
    -- replace (slot 16), mirroring the offhand-item branch above. Covers BOTH the
    -- dual-wield case (dualSlotCompare, min-vs-0 otherwise) AND the off-hand-only
    -- case (hands=="off": Frost DK/Survival/BrM/WW on a 2H taking a WEAPONOFFHAND
    -- drop — AUD-401). Excluded: a 2H drop (Fury Titan's Grip) DOES fill the empty
    -- off-hand with a second two-hander, so it keeps the dual-min below. Ranged
    -- (bow/gun) is never dualSlotCompare (no off-hand listing) and doesn't reach here.
    if (dualSlotCompare or hands == "off") and itemData.equipLoc ~= "INVTYPE_2HWEAPON"
       and char.getLiveSlotLink(17) == nil then
      -- M1 fail-closed (MEMBERS ONLY): an empty off-hand beside a main-hand whose
      -- type is unresolved (cold cache → equipLoc nil) could hide a 2H, so
      -- is2HEquipped can't be trusted here. Skip rather than min-vs-0. An OCCUPIED
      -- off-hand proves genuine dual-wield, so this is scoped to the empty case.
      -- The player's own equipLoc is reliably client-cached, so this gates members.
      if not char.isPlayer and char.getLiveSlotLink(16) and char.getSlotEquipLoc(16) == nil then
        return false, nil, nil, "main-hand type unresolved"
      end
      if char.is2HEquipped() then
        -- A heirloom main-hand is already caught above: the dualSlotCompare heirloom
        -- gate (mhHeirloomActive + ohEmpty → "heirloom") for the dual case, and the
        -- weaponSlot==17 heirloom gate for the hands=="off" case. So the 2H here is
        -- a beatable non-heirloom weapon.
        local twoHandIlvl = char.getLiveSlotIlvl(16)
        if (droppedIlvl - twoHandIlvl) < threshold then return false, twoHandIlvl, 16, "ilvl" end
        return true, twoHandIlvl, 16, "eligible"
      end
    end
    local compareSlot, compareIlvl = ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, char.getLiveSlotIlvl, mhHeirloomActive, ohHeirloomActive)
    if (droppedIlvl - compareIlvl) < threshold then return false, compareIlvl, compareSlot, "ilvl" end
    return true, compareIlvl, compareSlot, "eligible"

  elseif cat == "offhand" then
    -- Usability (SPEC_TABLE): the spec's offHandItem must list this subID
    -- (shield 6 / holdable 0). Omission, or an unknown/nil spec, = not usable
    -- (fail closed) — replaces the old class-proficiency gate (ITEM_CLASS_RESTRICT[4]).
    if not SpecOffHandItemUsable(char.specID, itemData.offhandSubID) then
      return false, nil, nil, "offhand not usable by spec (spec=" .. tostring(char.specID)
        .. " subID=" .. tostring(itemData.offhandSubID) .. ")"
    end
    -- Primary stat gate (F4): an INT/STR/AGI-carrying shield or holdable
    -- must match this character's spec stat, same as ring/trinket/weapon.
    local memberStat = itemData.primaryStats and SpecPrimaryStat(char.specID)
    local statStatus = StatGateStatus(itemData.primaryStats, memberStat)
    if statStatus == "unknown_spec" then return false, nil, nil, "spec unknown" end
    if statStatus == "mismatch" then
      return false, nil, nil, "stat mismatch (" .. statSetLabel(itemData.primaryStats) .. "/" .. tostring(memberStat) .. ")"
    end
    -- M1 fail-closed (MEMBERS ONLY): if a main-hand item exists but its type is
    -- unresolved (cold item cache even at inspect time → cached equipLoc nil), we
    -- can't tell whether they wield a 2H. Skip rather than risk the branch below
    -- comparing this off-hand drop against an empty off-hand slot (ilvl 0 → false
    -- positive). NOT applied to the local player: there "skip" inverts to "not my
    -- upgrade → offer it away", and the player's own equipped gear is reliably
    -- client-cached anyway, so equipLoc there is trustworthy.
    if not char.isPlayer and char.getLiveSlotLink(16) and char.getSlotEquipLoc(16) == nil then
      return false, nil, nil, "main-hand type unresolved"
    end
    -- Cross-config (D-16, supersedes the old D-11 blanket skip): a member on a
    -- 2H CAN switch to 1H + off-hand item, so the item is a candidate — judged
    -- STRAIGHT against the 2H it would (partly) displace (slot 16). Off a 2H, it
    -- simply replaces whatever is in the off-hand slot (17), as before.
    if char.is2HEquipped() then
      -- Heirlooms win (M2): taking this off-hand means dropping the equipped 2H.
      -- An active heirloom 2H is unbeatable while leveling, so it's not a real
      -- upgrade even when the off-hand out-ilvls it. (The slot-17 heirloom case
      -- for a member NOT on a 2H is handled below.)
      if isHeirloomActive(char.getLiveSlotLink(16), char.level) then
        return false, nil, 16, "heirloom"
      end
      local twoHandIlvl = char.getLiveSlotIlvl(16)
      if (droppedIlvl - twoHandIlvl) < threshold then return false, twoHandIlvl, 16, "ilvl" end
      return true, twoHandIlvl, 16, "eligible"
    end
    if isHeirloomActive(char.getLiveSlotLink(17), char.level) then
      return false, nil, 17, "heirloom"
    end
    local current = char.getLiveSlotIlvl(17)
    if (droppedIlvl - current) < threshold then return false, current, 17, "ilvl" end
    return true, current, 17, "eligible"

  else
    return false, nil, nil, "unknown category"
  end
end

-- ============================================================
-- LIF.IsPlayerUpgrade(itemData, threshold)
-- Returns true iff the dropped item is an upgrade for the player given the
-- slot-category rules from CONTEXT.md D-13 and STATE.md in-execution decisions.
--
-- itemData: as produced by LIF.ClassifyItem (Plan 03-02). If slotCategory or
--   ilvl is absent (e.g. a malformed test-only shape), returns false rather
--   than attempting classification itself — callers must classify first.
-- threshold: numeric ilvl delta minimum (e.g., 1 from the hardcoded delta > 0 threshold; tests may pass 10 to verify boundary semantics).
--
-- Returns: true | false. Never crashes on nil player gear (empty slot → ilvl 0).
-- Uses GetSpecialization() (player-only, D-13) — never the inspect variant.
-- ============================================================
function LIF.IsPlayerUpgrade(itemData, threshold)
  if itemData == nil then return false end

  -- itemData must come from ClassifyItem (production always classifies first).
  local data = itemData
  if data.slotCategory == nil or data.ilvl == nil then
    LIF.Log("self-check skip: missing slotCategory/ilvl for " .. tostring(data.link or data.id))
    return false
  end

  local _, playerClassToken = UnitClass("player")
  local specIndex = GetSpecialization()
  local playerSpecID = specIndex and specIndex > 0 and GetSpecializationInfo(specIndex)
  local playerLive = function(slot) return GetInventoryItemLink("player", slot) end
  local playerChar = {
    isPlayer        = true,
    classToken      = playerClassToken,
    specID          = playerSpecID,
    level           = UnitLevel("player"),
    getSlotIlvl     = readPlayerSlotIlvl,
    getSlotLink     = playerLive,
    getLiveSlotIlvl = readPlayerSlotIlvl,
    getLiveSlotLink = playerLive,
    -- The player's own equipped gear is reliably client-cached, so a live
    -- equipLoc read is trustworthy (unlike a party member's — see M1).
    getSlotEquipLoc = function(slot)
      local link = GetInventoryItemLink("player", slot)
      if not link then return nil end
      return select(9, GetItemInfo(link))
    end,
    is2HEquipped    = function() return Is2HWeaponEquipped("player") end,
  }

  local eligible, ilvlCurrent, _, reason = EvaluateItemForCharacter(data, threshold, playerChar)

  local specLabel = (playerSpecID and LIF.SPEC_LABEL[playerSpecID]) or tostring(playerSpecID or "?")
  LIF.Log("self-check " .. tostring(playerClassToken) .. " " .. specLabel
    .. " " .. tostring(data.slotCategory)
    .. " drop=" .. tostring(data.ilvl)
    .. " threshold=" .. tostring(threshold)
    .. " equip=[" .. LIF.FormatDecisionGear(playerChar, data.slotCategory, data) .. "]"
    .. " result=" .. tostring(eligible)
    .. " reason=" .. tostring(reason))

  -- Return the basis the decision actually used (pair-average for a 2H vs a
  -- 1H+off-hand, the stat-gated slot, the heirloom-adjusted weapon slot, etc.) so
  -- the caller's "+X ilvl" chat line matches the decision rather than recomputing
  -- a possibly-different min (L1). nil on the not-an-upgrade path.
  return eligible, ilvlCurrent
end

-- ============================================================
-- _checkMemberEligibility(itemData, member, unit, threshold) — module-local helper
-- Used by OnLootInspectReady after fresh inspect data is available.
-- Nil gear slots are treated as ilvl 0 per D-03.
-- Returns: (eligible: bool, candidate: table|nil, reason: string)
--   reason is EvaluateItemForCharacter's reason on the false path ("ilvl",
--   "heirloom", "stat mismatch (...)", etc.) and "eligible" on the true path.
--   Internal callers ignore the 3rd value; it exists for LIF.CheckMemberEligibility
--   (the offline-testable seam — AUD-311) to assert WHY a member was excluded.
-- ============================================================
local function _checkMemberEligibility(itemData, member, unit, threshold)
  local _, classToken = UnitClass(unit)
  -- Whisper target: realm-qualified so cross-realm SendChatMessage works.
  local _wn, _wr = UnitFullName(unit)
  local whisperTarget = (_wn and _wr and _wr ~= "") and (_wn .. "-" .. _wr) or UnitName(unit)
  local cmpName = UnitName(unit) or unit

  -- All slots read from the inspect cache (member.gear), refreshed by the
  -- loot-time reinspect. A party member has no live gear source distinct from
  -- the inspect: GetInventoryItemLink(unit) is inspect data, released by
  -- ClearInspectPlayer before this resolve runs, so a live read here comes back
  -- nil (→ ilvl 0). Weapons/off-hands therefore read the cache like every other
  -- slot; the getLiveSlot* accessors collapse onto it for a member.
  local function cachedIlvl(slot)
    local g = member.gear and member.gear[slot]
    return g and g.ilvl or 0
  end
  local function cachedLink(slot)
    local g = member.gear and member.gear[slot]
    return g and g.link
  end
  -- equipLoc captured per slot at inspect time (queue.lua). Reading it from the
  -- cache — rather than re-calling GetItemInfo(cachedLink) live here — is the M1
  -- fix: at loot time the item may have aged out of the local cache, so a live
  -- read returns nil and a real 2H reads as not-2H. Still nil if it couldn't be
  -- resolved even at inspect time; the offhand branch fails closed on that.
  local function cachedEquipLoc(slot)
    local g = member.gear and member.gear[slot]
    return g and g.equipLoc
  end
  local memberChar = {
    classToken = classToken,
    specID     = member.specID,
    level      = UnitLevel(unit),
    getSlotIlvl     = cachedIlvl,
    getSlotLink     = cachedLink,
    getLiveSlotIlvl = cachedIlvl,
    getLiveSlotLink = cachedLink,
    getSlotEquipLoc = cachedEquipLoc,
    is2HEquipped    = function()
      return cachedEquipLoc(16) == "INVTYPE_2HWEAPON"
    end,
  }

  local eligible, ilvlCurrent, slotID, reason = EvaluateItemForCharacter(itemData, threshold, memberChar)
  local cat = itemData.slotCategory

  local specLabel = (member.specID and LIF.SPEC_LABEL[member.specID]) or tostring(member.specID or "?")
  local gearStr = LIF.FormatDecisionGear(memberChar, cat, itemData)

  if not eligible then
    LIF.Log("cmp " .. cmpName .. " " .. tostring(classToken) .. " " .. specLabel
      .. " " .. tostring(cat) .. " equip=[" .. gearStr .. "] -> skip(" .. tostring(reason) .. ")")
    return false, nil, reason
  end

  local delta = ilvlCurrent and (itemData.ilvl - ilvlCurrent) or nil
  LIF.Log("cmp " .. cmpName .. " " .. tostring(classToken) .. " " .. specLabel
    .. " " .. tostring(cat) .. " drop=" .. tostring(itemData.ilvl)
    .. " curr=" .. tostring(ilvlCurrent) .. " slot=" .. tostring(slotID)
    .. " delta=+" .. tostring(delta)
    .. " equip=[" .. gearStr .. "] -> eligible")

  return true, {
    guid          = member.guid,
    unit          = unit,
    name          = UnitName(unit),
    whisperTarget = whisperTarget,
    class         = classToken,
    ilvl_current  = ilvlCurrent,
    ilvl_dropped  = itemData.ilvl,
    delta         = delta,
    slotID        = slotID,
  }, "eligible"
end

-- Offline-testable eligibility seam (AUD-311): a rename-free alias of the module-
-- local helper (not a new code path). The same per-member evaluation OnLootInspectReady
-- runs, exposed for direct unit tests — assert eligible → candidate fields
-- (delta/slotID/ilvl_current), or ineligible → false + reason.
LIF.CheckMemberEligibility = _checkMemberEligibility

-- ============================================================
-- _resolveCandidateFallback(entry, guid) — assigns the forward-declared upvalue.
-- Resolves a candidate that could not be freshly inspected in time against its
-- retained gear snapshot (member.gear, preserved by RequestReinspect). Mirrors
-- the per-entry resolution in OnLootInspectReady but reads the cached snapshot
-- instead of requiring a fresh COMPLETE. Idempotent: always clears the guid from
-- scanningGuids. The CALLER opens the popup (_tryOpenPopup) after resolving.
-- ============================================================
_resolveCandidateFallback = function(entry, guid)
  if entry.cancelled then return end
  if not (entry.scanningGuids and entry.scanningGuids[guid]) then return end

  local member = LIF.Cache.GetMember(guid)
  local unit   = LIF.GuidToUnit(guid)
  local hasSnapshot = member and member.gear and next(member.gear) ~= nil

  if member and unit and hasSnapshot then
    local eligible, candidate = _checkMemberEligibility(entry.itemData, member, unit, entry.threshold or 1)
    LIF.Log("loot fallback resolve guid=" .. guid:sub(-6) .. " eligible=" .. tostring(eligible))
    -- A fallback only ever runs while scanningGuids is non-empty (pre-open), so
    -- the popup is never open here — just record the result; the caller's
    -- _tryOpenPopup renders it. (No popupOpened branch: it would be dead code.)
    if eligible then
      entry.confirmedCandidates = entry.confirmedCandidates or {}
      entry.confirmedCandidates[guid] = candidate
    end
  else
    -- No snapshot to fall back on (member never successfully scanned, or left the
    -- group) — genuinely can't evaluate them; drop from the scan set so the popup
    -- isn't blocked. Logged so it isn't a silent miss.
    LIF.Log("loot fallback drop guid=" .. guid:sub(-6) .. " — no cached gear")
  end

  entry.scanningGuids[guid] = nil
end

-- ============================================================
-- LIF.EvaluateCandidates(itemData, threshold)
-- Pre-filter pass: identifies which party members MIGHT benefit from the
-- dropped item using cached/live data only (D-16). Calls RequestReinspect
-- for each qualifying member to force a fresh loot-time scan.
-- ALWAYS returns { candidates = {}, scanningGuids = { [guid] = true, ... } }
-- per D-04 — candidates are always empty; eligibility is confirmed after inspect.
-- ============================================================

-- ============================================================
-- ClassCouldUseItem(classToken, itemData) — weapon/offhand prefilter predicate.
-- By-class, respec-proof union across CLASS_SPECS: never reads cached
-- member.specID (which can be stale after a respec). Includes a member iff SOME
-- spec of their live class could use the item — for weapon/offhand that means
-- the spec can wield/use the subID AND (item is statless OR shares a primary
-- stat with that spec). Statless items qualify on usability alone. The exact
-- current spec (and precise stat/ilvl) is confirmed post-inspect in the full
-- check; this is only the conservative "worth inspecting?" gate.
-- Unknown class → conservative include.
-- ============================================================
local function ClassCouldUseItem(classToken, itemData)
  local specs = classToken and LIF.CLASS_SPECS and LIF.CLASS_SPECS[classToken]
  if not specs then return true end
  local cat      = itemData.slotCategory
  local statsSet = itemData.primaryStats
  for _, specID in ipairs(specs) do
    local usable
    if cat == "weapon" then
      usable = SpecWeaponUsable(specID, itemData.equipLoc, itemData.weaponSubID)
    elseif cat == "offhand" then
      usable = SpecOffHandItemUsable(specID, itemData.offhandSubID)
    else
      usable = true
    end
    if usable then
      if statsSet == nil then return true end  -- statless → usability alone
      local s = SpecPrimaryStat(specID)
      if s and statsSet[s] then return true end
    end
  end
  return false
end

function LIF.EvaluateCandidates(itemData, threshold)
  local cat       = itemData.slotCategory
  local armorType = itemData.armorType

  -- itemData must come from ClassifyItem (production always classifies first).
  if cat == nil then
    LIF.Log("evaluate skip: itemData missing slotCategory for " .. tostring(itemData.link))
    return { candidates = {}, scanningGuids = {} }
  end

  local scanningGuids = {}

  for guid, member in pairs(LIF.Cache.GetAll()) do
    local unit = LIF.GuidToUnit(guid)
    if unit ~= nil and unit ~= "player" then
      -- Live UnitClass (works without inspect; respec-proof — never cached
      -- member.specID). Used by the armor and weapon/offhand gates and the
      -- prefilter-skip log line below.
      local _, unitClassToken = UnitClass(unit)
      local shouldInclude = false
      local skipReason = "excluded"

      if cat == "armor" then
        -- D-16: armor → filter by live UnitClass.
        if unitClassToken and LIF.ARMOR_TYPE[unitClassToken] == armorType then
          shouldInclude = true
        else
          skipReason = "armor type mismatch"
        end

      elseif cat == "weapon" or cat == "offhand" then
        -- By-class usability+stat union. 2H gate for offhand stays deferred to
        -- _checkMemberEligibility (needs a live slot 16 read).
        shouldInclude = ClassCouldUseItem(unitClassToken, itemData)
        if not shouldInclude then skipReason = "class can't use" end

      elseif cat == "trinket" or cat == "ring" or cat == "neck" or cat == "back" then
        -- D-16: filter by primary stat when the item has one; include all when it
        -- doesn't (e.g. secondary-stat-only rings, trinkets, necks, backs).
        local statsSet = itemData.primaryStats
        if statsSet == nil then
          shouldInclude = true  -- no primary stats → ilvl-only, include everyone
        elseif member.specID == nil then
          shouldInclude = true  -- unknown spec → can't rule out, include conservatively
        else
          local memberStat = SpecPrimaryStat(member.specID)
          if memberStat == nil then
            shouldInclude = true  -- unknown spec stat mapping → include conservatively
          else
            shouldInclude = statsSet[memberStat] == true
            if not shouldInclude then skipReason = "stat mismatch" end
          end
        end

      else
        -- Unknown category → include conservatively
        shouldInclude = true
      end

      if shouldInclude then
        scanningGuids[guid] = true
        LIF.RequestReinspect(guid)
      else
        -- Surface members excluded BEFORE reinspect (otherwise invisible in the
        -- log): the decision record must show who was considered and why they
        -- were dropped, not just who was inspected.
        LIF.Log("prefilter skip " .. (UnitName(unit) or unit) .. " "
          .. tostring(unitClassToken) .. " " .. tostring(cat) .. " -> " .. skipReason)
      end
    end
  end

  return { candidates = {}, scanningGuids = scanningGuids }
end

-- ============================================================
-- LIF.OnLootInspectReady(guid)
-- SOLE popup opener (D-08). Called after INSPECT_READY resolves a party member.
-- For each pending loot item that has this guid in scanningGuids, applies full
-- eligibility using fresh post-inspect gear data (nil slot = 0 ilvl per D-03).
--
-- Popup lifecycle per entry: accumulate confirmed candidates as each scan
-- resolves; _tryOpenPopup opens the popup once ALL scanningGuids have resolved
-- and ≥1 candidate is confirmed (sorted delta desc, D-12 tie-break). The popup
-- never opens mid-scan (scanningGuids is only populated at entry creation, never
-- re-added), so there is no incremental add/remove-candidate path (AUD-311).
-- ============================================================
function LIF.OnLootInspectReady(guid)
  if LIF.pendingLootItems == nil or #LIF.pendingLootItems == 0 then return end

  local member = LIF.Cache.GetMember(guid)
  if member == nil then return end

  -- Partial INSPECT_READY fires leave the member PENDING with incomplete gear
  -- (queue.lua MIN_SLOTS / stabilization gate returns before SetComplete).
  -- Evaluating now would read empty gear as ilvl 0 and confirm false
  -- candidates. Return WITHOUT consuming scanningGuids so the COMPLETE fire
  -- re-evaluates; the adaptive scanning-window timer covers members that never finish.
  if member.state ~= "COMPLETE" then return end

  local unit = LIF.GuidToUnit(guid)
  if unit == nil then return end

  for _, entry in ipairs(LIF.pendingLootItems) do
    -- Only process if this guid was registered for reinspect on this loot item.
    if entry.scanningGuids and entry.scanningGuids[guid] then

    local entryThreshold = entry.threshold or 1
    local eligible, candidate = _checkMemberEligibility(entry.itemData, member, unit, entryThreshold)

    -- Clear scanning sentinel for this guid regardless of eligibility.
    entry.scanningGuids[guid] = nil

    LIF.Log("loot inspect resolve guid=" .. guid:sub(-6) .. " eligible=" .. tostring(eligible))

    if eligible then
      entry.confirmedCandidates = entry.confirmedCandidates or {}
      entry.confirmedCandidates[guid] = candidate
    end
    _tryOpenPopup(entry)
    end  -- entry.scanningGuids check
  end
end

-- ============================================================
-- Preserved from Phase 2: ring and trinket upgrade helpers
-- ============================================================

-- Returns true if droppedIlvl is an upgrade for a member with two ring slots.
-- Uses the lower of the two equipped rings for comparison.
function LIF.IsRingUpgrade(droppedIlvl, memberRings, threshold)
  local lower = math.min(memberRings.slot11 or 0, memberRings.slot12 or 0)
  return (droppedIlvl - lower) >= threshold
end

-- Returns true if droppedIlvl is an upgrade for a member with two trinket slots.
function LIF.IsTrinketUpgrade(droppedIlvl, memberTrinkets, threshold)
  local lower = math.min(memberTrinkets.slot13 or 0, memberTrinkets.slot14 or 0)
  return (droppedIlvl - lower) >= threshold
end
