local _, LIF = ...

-- Example item link/ID shared from ui/popup.lua (REV-017; popup loads first).

local SOUND_OPTIONS = {
  { key = "NONE",                              label = "None / Disabled" },
  { key = "ALARM_CLOCK_WARNING_1",             label = "Alarm Clock (1)" },
  { key = "ALARM_CLOCK_WARNING_2",             label = "Alarm Clock (2)" },
  { key = "ALARM_CLOCK_WARNING_3",             label = "Alarm Clock (3)" },
  { key = "PVP_THROUGH_QUEUE",                 label = "Queue Ready" },
  { key = "UI_LEGENDARY_LOOT_TOAST",           label = "Legendary Loot Toast" },
  { key = "GM_CHAT_WARNING",                   label = "GM Chat Warning" },
  { key = "UI_EVENT_SCHEDULER_CHIME",          label = "Event Chime" },
  { key = "UI_DIG_SITE_COMPLETION_TOAST",      label = "Archaeology Toast" },
  { key = "LFG_REWARDS",                       label = "LFG Rewards" },
  { key = "UI_GARRISON_TOAST_INVASION_ALERT",  label = "Invasion Alert" },
  { key = "UI_70_CHALLENGE_MODE_NEW_RECORD",   label = "M+ New Record" },
}

-- Forced default when no valid sound is saved. Named (not the fragile positional
-- SOUND_OPTIONS[3]) so a future reorder of the list can't change what "default"
-- means. Exported as LIF.DEFAULT_SOUND_KEY (settings.lua loads before the entry file
-- per TOC) so the AceDB default (LootItForward.lua), the coercion below, and the
-- Settings registration all share this one source and can't drift (AUD-016/AUD-409).
local DEFAULT_SOUND_KEY = "ALARM_CLOCK_WARNING_2"
LIF.DEFAULT_SOUND_KEY = DEFAULT_SOUND_KEY

local function _labelForKey(key)
  for _, opt in ipairs(SOUND_OPTIONS) do
    if opt.key == key then return opt.label end
  end
  return nil
end

local function getSoundLabel(key)
  return _labelForKey(key) or _labelForKey(DEFAULT_SOUND_KEY)
end

