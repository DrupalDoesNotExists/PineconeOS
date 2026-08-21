--[[ PineconeOS login (getty)
  Prompts for username + password, verifies via the kernel login() syscall
  (checks /etc/passwd), spawns the shell on success. Runs as a service
  (/etc/sv/login/run). Single-user root for now.
  Input is read in raw console mode so the password is not echoed.
]]
ioctl(0, "console_mode", "raw")

local function read_line(echo)
  local buf = ""
  while true do
    local ev = read(0, 1)
    if not ev then sleep(0.05)
    elseif type(ev) == "table" then
      if ev[1] == "char" then
        local ch = ev[2]
        if ch == "\n" or ch == "\r" then
          return buf
        elseif ch == "\b" or ch == "\x7f" then
          buf = buf:sub(1, -2)
          if echo then write(1, "\b \b") end
        else
          buf = buf .. ch
          if echo then write(1, ch) end
        end
      elseif ev[1] == "key" and ev[2] == 28 then
        return buf
      end
    end
  end
end

while true do
  write(1, "PineconeOS login: ")
  local name = read_line(true)
  write(1, "\nPassword: ")
  local pass = read_line(false)
  write(1, "\n")
  local uid, gid = login(name, pass)
  if uid then
    write(1, "\n")
    local pid = spawn("/usr/bin/sh.lua")
    if pid then waitpid(pid) end
  else
    write(1, "Login incorrect\n")
    sleep(1)
  end
end
