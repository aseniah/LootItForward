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
-- Pending loot item state (exported so Plans 03-03/04/05 can append/read)
-- Each entry: { itemData = {...}, t = time(), confirmedCandidates = {}, scanningGuids = {} }
-- ============================================================
LIF.pendingLootItems = {}

-- ============================================================
-- LIF.GetSlotCategory(equipLoc, classID, subID)
-- Returns: "armor" | "ring" | "trinket" | "weapon" | "neck" | "back" | "skip"
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
  -- GetItemStats is deprecated; prefer C_Item.GetItemStats in modern retail.
  if equipLoc ~= "" and equipLoc ~= nil then
    local getStatsFn = (C_Item and C_Item.GetItemStats) or GetItemStats
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
-- Phase 4 popup callback stubs (Plan 03-05, D-09).
-- Phase 4 (ui/popup.lua) overrides these by reassigning LIF.ShowPopup etc.
-- itemLink on Update/Remove routes to the correct item section in multi-item popup (D-09).
-- Each stub is defensive against nil/non-nil args via tostring().
-- ============================================================
function LIF.ShowPopup(itemData, candidates)
  LIF.Log("popup stub: ShowPopup item=" .. tostring(itemData and itemData.link)
    .. " candidates=" .. tostring(candidates and #candidates or 0))
end

function LIF.Popup_UpdateCandidate(guid, candidateData, itemLink)
  LIF.Log("popup stub: UpdateCandidate guid=" .. tostring(guid and guid:sub(-6) or "nil")
    .. " item=" .. tostring(itemLink))
end

function LIF.Popup_RemoveCandidate(guid, itemLink)
  LIF.Log("popup stub: RemoveCandidate guid=" .. tostring(guid and guid:sub(-6) or "nil")
    .. " item=" .. tostring(itemLink))
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

local function _emitLootChatNotif(itemData, sorted)
  LIF.Log(itemData.name .. " (" .. itemData.ilvl .. ") — not an upgrade for you", "info")
  if #sorted == 0 then
    LIF.Log("  no party upgrades found", "info")
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

-- Opens the popup for `entry` once ALL scans have resolved and ≥1 candidate is confirmed.
-- Called after every scan resolve and from the 4-second timeout timer.
local function _tryOpenPopup(entry)
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
  -- Phase 5: minPartySize gate (D-10). Nil-safe for absent GetNumGroupMembers in
  -- offline test harness: treat nil as 0, and groupSize > 0 is required before
  -- applying the gate so offline tests (groupSize == 0) always fall through.
  local minSize = (LootItForward and LootItForward.db and LootItForward.db.profile and LootItForward.db.profile.minPartySize) or 2
  local groupSize = GetNumGroupMembers and GetNumGroupMembers() or 0
  if groupSize > 0 and groupSize < minSize then return end
  if LIF.ShowPopup then
    LIF.ShowPopup(entry.itemData, sorted)
  end
  entry.popupOpened = true
end

-- Bag-cache-lag retry budget for OnPlayerLootReceived's tradeability check
-- (see confirmTradeableAndProceed below). ~1.5s total, well under the 4s
-- pending-loot cleanup timer.
local TRADE_RETRY_DELAY = 0.3
local TRADE_RETRY_MAX   = 5

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
          -- Log anchor + actual tooltip lines so we can diagnose BIND_TRADE_TIME_REMAINING mismatches.
          LIF.Log("trade-scan: anchor=«" .. anchor .. "» BIND_TRADE_TIME_REMAINING=«"
            .. tostring(BIND_TRADE_TIME_REMAINING) .. "»")
          for i, l in ipairs(lines) do
            LIF.Log("trade-scan line[" .. i .. "]: " .. l:sub(1, 120))
          end
        end
      end
    end
  end
  return nil, nil
end

function LIF.IsItemTradeable(itemLink, itemID)
  local bindType = select(14, GetItemInfo(itemLink))

  if bindType then
    -- Account-bound: never player-tradeable.
    if bindType == 7 or bindType == 8 or bindType == 9 then
      LIF.Log("loot skip: account-bound itemID=" .. tostring(itemID))
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
-- LIF.OnPlayerLootReceived(itemLink, itemID[, opts])
-- Entry point for ENCOUNTER_LOOT_RECEIVED (wired in Plan 03-05).
-- Full pipeline: classify → self-upgrade check → one-frame defer →
-- tradeability check → queue PENDING members → EvaluateCandidates →
-- append pendingLootItems entry → 4-second cleanup timer.
-- NOTE: ShowPopup is NOT called here — deferred to OnLootInspectReady (D-08).
-- opts (optional, for /lif force-loot debug command):
--   skipSelfCheck: bool  — bypass IsPlayerUpgrade check
--   threshold: number    — override the default delta > 0 threshold for both self and member checks
-- ============================================================
function LIF.OnPlayerLootReceived(itemLink, itemID, opts)
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
  LIF.Log("item " .. tostring(itemData.name)
    .. " ilvl=" .. tostring(itemData.ilvl)
    .. " cat=" .. tostring(itemData.slotCategory)
    .. " " .. (itemWowheadURL(itemLink) or ("id=" .. tostring(itemID))))

  -- Step 2: self-upgrade check (D-13).
  local threshold = (opts and opts.threshold ~= nil and opts.threshold) or 1
  if not (opts and opts.skipSelfCheck) and LIF.IsPlayerUpgrade(itemData, threshold) then
    LIF.Log("loot self-upgrade skip " .. tostring(itemLink))
    if GetNumGroupMembers and GetNumGroupMembers() > 0 then
      local slotIDs = itemData.slotIDs or {}
      local curr1 = slotIDs[1] and readPlayerSlotIlvl(slotIDs[1]) or 0
      local curr2 = slotIDs[2] and readPlayerSlotIlvl(slotIDs[2]) or nil
      local currIlvl = curr2 and math.min(curr1, curr2) or curr1
      LIF.Log(itemData.name .. " (" .. itemData.ilvl .. ") — upgrade for you (+"
        .. (itemData.ilvl - currIlvl) .. " ilvl)", "info")
    end
    return
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
    -- starting the 4-second scanning window now would let it expire before combat
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

    -- Step 5: build and append pending loot entry.
    -- threshold is stored so OnLootInspectReady uses the same value (not re-read from db).
    local entry = {
      itemData            = itemData,
      t                   = time(),
      threshold           = threshold,
      confirmedCandidates = {},
      scanningGuids       = scanningGuids,
      popupOpened         = false,
      hadPartyMembers     = next(scanningGuids) ~= nil,
      chatNotifEmitted    = false,
    }
    table.insert(LIF.pendingLootItems, entry)

    -- Step 6: 4-second scanning window timer (D-10).
    -- Local-capture pattern (matching queue.lua) prevents upvalue mutation issues.
    local capturedEntry = entry
    C_Timer.After(4, function()
      if capturedEntry.scanningGuids then
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
      .. " scanning=" .. tostring(next(scanningGuids) and "yes" or "no"))
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
-- In-game verification (2026-05-19, Plan 03.1-03):
--   C_Heirloom.IsItemHeirloom confirmed present — output: function: 0x79585c778.
--   Using IsItemHeirloom branch (not GetHeirloomInfo fallback). D-02 guard retained for
--   future-patch safety only.
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

-- ============================================================
-- ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, getIlvl, ohHeirloomActive)
-- Shared weapon dual-slot arithmetic (REV-010/D-15): non-dual-wield specs
-- always compare against weaponSlot; dual-wield specs (or Fury+2H) compare
-- against the weaker of MH/OH, unless OH holds an active heirloom (then MH
-- only — an active heirloom never loses a comparison it can't win anyway).
-- getIlvl(slotID) abstracts live (player) vs cached (party member) reads.
-- Returns (compareSlotID, compareIlvl). Tie goes to slot 16 (main-hand).
-- ============================================================
local function ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, getIlvl, ohHeirloomActive)
  if not dualSlotCompare then
    return weaponSlot, getIlvl(weaponSlot)
  end
  if ohHeirloomActive then
    return 16, getIlvl(16)
  end
  local ilvl16, ilvl17 = getIlvl(16), getIlvl(17)
  if ilvl16 <= ilvl17 then return 16, ilvl16 end
  return 17, ilvl17
end

-- ============================================================
-- Is2HWeaponEquipped(unit)
-- D-11: an off-hand item can never be an upgrade for a unit currently
-- wielding a two-handed weapon (nothing to hold it in). Shared by the
-- self-check and party-candidate offhand branches — previously only the
-- party path checked this, which meant a 2H-wielding player's own off-hand
-- drops silently misread as self-upgrades (popup never fired for anyone).
-- ============================================================
local function Is2HWeaponEquipped(unit)
  local link = GetInventoryItemLink(unit, 16)
  if link == nil then return false end
  local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
  return equipLoc == "INVTYPE_2HWEAPON"
end

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
    if isHeirloomActive(char.getLiveSlotLink(weaponSlot), char.level) then
      return false, nil, weaponSlot, "heirloom"
    end
    local dualSlotCompare = (hands == "both")
    -- Cross-config (D-16): a 2H that REPLACES a current 1H+off-hand setup is
    -- judged against the AVERAGE of the two slots it displaces. Self-gating —
    -- only fires when an off-hand is actually equipped (slot 17 > 0) and the
    -- member isn't already on a 2H, i.e. exactly the 1H+off-hand config; a
    -- pure-2H spec (Arms) never has an off-hand to average. Fury's Titan's-Grip
    -- 2H is the dual-slot (min) case above, not this one.
    if itemData.equipLoc == "INVTYPE_2HWEAPON" and not dualSlotCompare
       and not char.is2HEquipped() and char.getLiveSlotIlvl(17) > 0 then
      local pairAvg = math.floor((char.getLiveSlotIlvl(16) + char.getLiveSlotIlvl(17)) / 2)
      if (droppedIlvl - pairAvg) < threshold then return false, pairAvg, 16, "ilvl" end
      return true, pairAvg, 16, "eligible"
    end
    local ohHeirloomActive = dualSlotCompare and isHeirloomActive(char.getLiveSlotLink(17), char.level)
    local compareSlot, compareIlvl = ResolveWeaponCompareSlot(dualSlotCompare, weaponSlot, char.getLiveSlotIlvl, ohHeirloomActive)
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
    -- Cross-config (D-16, supersedes the old D-11 blanket skip): a member on a
    -- 2H CAN switch to 1H + off-hand item, so the item is a candidate — judged
    -- STRAIGHT against the 2H it would (partly) displace (slot 16). Off a 2H, it
    -- simply replaces whatever is in the off-hand slot (17), as before.
    if char.is2HEquipped() then
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
    classToken      = playerClassToken,
    specID          = playerSpecID,
    level           = UnitLevel("player"),
    getSlotIlvl     = readPlayerSlotIlvl,
    getSlotLink     = playerLive,
    getLiveSlotIlvl = readPlayerSlotIlvl,
    getLiveSlotLink = playerLive,
    is2HEquipped    = function() return Is2HWeaponEquipped("player") end,
  }

  local eligible, _, _, reason = EvaluateItemForCharacter(data, threshold, playerChar)

  LIF.Log("self-check " .. tostring(data.equipLoc or data.slotCategory)
    .. " cat="       .. tostring(data.slotCategory)
    .. " drop="      .. tostring(data.ilvl)
    .. " threshold=" .. tostring(threshold)
    .. " result="    .. tostring(eligible)
    .. " reason="    .. tostring(reason))

  return eligible
