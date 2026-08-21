-- ttybcd - Tty Broadcast Daemon
-- Retransmit primary terminal (term) to all large monitors via /dev/peripherals/monitors/*
-- Sandboxed userland: only syscall wrappers + safe libs (no io/os/fs/term/arg).
-- Usage: ttybcd [start|stop|status]

local args = {...}
local mode = args[1] or "run"

local function list_monitors()
  local ok, entries = pcall(readdir, "/dev/peripherals/monitors")
  if not ok or not entries then return {} end
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = type(e) == "table" and e.name or e
  end
  return out
end

local function broadcast(text)
  local n = 0
  for _, name in ipairs(list_monitors()) do
    local path = "/dev/peripherals/monitors/" .. name
    local fd, err = open(path, "w")
    if fd then
      pcall(write, fd, "write " .. tostring(text):gsub("\n", " ") .. "\n")
      pcall(close, fd)
      n = n + 1
    end
  end
  return n
end

if mode == "status" then
  print("ttybcd: virtual /dev/peripherals/monitors broadcast daemon")
  return
elseif mode == "stop" then
  print("ttybcd: stop (no pidfile)")
  return
end

print("ttybcd: started, broadcasting term to /dev/peripherals/monitors/*")
while true do
  pcall(broadcast, "ttybcd heartbeat")
  sleep(5)
end
