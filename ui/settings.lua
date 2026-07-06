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

local function getSoundLabel(key)
  for _, opt in ipairs(SOUND_OPTIONS) do
    if opt.key == key then return opt.label end
  end
  return SOUND_OPTIONS[2].label
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
  local function addCheckbox(yTop, settingKey, labelText, descText)
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
    end)
    return chk
  end

  local chkOpenWorld = addCheckbox(-65,
    "enableOpenWorld",
    "Enable in open world groups",
    "When disabled, the addon is fully inactive outside of dungeons. Dungeon groups are always active.")

  local chkNotifs = addCheckbox(-113,
    "showChatNotifications",
    "Show chat notifications",
    "Show confirmation messages in chat when you whisper or trade a candidate.")

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
  end)

  local descParty = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  descParty:SetPoint("TOPLEFT", 12, -193)
  descParty:SetWidth(540)
  descParty:SetJustifyH("LEFT")
  descParty:SetText("Only show the popup when your group has at least this many members (including yourself).")

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
  hintMsg:SetText("Use {link} where the item link should appear. [Loot It Forward] is always prepended.")

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
  editbox:SetMaxLetters(500)
  editbox:SetScript("OnEscapePressed", EditBox_ClearFocus)

  local lblPreview = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  lblPreview:SetPoint("TOPLEFT", 12, -401)
  lblPreview:SetText("Whisper preview")

  local preview = canvas:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  preview:SetPoint("TOPLEFT", 12, -418)
  preview:SetWidth(540)
  preview:SetJustifyH("LEFT")

  local function updatePreview(t)
    preview:SetText("|cffaaaaaa[Loot It Forward]|r " .. t:gsub("{link}", LIF.EXAMPLE_ITEM_LINK))
  end

  editbox:SetScript("OnTextChanged", function(self)
    updatePreview(self:GetText())
  end)
  editbox:SetScript("OnEditFocusLost", function(self)
    LootItForward.db.profile.whisperMessage = self:GetText()
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
      LootItForward.db.char.popupPosition = { x = 0, y = 400 }
    end
    if LIF.Popup_RestorePosition then LIF.Popup_RestorePosition() end
  end)

  canvas:SetScript("OnHide", function()
    if editbox:HasFocus() then
      LootItForward.db.profile.whisperMessage = editbox:GetText()
    end
  end)

  canvas:SetScript("OnShow", function()
    local db = LootItForward.db.profile
    chkOpenWorld:SetChecked(db.enableOpenWorld)
    chkNotifs:SetChecked(db.showChatNotifications)
    slider.Slider:SetValue(db.minPartySize or 2)
    soundDropdown:OverrideText(getSoundLabel(db.popupSound or "ALARM_CLOCK_WARNING_1"))
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

  local db = LootItForward.db.profile
  Settings.RegisterAddOnSetting(category, "LootItForward_enableOpenWorld",        "enableOpenWorld",        db, type(true), "Enable in open world groups", true)
  Settings.RegisterAddOnSetting(category, "LootItForward_showChatNotifications",  "showChatNotifications",  db, type(true), "Show chat notifications",     true)
  Settings.RegisterAddOnSetting(category, "LootItForward_minPartySize",           "minPartySize",           db, type(0),    "Minimum party size",          2)
  Settings.RegisterAddOnSetting(category, "LootItForward_popupSound",             "popupSound",             db, type(""),   "Sound on popup",              "ALARM_CLOCK_WARNING_1")

  C_Item.RequestLoadItemDataByID(LIF.EXAMPLE_ITEM_ID)
end
