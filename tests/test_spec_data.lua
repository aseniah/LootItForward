-- tests/test_spec_data.lua
-- Bidirectional completeness validation for the SPEC_TABLE in core/character_data.lua (D-07).
-- Also covers core/armor_data.lua (REQ-test-coverage-offline).
-- Run: lua tests/test_spec_data.lua  (from project root)

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

local lu = require("luaunit")

-- ============================================================
-- Ground truth: every retail spec (Midnight).
-- D-07: adding a spec to the SPEC_TABLE in character_data.lua ALSO requires updating this table.
-- D-06: spec 1480 (Devourer DH) is INT, not AGI.
-- ============================================================
local EXPECTED = {
  [71]  = "STR", [72]  = "STR", [73]  = "STR",           -- Warrior
  [65]  = "INT", [66]  = "STR", [70]  = "STR",           -- Paladin
  [253] = "AGI", [254] = "AGI", [255] = "AGI",           -- Hunter
  [259] = "AGI", [260] = "AGI", [261] = "AGI",           -- Rogue
  [256] = "INT", [257] = "INT", [258] = "INT",           -- Priest
  [250] = "STR", [251] = "STR", [252] = "STR",           -- Death Knight
  [262] = "INT", [263] = "AGI", [264] = "INT",           -- Shaman
  [62]  = "INT", [63]  = "INT", [64]  = "INT",           -- Mage
  [265] = "INT", [266] = "INT", [267] = "INT",           -- Warlock
  [268] = "AGI", [269] = "AGI", [270] = "INT",           -- Monk
  [102] = "INT", [103] = "AGI", [104] = "AGI", [105] = "INT",  -- Druid
  [577] = "AGI", [581] = "AGI", [1480] = "INT",          -- Demon Hunter (1480=Devourer, D-06)
  [1467] = "INT", [1468] = "INT", [1473] = "INT",        -- Evoker
}

local VALID_STATS = { STR = true, AGI = true, INT = true }

