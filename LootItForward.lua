-- LootItForward — entry point and addon registration

local addonName, LIF = ...
LootItForward = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0")

local defaults = {
  profile = {
    enableOpenWorld        = true,
    showChatNotifications  = true,
    minPartySize           = 2,
    whisperMessage         = LIF.DEFAULT_WHISPER_TEMPLATE,
    popupSound             = LIF.DEFAULT_SOUND_KEY,
  },
  char = {
    debugMode = false,
    skipHeirloomCheck = false,
  },
}

function LootItForward:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("LootItForwardDB", defaults, true)
  if LIF.InitSettings then LIF.InitSettings() end
  local ver = C_AddOns.GetAddOnMetadata("LootItForward", "Version") or "?"
  LootItForwardLog = LIF.InitLog(LootItForwardLog, ver)
  -- Debug window is shown from PLAYER_ENTERING_WORLD (fires at login/reload), NOT
  -- here: at OnInitialize the UI scale isn't settled, so the position self-heal's
  -- UIParent:GetHeight() check would judge a valid saved position off-screen and wipe
  -- it. Same reason the popup restores at OnEnable, not ADDON_LOADED.
  SLASH_LIF1 = "/lif"
  SlashCmdList["LIF"] = function(msg)
    -- Normalize to lowercase (AUD-017): every subcommand is all-lowercase ASCII and
    -- the only free-text arg is the numeric log count, so /lif Debug On resolves the
    -- same as /lif debug on rather than falling to the help branch.
    msg = strtrim(msg or ""):lower()
    -- Collapse internal whitespace runs (AUD-321) so "/lif debug  on" (double
    -- space) matches the same literal as "/lif debug on" instead of falling to
    -- the unknown-command branch.
    msg = msg:gsub("%s+", " ")
    if msg == "settings" then -- /lif settings: open in-game ESC > Options panel
      if LIF._settingsCategoryID then
        Settings.OpenToCategory(LIF._settingsCategoryID)
      end
    elseif msg == "debug" then
      local p = LIF.Print
      p("Debug commands (hidden):")
      p("  /lif debug on          — enable debug logging + show debug window")
      p("  /lif debug off         — disable debug logging + hide debug window")
      p("  /lif debug resetpos    — reset debug window to center")
      p("  /lif log [N]           — last N log entries (default 30)")
      p("  /lif clearlog          — clear session log")
      p("  /lif inspectlog        — all persisted inspect records")
      p("  /lif clearinspectlog   — clear inspect records")
      p("  /lif heirloom on|off   — set heirloom-check skip (only takes effect while debug mode is on)")
    elseif msg == "debug on" then
      LIF.SetDebugMode(true)
    elseif msg == "debug off" then
      LIF.SetDebugMode(false)
    elseif msg == "debug resetpos" then
      if LootItForward.db then
        LootItForward.db.char.debugPosition = nil
      end
      if LIF.Debug_RestorePosition then LIF.Debug_RestorePosition() end
      LIF.Print("debug window position reset to center")
    elseif msg:match("^log%s*%d*$") then
      -- Anchored so /lif logout and /lif logs fall through to help, and the count
      -- is read only from the trailing digits — not from digits anywhere (AUD-017).
      local n = tonumber(msg:match("^log%s*(%d*)$")) or 30
      local entries = LIF.GetLog()
      local p = LIF.Print
      p(("--- last %d of %d log entries ---"):format(math.min(n, #entries), #entries))
      local start = math.max(1, #entries - n + 1)
      for i = start, #entries do
        local e = entries[i]
        p(e.t .. "  " .. e.msg)
      end
    elseif msg == "clearlog" then
      LIF.ClearLog()
      LIF.Print("log cleared")
    elseif msg == "inspectlog" then
      local records = LIF.GetInspectRecords()
      local p = LIF.Print
      p(("--- inspect records (%d) ---"):format(#records))
      for _, r in ipairs(records) do
        local nameRealm = (r.realm and r.realm ~= "") and (r.name .. "-" .. r.realm) or r.name
        p(("%s  %s  class=%s  spec=%s(%s)  gear=%d/16"):format(
          r.t, nameRealm, r.class,
          tostring(r.specID), tostring(r.specName), r.slots))
        p(("  got: %s"):format(r.got or r.filled or ""))
        p(("  nil: %s"):format(r.nil_ or r.missing or ""))
      end
      if #records == 0 then p("no inspect records yet") end
    elseif msg == "clearinspectlog" then
      LIF.ClearInspectRecords()
      LIF.Print("inspect records cleared")
    elseif msg == "heirloom on" or msg == "heirloom off" then
      local enabled = msg == "heirloom on"
      if LootItForward.db then LootItForward.db.char.skipHeirloomCheck = enabled end
      -- LIF.Log records to the session log buffer (reviewable via /lif log or the
      -- debug window) but is a silent no-op while debug mode is off — so give an
      -- explicit chat confirmation in that case instead.
      if LootItForward.db and LootItForward.db.char.debugMode then
        LIF.Log("heirloom check skip " .. (enabled and "on" or "off"))
      else
        LIF.Print("heirloom check skip " .. (enabled and "on" or "off")
          .. " (no effect until debug mode is on)")
      end
    elseif msg == "resetpos" then
      if LootItForward.db then
        LootItForward.db.char.popupPosition = nil
      end
      if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
      LIF.Print("popup position reset to default")
    elseif msg == "example" then
      if LIF.ShowExamplePopup then
        LIF.ShowExamplePopup()
      else
        LIF.Print("ShowExamplePopup not loaded")
      end
    elseif msg == "" then
      local p = LIF.Print
      p("Commands:")
      p("  /lif settings   — open settings panel")
      p("  /lif example    — show example popup (drag to reposition)")
      p("  /lif resetpos   — reset popup to default position")
    else
      -- Do NOT echo the raw input: pipes typed into the chat editbox reach here
      -- literally, so echoing `msg` would render live color/link escapes as garbage
      -- (AUD-410). Every branch prints only fixed strings.
      LIF.Print("Unknown command. Type /lif for commands.")
    end
  end
  SLASH_LOOTITFORWARD1 = "/lootitforward"
  SlashCmdList["LOOTITFORWARD"] = SlashCmdList["LIF"]
end

function LootItForward:OnEnable()
  LIF.Log("enabled")
  -- Restore popup position at PLAYER_LOGIN, not OnInitialize/ADDON_LOADED: the
  -- off-screen re-center check (AUD-018) reads UIParent:GetHeight(), and the UI
  -- scale may not be applied yet at ADDON_LOADED — a legit save could be judged
  -- against the wrong screen height and wiped. By OnEnable the scale is settled.
  if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
  self:RegisterEvent("PLAYER_ENTERING_WORLD")
  self:RegisterEvent("GROUP_ROSTER_UPDATE")
  self:RegisterEvent("RAID_ROSTER_UPDATE")
  self:RegisterEvent("INSPECT_READY")
  self:RegisterEvent("PLAYER_REGEN_ENABLED")
  self:RegisterEvent("PLAYER_REGEN_DISABLED")
  self:RegisterEvent("UNIT_HEALTH")
  self:RegisterEvent("UNIT_CONNECTION")
  self:RegisterEvent("ENCOUNTER_LOOT_RECEIVED")
  -- Boss-encounter chat lockdown: grey the popup's Whisper buttons for the fight,
  -- restore them after (AUD-014). ADDON_ACTION_BLOCKED is logged (not suppressed) so
  -- a slipped-through blocked whisper still surfaces to BugSack / the default error UI.
  self:RegisterEvent("ENCOUNTER_START")
  self:RegisterEvent("ENCOUNTER_END")
  self:RegisterEvent("ADDON_ACTION_BLOCKED")
end

function LootItForward:OnDisable()
  LIF.Queue_StopAndReset()
  if LIF.Loot_Reset then LIF.Loot_Reset() end
  self:UnregisterAllEvents()
end

-- Reset matrix (which transition clears what) — AUD-021 documentation:
--   GROUP_ROSTER_UPDATE / RAID_ROSTER_UPDATE inactive : Queue_StopAndReset +
--       Cache.Clear + Loot_Reset + Popup_OnRosterUpdate (prunes departed rows)
--   PLAYER_ENTERING_WORLD inactive                    : Queue_StopAndReset +
--       Cache.Clear + Loot_Reset; popup dismissed on a location change (above)
--   OnDisable                                         : Queue_StopAndReset +
--       Loot_Reset; cache RETAINED intentionally (L6); popup untouched (addon off)
-- The cache-retention asymmetry on OnDisable is deliberate, not an oversight.

function LootItForward:ShouldBeActive()
  -- Pure check, no side effects (REV-013): every inactive caller path clears
  -- the cache itself, and the debug window polls this every 3 seconds.
  if IsInRaid() then
    -- Covers instanced AND open world raid groups (CON-006, DEC-004)
    return false
  end
  if not IsInGroup() then
    return false
  end
  -- Below the configured minimum party size the addon is fully disabled (AUD-009),
  -- not merely popup-suppressed. Bidirectional: crossing the threshold via a join
  -- re-activates through GROUP_ROSTER_UPDATE; dropping below runs its cleanup branch.
  if LIF.GroupMeetsMinPartySize and not LIF.GroupMeetsMinPartySize() then
    return false
  end
  local inInstance, instanceType = IsInInstance()
  if inInstance and instanceType == "party" then
    -- All 5-player difficulties: normal, heroic, mythic, timewalking (CON-007)
    return true
  end
  if not inInstance and self.db and self.db.profile.enableOpenWorld then
    return true
  end
  -- arena, pvp, raid instance, scenario, neighborhood, interior -> inactive
  return false
end

function LootItForward:PLAYER_ENTERING_WORLD()
  -- Close any open popup (real or example) when a loading screen means we actually
  -- changed location (AUD-021): entering/leaving a dungeon, or moving between
  -- instances. A MID-instance loading screen (still the same instanceID) is NOT a
  -- location change, so the popup survives it. Cinematics fire CINEMATIC_*/
  -- PLAY_MOVIE, not PLAYER_ENTERING_WORLD, so they never dismiss.
  -- NOTE: relies on instanceID staying constant across an intra-dungeon loading
  -- screen — confirm in-game (/dump select(8, GetInstanceInfo()) before/after);
  -- if it ever differs, the popup simply closes (the prior behaviour).
  local inInstance = IsInInstance()
  local instanceID = select(8, GetInstanceInfo())
  local sameInstance = inInstance and instanceID == self._lastInstanceID
  self._lastInstanceID = inInstance and instanceID or nil
  if not sameInstance and LIF.Popup_Dismiss then
    LIF.Popup_Dismiss()
  end

  local active = self:ShouldBeActive()
  LIF.Log("PLAYER_ENTERING_WORLD — active=" .. tostring(active))
  self._rosterActive = active
  if self.db and self.db.char.debugMode then LIF.ShowDebugWindow() end
  if active then
    LIF.OnGroupRosterUpdate()
  else
    LIF.Queue_StopAndReset()
    LIF.Cache.Clear()
    if LIF.Loot_Reset then LIF.Loot_Reset() end
  end
end

function LootItForward:GROUP_ROSTER_UPDATE()
  local active = self:ShouldBeActive()
  -- GROUP_ROSTER_UPDATE fires far more often than real roster changes (Blizzard
  -- syncs personal-loot eligibility per item through it), so only log the active
  -- state when it actually flips. Real membership changes are logged as
  -- "queue"/"remove" inside OnGroupRosterUpdate below.
  if active ~= self._rosterActive then
    LIF.Log("GROUP_ROSTER_UPDATE — active=" .. tostring(active))
    self._rosterActive = active
  end
  if not active then
    LIF.Queue_StopAndReset()
    LIF.Cache.Clear()
    if LIF.Loot_Reset then LIF.Loot_Reset() end
    if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
    return
  end
  LIF.OnGroupRosterUpdate()
  -- Remove departed candidates from the popup (ui/popup.lua defines this;
  -- nil-guard in case popup.lua has not loaded yet).
  if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
end

-- Defensive inactive-sweep only: while in a raid ShouldBeActive() is always false
-- (IsInRaid gate), and GROUP_ROSTER_UPDATE — the authoritative roster handler — fires
-- alongside every raid roster change. The resets here are idempotent; there is
-- deliberately no active path (see GROUP_ROSTER_UPDATE above).
function LootItForward:RAID_ROSTER_UPDATE()
  local active = self:ShouldBeActive()
  if not active then
    LIF.Queue_StopAndReset()
    LIF.Cache.Clear()
    if LIF.Loot_Reset then LIF.Loot_Reset() end
    if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
  end
end

function LootItForward:INSPECT_READY(_, guid)
  LIF.OnInspectReady(guid)
  LIF.OnLootInspectReady(guid)
end

function LootItForward:PLAYER_REGEN_DISABLED()
  LIF.Log("combat start")
  -- Clear any open example/preview popup so a real drop later this fight does
  -- not interleave with the fabricated example rows (M5).
  if LIF.Popup_DismissExample then LIF.Popup_DismissExample() end
end

function LootItForward:PLAYER_REGEN_ENABLED()
  LIF.Log("combat end")
  -- Short delay before scanning: PLAYER_REGEN_ENABLED fires in the same event
  -- burst where other addons (e.g. Details) do their combat-end processing.
  -- NotifyInspect in that window can trigger bugs in third-party code.
  C_Timer.After(1, function()
    LIF.TryQueuePendingMembers()
    -- Run loot reinspects deferred while combat was active; the same settle
    -- delay applies since these also NotifyInspect via RequestReinspect.
    LIF.FlushAfterCombatCallbacks()
  end)
end

function LootItForward:UNIT_HEALTH(_, unitToken)
  if not unitToken:match("^party[1-4]$") then return end
  LIF.OnUnitHealthChanged(unitToken)
  -- Recovery direction (REQ-scan-retry-on-events, REV-006): a resurrected
  -- member may be scannable again. Skip in combat — CanScanUnit would fail
  -- anyway and UNIT_HEALTH fires constantly while fighting.
  if not InCombatLockdown() and not UnitIsDeadOrGhost(unitToken) then
    LIF.OnUnitMaybeScannable(unitToken)
  end
end

function LootItForward:UNIT_CONNECTION(_, unitToken, isConnected)
  -- Filter to party members before any work, same as UNIT_HEALTH (AUD-023).
  -- Downstream already early-exits on a cache miss / currentlyInspecting mismatch,
  -- so this is a consistency guard, not a correctness fix.
  if not unitToken:match("^party[1-4]$") then return end
  if isConnected then
    LIF.OnUnitMaybeScannable(unitToken)
  else
    LIF.OnUnitDisconnect(unitToken)
  end
end

function LootItForward:ENCOUNTER_LOOT_RECEIVED(_, encounterID, itemID, itemLink, _, playerName, _)
  if not LIF.IsLocalPlayerName(playerName) then return end
  if not self:ShouldBeActive() then return end
  LIF.Log("ENCOUNTER_LOOT_RECEIVED " .. tostring(itemLink) .. " enc=" .. tostring(encounterID))
  LIF.OnPlayerLootReceived(itemLink, itemID)
end

function LootItForward:ENCOUNTER_START(_, encounterID)
  -- Chat enters messaging lockdown for the fight — grey Whisper buttons so the user
  -- sees why they can't whisper (AUD-014). Trade is chat-independent and stays live.
  LIF.Log("encounter start enc=" .. tostring(encounterID))
  if LIF.Popup_GreyWhisperButtons then LIF.Popup_GreyWhisperButtons() end
end

function LootItForward:ENCOUNTER_END(_, encounterID)
  -- Lockdown lifts — re-enable Whisper buttons, but only if the template is non-empty
  -- and lockdown has actually cleared (Popup_RefreshWhisperButtons rechecks both).
  LIF.Log("encounter end enc=" .. tostring(encounterID))
  if LIF.Popup_RefreshWhisperButtons then LIF.Popup_RefreshWhisperButtons() end
  -- InChatMessagingLockdown() may not have flipped false yet at ENCOUNTER_END (the
  -- mirror of the START-side skew the popup already guards). Without a recheck the
  -- buttons could stick greyed until the next boss. Re-run shortly after; idempotent.
  C_Timer.After(1, function()
    if LIF.Popup_RefreshWhisperButtons then LIF.Popup_RefreshWhisperButtons() end
  end)
end

function LootItForward:ADDON_ACTION_BLOCKED(_, blockedAddon, functionName)
  -- Surface, do not suppress (AUD-014): if a whisper (or anything) slips past the
  -- lockdown guards and gets blocked, log it so BugSack / the default error UI still
  -- shows it. Registering this handler does not stop the default error from firing.
  -- Deliberately UNFILTERED (AUD-324): WoW misattributes taint blame across addons
  -- (the AccWideUILayoutSelection incident blamed the wrong addon), so a
  -- blockedAddon == addonName filter would hide the very cross-addon blocks this
  -- handler exists to catch. The 500-entry cap risking eviction under boss-fight
  -- spam is the accepted cost.
  LIF.Log("ADDON_ACTION_BLOCKED addon=" .. tostring(blockedAddon) .. " fn=" .. tostring(functionName))
end
