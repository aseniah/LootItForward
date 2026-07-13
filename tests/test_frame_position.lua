-- tests/test_frame_position.lua
-- luaunit suite for the shared saved-window-position rules (core/frame_position.lua).
-- Run: lua tests/test_frame_position.lua  (from project root)
--
-- The popup and the debug panel used to carry a copy of these rules each, and the copies
-- had already drifted (AUD-525). They are pure arithmetic, so they belong in the harness.
--
-- Convention under test: the frame's TOPLEFT is anchored against UIParent's BOTTOMLEFT,
-- so x is the LEFT edge and y is the TOP edge's height above the bottom of the screen.

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

local SCREEN_W, SCREEN_H = 1920, 1080
local GEOM = { width = 340, titleStrip = 24 }   -- the popup's geometry

TestFramePosition = {}

-- ============================================================
-- HasSavedPosition — is the stored table even usable?
-- ============================================================

function TestFramePosition:test_a_well_formed_position_is_accepted()
  lu.assertTrue(LIF.HasSavedPosition({ x = 100, y = 500 }))
  lu.assertTrue(LIF.HasSavedPosition({ x = 0, y = 1 }), "x may legitimately be zero")
end

function TestFramePosition:test_nil_and_empty_are_rejected()
  lu.assertFalse(LIF.HasSavedPosition(nil))
  lu.assertFalse(LIF.HasSavedPosition({}))
end

function TestFramePosition:test_a_half_written_save_is_rejected()
  -- The failure this guard exists for: { y = 400 } with no x passes a y-only check and
  -- then throws inside SetPoint(nil).
  lu.assertFalse(LIF.HasSavedPosition({ y = 400 }), "y without x must not pass")
  lu.assertFalse(LIF.HasSavedPosition({ x = 400 }), "x without y must not pass")
end

function TestFramePosition:test_non_numeric_coords_are_rejected()
  lu.assertFalse(LIF.HasSavedPosition({ x = "100", y = 500 }))
  lu.assertFalse(LIF.HasSavedPosition({ x = 100, y = false }))
end

function TestFramePosition:test_a_non_positive_y_is_rejected()
  -- y is the TOP edge above the screen bottom, so y <= 0 puts the whole frame below it.
  lu.assertFalse(LIF.HasSavedPosition({ x = 100, y = 0 }))
  lu.assertFalse(LIF.HasSavedPosition({ x = 100, y = -50 }))
end

-- ============================================================
-- IsPositionOnScreen
-- ============================================================

function TestFramePosition:test_a_centred_position_is_on_screen()
  lu.assertTrue(LIF.IsPositionOnScreen(800, 600, GEOM, SCREEN_W, SCREEN_H))
end

function TestFramePosition:test_horizontal_overlap_boundary()
  -- Exactly MIN_ONSCREEN px visible on the right edge: still grabbable.
  local x = SCREEN_W - LIF.MIN_ONSCREEN
  lu.assertTrue(LIF.IsPositionOnScreen(x, 600, GEOM, SCREEN_W, SCREEN_H))
  lu.assertFalse(LIF.IsPositionOnScreen(x + 1, 600, GEOM, SCREEN_W, SCREEN_H),
    "one px past the minimum overlap is off-screen")

  -- Same on the left, where the frame hangs off past its own width.
  local xLeft = LIF.MIN_ONSCREEN - GEOM.width
  lu.assertTrue(LIF.IsPositionOnScreen(xLeft, 600, GEOM, SCREEN_W, SCREEN_H))
  lu.assertFalse(LIF.IsPositionOnScreen(xLeft - 1, 600, GEOM, SCREEN_W, SCREEN_H))
end

