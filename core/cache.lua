local _, LIF = ...

-- Circular debug log — initialized by LIF.InitLog() from OnInitialize.
-- logEntries points into LootItForwardLog.entries (the SavedVariable table).
-- Writes before InitLog is called go to chat only.
local logEntries = nil
local inspectRecords = nil  -- separate persistent table, never cleared by ClearLog
local LOG_MAX = 500
local INSPECT_MAX = 200

function LIF.InitLog(savedVar, version)
  local log = savedVar or {}
  log.version = version
  log.session = (log.session or 0) + 1
  log.entries = log.entries or {}
  log.inspectRecords = log.inspectRecords or {}
  logEntries = log.entries
  inspectRecords = log.inspectRecords
  while #logEntries > LOG_MAX do table.remove(logEntries, 1) end
  table.insert(logEntries, { t = date("!%H:%M:%S"), msg = "=== SESSION " .. log.session .. " v" .. version .. " ===" })
  return log
end

-- level: "debug" (default) = only when debugMode on, recorded to buffer
--        "info"            = shown in chat unless showChatNotifications is false, never recorded
function LIF.Log(msg, level)
  if level == "info" then
    -- Nil-safe gate: if db is not yet initialized, show is true (Pitfall 3 failsafe).
    local show = not (LootItForward and LootItForward.db)
                 or LootItForward.db.profile.showChatNotifications
    if show then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[Loot It Forward]|r " .. msg)
    end
    return
  end
  if not (LootItForward and LootItForward.db and LootItForward.db.char.debugMode) then return end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[LIF]|r " .. msg)
  if logEntries then
    table.insert(logEntries, { t = date("!%H:%M:%S"), msg = msg })
    if #logEntries > LOG_MAX then table.remove(logEntries, 1) end
  end
end

function LIF.GetLog()
  return logEntries or {}
end

function LIF.ClearLog()
  if not logEntries then return end
  for i = #logEntries, 1, -1 do logEntries[i] = nil end
end

function LIF.RecordInspect(record)
  if not inspectRecords then return end
  table.insert(inspectRecords, record)
  while #inspectRecords > INSPECT_MAX do table.remove(inspectRecords, 1) end
end

function LIF.GetInspectRecords()
  return inspectRecords or {}
end

function LIF.ClearInspectRecords()
  if not inspectRecords then return end
  for i = #inspectRecords, 1, -1 do inspectRecords[i] = nil end
end

LIF.Cache = {}

local cache = {}

function LIF.Cache.Add(guid)
  if not cache[guid] then
    cache[guid] = { guid = guid, state = "PENDING" }
  end
end

function LIF.Cache.Remove(guid)
  cache[guid] = nil
end

function LIF.Cache.SetComplete(guid, data)
  if cache[guid] then
    cache[guid].state = "COMPLETE"
    if data then
      for k, v in pairs(data) do cache[guid][k] = v end
    end
  end
end

function LIF.Cache.GetMember(guid)
  return cache[guid]
end

function LIF.Cache.GetAll()
  return cache
end

function LIF.Cache.Clear()
  cache = {}
end
