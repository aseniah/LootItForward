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
  -- >= so trimming leaves room for the session header appended next (else the
  -- buffer overflows to LOG_MAX+1 and never recovers — AUD-314).
  while #logEntries >= LOG_MAX do table.remove(logEntries, 1) end
  table.insert(logEntries, { t = date("!%H:%M:%S"), msg = "=== SESSION " .. log.session .. " v" .. version .. " ===" })
  return log
end

-- Chat prefix for user-facing output: the spaced display name in gold. Used by
-- LIF.Print (command replies, notices) and the "info" log level below, so every
-- non-debug line the user sees carries one consistent, coloured prefix. The debug
-- stream keeps the short "[LIF]" tag.
LIF.CHAT_PREFIX = "|cffffff00[Loot It Forward]|r "

-- Ungated user-facing print (command replies, one-off notices). Always shown,
-- regardless of debugMode or showChatNotifications — a typed command must answer.
function LIF.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(LIF.CHAT_PREFIX .. msg)
end

-- level: "debug" (default) = only when debugMode on, recorded to buffer
--        "info"            = shown in chat unless showChatNotifications is false, never recorded
function LIF.Log(msg, level)
  if level == "info" then
    -- Nil-safe gate: if db is not yet initialized, show is true (Pitfall 3 failsafe).
    local show = not (LootItForward and LootItForward.db)
                 or LootItForward.db.profile.showChatNotifications
    if show then
      DEFAULT_CHAT_FRAME:AddMessage(LIF.CHAT_PREFIX .. msg)
    end
    return
  end
  if not (LootItForward and LootItForward.db and LootItForward.db.char.debugMode) then return end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[LIF]|r " .. msg)
  if logEntries then
    table.insert(logEntries, { t = date("!%H:%M:%S"), msg = msg })
    -- while (not if) so any excess is fully trimmed, matching RecordInspect and
    -- recovering a legacy oversized buffer in one insert (AUD-314).
    while #logEntries > LOG_MAX do table.remove(logEntries, 1) end
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

-- Marks a member COMPLETE and MERGES the given fields (does NOT replace): keys
-- absent from `data` keep their previous value. Callers refreshing a member must
-- therefore pass EVERY field — a nil-valued field is omitted from the table
-- literal (Lua drops nil keys), so its stale value would silently survive. See
-- AUD-013: the sole caller normalizes specID to 0 so a member who lost their spec
-- selection can never resurrect a previous specID and be wrongly evaluated.
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
