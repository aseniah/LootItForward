-- tests/test_spec_data.lua
-- Bidirectional completeness validation for core/spec_data.lua (D-07).
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
-- Ground truth: every retail spec as of WoW 11.x (Midnight expansion).
-- D-07: updating spec_data.lua for a new spec ALSO requires updating this table.
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
  end
end

-- ============================================================
-- Run suite
-- ============================================================
os.exit(lu.LuaUnit.run())
