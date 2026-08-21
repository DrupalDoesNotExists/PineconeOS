--[[
  ttybcd — PTY broadcast daemon (general master/slave pty, Linux-pts style)
  =========================================================================
  Claims a real tty, opens a pty (/dev/ptmx), and runs a shell on the pty
  SLAVE. It proxies the real tty's keyboard into the slave's input and the
  slave's output back to the real tty's display — and simultaneously
  broadcasts the slave's output to any connected monitors.

  The pty is a general mechanism (like Linux pts); monitors are just one
  consumer. Other programs could attach to the master for logging,
  recording, etc.

  Usage:
    ttybcd [tty]                                 main mode (default tty 2)
    ttybcd forward <master_fd> <real_fd> [mon...]  internal output forwarder
]]

local args = {...}
local mode = args[1]

-- ---- internal forwarder: slave output -> real display + monitors ----
if mode == "forward" then
  local master_fd = tonumber(args[2])
  local real_fd = tonumber(args[3])
  local monitors = {}
  for i = 4, #args do
    local fd = open(args[i], "w")
    if fd then
      write(fd, "clear")
      monitors[#monitors + 1] = fd
    end
  end

  -- Strip control chars except \n and \t; escape \ and " for the peripheral
  -- wrapper so space-containing text reaches the monitor intact.
  local function mon_escape(s)
    s = s:gsub("[%z\1-\8\11-\31]", "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return s
  end

  while true do
    local chunk = read(master_fd, 4096)
    if chunk == nil then break end
    -- real display gets the raw stream (tty device handles control chars)
    write(real_fd, chunk)
    -- monitors get escaped text (the monitor wraps + scrolls itself)
    local e = mon_escape(chunk)
    if e ~= "" then
      for _, m in ipairs(monitors) do
        write(m, 'write "' .. e .. '"')
      end
    end
  end
  for _, m in ipairs(monitors) do close(m) end
  return
end

-- ---- main mode ----
local tty = tonumber(args[1]) or 2

local real_fd = open("/dev/tty" .. tty, 2)  -- O_RDWR
if not real_fd then
  print("ttybcd: cannot open /dev/tty" .. tty)
  return
end
ioctl(real_fd, "TIOCSCTTY", 0)
ioctl(real_fd, "console_mode", "raw")   -- raw key events for proxying
ioctl(0, "VT_ACTIVATE", tty)

-- create a pty; the slave becomes the shell's controlling terminal
local master_fd = open("/dev/ptmx")
if not master_fd then
  print("ttybcd: cannot open /dev/ptmx")
  return
end
local slave_path = ptsname(master_fd)
if not slave_path then
  print("ttybcd: ptsname failed")
  return
end
local slave_fd = open(slave_path, 2)
if not slave_fd then
  print("ttybcd: cannot open " .. slave_path)
  return
end

-- discover monitors
local mon_paths = {}
local ok, entries = pcall(readdir, "/dev/peripherals/monitors")
if ok and entries then
  for _, e in ipairs(entries) do
    if e.type == "file" then
      mon_paths[#mon_paths + 1] = "/dev/peripherals/monitors/" .. e.name
    end
  end
end

-- spawn the shell on the slave (its stdin/stdout/stderr = the pty slave)
local sh_pid = spawn("/usr/bin/sh.lua", { [0] = slave_fd, [1] = slave_fd, [2] = slave_fd })
if not sh_pid then
  print("ttybcd: failed to spawn shell")
  return
end

-- spawn the output forwarder (inherits our fds: master_fd, real_fd, slave_fd)
local fwd_args = { "forward", tostring(master_fd), tostring(real_fd) }
for _, mp in ipairs(mon_paths) do fwd_args[#fwd_args + 1] = mp end
spawn("/usr/bin/ttybcd.lua", table.unpack(fwd_args))

-- keyboard loop: real tty key events -> pty slave input (via master)
while true do
  local ev = read(real_fd, 1)
  if ev == nil then break end
  write(master_fd, ev)
end
