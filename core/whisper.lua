local _, LIF = ...

-- ============================================================
-- Whisper composition — pure string logic, no frames, no send.
--
-- Lives in core/ (not ui/) so the test harness can reach it: every step here is
-- pure, and the chain has historically been the addon's most bug-prone surface
-- (AUD-506). ui/popup.lua sends what ComposeWhisper returns; ui/settings.lua
-- renders its preview and counts its editbox with the same primitives, so the
-- preview can never drift from what is actually sent (AUD-318).
-- ============================================================

-- Prepended to every outgoing whisper (AUD-014). Counts toward the 255-byte
-- SendChatMessage limit. Carries its own trailing space.
LIF.WHISPER_PREFIX = "[Loot It Forward] "
LIF.WHISPER_MAX_BYTES = 255
-- Max characters the settings whisper-template editbox accepts. Shared by the
-- settings hint, SetMaxLetters, and the length counter (AUD-318).
LIF.WHISPER_MAX_TEMPLATE_CHARS = 100
-- Single source of truth (AUD-408) for the AceDB `defaults` table in
-- LootItForward.lua and the send-time fallback in ui/popup.lua.
LIF.DEFAULT_WHISPER_TEMPLATE = "Hey, {link} dropped for me and I don't need it. Do you want it?"

-- Substitute every {link} occurrence, WITHOUT the prefix. gsub replaces all
-- occurrences, so a multi-{link} template is measured exactly (AUD-014).
-- % is magic in the REPLACEMENT (%1..%9; a lone %x errors) and a localized item
-- name/link is outside our control — the over-length degrade path feeds the raw
-- name in by design — so escape % before substituting (AUD-304). Assign to a
-- local first: inlining the :gsub would pass its match COUNT as the outer gsub's
-- n argument and cap replacements.
--
-- A whisper is a single line, but the settings editbox is SetMultiLine, so a stored
-- template can contain newlines. Collapse them here rather than at the send site so
-- the settings preview shows exactly what will be sent (AUD-504).
function LIF.RenderWhisperBody(template, link)
  local replacement = (link or ""):gsub("%%", "%%%%")
  local body = string.gsub(template or "", "{link}", replacement)
  return (body:gsub("[\r\n]+", " "))
end

-- The full outgoing message: prefix + substituted body.
function LIF.RenderWhisperMessage(template, link)
  return LIF.WHISPER_PREFIX .. LIF.RenderWhisperBody(template, link)
end

-- Reduce WoW color/hyperlink/texture markup to plain text. Used on the degrade
-- path so a byte-truncated message can never end mid-escape (AUD-306): |H..|h /
-- |c..|r sequences are pure ASCII, so the UTF-8 boundary back-up doesn't protect
-- them, and a cut inside one throws "Invalid escape code". Reducing to plain text
-- BEFORE the cut makes truncation safe at any byte. A literal-pipe escape "||" is
-- protected first (swapped to \1) so the strip patterns can't match at its second
-- pipe and mangle a following escape-shaped run into a stray "|" (AUD-407), then
-- restored — "||" is already the correct form to send.
function LIF.StripWoWEscapes(s)
  s = s:gsub("||", "\1")                 -- protect literal-pipe escapes
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")   -- color open, hex form (|cAARRGGBB)
  s = s:gsub("|cn.-:", "")               -- color open, named form (|cnIQ4:) — what loot links use
  s = s:gsub("|H.-|h(.-)|h", "%1")       -- hyperlink -> its display text
  s = s:gsub("|T.-|t", "")               -- inline texture
  s = s:gsub("|A.-|a", "")               -- inline atlas
  s = s:gsub("|[rhta]", "")              -- stray color/link/texture/atlas closers
  s = s:gsub("\1", "||")                 -- restore literal-pipe escapes
  return s
end

-- Cut to WHISPER_MAX_BYTES on a UTF-8 character boundary, never mid-sequence:
-- SetMaxLetters caps CHARACTERS not bytes, and non-ASCII templates / localized
-- item names can still overflow. WoW rejects malformed UTF-8. If the byte just
-- past the cut is a continuation byte (0x80-0xBF) the cut is mid-character, so
-- back it up to the preceding lead byte.
-- Pipes get a second pass: "|" is ASCII (0x7C), so the UTF-8 back-up above cannot
-- protect a "||" escape whose two bytes straddle the cut, and a message ending on a
-- lone "|" is an invalid escape code — the class AUD-306 exists to prevent. Every pipe
-- run in a stripped message is even, so an ODD trailing run means the cut split a pair
-- (AUD-503). Trim one. Cutting the \1-protected form instead would undercount bytes
-- (each "||" counts as 1) and could end up over the cap after restore.
function LIF.TruncateWhisperBytes(msg)
  if #msg <= LIF.WHISPER_MAX_BYTES then return msg end
  local cut = LIF.WHISPER_MAX_BYTES
  while cut > 0 do
    local b = msg:byte(cut + 1)
    if b and b >= 0x80 and b <= 0xBF then cut = cut - 1 else break end
  end
  msg = msg:sub(1, cut)
  if #msg:match("|*$") % 2 == 1 then
    msg = msg:sub(1, #msg - 1)
  end
  return msg
end

-- Count the characters the user actually TYPED. Count codepoints, not bytes: every
-- non-continuation byte (outside 0x80-0xBF) begins one. GetText() escapes each typed
-- "|" as "||", so collapse those first or the count runs ahead of what was typed.
function LIF.CountTypedChars(text)
  local displayed = (text or ""):gsub("||", "|")
  return select(2, displayed:gsub("[^\128-\191]", ""))
end

-- Cut `text` (the editbox's escaped form) to at most maxChars TYPED characters.
--
-- This is what actually enforces the template cap (AUD-517). SetMaxLetters is left as a
-- loose backstop because it is not documented whether it counts the typed form or the
-- escaped one — and if it counts the escaped form, a pipe-carrying template would stop
-- accepting input before the displayed counter ever reached the cap. Enforcing the rule
-- here makes our count the single source of truth, so the counter and the box always
-- agree no matter how the client counts.
--
-- Walks codepoints, treating "||" as the ONE pipe the user typed, so a cut can never
-- land between the two halves of an escape.
function LIF.TruncateTypedChars(text, maxChars)
  text = text or ""
  local out, typed, i = {}, 0, 1
  local n = #text
  while i <= n and typed < maxChars do
    local b = text:byte(i)
    local len = 1
    if b == 0x7C and text:byte(i + 1) == 0x7C then
      len = 2                      -- "||" — one typed pipe, two stored characters
    elseif b >= 0xF0 then len = 4  -- UTF-8 lead bytes
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2
    end
    out[#out + 1] = text:sub(i, i + len - 1)
    i = i + len
    typed = typed + 1
  end
  return table.concat(out)
end

-- The whole send-path decision, in one place.
-- Returns (message, degraded). The full item link is used when it fits; otherwise
-- the message is rebuilt from the plain item NAME and stripped of markup (a cut
-- through a link escape throws "Invalid escape code" and can disconnect — AUD-014),
-- then truncated on a safe boundary.
function LIF.ComposeWhisper(template, link, itemName)
  local msg = LIF.RenderWhisperMessage(template, link)
  if #msg <= LIF.WHISPER_MAX_BYTES then return msg, false end
  msg = LIF.StripWoWEscapes(LIF.RenderWhisperMessage(template, itemName or link))
  return LIF.TruncateWhisperBytes(msg), true
end