local function buildCanvas()
  local canvas = CreateFrame("Frame")

  -- Title
  local title = canvas:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
  title:SetPoint("TOPLEFT", 7, -22)
  title:SetJustifyH("LEFT")
  title:SetText("Loot It Forward")

  local titleDivider = canvas:CreateTexture(nil, "ARTWORK")
  titleDivider:SetPoint("TOPLEFT", 0, -50)
  titleDivider:SetAtlas("Options_HorizontalDivider", true)

  -- Checkbox helper; yTop is relative to canvas top (after header)
  local function addCheckbox(yTop, settingKey, labelText, descText, onChanged)
    local chk = CreateFrame("CheckButton", nil, canvas, "SettingsCheckBoxTemplate")
    chk:SetPoint("TOPLEFT", 5, yTop)
    chk:SetSize(21, 20)
    chk.HoverBackground = nil

    local lbl = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
    lbl:SetText(labelText)
    chk:SetHitRectInsets(0, -lbl:GetStringWidth(), 0, 0)

    local desc = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", 30, yTop - 22)
    desc:SetWidth(540)
    desc:SetJustifyH("LEFT")
    desc:SetText(descText)

    chk:SetScript("OnClick", function(self)
      LootItForward.db.profile[settingKey] = self:GetChecked()
      if onChanged then onChanged() end
    end)
    return chk
  end

  local chkOpenWorld = addCheckbox(-65,
    "enableOpenWorld",
    "Enable in open world groups",
    "When disabled, the addon is fully inactive outside of dungeons. Dungeon groups are always active.",
    -- Re-evaluate active state now (AUD-322, sibling of AUD-009): toggling
    -- open-world eligibility while grouped in the open world must flip the
    -- addon active/inactive immediately, not wait for the next roster tick.
    function()
      if LootItForward.GROUP_ROSTER_UPDATE then LootItForward:GROUP_ROSTER_UPDATE() end
    end)

  local chkNotifs = addCheckbox(-113,
    "showChatNotifications",
    "Show chat notifications",
    "Show Loot It Forward messages in chat (loot-drop scans, plus whisper and trade confirmations).")

  -- Minimum party size
  local lblParty = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lblParty:SetPoint("TOPLEFT", 12, -172)
  lblParty:SetText("Minimum party size")

  local right = MinimalSliderWithSteppersMixin.Label.Right
  local sliderFormatters = { [right] = CreateMinimalSliderFormatter(right, function(v)
    return tostring(math.floor(v + 0.5))
  end) }
  local slider = CreateFrame("Slider", nil, canvas, "MinimalSliderWithSteppersTemplate")
  slider:SetPoint("TOPLEFT", 195, -161)
  slider:SetWidth(200)
  slider:Init(2, 2, 5, 3, sliderFormatters)

  -- HookScript so the template's internal RightText update still fires
  slider.Slider:HookScript("OnValueChanged", function(_, v)
    LootItForward.db.profile.minPartySize = math.floor(v + 0.5)
    -- Re-evaluate active state now (AUD-009): raising the threshold past the current
    -- group size disables the addon immediately, lowering it re-enables — without
    -- waiting for the next roster tick. GROUP_ROSTER_UPDATE runs the right branch.
    if LootItForward.GROUP_ROSTER_UPDATE then LootItForward:GROUP_ROSTER_UPDATE() end
  end)

  local descParty = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  descParty:SetPoint("TOPLEFT", 12, -193)
  descParty:SetWidth(540)
  descParty:SetJustifyH("LEFT")
  descParty:SetText("Loot It Forward is inactive when your group is smaller than this (including yourself) — no new scans, chat messages, or popups.")

  -- Sound on popup
  local lblSound = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lblSound:SetPoint("TOPLEFT", 12, -224)
  lblSound:SetText("Sound on popup")

  local previewBtn = CreateFrame("Button", nil, canvas)
  previewBtn:SetPoint("TOPLEFT", 195, -218)
  previewBtn:SetSize(22, 22)
  local speakerIcon = previewBtn:CreateTexture(nil, "ARTWORK")
  speakerIcon:SetAllPoints()
  speakerIcon:SetTexture("Interface\\Common\\VoiceChat-Speaker")
  speakerIcon:SetVertexColor(0.7, 0.7, 0.7)
  previewBtn:SetScript("OnEnter", function()
    speakerIcon:SetVertexColor(1, 1, 1)
    GameTooltip:SetOwner(previewBtn, "ANCHOR_TOP")
    -- r/g/b/wrapText are optional in the real API; the LuaLS signature marks them required.
    ---@diagnostic disable-next-line: missing-parameter
    GameTooltip:SetText("Preview sound")
    GameTooltip:Show()
  end)
  previewBtn:SetScript("OnLeave", function()
    speakerIcon:SetVertexColor(0.7, 0.7, 0.7)
    GameTooltip:Hide()
  end)
  previewBtn:SetScript("OnClick", function()
    local key = LootItForward.db.profile.popupSound
    if key and key ~= "NONE" and SOUNDKIT[key] ~= nil then
      PlaySound(SOUNDKIT[key], "Master")
    end
  end)

  local soundDropdown = CreateFrame("DropdownButton", nil, canvas, "WowStyle1DropdownTemplate")
  soundDropdown:SetPoint("LEFT", previewBtn, "RIGHT", 6, 0)
  soundDropdown:SetWidth(220)
  soundDropdown:SetupMenu(function(_, rootDescription)
    for _, opt in ipairs(SOUND_OPTIONS) do
      rootDescription:CreateRadio(opt.label,
        function(k) return LootItForward.db.profile.popupSound == k end,
        function(k)
          LootItForward.db.profile.popupSound = k
          soundDropdown:OverrideText(getSoundLabel(k))
        end,
        opt.key)
    end
  end)

  local descSound = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  descSound:SetPoint("TOPLEFT", 12, -245)
  descSound:SetWidth(540)
  descSound:SetJustifyH("LEFT")
  descSound:SetText("Plays when a popup appears. Click the speaker to preview.")

  -- Divider
  local divider1 = canvas:CreateTexture(nil, "ARTWORK")
  divider1:SetPoint("TOPLEFT", 0, -268)
  divider1:SetAtlas("Options_HorizontalDivider", true)

  -- Whisper section
  local lblMsg = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lblMsg:SetPoint("TOPLEFT", 12, -287)
  lblMsg:SetText("Whisper message template")

  local hintMsg = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hintMsg:SetPoint("TOPLEFT", 12, -304)
  hintMsg:SetWidth(540)
  hintMsg:SetJustifyH("LEFT")
  hintMsg:SetText(string.format(
    "Use {link} where the item link should appear. %sis always prepended. Max %d characters.",
    LIF.WHISPER_PREFIX, LIF.WHISPER_MAX_TEMPLATE_CHARS))

  local bgEdit = canvas:CreateTexture(nil, "BACKGROUND")
  bgEdit:SetPoint("TOPLEFT", 8, -325)
  bgEdit:SetSize(504, 64)
  bgEdit:SetColorTexture(0, 0, 0, 0.3)

  local editbox = CreateFrame("EditBox", nil, canvas)
  editbox:SetPoint("TOPLEFT", 12, -329)
  editbox:SetSize(496, 56)
  editbox:SetMultiLine(true)
  editbox:SetAutoFocus(false)
  editbox:SetFontObject("ChatFontNormal")
  -- Cap typed chars (AUD-014; WHISPER_MAX_TEMPLATE_CHARS): {link} counts as its 6
  -- literal chars; the send-time backstop in popup.lua handles the real rendered
  -- length against the 255-byte cap.
  editbox:SetMaxLetters(LIF.WHISPER_MAX_TEMPLATE_CHARS)
  editbox:SetScript("OnEscapePressed", EditBox_ClearFocus)

  -- Live length counter under the box: typed chars plus an estimate of the full sent
  -- byte length (prefix + rendered {link}), using the example link the preview uses.
  -- Turns red past 255 (AUD-014). Real drop links can be longer than the example, so
  -- this is an approximation — the popup send path degrades to the item name if the
  -- real message would overflow.
  local counter = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  counter:SetPoint("TOPLEFT", 12, -389)
  counter:SetWidth(496)
  counter:SetJustifyH("LEFT")

  local lblPreview = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lblPreview:SetPoint("TOPLEFT", 12, -401)
  lblPreview:SetText("Whisper preview")

  local preview = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  preview:SetPoint("TOPLEFT", 12, -418)
  preview:SetWidth(540)
  preview:SetJustifyH("LEFT")

  local maxBytes = LIF.WHISPER_MAX_BYTES
  local function updatePreview(t)
    t = t or ""
    -- Build from the shared prefix so the preview never drifts from what is actually
    -- sent (AUD-318). WHISPER_PREFIX carries its trailing space, so it sits inside the
    -- grey color span — cosmetically identical.
    preview:SetText("|cffaaaaaa" .. LIF.WHISPER_PREFIX .. "|r" .. t:gsub("{link}", LIF.EXAMPLE_ITEM_LINK))
    -- Count CODEPOINTS, not bytes, to match SetMaxLetters (which caps characters):
    -- every non-continuation byte (outside 0x80-0xBF) begins one codepoint.
    -- GetText() escapes each typed "|" as "||", so collapse those first or the count
    -- runs ahead of the cap the user is actually typing against. The byte estimate
    -- below deliberately keeps the escaped form — that IS what gets sent.
    local displayed = t:gsub("||", "|")
    local typed = select(2, displayed:gsub("[^\128-\191]", ""))
    local sent = #LIF.RenderWhisperMessage(t, LIF.EXAMPLE_ITEM_LINK)
    local sentColor = (sent > maxBytes) and "ffff4040" or "ff808080"
    counter:SetText(string.format("%d / %d typed   |c%s~%d / %d when sent|r",
      typed, LIF.WHISPER_MAX_TEMPLATE_CHARS, sentColor, sent, maxBytes))
  end

  editbox:SetScript("OnTextChanged", function(self)
    updatePreview(self:GetText())
  end)
  editbox:SetScript("OnEditFocusLost", function(self)
    -- Trim so a whitespace-only template persists as "" and hits the empty-template
    -- gate in popup.lua (which disables the Whisper buttons); otherwise a one-space
    -- entry would send a useless prefix-only whisper (AUD-319).
    LootItForward.db.profile.whisperMessage = strtrim(self:GetText())
    -- Reflect an emptied/refilled template on any open popup's Whisper buttons.
    if LIF.Popup_RefreshWhisperButtons then LIF.Popup_RefreshWhisperButtons() end
  end)

  -- Divider
  local divider2 = canvas:CreateTexture(nil, "ARTWORK")
  divider2:SetPoint("TOPLEFT", 0, -463)
  divider2:SetAtlas("Options_HorizontalDivider", true)

  -- Popup section
  local descPopup = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  descPopup:SetPoint("TOPLEFT", 12, -483)
  descPopup:SetWidth(540)
  descPopup:SetJustifyH("LEFT")
  descPopup:SetText("Click 'Show Example' to drag the popup into position, then close it to save.")

  local btnExample = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
  btnExample:SetPoint("TOPLEFT", 12, -505)
  btnExample:SetSize(160, 22)
  btnExample:SetText("Show Example Popup")
  btnExample:SetScript("OnClick", function()
    if LIF.ShowExamplePopup then LIF.ShowExamplePopup() end
  end)

  local btnReset = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
  btnReset:SetPoint("LEFT", btnExample, "RIGHT", 8, 0)
  btnReset:SetSize(140, 22)
  btnReset:SetText("Reset Position")
  btnReset:SetScript("OnClick", function()
    if LootItForward.db then
      LootItForward.db.char.popupPosition = nil
    end
    if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
  end)

  canvas:SetScript("OnHide", function()
    if editbox:HasFocus() then
      LootItForward.db.profile.whisperMessage = strtrim(editbox:GetText())  -- AUD-319 (see OnEditFocusLost)
      if LIF.Popup_RefreshWhisperButtons then LIF.Popup_RefreshWhisperButtons() end
    end
  end)

  canvas:SetScript("OnShow", function()
    -- Deref .profile live on every show, not once at build time, so an AceDB profile
    -- swap can't leave the panel bound to an orphaned table (AUD-325).
    local db = LootItForward.db and LootItForward.db.profile
    if not db then return end
    -- Coerce a stale/unknown saved sound key (e.g. a pre-M9 key no longer in the
    -- list) to the default, so the dropdown label matches the sound that actually
    -- plays instead of self-healing only when the user re-picks (AUD-016). "NONE"
    -- is a valid key and is preserved.
    if not _labelForKey(db.popupSound) then
      db.popupSound = DEFAULT_SOUND_KEY
    end
    chkOpenWorld:SetChecked(db.enableOpenWorld)
    chkNotifs:SetChecked(db.showChatNotifications)
    slider.Slider:SetValue(db.minPartySize or 2)
    soundDropdown:OverrideText(getSoundLabel(db.popupSound))
    local t = db.whisperMessage or ""
    editbox:SetText(t)
    updatePreview(t)
  end)

  return canvas