end

-- ============================================================
-- _checkMemberEligibility(itemData, member, unit, threshold) — module-local helper
-- Used by OnLootInspectReady after fresh inspect data is available.
-- Nil gear slots are treated as ilvl 0 per D-03.
-- Returns: (eligible: bool, candidate: table|nil)
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
  local memberChar = {
    classToken = classToken,
    specID     = member.specID,
    level      = UnitLevel(unit),
    getSlotIlvl     = cachedIlvl,
    getSlotLink     = cachedLink,
    getLiveSlotIlvl = cachedIlvl,
    getLiveSlotLink = cachedLink,
    is2HEquipped    = function()
      local link = cachedLink(16)
      if not link then return false end
      return select(9, GetItemInfo(link)) == "INVTYPE_2HWEAPON"
    end,
  }

  local eligible, ilvlCurrent, slotID, reason = EvaluateItemForCharacter(itemData, threshold, memberChar)
  local cat = itemData.slotCategory

  if not eligible then
    LIF.Log("cmp " .. cmpName .. " " .. tostring(cat) .. " -> skip(" .. tostring(reason) .. ")")
    return false, nil
  end

  local delta = ilvlCurrent and (itemData.ilvl - ilvlCurrent) or nil
  LIF.Log("cmp " .. cmpName .. " " .. tostring(cat) .. " drop=" .. tostring(itemData.ilvl)
    .. " curr=" .. tostring(ilvlCurrent) .. " slot=" .. tostring(slotID)
    .. " delta=+" .. tostring(delta) .. " -> eligible")

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
  }
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
      local shouldInclude = false

      if cat == "armor" then
        -- D-16: armor → filter by live UnitClass (works without inspect)
        local _, classToken = UnitClass(unit)
        if classToken and LIF.ARMOR_TYPE[classToken] == armorType then
          shouldInclude = true
        end

      elseif cat == "weapon" or cat == "offhand" then
        -- By-class usability+stat union (respec-proof; live UnitClass, never
        -- cached member.specID). 2H gate for offhand stays deferred to
        -- _checkMemberEligibility (needs a live slot 16 read).
        local _, memberClassToken = UnitClass(unit)
        shouldInclude = ClassCouldUseItem(memberClassToken, itemData)

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
          end
        end

      else
        -- Unknown category → include conservatively
        shouldInclude = true
      end

      if shouldInclude then
        scanningGuids[guid] = true
        LIF.RequestReinspect(guid)
      end
    end
  end

  return { candidates = {}, scanningGuids = scanningGuids }
