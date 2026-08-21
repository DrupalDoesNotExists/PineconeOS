--[[
  PineconeOS Installer
  ====================
  Runs on stock CraftOS (no KNUCK yet). Downloads and installs the
  base system from the GitHub distrorepo.

  Usage: pastebin run <code> or copy to /startup on a fresh computer.

  Steps:
    1. Check HTTP API availability
    2. Fetch PINEINDEX from distrorepo
    3. Download and extract core packages
    4. Set up /boot/knuck.conf
    5. Install /sbin/init.lua (not in any .cone package)
    6. Install default services under /etc/sv
    7. Write /startup boot entry
    8. Offer reboot
]]

-- ============================================================
-- Configuration
-- ============================================================

local PINE_CONF = "/etc/pine.conf"
local REPO_BASE_DEFAULT = "https://raw.githubusercontent.com/DrupalDoesNotExists/PineconeOS-distrorepo/master"
local REPO_BASE = REPO_BASE_DEFAULT
local INDEX_URL = REPO_BASE .. "/PINEINDEX"
local INSTALL_ROOT = ""  -- empty = install to computer root
local CORE_PACKAGES = {
  "knuck",      -- kernel (essential)
  "pine",       -- package manager
  "shell",      -- interactive shell
  "coreutils",  -- basic utilities (cat, ls, cp, mv, rm, mkdir)
  "login",      -- login/auth
}

-- ============================================================
-- Helpers (pure CraftOS, no KNUCK)
-- ============================================================

local function msg(text)
  term.setTextColor(colors.cyan)
  write("[install] ")
  term.setTextColor(colors.white)
  print(text)
end

local function warn(text)
  term.setTextColor(colors.yellow)
  write("[install] WARNING: ")
  term.setTextColor(colors.white)
  print(text)
end

local function err(text)
  term.setTextColor(colors.red)
  write("[install] ERROR: ")
  term.setTextColor(colors.white)
  print(text)
end

local function success(text)
  term.setTextColor(colors.green)
  write("[install] OK: ")
  term.setTextColor(colors.white)
  print(text)
end

local function header(text)
  term.setTextColor(colors.green)
  print("")
  print("=== " .. text .. " ===")
  term.setTextColor(colors.white)
end

