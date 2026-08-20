--[[
  PineconeOS hotplug daemon
  =========================
  Reads /dev/devctl for peripheral attach/detach events and logs them.
  The kernel already mounts/unmounts disk drives on hotplug; this daemon
  records the events and can be extended to run per-device actions.

  Event format from /dev/devctl: "attach <side>" | "detach <side>"
]]

local function log(msg)
  print("[hotplugd] " .. msg)
end

print("hotplugd: started, pid " .. getpid())

while true do
  local f = open("/dev/devctl", "r")
  if f then
    local ev = read(f, 256)
    close(f)
    if ev and #ev > 0 then
      log(ev)
    end
  end
  sleep(0.1)
end