end

-- NOTE: LIF.RevalidateCandidates (link re-read revalidation) was removed
-- 2026-06-12 (REV-011). The rescan-all-at-loot design (EvaluateCandidates →
-- RequestReinspect → fresh inspect before popup) supersedes it; see git
-- history if per-candidate link revalidation is ever needed again.

-- ============================================================
-- LIF.OnLootInspectReady(guid)
-- SOLE popup opener (D-08). Called after INSPECT_READY resolves a party member.
-- For each pending loot item that has this guid in scanningGuids, applies full
-- eligibility using fresh post-inspect gear data (nil slot = 0 ilvl per D-03).
--
-- Popup lifecycle per entry:
--   - popupOpened == false: accumulate candidates; when ALL scanningGuids resolve,
--     call LIF.ShowPopup with sorted confirmedCandidates (delta desc, D-12 tie-break).
--   - popupOpened == true: call LIF.Popup_UpdateCandidate for new eligible candidates.
--   - Not eligible: call LIF.Popup_RemoveCandidate.
-- ============================================================
function LIF.OnLootInspectReady(guid)
  if LIF.pendingLootItems == nil or #LIF.pendingLootItems == 0 then return end

  local member = LIF.Cache.GetMember(guid)
  if member == nil then return end

  -- Partial INSPECT_READY fires leave the member PENDING with incomplete gear
  -- (queue.lua MIN_SLOTS / stabilization gate returns before SetComplete).
  -- Evaluating now would read empty gear as ilvl 0 and confirm false
  -- candidates. Return WITHOUT consuming scanningGuids so the COMPLETE fire
  -- re-evaluates; the 4-second window timer covers members that never finish.
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
      if entry.popupOpened then
        if LIF.Popup_UpdateCandidate then
          LIF.Popup_UpdateCandidate(guid, candidate, entry.itemData.link)
        end
      end
    else
      if entry.popupOpened then
        if LIF.Popup_RemoveCandidate then
          LIF.Popup_RemoveCandidate(guid, entry.itemData.link)
        end
      end
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

-- Returns true if the item's primary stat matches the member's spec primary stat.
function LIF.IsTrinketCompatible(itemPrimaryStat, memberPrimaryStat)
  return itemPrimaryStat == memberPrimaryStat
end