-- Read entire file into string
local function read_all(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local data = h.readAll()
  h.close()
  return data
end

-- mkdir -p equivalent
local function mkdir_p(path)
  if fs.exists(path) then return true end
  local parent = path:match("^(.+)/[^/]+$")
  if parent and parent ~= "" then mkdir_p(parent) end
  fs.makeDir(path)
  return true
end

-- Write string to file, creating parent dirs
local function write_file(path, data)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then mkdir_p(dir) end
  local h = fs.open(path, "wb")
  if not h then
    err("write_file: cannot open " .. path)
    return false
  end
  h.write(data)
  h.close()
  -- Verify write succeeded
  if not fs.exists(path) then
    err("write_file: " .. path .. " not found after write")
    return false
  end
  return true
end

-- ============================================================
-- Config: read /etc/pine.conf if present
-- ============================================================

do
  local conf_path = INSTALL_ROOT .. PINE_CONF
  local h = fs.open(conf_path, "r")
  if h then
    local data = h.readAll()
    h.close()
    if data then
      for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        local k, v = line:match("^([A-Z_]+)%s*=%s*(.+)$")
        if k == "REPO_BASE" and v ~= "" then
          REPO_BASE = v
          INDEX_URL = REPO_BASE .. "/PINEINDEX"
        end
      end
    end
  end
end

-- ============================================================
-- Step 1: Check HTTP availability
-- ============================================================

local function check_http()
  header("Checking HTTP API")

  if not http then
    err("HTTP API is not available!")
    print("  To enable HTTP:")
    print("  1. Edit /Computercraft/luaconf.conf")
    print("  2. Add or uncomment: http_enable = true")
    print("  3. Restart the computer")
    return false
  end

  -- Test connectivity with a small request
  msg("Testing connection...")
  local ok, err_msg = pcall(function()
    local resp = http.get(INDEX_URL)
    if resp then
      resp.close()
      return true
    end
    return false
  end)

  if not ok or err_msg == false then
    err("Cannot reach distro repository!")
    print("  URL: " .. INDEX_URL)
    print("  Check your network connection.")
    return false
  end

  success("HTTP API available and connected")
  return true
end

-- ============================================================
-- Step 2: Fetch and parse PINEINDEX
-- ============================================================

local function fetch_index()
  header("Fetching package index")

  msg("Downloading PINEINDEX...")
  local resp = http.get(INDEX_URL)
  if not resp then
    err("Failed to download PINEINDEX")
    return nil
  end

  local data = resp.readAll()
  resp.close()

  if not data or #data == 0 then
    err("PINEINDEX is empty")
    return nil
  end

  -- Validate header
  local first_line = data:match("([^\n]+)")
  if first_line ~= "---PINEINDEX v1---" then
    err("Invalid PINEINDEX format")
    return nil
  end

  -- Parse entries
  local packages = {}
  local blocks = {}
  for block in (data .. "\n---\n"):gmatch("(.-)\n%-%-%-\n") do
    blocks[#blocks + 1] = block
  end

  for _, block in ipairs(blocks) do
    local pkg = {}
    for line in (block .. "\n"):gmatch("([^\n]*)\n") do
      local k, v = line:match("^(%S+):(.*)$")
      if k then pkg[k] = v end
    end
    if pkg.pkg then
      pkg.name = pkg.pkg
      -- If duplicate name, keep the higher version (not just last-wins)
      local existing = packages[pkg.name]
      if existing and existing.version and pkg.version then
        local function parse_ver(v)
          local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
          if a then return tonumber(a), tonumber(b), tonumber(c) end
          return 0, 0, 0
        end
        local ea, eb, ec = parse_ver(existing.version)
        local na, nb, nc = parse_ver(pkg.version)
        if na > ea or (na == ea and nb > eb) or (na == ea and nb == eb and nc > ec) then
          packages[pkg.name] = pkg  -- new version is higher, replace
        end
        -- else keep existing (higher or equal)
      else
        packages[pkg.name] = pkg
      end
    end
  end

  local count = 0
  for _ in pairs(packages) do count = count + 1 end
  success("Loaded index: " .. count .. " packages")

  return packages
end

-- ============================================================
-- Step 3: Download and extract .cone packages
-- ============================================================

-- Parse the .cone format (length-prefixed binary)
local function parse_cone(data)
  local manifest = {}
  local files = {}
  local pos = 1
  local dlen = #data

  -- Expect header
  local hs = data:find("---PINEPKG v1---", pos, true)
  if not hs then return nil, "missing header" end
  pos = hs + #"---PINEPKG v1---" + 1

  -- Read manifest until ---END MANIFEST---
  while pos <= dlen do
    local le = data:find("\n", pos)
    local line
    if le then
      line = data:sub(pos, le - 1)
      pos = le + 1
    else
      line = data:sub(pos)
      pos = dlen + 1
    end
    if line == "---END MANIFEST---" then break end
    local k, v = line:match("^([^=]+)%s*=%s*(.*)$")
    if k then manifest[k] = v end
  end

  -- Read FILE entries
  while pos <= dlen do
    if data:sub(pos, pos + 7) ~= "---FILE " then break end
    local fe = pos + 7
    local hline_end = data:find("\n", fe + 1)
    if not hline_end then return nil, "malformed FILE header" end
    local hline = data:sub(fe + 1, hline_end - 1)
    pos = hline_end + 1

    -- Strip trailing --- delimiter
    if hline:sub(-3) ~= "---" then
      return nil, "malformed FILE header (no --- delimiter)"
    end
    hline = hline:sub(1, -4)

    local fpath, fmode, fsize_s, fchk, ftype = hline:match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not fpath then return nil, "bad FILE header" end
    local fsize = tonumber(fsize_s)
    if not fsize then return nil, "bad file size" end

    -- Extract content
    if pos + fsize - 1 > dlen then
      return nil, "truncated: " .. fpath
    end
    local content = data:sub(pos, pos + fsize - 1)
    pos = pos + fsize

    files[#files + 1] = {
      path = fpath,
      mode = tonumber(fmode, 8),
      size = fsize,
      checksum = fchk,
      type = ftype,
      content = content,
    }
  end

  if not manifest.name then return nil, "missing name" end
  if not manifest.version then return nil, "missing version" end

  return {
    manifest = manifest,
    files = files,
  }
end

local function download_and_extract(pkg_name, pkg_info)
  local version = pkg_info.version
  local filename = pkg_info.file or (pkg_name .. "-" .. version .. ".cone")
  local url = REPO_BASE .. "/" .. filename

  msg("Downloading " .. pkg_name .. " " .. version .. "...")
  local resp = http.get(url)
  if not resp then
    err("Failed to download " .. filename)
    return false
  end

  local data = resp.readAll()
  resp.close()

  if not data or #data == 0 then
    err("Package " .. pkg_name .. " is empty")
    return false
  end

  msg("Parsing " .. filename .. "...")
  local pkg, parse_err = parse_cone(data)
  if not pkg then
    err("Parse error in " .. filename .. ": " .. tostring(parse_err))
    return false
  end

  -- Verify name matches
  if pkg.manifest.name ~= pkg_name then
    warn("Package name mismatch: expected " .. pkg_name .. ", got " .. pkg.manifest.name)
  end

  -- Extract files
  msg("Extracting " .. #pkg.files .. " files...")
  -- Ensure critical directories exist (defense-in-depth)
  mkdir_p(INSTALL_ROOT .. "/etc")
  mkdir_p(INSTALL_ROOT .. "/etc/sv")
  mkdir_p(INSTALL_ROOT .. "/lib")
  mkdir_p(INSTALL_ROOT .. "/lib/knuck")
  mkdir_p(INSTALL_ROOT .. "/lib/knuck/kernel")
  mkdir_p(INSTALL_ROOT .. "/lib/knuck/kernel/drivers")
  for _, f in ipairs(pkg.files) do
    local target = INSTALL_ROOT .. f.path
    local ok = write_file(target, f.content)
    if not ok then
      err("FAILED to write " .. target)
      return false
    end
  end

  -- Run postinst hook if present
  if pkg.manifest.postinst and pkg.manifest.postinst ~= "" then
    msg("Running postinst hook...")
    -- Create minimal hook environment
    local hook_env = {
      string = string, table = table, math = math,
      tostring = tostring, tonumber = tonumber, type = type,
      pairs = pairs, ipairs = ipairs, pcall = pcall, error = error,
      PKG_NAME = pkg_name,
      HOOK = "postinst",
      print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        write(1, table.concat(parts, "\t") .. "\n")
      end,
    }
    setmetatable(hook_env, { __index = _G })

    local fn, compile_err = load(pkg.manifest.postinst, "=postinst", "t", hook_env)
    if fn then
      local ok, run_err = pcall(fn)
      if not ok then
        warn("postinst hook failed: " .. tostring(run_err))
      end
    else
      warn("postinst compile error: " .. tostring(compile_err))
    end
  end

  success(pkg_name .. " " .. version .. " installed (" .. #pkg.files .. " files)")
  return true
end

-- ============================================================
-- Step 4: Install core packages
-- ============================================================

local function install_packages(index)
  header("Installing core packages")

  -- Ensure service dir exists even if no package provides it (init scans /etc/sv)
  mkdir_p(INSTALL_ROOT .. "/etc")
  mkdir_p(INSTALL_ROOT .. "/etc/sv")

  for _, pkg_name in ipairs(CORE_PACKAGES) do
    local pkg_info = index[pkg_name]
    if not pkg_info then
      err("Package '" .. pkg_name .. "' not found in repository!")
      return false
    end

    local ok = download_and_extract(pkg_name, pkg_info)
    if not ok then
      return false
    end
  end

  return true
end

-- ============================================================
-- Step 5: Write /boot/knuck.conf
-- ============================================================

local function write_knuck_conf()
  header("Configuring kernel")

  local conf = [[
# KNUCK kernel configuration
# Generated by PineconeOS installer

# Init process
init /sbin/init.lua

# Extra modules (loaded in order)
# module /lib/knuck/kernel/net.lua
# module /lib/knuck/kernel/net_transport.lua
]]

  local path = INSTALL_ROOT .. "/boot/knuck.conf"
  msg("Writing " .. path .. "...")
  write_file(path, conf)
  success("Kernel config written")
  return true
end

-- ============================================================
-- Step 5b: Write /etc/pine.conf
-- ============================================================

local function write_pine_conf()
  header("Writing package manager config")

  local conf = "# Pine package manager configuration\nREPO_BASE=" .. REPO_BASE .. "\n"

  local path = INSTALL_ROOT .. PINE_CONF
  msg("Writing " .. path .. "...")
  write_file(path, conf)
  success("pine config written")
  return true
end

-- ============================================================
-- Step 6: Install /sbin/init.lua (not in any .cone package)
-- ============================================================

local INIT_SOURCE = [=[
--[[
  PineconeOS init (pid 1) -- runit-style supervisor
  =================================================
  Scans /etc/sv/ for service directories, spawns each <name>/run script,
  then supervises them: on exit, respawns with a short backoff so a crashing
  service doesn't spin the CPU.

  Service layout (runit convention):
    /etc/sv/<name>/run     executable Lua script (the service)

  The kernel spawns this as pid 1 (default /sbin/init.lua, overridable via
  init path in /boot/knuck.conf).
]]

local BACKOFF = 1  -- seconds to wait before respawning a crashed service

local function log(msg)
  print("[init] " .. msg)
end

-- discover services under /etc/sv
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

-- spawn all services
for _, svc in ipairs(services) do
  local pid = spawn(svc.path)
  if pid then
    svc.pid = pid
    log("started " .. svc.name .. " pid " .. pid)
  else
    log("FAILED to start " .. svc.name)
  end
end

-- supervise: reap children, respawn crashed services
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
]=]

local function write_init()
  header("Installing init process")

  local path = INSTALL_ROOT .. "/sbin/init.lua"
  msg("Writing " .. path .. "...")
  write_file(path, INIT_SOURCE)
  success("Init process installed")
  return true
end

-- ============================================================
-- Step 6b: Install default service configs under /etc/sv
-- ============================================================

local DEFAULT_SV_SERVICES = {
  dhcp = [=[
#!/usr/bin/env lua
-- Default DHCP service
while true do
  local ok, err = pcall(function() dofile("/usr/bin/dhcp.lua") end)
  if not ok then print("dhcp error: "..tostring(err)) sleep(5) else sleep(60) end
end
]=],

  getty = [=[
#!/usr/bin/env lua
-- Getty: login prompt on console
while true do
  local ok, err = pcall(function() dofile("/usr/bin/sh.lua") end)
  if not ok then print("getty error: "..tostring(err)) sleep(2) end
end
]=],

  logind = [=[
#!/usr/bin/env lua
-- logind: user session/logind supervisor (stub, respawn login)
while true do
  local ok, err = pcall(function() dofile("/usr/bin/login.lua") end)
  if not ok then print("logind error: "..tostring(err)) sleep(2) else sleep(1) end
end
]=],

  hotplugd = [=[
#!/usr/bin/env lua
-- hotplugd: watches device hotplug via /dev (stub)
while true do
  local ok, err = pcall(function() sleep(10) end)
  if not ok then print("hotplugd error: "..tostring(err)) sleep(2) end
end
]=],

  syslogd = [=[
#!/usr/bin/env lua
-- syslogd: system log collector (stub, drains print buffer)
while true do
  local ok, err = pcall(function() sleep(10) end)
  if not ok then print("syslogd error: "..tostring(err)) sleep(2) end
end
]=],
}

local function write_default_sv()
  header("Installing default services")

  for name, source in pairs(DEFAULT_SV_SERVICES) do
    local dir = INSTALL_ROOT .. "/etc/sv/" .. name
    mkdir_p(dir)
    local path = dir .. "/run"
    msg("Writing " .. path .. "...")
    write_file(path, source)
    success("Service " .. name .. " installed")
  end

  return true
end

-- ============================================================
-- Step 7: Write /startup entry point
-- ============================================================

local function write_startup()
  header("Writing boot entry")

  local startup = [[
-- /startup — distro-owned boot entry (CraftOS runs this).
-- Loads the KNUCK kernel, which is provided by the `knuck` pine package
-- (the package owns /lib/knuck/). Removing that package leaves
-- /lib/knuck/boot.lua missing, so the system won't boot — pine refuses
-- to remove it without --force.
local function try_load(path)
  local f, err = loadfile(path, "bt", _G)
  if f then return f end
  return nil, err
end

local f, err = try_load("/lib/knuck/boot.lua")
if not f then f, err = try_load("/tmp/PineconeOS/kernel/boot.lua") end
if not f then f, err = try_load("./kernel/boot.lua") end
if not f then
  error("kernel not installed: /lib/knuck/boot.lua missing (" .. tostring(err) .. ")")
end
f()
]]

  local path = INSTALL_ROOT .. "/startup"
  msg("Writing " .. path .. "...")
  write_file(path, startup)
  success("Boot entry written")
  return true
end

-- ============================================================
-- Step 7: Verify installation
-- ============================================================

local function verify_install()
  header("Verifying installation")

  local critical_files = {
    "/lib/knuck/boot.lua",
    "/sbin/init.lua",
    "/usr/bin/pine.lua",
    "/usr/bin/sh.lua",
    "/usr/bin/ls.lua",
    "/usr/bin/cat.lua",
    "/boot/knuck.conf",
    "/startup",
    "/etc/sv/dhcp/run",
    "/etc/sv/getty/run",
  }

  local all_ok = true
  for _, path in ipairs(critical_files) do
    local full = INSTALL_ROOT .. path
    if fs.exists(full) then
      success(path)
    else
      err("MISSING: " .. path)
      all_ok = false
    end
  end

  return all_ok
end

-- ============================================================
-- Main
-- ============================================================

local function main()
  -- Banner
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.green)
  print("╔══════════════════════════════════════╗")
  print("║        PineconeOS Installer          ║")
  print("║    KNUCK Microkernel for CC:Tweaked  ║")
  print("╚══════════════════════════════════════╝")
  term.setTextColor(colors.white)
  print("")

  -- Confirmation
  term.setTextColor(colors.yellow)
  print("This will install PineconeOS to this computer.")
  print("Existing files in /lib, /sbin, /usr, /boot, /etc will be overwritten.")
  term.setTextColor(colors.white)
  write("\nContinue? [Y/n] ")
  local answer = read()
  if answer and answer:lower() == "n" then
    print("Installation cancelled.")
    return
  end

  -- Step 1: Check HTTP
  if not check_http() then
    err("HTTP check failed. Cannot continue.")
    return
  end

  -- Step 2: Fetch index
  local index = fetch_index()
  if not index then
    err("Failed to fetch package index. Cannot continue.")
    return
  end

  -- Step 3-4: Install packages
  if not install_packages(index) then
    err("Package installation failed.")
    return
  end

  -- Step 5: Write kernel config
  if not write_knuck_conf() then
    err("Failed to write kernel config.")
    return
  end

  -- Step 5b: Write pine config
  if not write_pine_conf() then
    err("Failed to write pine config.")
    return
  end

  -- Step 6a: Install init (not in any .cone package)
  if not write_init() then
    err("Failed to install init process.")
    return
  end

  -- Step 6b: Install default services under /etc/sv
  if not write_default_sv() then
    err("Failed to install default services.")
    return
  end

  -- Step 6c: Write startup entry
  if not write_startup() then
    err("Failed to write boot entry.")
    return
  end

  -- Step 7: Verify
  if not verify_install() then
    warn("Some files are missing. Installation may be incomplete.")
  end

  -- Done
  header("Installation Complete")
  term.setTextColor(colors.green)
  print("PineconeOS has been installed successfully!")
  term.setTextColor(colors.white)
  print("")
  print("To start the system, reboot this computer.")
  print("  os.reboot()")
  print("")
  write("Reboot now? [Y/n] ")
  local answer = read()
  if not answer or answer:lower() ~= "n" then
    print("Rebooting...")
    os.reboot()
  else
    print("You can reboot later with: os.reboot()")
  end
end

-- Run
main()
