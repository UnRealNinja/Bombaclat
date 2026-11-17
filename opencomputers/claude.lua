-- claude.lua - chat with Claude from an OpenComputers computer (GT: New Horizons)
-- Needs: OpenOS, an Internet Card, and your Anthropic API key saved in KEY_PATH.
-- Usage: claude          (type /reset to clear the conversation, /exit to quit)

local component = require("component")
local computer = require("computer")
local term = require("term")

------------------------------------------------------------------ settings
local MODEL    = "claude-opus-5-5"   -- e.g. "claude-haiku-5-5" is much cheaper
local KEY_PATH = "/home/.claude_key"
local URL      = "https://api.anthropic.com/v1/messages"
local TIMEOUT  = 180                  -- seconds to wait for a reply
local SYSTEM   = "You are chatting through an OpenComputers terminal inside the " ..
  "Minecraft modpack GregTech: New Horizons. The screen is small and shows plain " ..
  "text only: no Markdown, no tables, short lines. Keep answers concise."

------------------------------------------------------------------ checks
if not component.isAvailable("internet") then
  io.stderr:write("No Internet Card found. Install one in this computer.\n")
  return
end
local inet = component.internet
if not inet.isHttpEnabled() then
  io.stderr:write("HTTP is disabled in the server's OpenComputers config.\n")
  return
end

local f = io.open(KEY_PATH, "r")
if not f then
  io.stderr:write("Save your API key in " .. KEY_PATH .. " first (edit " .. KEY_PATH .. ").\n")
  return
end
local API_KEY = (f:read("*l") or ""):gsub("%s", "")
f:close()

------------------------------------------------------------------ JSON
local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encStr(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local encode
function encode(v)
  local t = type(v)
  if t == "string" then return encStr(v)
  elseif t == "number" or t == "boolean" then return tostring(v)
  elseif t == "nil" then return "null"
  elseif t == "table" then
    local out = {}
    if v[1] ~= nil then
      for i = 1, #v do out[i] = encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, val in pairs(v) do out[#out + 1] = encStr(tostring(k)) .. ":" .. encode(val) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end

local function utf8char(cp)
  local fl = math.floor
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + fl(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(0xE0 + fl(cp / 4096), 0x80 + fl(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + fl(cp / 262144), 0x80 + fl(cp / 4096) % 64,
                     0x80 + fl(cp / 64) % 64, 0x80 + cp % 64)
end

local unesc = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function skip(s, i) return s:find("[^ \t\r\n]", i) or (#s + 1) end

local function parseString(s, i)
  if s:sub(i, i) ~= '"' then error("JSON: expected string at " .. i) end
  local buf, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("JSON: unterminated string") end
    if c == '"' then return table.concat(buf), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
          local lo = tonumber(s:sub(j + 2, j + 5), 16)
          cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
          j = j + 6
        end
        buf[#buf + 1] = utf8char(cp)
      else
        buf[#buf + 1] = unesc[e] or e
        j = j + 2
      end
    else
      local k = s:find('["\\]', j) or (#s + 1)
      buf[#buf + 1] = s:sub(j, k - 1)
      j = k
    end
  end
end

local function parseValue(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local key
      key, i = parseString(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("JSON: expected ':' at " .. i) end
      obj[key], i = parseValue(s, i + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then error("JSON: expected ',' or '}' at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local arr, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = parseValue(s, i)
      n = n + 1
      arr[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then error("JSON: expected ',' or ']' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then return parseString(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not num then error("JSON: unexpected character at " .. i) end
  return tonumber(num), i + #num
end

local function decode(s) return (parseValue(s, 1)) end

------------------------------------------------------------------ HTTP
local function post(body)
  local headers = {
    ["content-type"] = "application/json",
    ["x-api-key"] = API_KEY,
    ["anthropic-version"] = "2026-10-21",
    ["anthropic-beta"] = "server-side-fallback-2026-07-01",
  }
  local h, err = inet.request(URL, body, headers)
  if not h then error("request failed: " .. tostring(err)) end
  local deadline = computer.uptime() + TIMEOUT
  while true do
    local ok, e = h.finishConnect()
    if ok then break end
    if ok == nil then error("could not connect: " .. tostring(e)) end
    if computer.uptime() > deadline then h.close(); error("timed out connecting") end
    os.sleep(0.1)
  end
  local chunks = {}
  while true do
    local data, e = h.read(math.huge)
    if data == nil then
      if e then h.close(); error("read error: " .. tostring(e)) end
      break
    elseif #data > 0 then
      chunks[#chunks + 1] = data
    else
      if computer.uptime() > deadline then h.close(); error("timed out waiting for reply") end
      os.sleep(0.05)
    end
  end
  local code = h.response()
  h.close()
  return code, table.concat(chunks)
end

------------------------------------------------------------------ chat
local messages = {}

local function ask(text)
  messages[#messages + 1] = { role = "user", content = text }
  local body = encode({
    model = MODEL,
    max_tokens = 4096,
    system = SYSTEM,
    output_config = { effort = "low" },
    fallbacks = "default",
    messages = messages,
  })
  local ok, code, raw = pcall(post, body)
  if not ok then
    table.remove(messages)
    return nil, tostring(code)
  end
  local dok, resp = pcall(decode, raw)
  if not dok or type(resp) ~= "table" then
    table.remove(messages)
    return nil, "bad reply (HTTP " .. tostring(code) .. "): " .. raw:sub(1, 200)
  end
  if resp.type == "error" then
    table.remove(messages)
    local e = resp.error or {}
    return nil, tostring(e.type) .. ": " .. tostring(e.message)
  end
  if resp.stop_reason == "refusal" then
    table.remove(messages)
    return nil, "Claude declined to answer that request."
  end

  -- Keep the assistant turn (thinking blocks included, unchanged) for context.
  local keep, out = {}, {}
  for _, b in ipairs(resp.content or {}) do
    if b.type == "text" then
      keep[#keep + 1] = { type = "text", text = b.text }
      out[#out + 1] = b.text
    elseif b.type == "thinking" then
      keep[#keep + 1] = { type = "thinking", thinking = b.thinking or "", signature = b.signature }
    elseif b.type == "redacted_thinking" then
      keep[#keep + 1] = { type = "redacted_thinking", data = b.data }
    end
  end
  if #keep > 0 then
    messages[#messages + 1] = { role = "assistant", content = keep }
  else
    table.remove(messages)
  end
  local reply = table.concat(out, "\n")
  if resp.stop_reason == "max_tokens" then reply = reply .. "\n[reply cut off]" end
  return reply
end

print("Claude chat (" .. MODEL .. "). /reset clears the chat, /exit quits.")
while true do
  io.write("\nYou> ")
  local line = io.read()
  if not line or line == "/exit" then break end
  if line == "/reset" then
    messages = {}
    print("(conversation cleared)")
  elseif line:match("%S") then
    io.write("Claude is thinking...")
    local reply, err = ask(line)
    term.clearLine()
    if reply then
      print("Claude> " .. reply)
    else
      print("[error] " .. err)
    end
  end
end
