--[[
  PineconeOS init (pid 1)
  =======================
  Parses /boot/init.rc, spawns each declared service, then reaps children
  forever (waitpid loop) so zombies never accumulate.

  init.rc format (one directive per line, '#' comments):
    service <name> <path> [args...]

  The kernel spawns this as pid 1 (default /knuck/sbin/init.lua, overridable
  via `init <path>` in /boot/knuck.conf).
]]

local function read_all(path)
  local f = open(path, "r")
  if not f then return nil end
  local data = read(f, 65536)
  close(f)
  return data
end

local function log(msg)
  print("[init] " .. msg)
end

-- ---- parse /boot/init.rc ----
local services = {}
local rc = read_all("/boot/init.rc")
if rc then
  for line in (rc .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local cmd, rest = line:match("^(%S+)%s+(.+)$")
      if cmd == "service" and rest then
        local name, path = rest:match("^(%S+)%s+(%S+)")
        if name and path then
          local args = {}
          for a in (rest:gsub("^%S+%s+%S+", "")):gmatch("%S+") do
            args[#args + 1] = a
          end
          services[#services + 1] = { name = name, path = path, args = args }
        end
      end
    end
  end
else
  log("no /boot/init.rc, starting with no services")
end

-- ---- spawn all services ----
for _, svc in ipairs(services) do
  local pid = spawn(svc.path, table.unpack(svc.args))
  if pid then
    log("started " .. svc.name .. " pid " .. pid)
  else
    log("FAILED to start " .. svc.name .. " (" .. svc.path .. ")")
  end
end

-- ---- reap children forever ----
while true do
  local pid, how, code = waitpid(-1)
  if pid then
    log("reaped pid " .. pid .. " (" .. tostring(how) .. " " .. tostring(code) .. ")")
  end
end