end

function LIF.InitSettings()
  local canvas = buildCanvas()
  local category = Settings.RegisterCanvasLayoutCategory(canvas, "Loot It Forward")
  Settings.RegisterAddOnCategory(category)
  LIF._settingsCategoryID = category:GetID()

  -- Captured once and handed to the registry (AUD-325). This assumes the profile
  -- table is never swapped: AceDB profile switching replaces LootItForward.db.profile,
  -- which would leave these bindings reading the orphaned old table. Safe today — the
  -- addon ships no profile UI and the canvas widgets deref .profile live — but if
  -- profiles ever land, re-derive these on an OnProfileChanged callback.
  local db = LootItForward.db.profile
  Settings.RegisterAddOnSetting(category, "LootItForward_enableOpenWorld",        "enableOpenWorld",        db, type(true), "Enable in open world groups", true)
  Settings.RegisterAddOnSetting(category, "LootItForward_showChatNotifications",  "showChatNotifications",  db, type(true), "Show chat notifications",     true)
  Settings.RegisterAddOnSetting(category, "LootItForward_minPartySize",           "minPartySize",           db, type(0),    "Minimum party size",          2)
  Settings.RegisterAddOnSetting(category, "LootItForward_popupSound",             "popupSound",             db, type(""),   "Sound on popup",              DEFAULT_SOUND_KEY)

  C_Item.RequestLoadItemDataByID(LIF.EXAMPLE_ITEM_ID)
end