-- Legal weapon subIDs (classID 2) per the SPEC_TABLE header vocabulary:
-- 0 1HAxe · 1 2HAxe · 2 Bow · 3 Gun · 4 1HMace · 5 2HMace · 6 Polearm ·
-- 7 1HSword · 8 2HSword · 9 Warglaive · 10 Staff · 13 Fist · 15 Dagger ·
-- 18 Crossbow · 19 Wand. Off-hand items (classID 4): 0 Holdable · 6 Shield.
local VALID_WEAPON_SUBIDS = {
  [0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,
  [8]=true,[9]=true,[10]=true,[13]=true,[15]=true,[18]=true,[19]=true,
}
local VALID_OFFHAND_ITEM_SUBIDS = { [0]=true, [6]=true }

-- ============================================================
-- TestSpecData
-- ============================================================
TestSpecData = {}

function TestSpecData:setUp()
  ResetMocks()
end

-- Check every SPEC_TABLE entry's primaryStat maps to a valid stat string.
-- Catches typos like "AGi" or "str".
function TestSpecData:test_all_stats_are_valid_values()
  for specID, entry in pairs(LIF.SPEC_TABLE) do
    lu.assertTrue(VALID_STATS[entry.primaryStat] == true,
      ("spec %d has invalid primaryStat %q (must be STR, AGI, or INT)"):format(specID, tostring(entry.primaryStat)))
  end
end

-- Check every SPEC_TABLE entry's primaryStat exists in EXPECTED with the same value.
-- Key cases: 1480 -> "INT" (D-06), 62 -> "INT", 71 -> "STR", 577 -> "AGI".
function TestSpecData:test_forward_matches_expected()
  for specID, entry in pairs(LIF.SPEC_TABLE) do
    local expected = EXPECTED[specID]
    lu.assertNotNil(expected,
      ("spec %d found in SPEC_TABLE but not in EXPECTED table"):format(specID))
    lu.assertEquals(entry.primaryStat, expected,
      ("spec %d: got %q, expected %q"):format(specID, entry.primaryStat, expected))
  end
end

-- Check every specID in EXPECTED exists in LIF.SPEC_TABLE with the same primaryStat.
-- Catches missing entries (production table has fewer specs than expected).
function TestSpecData:test_reverse_all_expected_present()
  for specID, expected in pairs(EXPECTED) do
    local entry = LIF.SPEC_TABLE[specID]
    lu.assertNotNil(entry,
      ("spec %d expected in SPEC_TABLE but not found"):format(specID))
    lu.assertEquals(entry.primaryStat, expected,
      ("spec %d: got %q, expected %q"):format(specID, tostring(entry and entry.primaryStat), expected))
  end
end

-- ============================================================
-- TestArmorData
-- ============================================================
TestArmorData = {}

function TestArmorData:setUp()
  ResetMocks()
end

-- Check every class token in LIF.ARMOR_TYPE maps to a valid armor type.
-- Explicitly assert spot-check classes: WARRIOR->Plate, MAGE->Cloth, DRUID->Leather, HUNTER->Mail.
function TestArmorData:test_all_classes_map_to_valid_armor_type()
  local VALID_ARMOR = { Plate = true, Mail = true, Leather = true, Cloth = true }
  for classToken, armorType in pairs(LIF.ARMOR_TYPE) do
    lu.assertTrue(VALID_ARMOR[armorType] == true,
      ("class %s maps to invalid armor type %q"):format(classToken, tostring(armorType)))
  end
  -- Spot-check known mappings
  lu.assertEquals(LIF.ARMOR_TYPE["WARRIOR"], "Plate",
    "WARRIOR must map to Plate")
  lu.assertEquals(LIF.ARMOR_TYPE["MAGE"], "Cloth",
    "MAGE must map to Cloth")
  lu.assertEquals(LIF.ARMOR_TYPE["DRUID"], "Leather",
    "DRUID must map to Leather")
  lu.assertEquals(LIF.ARMOR_TYPE["HUNTER"], "Mail",
    "HUNTER must map to Mail")
end

-- AUD-005: the production armor gate (loot.lua) compares itemData.armorType, drawn
-- from SUBCLASS_ARMOR[subID], against LIF.ARMOR_TYPE[classToken] by RAW equality. The
-- two vocabularies are authored independently in different files; if either drifts
-- (e.g. "Plate" -> "PLATE" on one side), the gate always-mismatches and an entire
-- armor class is silently dropped from every armor drop. This guards that the two
-- value-sets stay identical — the actual drift the raw-equality gate is exposed to
-- (the pre-existing test above only checks ARMOR_TYPE against a hardcoded literal,
-- never against SUBCLASS_ARMOR).
function TestArmorData:test_subclass_armor_and_armor_type_vocabularies_match()
  local function valueSet(t)
    local s = {}
    for _, v in pairs(t) do s[v] = true end
    return s
  end
  local VALID_ARMOR_TYPES = { Cloth = true, Leather = true, Mail = true, Plate = true }
  local subclassSet = valueSet(LIF.SUBCLASS_ARMOR)
  local classSet    = valueSet(LIF.ARMOR_TYPE)

  for v in pairs(VALID_ARMOR_TYPES) do
    lu.assertTrue(subclassSet[v] == true, ("SUBCLASS_ARMOR is missing armor type %q"):format(v))
    lu.assertTrue(classSet[v] == true, ("ARMOR_TYPE is missing armor type %q"):format(v))
  end
  for v in pairs(subclassSet) do
    lu.assertTrue(VALID_ARMOR_TYPES[v] == true, ("SUBCLASS_ARMOR has unexpected armor type %q"):format(v))
    lu.assertTrue(classSet[v] == true,
      ("armor type %q in SUBCLASS_ARMOR is absent from ARMOR_TYPE — the raw-equality gate would always mismatch"):format(v))
  end
  for v in pairs(classSet) do
    lu.assertTrue(subclassSet[v] == true,
      ("armor type %q in ARMOR_TYPE is absent from SUBCLASS_ARMOR — the raw-equality gate would always mismatch"):format(v))
  end
end

-- ============================================================
-- TestSpecTableConsistency
-- Structural invariants for the per-spec truth table. Guards against the
-- silently-incomplete-coverage bug class (a spec missing a field, or a spec
-- present in one of CLASS_SPECS/SPEC_TABLE but not the other).
-- ============================================================
TestSpecTableConsistency = {}

function TestSpecTableConsistency:setUp()
  ResetMocks()
end

-- Every SPEC_TABLE entry must carry all four fields with the right shape:
-- primaryStat is a valid stat; mainHand/offHandWeapon/offHandItem are tables
-- whose keys are numeric subIDs and whose values are the literal `true`.
function TestSpecTableConsistency:test_every_spec_entry_is_complete()
  for specID, entry in pairs(LIF.SPEC_TABLE) do
    lu.assertTrue(VALID_STATS[entry.primaryStat] == true,
      ("spec %d: primaryStat must be STR/AGI/INT"):format(specID))
    for _, field in ipairs({ "mainHand", "offHandWeapon", "offHandItem" }) do
      local set = entry[field]
      lu.assertEquals(type(set), "table",
        ("spec %d: %s must be a table (may be empty, never nil)"):format(specID, field))
      for k, v in pairs(set) do
        lu.assertEquals(type(k), "number",
          ("spec %d: %s has non-numeric subID key %q"):format(specID, field, tostring(k)))
        lu.assertEquals(v, true,
          ("spec %d: %s[%s] must be literal true (positive-fact table)"):format(specID, field, tostring(k)))
      end
    end
  end
end

-- Every subID key must be a member of the legal vocabulary (AUD-012). Without
-- this, a typo like [14] for dagger [15] or [11] for staff [10] passes every
-- other test yet silently removes that weapon type from the spec (omission =
-- not usable → missed candidate forever). Weapon fields draw from the classID-2
-- vocabulary; offHandItem from the classID-4 {holdable, shield} pair.
function TestSpecTableConsistency:test_every_subid_key_is_in_the_legal_vocabulary()
  for specID, entry in pairs(LIF.SPEC_TABLE) do
    for _, field in ipairs({ "mainHand", "offHandWeapon" }) do
      for k in pairs(entry[field]) do
        lu.assertTrue(VALID_WEAPON_SUBIDS[k] == true,
          ("spec %d: %s has out-of-vocabulary weapon subID %s"):format(specID, field, tostring(k)))
      end
    end
    for k in pairs(entry.offHandItem) do
      lu.assertTrue(VALID_OFFHAND_ITEM_SUBIDS[k] == true,
        ("spec %d: offHandItem has out-of-vocabulary subID %s (only 0 holdable / 6 shield)")
          :format(specID, tostring(k)))
    end
  end
end

-- A spec has at most ONE free off-hand: it either dual-wields a weapon there
-- (offHandWeapon non-empty) OR holds a shield/holdable there (offHandItem
-- non-empty), never both. This holds for every current spec; the test locks it
-- so a future edit re-introducing an off-hand item on a dual-wield spec (the
-- exact false-positive class the data-validation pass fixed) fails loudly.
function TestSpecTableConsistency:test_no_spec_has_both_offhand_weapon_and_item()
  for specID, entry in pairs(LIF.SPEC_TABLE) do
    local dualWields = next(entry.offHandWeapon) ~= nil
    local holdsItem  = next(entry.offHandItem) ~= nil
    lu.assertFalse(dualWields and holdsItem,
      ("spec %d lists both an offHandWeapon and an offHandItem — a spec has only "
        .. "one off-hand slot, so it can dual-wield OR hold a shield/holdable, not both")
        :format(specID))
  end
end

-- CLASS_SPECS and SPEC_TABLE must cover exactly the same set of specs, and each
-- spec belongs to exactly one class list.
function TestSpecTableConsistency:test_class_specs_and_spec_table_cover_same_specs()
  local seen = {}
  for classToken, specs in pairs(LIF.CLASS_SPECS) do
    for _, specID in ipairs(specs) do
      lu.assertNil(seen[specID],
        ("spec %d appears in CLASS_SPECS more than once (%s and %s)"):format(specID, tostring(seen[specID]), classToken))
      seen[specID] = classToken
      lu.assertNotNil(LIF.SPEC_TABLE[specID],
        ("spec %d listed in CLASS_SPECS[%s] but missing from SPEC_TABLE"):format(specID, classToken))
    end
  end
  for specID in pairs(LIF.SPEC_TABLE) do
    lu.assertNotNil(seen[specID],
      ("spec %d present in SPEC_TABLE but not in any CLASS_SPECS list"):format(specID))
    -- SPEC_LABEL is a third parallel spec-keyed table; guard it against the
    -- same drift (a spec resolving to a raw ID in the debug/chat label).
    lu.assertNotNil(LIF.SPEC_LABEL[specID],
      ("spec %d present in SPEC_TABLE but missing from SPEC_LABEL"):format(specID))
  end
  for specID in pairs(LIF.SPEC_LABEL) do
    lu.assertNotNil(LIF.SPEC_TABLE[specID],
      ("spec %d present in SPEC_LABEL but missing from SPEC_TABLE"):format(specID))
  end
end

-- The three class-keyed tables (CLASS_SPECS, ARMOR_TYPE, CLASS_SHORT) must
-- cover exactly the same set of class tokens. A drift — a class in one but not
-- another — silently breaks the armor-type gate or the chat class label for
-- that class, and no other test would catch an entire class going dark.
function TestSpecTableConsistency:test_class_keyed_tables_cover_same_classes()
  for classToken in pairs(LIF.CLASS_SPECS) do
    lu.assertNotNil(LIF.ARMOR_TYPE[classToken],
      ("class %s in CLASS_SPECS but missing from ARMOR_TYPE"):format(classToken))
    lu.assertNotNil(LIF.CLASS_SHORT[classToken],
      ("class %s in CLASS_SPECS but missing from CLASS_SHORT"):format(classToken))
  end
  for classToken in pairs(LIF.ARMOR_TYPE) do
    lu.assertNotNil(LIF.CLASS_SPECS[classToken],
      ("class %s in ARMOR_TYPE but missing from CLASS_SPECS"):format(classToken))
  end
  for classToken in pairs(LIF.CLASS_SHORT) do
    lu.assertNotNil(LIF.CLASS_SPECS[classToken],
      ("class %s in CLASS_SHORT but missing from CLASS_SPECS"):format(classToken))
  end
end

-- ============================================================
-- TestSpecTableProperties (AUD-519)
-- The suite double-entry-locks primaryStat, but nothing independently locked the
-- CONTENTS of mainHand / offHandWeapon / offHandItem — the cells where one wrong
-- entry silently mis-verdicts a spec forever. Deleting [7] from Mage 62's mainHand,
-- or adding shield [6] to Enhancement 263, used to pass every test.
--
-- These are RELATIONAL invariants, not a mirrored copy of the table: they assert
-- rules the data must obey ("no two-hander in an off-hand"), so they do not rot the
-- way a second copy of the same numbers would.
--
-- Weapon subIDs: 0 1HAxe · 1 2HAxe · 2 Bow · 3 Gun · 4 1HMace · 5 2HMace ·
--   6 Polearm · 7 1HSword · 8 2HSword · 9 Warglaive · 10 Staff · 13 Fist ·
--   15 Dagger · 18 Crossbow · 19 Wand.  Off-hand item subIDs: 0 Holdable · 6 Shield.
-- ============================================================
TestSpecTableProperties = {}

-- Set helpers, kept with the tests (never in production).
local function keysOf(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end
local function setOf(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end
local function specIDsWhere(pred)
  local out = {}
  for specID, e in pairs(LIF.SPEC_TABLE) do
    if pred(specID, e) then out[#out + 1] = specID end
  end
  table.sort(out)
  return out
end

-- Two documented exceptions, named here so a reader sees them without opening the data.
local OUTLAW = 260          -- off-hand accepts any 1H incl. dagger; main-hand excludes dagger
local FURY   = 72           -- Titan's Grip: two-handers in BOTH hands
local TITANS_GRIP_SET = { [1] = true, [5] = true, [6] = true, [8] = true }

-- SubIDs that can never sit in an off-hand: two-handers and ranged weapons.
local TWO_HAND_OR_RANGED = setOf({ 1, 2, 3, 5, 6, 8, 10, 18, 19 })

function TestSpecTableProperties:test_offhand_weapons_are_a_subset_of_main_hand()
  for specID, e in pairs(LIF.SPEC_TABLE) do
    if specID ~= OUTLAW then
      for subID in pairs(e.offHandWeapon) do
        lu.assertTrue(e.mainHand[subID],
          ("spec %d lists weapon subID %d off-hand but not main-hand"):format(specID, subID))
      end
    end
  end
  -- Outlaw is the documented exception: dagger off-hand only.
  lu.assertTrue(LIF.SPEC_TABLE[OUTLAW].offHandWeapon[15], "Outlaw off-hand accepts daggers")
  lu.assertNil(LIF.SPEC_TABLE[OUTLAW].mainHand[15], "Outlaw main-hand excludes daggers")
end

function TestSpecTableProperties:test_no_two_hander_or_ranged_in_an_off_hand()
  for specID, e in pairs(LIF.SPEC_TABLE) do
    if specID ~= FURY then
      for subID in pairs(e.offHandWeapon) do
        lu.assertNil(TWO_HAND_OR_RANGED[subID],
          ("spec %d lists 2H/ranged subID %d in offHandWeapon"):format(specID, subID))
      end
    end
  end
  -- Fury is the documented exception (Titan's Grip), and its set is exact.
  lu.assertEquals(keysOf(LIF.SPEC_TABLE[FURY].offHandWeapon), keysOf(TITANS_GRIP_SET),
    "Fury's Titan's-Grip off-hand set must be exactly {1,5,6,8}")
end

function TestSpecTableProperties:test_every_spec_can_wield_something()
  for specID, e in pairs(LIF.SPEC_TABLE) do
    lu.assertNotNil(next(e.mainHand),
      ("spec %d has an empty mainHand — it could never be a weapon candidate"):format(specID))
  end
end

function TestSpecTableProperties:test_dual_wield_specs_are_exactly_these()
  local dualWielders = specIDsWhere(function(_, e) return next(e.offHandWeapon) ~= nil end)
  lu.assertEquals(dualWielders,
    { 72, 251, 255, 259, 260, 261, 263, 268, 269, 577, 581, 1480 },
    "the set of dual-wielding specs changed")
end

function TestSpecTableProperties:test_shield_only_for_shield_specs()
  local shieldSpecs = specIDsWhere(function(_, e) return e.offHandItem[6] end)
  lu.assertEquals(shieldSpecs, { 65, 66, 73, 262, 264 },
    "only Prot Warrior, Holy/Prot Paladin and Ele/Resto Shaman use shields")
end

function TestSpecTableProperties:test_holdable_only_for_caster_specs()
  local holdableSpecs = specIDsWhere(function(_, e) return e.offHandItem[0] end)
  lu.assertEquals(#holdableSpecs, 18, "18 caster/healer specs can hold an off-hand item")
  -- Ele/Resto Shaman keep holdables (see docs: SHAMAN=true is correct, not a bug).
  lu.assertTrue(LIF.SPEC_TABLE[262].offHandItem[0], "Elemental Shaman can hold a holdable")
  lu.assertTrue(LIF.SPEC_TABLE[264].offHandItem[0], "Restoration Shaman can hold a holdable")
end

function TestSpecTableProperties:test_wand_only_for_priest_mage_warlock()
  local wandSpecs = specIDsWhere(function(_, e) return e.mainHand[19] end)
  lu.assertEquals(wandSpecs, { 62, 63, 64, 256, 257, 258, 265, 266, 267 },
    "wands belong to the nine Priest/Mage/Warlock specs")
end

function TestSpecTableProperties:test_warglaive_only_for_demon_hunters()
  local glaiveSpecs = specIDsWhere(function(_, e) return e.mainHand[9] end)
  lu.assertEquals(glaiveSpecs, { 577, 581, 1480 }, "warglaives are Demon Hunter only")
end

function TestSpecTableProperties:test_ranged_weapons_only_for_bm_and_mm_hunters()
  local rangedSpecs = specIDsWhere(function(_, e)
    return e.mainHand[2] or e.mainHand[3] or e.mainHand[18]
  end)
  lu.assertEquals(rangedSpecs, { 253, 254 },
    "bow/gun/crossbow belong to Beast Mastery and Marksmanship only")
end

function TestSpecTableProperties:test_within_class_groups_share_identical_sets()
  -- Specs of one class that are mechanically identical for loot purposes must not drift
  -- apart: a fix applied to one and missed on its siblings is the failure this catches.
  local groups = {
    { name = "Priest",  ids = { 256, 257, 258 } },
    { name = "Mage",    ids = { 62, 63, 64 } },
    { name = "Warlock", ids = { 265, 266, 267 } },
    { name = "Evoker",  ids = { 1467, 1468, 1473 } },
    { name = "Hunter ranged", ids = { 253, 254 } },
    { name = "Monk melee",    ids = { 268, 269 } },
  }
  for _, g in ipairs(groups) do
    local first = LIF.SPEC_TABLE[g.ids[1]]
    for i = 2, #g.ids do
      local e = LIF.SPEC_TABLE[g.ids[i]]
      lu.assertEquals(keysOf(e.mainHand), keysOf(first.mainHand),
        ("%s specs must share one mainHand set (%d drifted)"):format(g.name, g.ids[i]))
      lu.assertEquals(keysOf(e.offHandWeapon), keysOf(first.offHandWeapon),
        ("%s specs must share one offHandWeapon set (%d drifted)"):format(g.name, g.ids[i]))
      lu.assertEquals(keysOf(e.offHandItem), keysOf(first.offHandItem),
        ("%s specs must share one offHandItem set (%d drifted)"):format(g.name, g.ids[i]))
      lu.assertEquals(e.primaryStat, first.primaryStat,
        ("%s specs must share one primaryStat (%d drifted)"):format(g.name, g.ids[i]))
    end
  end
end

-- ============================================================
-- TestEquipLocVocabulary (AUD-523)
-- The equipLoc vocabulary is now ONE table (LIF.EQUIP_LOC): slots + an optional
-- hand label. It used to be two tables keyed by the same names, and they had already
-- drifted — INVTYPE_OFFHAND was a real, classified off-hand equipLoc but was missing
-- from the label table, so such a drop logged no hand= tag while its INVTYPE_HOLDABLE
-- sibling did. These guards make a half-added equipLoc fail loudly.
-- ============================================================
TestEquipLocVocabulary = {}

local function touchesHandSlot(slots)
  for _, s in ipairs(slots) do
    if s == 16 or s == 17 then return true end
  end
  return false
end

function TestEquipLocVocabulary:test_hand_label_exactly_on_the_weapon_and_offhand_slots()
  for equipLoc, e in pairs(LIF.EQUIP_LOC) do
    if touchesHandSlot(e.slots) then
      lu.assertNotNil(e.hand,
        ("%s occupies slot 16/17 but has no hand label — the drop header would omit hand=")
          :format(equipLoc))
    else
      lu.assertNil(e.hand,
        ("%s does not occupy slot 16/17 but carries a hand label"):format(equipLoc))
    end
  end
end

function TestEquipLocVocabulary:test_every_equiploc_has_at_least_one_slot()
  for equipLoc, e in pairs(LIF.EQUIP_LOC) do
    lu.assertNotNil(e.slots, ("%s has no slots"):format(equipLoc))
    lu.assertNotNil(e.slots[1], ("%s has an empty slot list"):format(equipLoc))
  end
end

function TestEquipLocVocabulary:test_offhand_category_equiplocs_are_all_present()
  -- The classifier routes these three to the "offhand" category; each must be in the
  -- vocabulary with slot 17 and a hand label. INVTYPE_OFFHAND is the one that drifted.
  for _, equipLoc in ipairs({ "INVTYPE_OFFHAND", "INVTYPE_SHIELD", "INVTYPE_HOLDABLE" }) do
    local e = LIF.EQUIP_LOC[equipLoc]
    lu.assertNotNil(e, ("%s missing from the equipLoc vocabulary"):format(equipLoc))
    lu.assertEquals(e.slots, { 17 }, ("%s must map to slot 17"):format(equipLoc))
    lu.assertNotNil(e.hand, ("%s must carry a hand label"):format(equipLoc))
    lu.assertEquals(LIF.GetSlotCategory(equipLoc, 4, 0), "offhand",
      ("%s must classify as the offhand category"):format(equipLoc))
  end
end

-- ============================================================
-- Run suite
-- ============================================================
os.exit(lu.LuaUnit.run())
