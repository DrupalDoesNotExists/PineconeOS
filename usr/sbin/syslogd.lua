--[[
  PineconeOS syslog daemon
  ========================
  Reads /proc/kmsg (drain-on-read) in a loop and appends each batch to
  /var/log/syslog. Started as a service by init (see /boot/init.rc).
]]

local function append(path, data)
  local f = open(path, "a")
  if not f then return false end
  write(f, data)
  close(f)
  return true
end

-- ensure /var/log exists
if not stat("/var/log") then
  mkdir("/var/log")
end

print("syslogd: started, pid " .. getpid())

while true do
  local f = open("/proc/kmsg", "r")
  if f then
    local data = read(f, 65536)
    close(f)
    if data and #data > 0 then
      append("/var/log/syslog", data)
    end
  end
  sleep(1)
end