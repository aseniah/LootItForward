local _, LIF = ...

-- ============================================================
-- Saved window position — validation, the on-screen test, and the self-heal verdict.
--
-- One copy of the rules for both movable windows (the popup and the debug panel), which
-- had drifted apart while claiming to mirror each other (AUD-525). The rules are pure —
-- no frames, no UIParent — so the harness can reach them: callers pass their own geometry
-- and the current screen size, and APPLY the verdict (anchor the frame, clear a bad save,
-- log). The lone exception is SaveDraggedPosition at the bottom, which needs the frame.
--
-- Coordinate convention, shared by both windows: the frame's TOPLEFT is anchored against
-- UIParent's BOTTOMLEFT, so x is the frame's left edge and y is its TOP edge's height
-- above the bottom of the screen.
-- ============================================================

LIF.MIN_ONSCREEN = 40  -- px of the frame that must stay visible, so it remains grabbable

-- Both coords must be real numbers, and y must be positive — with a TOPLEFT/BOTTOMLEFT
-- anchor, y <= 0 puts the whole frame below the screen. A partially-corrupt save such as
-- { y = 400 } with no x would otherwise pass a y-only guard and then throw inside SetPoint.
function LIF.HasSavedPosition(pos)
  return (pos ~= nil
    and type(pos.x) == "number"
    and type(pos.y) == "number"
    and pos.y > 0) or false
end

-- Is (x, y) on the CURRENT screen? Requires horizontal overlap and the title strip within
-- the vertical extent, so the window can always be grabbed and dragged back. A position
-- saved at a larger resolution, or before a UI-scale change, can land off-screen.
--
-- geom is { width, titleStrip }. Comparisons are in positive form so a NaN coord (which
-- fails every ordered compare) reads as off-screen instead of slipping through a negation.
function LIF.IsPositionOnScreen(x, y, geom, screenW, screenH)
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local visibleW = math.min(x + geom.width, screenW) - math.max(x, 0)
  if not (visibleW >= LIF.MIN_ONSCREEN) then return false end
  if not (y <= screenH and y >= geom.titleStrip) then return false end
  return true
end

-- The self-heal decision. Returns a verdict, plus the coords when they are usable:
--   "saved"     — open at the returned x, y
--   "offscreen" — well-formed but not on this screen
--   "corrupt"   — stored but malformed
--   "none"      — nothing stored
-- Anything but "saved" means CENTRE. For "offscreen" and "corrupt" the caller must also
-- CLEAR the stored value, or the lost point is re-detected and re-reported on every show.
function LIF.ResolveSavedPosition(pos, geom, screenW, screenH)
  if pos == nil then return "none" end
  if not LIF.HasSavedPosition(pos) then return "corrupt" end
  if not LIF.IsPositionOnScreen(pos.x, pos.y, geom, screenW, screenH) then return "offscreen" end
  return "saved", pos.x, pos.y
end

-- Centre a frame of this size. y is the TOP edge (hence + height/2, not -). Pass the
-- frame's CURRENT height: centring a content-sized window against its minimum height
-- opens it low on the screen (AUD-513).
function LIF.CenteredPosition(frameWidth, frameHeight, screenW, screenH)
  return (screenW - frameWidth) / 2, (screenH + frameHeight) / 2
end

-- Persist where the user dragged a window, and re-anchor it to the point that was stored.
--
-- The re-anchor matters: a dragged frame keeps whatever anchor it had before the drag, so
-- without it the frame and the saved coords describe the same spot by luck rather than by
-- construction, and the next restore moves the window. Storing TOPLEFT/BOTTOMLEFT offsets
-- makes the save and the restore speak the same coordinate system.
--
-- The one function here that touches frames, so it is the one the harness cannot reach —
-- everything above is pure. Both movable windows call it on mouse-up. `key` is the
-- LootItForward.db.char field to write ("popupPosition" / "debugPosition"), `label` the
-- log prefix.
function LIF.SaveDraggedPosition(frame, key, label)
  local x = frame:GetLeft() - UIParent:GetLeft()
  local y = frame:GetTop() - UIParent:GetBottom()
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  if LootItForward and LootItForward.db then
    LootItForward.db.char[key] = { x = x, y = y }
    LIF.Log(label .. ": position saved x=" .. x .. " y=" .. y)
  end
end
