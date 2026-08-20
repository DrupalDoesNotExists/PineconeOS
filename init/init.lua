--[[
  PineconeOS init (pid 1) — runit-style supervisor
  =================================================
  Scans /etc/sv/ for service directories, spawns each <name>/run script,
  then supervises them: on exit, respawns with a short backoff so a crashing
  service doesn't spin the CPU.

  Service layout (runit convention):
    /etc/sv/<name>/run     executable Lua script (the service)

  The kernel spawns this as pid 1 (default /sbin/init.lua, overridable via
  `init <path>` in /boot/knuck.conf).
]]

local BACKOFF = 1  -- seconds to wait before respawning a crashed service

local function log(msg)
  print("[init] " .. msg)
end

-- ---- discover services under /etc/sv ----
local services = {}  -- { name = <name>, path = <path>, pid = <pid> }
local ok, entries = pcall(readdir, "/etc/sv")
if ok and entries then
  for _, entry in ipairs(entries) do
    local name = entry.name
    local run = "/etc/sv/" .. name .. "/run"
    local ino = stat(run)
    if ino and ino.type == "file" then
      services[#services + 1] = { name = name, path = run, pid = nil }
    end
  end
else
  log("no /etc/sv, starting with no services")
end

-- ---- spawn all services ----
for _, svc in ipairs(services) do
  local pid = spawn(svc.path)
  if pid then
    svc.pid = pid
    log("started " .. svc.name .. " pid " .. pid)
  else
    log("FAILED to start " .. svc.name)
  end
end

-- ---- supervise: reap children, respawn crashed services ----
while true do
  local pid, how, code = waitpid(-1)
  if pid then
    -- find which service this pid belonged to
    local svc = nil
    for _, s in ipairs(services) do
      if s.pid == pid then svc = s break end
    end
    if svc then
      log(svc.name .. " exited (" .. tostring(how) .. " " .. tostring(code) .. "), respawning")
      sleep(BACKOFF)
      local np = spawn(svc.path)
      if np then
        svc.pid = np
        log("restarted " .. svc.name .. " pid " .. np)
      else
        log("FAILED to restart " .. svc.name)
      end
    else
      log("reaped unknown pid " .. pid)
    end
  end
end