function TestFramePosition:test_the_title_strip_must_stay_on_screen()
  -- The title strip is the only draggable part: if it is below the bottom edge the
  -- window can never be recovered.
  lu.assertTrue(LIF.IsPositionOnScreen(800, GEOM.titleStrip, GEOM, SCREEN_W, SCREEN_H))
  lu.assertFalse(LIF.IsPositionOnScreen(800, GEOM.titleStrip - 1, GEOM, SCREEN_W, SCREEN_H))

  lu.assertTrue(LIF.IsPositionOnScreen(800, SCREEN_H, GEOM, SCREEN_W, SCREEN_H))
  lu.assertFalse(LIF.IsPositionOnScreen(800, SCREEN_H + 1, GEOM, SCREEN_W, SCREEN_H),
    "above the top edge is off-screen")
end

function TestFramePosition:test_a_position_saved_at_a_larger_resolution_is_off_screen()
  -- The scenario the check exists for: saved on a 3840-wide monitor, reopened on 1920.
  lu.assertFalse(LIF.IsPositionOnScreen(3000, 900, GEOM, SCREEN_W, SCREEN_H))
end

function TestFramePosition:test_nan_coords_read_as_off_screen()
  -- NaN fails every ordered comparison, so the checks are written in positive form to
  -- keep it from slipping through a negated one.
  local nan = 0 / 0
  lu.assertFalse(LIF.IsPositionOnScreen(nan, 600, GEOM, SCREEN_W, SCREEN_H))
  lu.assertFalse(LIF.IsPositionOnScreen(800, nan, GEOM, SCREEN_W, SCREEN_H))
end

-- ============================================================
-- ResolveSavedPosition — the self-heal verdict
-- ============================================================

function TestFramePosition:test_no_save_reports_none()
  lu.assertEquals(LIF.ResolveSavedPosition(nil, GEOM, SCREEN_W, SCREEN_H), "none")
end

function TestFramePosition:test_a_good_save_is_returned_verbatim()
  local verdict, x, y = LIF.ResolveSavedPosition({ x = 700, y = 800 }, GEOM, SCREEN_W, SCREEN_H)
  lu.assertEquals(verdict, "saved")
  lu.assertEquals(x, 700)
  lu.assertEquals(y, 800)
end

function TestFramePosition:test_a_malformed_save_reports_corrupt()
  local verdict, x, y = LIF.ResolveSavedPosition({ y = 400 }, GEOM, SCREEN_W, SCREEN_H)
  lu.assertEquals(verdict, "corrupt")
  lu.assertNil(x, "a corrupt save must not hand back coords")
  lu.assertNil(y)
end

function TestFramePosition:test_an_off_screen_save_reports_offscreen()
  local verdict, x, y = LIF.ResolveSavedPosition({ x = 3000, y = 900 }, GEOM, SCREEN_W, SCREEN_H)
  lu.assertEquals(verdict, "offscreen")
  lu.assertNil(x, "an off-screen save must not hand back coords")
  lu.assertNil(y)
end

-- ============================================================
-- CenteredPosition
-- ============================================================

function TestFramePosition:test_centering_puts_the_frame_in_the_middle()
  local x, y = LIF.CenteredPosition(340, 200, SCREEN_W, SCREEN_H)
  lu.assertEquals(x, (1920 - 340) / 2)
  -- y is the TOP edge, so it sits HALF THE HEIGHT ABOVE the screen's midpoint.
  lu.assertEquals(y, (1080 + 200) / 2)
  lu.assertEquals(y - 200 / 2, 1080 / 2, "the frame's centre lands on the screen's centre")
end

function TestFramePosition:test_centering_against_the_wrong_height_opens_the_frame_low()
  -- AUD-513: this is why every caller has to pass the frame's CURRENT height. Centring a
  -- 200px-tall popup as if it were 30px puts its top edge 85px too low.
  local _, yTall = LIF.CenteredPosition(340, 200, SCREEN_W, SCREEN_H)
  local _, yMin  = LIF.CenteredPosition(340, 30, SCREEN_W, SCREEN_H)
  lu.assertTrue(yMin < yTall, "the min-height centre sits lower than the true centre")
  lu.assertEquals(yTall - yMin, (200 - 30) / 2)
end

os.exit(lu.LuaUnit.run())
