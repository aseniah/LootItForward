-- tests/test_whisper.lua
-- luaunit test suite for core/whisper.lua — the whisper composition chain.
-- Run: lua tests/test_whisper.lua  (from project root)
--
-- This chain is pure string logic and had shipped five confirmed bugs across four
-- audit rounds while being unreachable from any harness (AUD-506). Everything here
-- is a pure function: no frames, no send, no mocks beyond the module loader.

package.path = package.path .. ";./tests/?.lua;../?.lua;../tests/?.lua"

require("mock_wow_api")

local LIF = {}
local _coreDir = "core"
do
  local f = io.open("core/whisper.lua", "r")
  if f then f:close() else _coreDir = "../core" end
end
LoadAddonModules(LIF, _coreDir)

local lu = require("luaunit")

-- A realistic retail loot link: named-colour form, as the loot events actually deliver.
local REAL_LINK = "|cnIQ4:|Hitem:251126::::::::90:::::|h[Greathelm of Temptation]|h|r"
-- The legacy hex-colour form.
local HEX_LINK = "|cffa335ee|Hitem:251126::::::::90:::::|h[Greathelm of Temptation]|h|r"

TestWhisper = {}

-- ============================================================
-- RenderWhisperBody / RenderWhisperMessage
-- ============================================================

function TestWhisper:test_render_substitutes_link()
  local msg = LIF.RenderWhisperMessage("Want {link}?", "LINK")
  lu.assertEquals(msg, LIF.WHISPER_PREFIX .. "Want LINK?")
end

function TestWhisper:test_render_substitutes_every_occurrence()
  -- AUD-014: a multi-{link} template must be measured exactly, so EVERY
  -- occurrence substitutes — not just the first.
  local msg = LIF.RenderWhisperBody("{link} {link} {link}", "X")
  lu.assertEquals(msg, "X X X")
end

function TestWhisper:test_render_escapes_percent_in_link()
  -- AUD-304: % is magic in the gsub REPLACEMENT (%1..%9; a lone %x errors).
  -- A localized item name is outside our control, so it must survive verbatim.
  local msg = LIF.RenderWhisperBody("Take {link}!", "50% Off Blade")
  lu.assertEquals(msg, "Take 50% Off Blade!")
end

function TestWhisper:test_render_collapses_newlines_to_a_space()
  -- AUD-504: the settings editbox is SetMultiLine, so Enter inserts a literal newline
  -- into the stored template. A newline must never reach SendChatMessage.
  lu.assertEquals(LIF.RenderWhisperBody("Hey\nwant this?", nil), "Hey want this?")
  lu.assertEquals(LIF.RenderWhisperBody("a\r\n\r\nb", nil), "a b", "a run collapses to ONE space")
  lu.assertEquals(LIF.RenderWhisperBody("trailing\n", nil), "trailing ")
end

function TestWhisper:test_compose_never_emits_a_newline()
  local msg = LIF.ComposeWhisper("Hey,\n{link}\nwant it?", REAL_LINK, "Greathelm")
  lu.assertNil(msg:find("\n", 1, true), "no newline may reach SendChatMessage")
  lu.assertNil(msg:find("\r", 1, true), "no carriage return may reach SendChatMessage")
end

function TestWhisper:test_render_handles_nil_template_and_link()
  lu.assertEquals(LIF.RenderWhisperBody(nil, nil), "")
  lu.assertEquals(LIF.RenderWhisperBody("{link}", nil), "")
end

-- ============================================================
-- StripWoWEscapes
-- ============================================================

function TestWhisper:test_strip_reduces_hyperlink_to_display_text()
  lu.assertEquals(LIF.StripWoWEscapes(HEX_LINK), "[Greathelm of Temptation]")
end

function TestWhisper:test_strip_removes_the_named_colour_form()
  -- AUD-516: the modern named form |cnIQ4: is what this addon's own loot-event links
  -- carry. Only the legacy hex form was stripped, so a |cn run survived into the
  -- message with un-doubled pipes and the client rejected it.
  lu.assertEquals(LIF.StripWoWEscapes(REAL_LINK), "[Greathelm of Temptation]")
  lu.assertNil(LIF.StripWoWEscapes(REAL_LINK):find("|", 1, true),
    "no bare pipe may survive the strip")
end

function TestWhisper:test_strip_preserves_literal_pipe_escapes()
  -- AUD-407: "||" is already the correct wire form for a literal pipe. It must be
  -- protected from the strip patterns and restored, not consumed.
  lu.assertEquals(LIF.StripWoWEscapes("a || b"), "a || b")
