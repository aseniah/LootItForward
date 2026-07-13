-- tests/test_active.lua
-- luaunit truth table for LIF.ComputeActive — whether the addon is alive at all.
-- Run: lua tests/test_active.lua  (from project root)
--
-- This is the single most consequential boolean in the addon, and it used to live in
-- the un-harnessed entry file where no test could reach it (AUD-520). Every input is
-- trivially mockable, so the whole predicate is a truth table.

package.path = package.path .. ";./tests/?.lua;../?.lua;../tests/?.lua"

require("mock_wow_api")

local LIF = {}
local _coreDir = "core"
do
  local f = io.open("core/loot.lua", "r")
  if f then f:close() else _coreDir = "../core" end
end
LoadAddonModules(LIF, _coreDir)

local lu = require("luaunit")

-- ============================================================
-- Harness: drive the five inputs, then read the verdict.
-- ============================================================
local function setState(o)
  ResetMocks()
  _mockInRaid          = o.raid or false
  _mockIsInGroup       = o.group or false
  _mockGroupSize       = o.size or 0
  _mockIsInInstance    = { o.inInstance or false, o.instanceType or "none" }
  _mockIsOnGarrisonMap = o.garrison or false
  LootItForward = {
    db = { profile = {
      enableOpenWorld = o.openWorld or false,
      minPartySize    = o.minPartySize or 2,
    } },
  }
end

TestComputeActive = {}

function TestComputeActive:tearDown()
  LootItForward = nil
end

-- ---------- solo / raid: never active ----------

function TestComputeActive:test_solo_is_never_active()
  setState({ group = false, inInstance = true, instanceType = "party", openWorld = true })
  lu.assertFalse(LIF.ComputeActive(), "ungrouped is always inactive, even in a dungeon")
end

function TestComputeActive:test_raid_is_never_active()
  -- Raids are excluded instanced AND in the open world.
  setState({ raid = true, group = true, size = 20, inInstance = true, instanceType = "raid" })
  lu.assertFalse(LIF.ComputeActive(), "raid instance is inactive")

  setState({ raid = true, group = true, size = 20, openWorld = true })
  lu.assertFalse(LIF.ComputeActive(), "open-world raid group is inactive even with open world on")

  setState({ raid = true, group = true, size = 20, inInstance = true, instanceType = "party" })
  lu.assertFalse(LIF.ComputeActive(), "raid flag beats a party instanceType")
end

-- ---------- 5-player dungeon: active regardless of the open-world setting ----------

function TestComputeActive:test_party_dungeon_is_active()
  setState({ group = true, size = 5, inInstance = true, instanceType = "party" })
  lu.assertTrue(LIF.ComputeActive(), "a 5-player dungeon is the addon's home turf")
end

function TestComputeActive:test_party_dungeon_ignores_the_open_world_setting()
  setState({ group = true, size = 5, inInstance = true, instanceType = "party", openWorld = false })
  lu.assertTrue(LIF.ComputeActive(), "the open-world toggle must not disable dungeons")
end

-- ---------- open world: gated by the setting ----------

function TestComputeActive:test_open_world_group_follows_the_setting()
  setState({ group = true, size = 3, openWorld = true })
  lu.assertTrue(LIF.ComputeActive(), "grouped in the open world with the setting ON")

  setState({ group = true, size = 3, openWorld = false })
  lu.assertFalse(LIF.ComputeActive(), "grouped in the open world with the setting OFF")
end

-- ---------- every other instance type: inactive ----------

function TestComputeActive:test_non_party_instance_types_are_inactive()
  for _, t in ipairs({ "raid", "arena", "pvp", "scenario", "neighborhood", "interior" }) do
    setState({ group = true, size = 5, inInstance = true, instanceType = t, openWorld = true })
    lu.assertFalse(LIF.ComputeActive(),
      ("instanceType %q must not activate the addon"):format(t))
  end
end

-- ---------- minPartySize boundary ----------

function TestComputeActive:test_min_party_size_boundary()
  -- At the threshold: active. One below: fully disabled, not merely popup-suppressed.
  setState({ group = true, size = 2, minPartySize = 2, inInstance = true, instanceType = "party" })
  lu.assertTrue(LIF.ComputeActive(), "group size AT the minimum is active")

  setState({ group = true, size = 1, minPartySize = 2, inInstance = true, instanceType = "party" })
  lu.assertFalse(LIF.ComputeActive(), "group size BELOW the minimum is inactive")

  setState({ group = true, size = 4, minPartySize = 5, inInstance = true, instanceType = "party" })
  lu.assertFalse(LIF.ComputeActive(), "a raised threshold disables an otherwise-valid dungeon group")

  setState({ group = true, size = 5, minPartySize = 5, inInstance = true, instanceType = "party" })
  lu.assertTrue(LIF.ComputeActive(), "meeting a raised threshold re-activates")
end

-- ---------- WoD garrison (AUD-I06) ----------

function TestComputeActive:test_garrison_is_not_a_dungeon()
  -- A garrison reports IsInInstance() == true, "party" — confirmed in-game 2026-07-12,
  -- where the addon went fully active while the player idled in their garrison. It is
  -- personal outdoor content, so it must follow the OPEN WORLD rule, not the dungeon one.
  setState({ group = true, size = 2, inInstance = true, instanceType = "party",
             garrison = true, openWorld = false })
  lu.assertFalse(LIF.ComputeActive(),
    "a garrison must not count as a 5-player dungeon")

  setState({ group = true, size = 2, inInstance = true, instanceType = "party",
             garrison = true, openWorld = true })
  lu.assertTrue(LIF.ComputeActive(),
    "with open world enabled a garrison follows the open-world rule")
end

function TestComputeActive:test_garrison_flag_does_not_leak_into_real_dungeons()
  setState({ group = true, size = 5, inInstance = true, instanceType = "party",
             garrison = false, openWorld = false })
  lu.assertTrue(LIF.ComputeActive(), "a real dungeon is unaffected by the garrison check")
end

os.exit(lu.LuaUnit.run())
