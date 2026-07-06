-- LootItForward — entry point and addon registration
-- Hover over WoW API calls below to verify the Ketho annotations are working.

local addonName, LIF = ...
LootItForward = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0")

local defaults = {
  profile = {
    enableOpenWorld        = true,
    showChatNotifications  = true,
    minPartySize           = 2,
    whisperMessage         = "Hey, {link} dropped for me and I don't need it. Do you want it?",
    popupSound             = "UI_PERSONAL_LOOT_BANNER",
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
  if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
  if self.db.char.debugMode then LIF.ShowDebugWindow() end
  SLASH_LIF1 = "/lif"
  SlashCmdList["LIF"] = function(msg)
    if msg == "settings" then -- /lif settings: open in-game ESC > Options panel
      if LIF._settingsCategoryID then
        Settings.OpenToCategory(LIF._settingsCategoryID)
      end
    elseif msg == "debug" then
      local p = function(s) DEFAULT_CHAT_FRAME:AddMessage("[LIF] " .. s) end
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
      DEFAULT_CHAT_FRAME:AddMessage("[LIF] debug window position reset to center")
    elseif msg:match("^log") then
      local n = tonumber(msg:match("(%d+)")) or 30
      local entries = LIF.GetLog()
      local p = function(s) DEFAULT_CHAT_FRAME:AddMessage("[LIF] " .. s) end
      p(("--- last %d of %d log entries ---"):format(math.min(n, #entries), #entries))
      local start = math.max(1, #entries - n + 1)
      for i = start, #entries do
        local e = entries[i]
        p(e.t .. "  " .. e.msg)
      end
    elseif msg == "clearlog" then
      LIF.ClearLog()
      DEFAULT_CHAT_FRAME:AddMessage("[LIF] log cleared")
    elseif msg == "inspectlog" then
      local records = LIF.GetInspectRecords()
      local p = function(s) DEFAULT_CHAT_FRAME:AddMessage("[LIF] " .. s) end
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
      DEFAULT_CHAT_FRAME:AddMessage("[LIF] inspect records cleared")
    elseif msg == "heirloom on" or msg == "heirloom off" then
      local enabled = msg == "heirloom on"
      if LootItForward.db then LootItForward.db.char.skipHeirloomCheck = enabled end
      -- LIF.Log records to the session log buffer (reviewable via /lif log or the
      -- debug window) but is a silent no-op while debug mode is off — so give an
      -- explicit chat confirmation in that case instead.
      if LootItForward.db and LootItForward.db.char.debugMode then
        LIF.Log("heirloom check skip " .. (enabled and "on" or "off"))
      else
        DEFAULT_CHAT_FRAME:AddMessage("[LIF] heirloom check skip " .. (enabled and "on" or "off")
          .. " (no effect until debug mode is on)")
      end
    elseif msg == "resetpos" then
      if LootItForward.db then
        LootItForward.db.char.popupPosition = { x = 0, y = 400 }
      end
      if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
      DEFAULT_CHAT_FRAME:AddMessage("[LIF] popup position reset to default")
    elseif msg == "example" then
      if LIF.ShowExamplePopup then
        LIF.ShowExamplePopup()
      else
        DEFAULT_CHAT_FRAME:AddMessage("[LIF] ShowExamplePopup not loaded")
      end
    elseif msg == "" then
      local p = function(s) DEFAULT_CHAT_FRAME:AddMessage("[LIF] " .. s) end
      p("Commands:")
      p("  /lif settings   — open settings panel")
      p("  /lif example    — show example popup (drag to reposition)")
      p("  /lif resetpos   — reset popup to default position")
    end
  end
  SLASH_LOOTITFORWARD1 = "/lootitforward"
  SlashCmdList["LOOTITFORWARD"] = SlashCmdList["LIF"]
end

function LootItForward:OnEnable()
  LIF.Log("enabled")
  self:RegisterEvent("PLAYER_ENTERING_WORLD")
  self:RegisterEvent("GROUP_ROSTER_UPDATE")
  self:RegisterEvent("RAID_ROSTER_UPDATE")
  self:RegisterEvent("INSPECT_READY")
  self:RegisterEvent("PLAYER_REGEN_ENABLED")
  self:RegisterEvent("PLAYER_REGEN_DISABLED")
  self:RegisterEvent("UNIT_HEALTH")
  self:RegisterEvent("UNIT_CONNECTION")
  self:RegisterEvent("ENCOUNTER_LOOT_RECEIVED")
end

function LootItForward:OnDisable()
  LIF.Queue_StopAndReset()
  self:UnregisterAllEvents()
end

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
  local active = self:ShouldBeActive()
  LIF.Log("PLAYER_ENTERING_WORLD — active=" .. tostring(active))
  self._rosterActive = active
  if self.db and self.db.char.debugMode then LIF.ShowDebugWindow() end
  if active then
    LIF.OnGroupRosterUpdate()
  else
    LIF.Queue_StopAndReset()
    LIF.Cache.Clear()
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
    if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
    return
  end
  LIF.OnGroupRosterUpdate()
  -- Remove departed candidates from the popup (ui/popup.lua defines this;
  -- nil-guard in case popup.lua has not loaded yet).
  if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
end

function LootItForward:RAID_ROSTER_UPDATE()
  local active = self:ShouldBeActive()
  if not active then
    LIF.Queue_StopAndReset()
    LIF.Cache.Clear()
    if LIF.Popup_OnRosterUpdate then LIF.Popup_OnRosterUpdate() end
  end
end

function LootItForward:INSPECT_READY(_, guid)
  LIF.OnInspectReady(guid)
  LIF.OnLootInspectReady(guid)
end

function LootItForward:PLAYER_REGEN_DISABLED()
  LIF.Log("combat start")
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
  if isConnected then
    LIF.OnUnitMaybeScannable(unitToken)
  else
    LIF.OnUnitDisconnect(unitToken)
  end
end

function LootItForward:ENCOUNTER_LOOT_RECEIVED(_, encounterID, itemID, itemLink, _, playerName, _)
  if not LIF.IsLocalPlayerName(playerName) then return end
  if not LootItForward:ShouldBeActive() then return end
  LIF.Log("ENCOUNTER_LOOT_RECEIVED " .. tostring(itemLink) .. " enc=" .. tostring(encounterID))
  LIF.OnPlayerLootReceived(itemLink, itemID)
end