end

function TestWhisper:test_strip_leaves_plain_text_untouched()
  lu.assertEquals(LIF.StripWoWEscapes("Hey, do you want this?"), "Hey, do you want this?")
end

-- ============================================================
-- TruncateWhisperBytes
-- ============================================================

function TestWhisper:test_truncate_leaves_short_message_untouched()
  lu.assertEquals(LIF.TruncateWhisperBytes("short"), "short")
end

function TestWhisper:test_truncate_at_exactly_max_bytes_is_untouched()
  local msg = string.rep("a", LIF.WHISPER_MAX_BYTES)
  lu.assertEquals(LIF.TruncateWhisperBytes(msg), msg)
  lu.assertEquals(#LIF.TruncateWhisperBytes(msg), LIF.WHISPER_MAX_BYTES)
end

function TestWhisper:test_truncate_cuts_ascii_to_max_bytes()
  local msg = string.rep("a", 300)
  lu.assertEquals(#LIF.TruncateWhisperBytes(msg), LIF.WHISPER_MAX_BYTES)
end

function TestWhisper:test_truncate_backs_up_off_a_utf8_continuation_byte()
  -- "é" is 2 bytes (0xC3 0xA9). Land the cut so byte 256 is the continuation byte:
  -- 254 ASCII + "é" puts the lead byte at 255 and the continuation at 256, so the
  -- naive cut would sever the character. WoW rejects malformed UTF-8.
  local msg = string.rep("a", 254) .. "\195\169" .. string.rep("b", 60)
  local out = LIF.TruncateWhisperBytes(msg)
  lu.assertEquals(#out, 254, "must back up past the lead byte, not split the character")
  lu.assertEquals(out, string.rep("a", 254))
end

function TestWhisper:test_truncate_never_ends_on_a_lone_pipe()
  -- AUD-503: "|" is ASCII (0x7C), so the UTF-8 back-up above never protects it. A cut
  -- landing between the two pipes of a "||" escape leaves a lone trailing "|", which
  -- the client rejects as an invalid escape code — the AUD-306 disconnect class.
  -- 254 filler + "||" puts the pair across the 255/256 boundary.
  local msg = string.rep("a", 254) .. "||" .. string.rep("b", 10)
  local out = LIF.TruncateWhisperBytes(msg)
  local trailingPipes = #out:match("|*$")
  lu.assertEquals(trailingPipes % 2, 0, "a truncated message must never end on an odd pipe run")
end

function TestWhisper:test_truncate_keeps_a_whole_pipe_escape_at_the_boundary()
  -- The complement: an intact "||" ending exactly at the cut must SURVIVE. Trimming
  -- unconditionally would corrupt a valid literal-pipe escape.
  local msg = string.rep("a", 253) .. "||" .. string.rep("b", 10)
  local out = LIF.TruncateWhisperBytes(msg)
  lu.assertEquals(#out, 255)
  lu.assertEquals(out:sub(-2), "||", "an intact escape at the boundary must survive")
end

-- ============================================================
-- CountTypedChars
-- ============================================================

function TestWhisper:test_count_counts_plain_ascii()
  lu.assertEquals(LIF.CountTypedChars("hello"), 5)
end

function TestWhisper:test_count_collapses_escaped_pipes_to_one_typed_char()
  -- GetText() returns "||" for a single typed "|". The counter tracks what the user
  -- typed, so a template of three typed pipes counts as 3, not 6.
  lu.assertEquals(LIF.CountTypedChars("||||||"), 3)
end

function TestWhisper:test_count_counts_multibyte_char_once()
  lu.assertEquals(LIF.CountTypedChars("\195\169"), 1)  -- "é"
end

function TestWhisper:test_count_handles_nil()
  lu.assertEquals(LIF.CountTypedChars(nil), 0)
end

-- ============================================================
-- TruncateTypedChars — the settings editbox's real cap (AUD-517)
-- ============================================================

function TestWhisper:test_typed_truncate_leaves_a_short_template_untouched()
  lu.assertEquals(LIF.TruncateTypedChars("hello", 100), "hello")
end

function TestWhisper:test_typed_truncate_at_the_cap_is_untouched()
  lu.assertEquals(LIF.TruncateTypedChars("hello", 5), "hello")
end

function TestWhisper:test_typed_truncate_cuts_ascii_to_the_cap()
  lu.assertEquals(LIF.TruncateTypedChars("hello world", 5), "hello")
end

function TestWhisper:test_typed_truncate_never_splits_a_pipe_escape()
  -- "||||" is two typed pipes. A cap of 1 must yield ONE whole escape, never a lone
  -- "|" — which would be an invalid escape code the moment it reached SendChatMessage.
  local out = LIF.TruncateTypedChars("||||", 1)
  lu.assertEquals(out, "||")
  lu.assertEquals(LIF.CountTypedChars(out), 1)
end

function TestWhisper:test_typed_truncate_counts_an_escaped_pipe_as_one_char()
  -- "a||b" is 3 typed chars, so a cap of 3 keeps all of it and a cap of 2 stops
  -- after the pipe.
  lu.assertEquals(LIF.TruncateTypedChars("a||b", 3), "a||b")
  lu.assertEquals(LIF.TruncateTypedChars("a||b", 2), "a||")
end

function TestWhisper:test_typed_truncate_never_splits_a_multibyte_char()
  -- Three "é" (2 bytes each). A cap of 2 must cut on a codepoint boundary — a cut
  -- between an é's two bytes is malformed UTF-8 and WoW rejects it.
  local out = LIF.TruncateTypedChars("\195\169\195\169\195\169", 2)
  lu.assertEquals(out, "\195\169\195\169")
  lu.assertEquals(LIF.CountTypedChars(out), 2)
end

function TestWhisper:test_typed_truncate_result_always_satisfies_the_counter()
  -- The cap and the displayed counter must agree, since the counter is what tells the
  -- user how much room is left.
  local samples = {
    "plain text",
    "pipes || everywhere || here",
    "caf\195\169 \195\169\195\169\195\169",
    string.rep("|| ", 60),
    string.rep("x", 300),
  }
  for _, s in ipairs(samples) do
    local out = LIF.TruncateTypedChars(s, LIF.WHISPER_MAX_TEMPLATE_CHARS)
    lu.assertTrue(LIF.CountTypedChars(out) <= LIF.WHISPER_MAX_TEMPLATE_CHARS,
      ("truncated %q still counts over the cap"):format(s:sub(1, 20)))
  end
end

function TestWhisper:test_typed_truncate_handles_nil()
  lu.assertEquals(LIF.TruncateTypedChars(nil, 10), "")
end

-- ============================================================
-- ComposeWhisper — the whole send-path decision
-- ============================================================

function TestWhisper:test_compose_keeps_the_full_link_when_it_fits()
  local msg, degraded = LIF.ComposeWhisper("Want {link}?", REAL_LINK, "Greathelm of Temptation")
  lu.assertFalse(degraded, "a message that fits must not degrade")
  -- plain find: the link's "[...]" is a character class to a pattern matcher.
  lu.assertNotNil(msg:find(REAL_LINK, 1, true), "the full item link must survive verbatim")
  lu.assertTrue(#msg <= LIF.WHISPER_MAX_BYTES)
end

function TestWhisper:test_compose_degrades_to_item_name_when_over_the_byte_cap()
  -- A multi-{link} template renders past 255 bytes with real links (reproduced live
  -- 2026-07-11 at ~299 bytes). The degrade path swaps in the plain NAME and strips
  -- markup, because a cut through a link escape throws "Invalid escape code".
  local template = "{link} {link} {link} {link}"
  lu.assertTrue(#LIF.RenderWhisperMessage(template, REAL_LINK) > LIF.WHISPER_MAX_BYTES,
    "setup: the undegraded render must exceed the byte cap")

  local msg, degraded = LIF.ComposeWhisper(template, REAL_LINK, "Greathelm of Temptation")
  lu.assertTrue(degraded, "an over-length message must degrade")
  lu.assertTrue(#msg <= LIF.WHISPER_MAX_BYTES, "the degraded message must fit the byte cap")
  lu.assertNotNil(msg:find("Greathelm of Temptation", 1, true), "the item name must survive the degrade")
  lu.assertNil(msg:find("|H", 1, true), "no hyperlink escape may survive into the sent message")
end

function TestWhisper:test_compose_never_exceeds_the_byte_cap()
  local msg = LIF.ComposeWhisper(string.rep("{link} ", 8), REAL_LINK, "A Very Long Item Name Indeed")
  lu.assertTrue(#msg <= LIF.WHISPER_MAX_BYTES, "got " .. #msg .. " bytes")
end

os.exit(lu.LuaUnit.run())
