--[[
  PineconeOS package manager (pine)
  ================================
  Pacman-style. Package format: .cone = tar archive containing a .CONEINFO
  metadata file plus the payload files (paths relative to /).

  Commands:
    pine -U <file.cone>   install from a local .cone file
    pine -S <pkg>         install from a configured repository
    pine -R <pkg>         remove an installed package
    pine -Q               list installed packages
    pine -Ss <term>       search repositories
    pine -Sy              refresh repository databases

  Config: /etc/pine/pine.conf   (repo lines: repo <name> <url>)
  DB:     /var/lib/pine/local/<name>/   (installed package + file list)
  Cache:  /var/cache/pine/pkg/
]]

local tar = dofile("/usr/lib/tar.lua")

local CONF = "/etc/pine/pine.conf"
local LOCAL_DB = "/var/lib/pine/local"
local CACHE = "/var/cache/pine/pkg"

-- ---- helpers ----

local function read_all(path)
  local f = open(path, "r")
  if not f then return nil end
  local data = read(f, 65536)
  close(f)
  return data
end

local function write_all(path, data)
  local f = open(path, "w")
  if not f then return false end
  write(f, data)
  close(f)
  return true
end

local function ensure_dir(path)
  if not stat(path) then mkdir(path) end
end

local function log(msg)
  print("[pine] " .. msg)
end

-- ---- .CONEINFO parsing ----

-- parse "key = value" lines into a table
local function parse_coneinfo(content)
  local info = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local k, v = line:match("^(%S+)%s*=%s*(.+)$")
      if k then info[k] = v end
    end
  end
  return info
end

-- read .CONEINFO from a .cone archive
local function read_coneinfo(cone_path)
  local content = tar.read_entry(cone_path, ".CONEINFO")
  if not content then return nil, "no .CONEINFO in package" end
  return parse_coneinfo(content)
end

-- ---- repository config ----

local function load_repos()
  local repos = {}
  local conf = read_all(CONF)
  if conf then
    for line in (conf .. "\n"):gmatch("([^\n]*)\n") do
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" and not line:match("^#") then
        local name, url = line:match("^repo%s+(%S+)%s+(%S+)$")
        if name and url then
          repos[#repos + 1] = { name = name, url = url }
        end
      end
    end
  end
  return repos
end

-- ---- install ----

-- install a .cone file: extract to /, record file list in the local db
local function install_file(cone_path)
  local info, err = read_coneinfo(cone_path)
  if not info then return nil, err end
  local name = info.name
  if not name then return nil, "package has no name" end
  local version = info.version or "0"

  -- list files before extracting (for the db)
  local entries = tar.list(cone_path)
  local files = {}
  for _, e in ipairs(entries or {}) do
    if e.name ~= ".CONEINFO" and e.typeflag == "0" then
      files[#files + 1] = "/" .. e.name
    end
  end

  -- extract to /
  local n = tar.extract(cone_path, "")
  if not n then return nil, "extract failed" end

  -- record in local db
  local dbdir = LOCAL_DB .. "/" .. name
  ensure_dir(dbdir)
  write_all(dbdir .. "/info", "name = " .. name .. "\nversion = " .. version .. "\n")
  local fl = table.concat(files, "\n")
  write_all(dbdir .. "/files", fl)

  log("installed " .. name .. " " .. version .. " (" .. #files .. " files)")
  return true
end

-- ---- remove ----

local function remove_pkg(name)
  local dbdir = LOCAL_DB .. "/" .. name
  local files = read_all(dbdir .. "/files")
  if not files then return nil, "package " .. name .. " not installed" end
  for line in (files .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      unlink(line)
    end
  end
  -- remove db dir (best effort)
  local entries = readdir(dbdir)
  if entries then
    for _, e in ipairs(entries) do unlink(dbdir .. "/" .. e.name) end
  end
  rmdir(dbdir)
  log("removed " .. name)
  return true
end

-- ---- query ----

local function query()
  local entries = readdir(LOCAL_DB)
  if not entries then
    log("no packages installed")
    return
  end
  for _, e in ipairs(entries) do
    local info = read_all(LOCAL_DB .. "/" .. e.name .. "/info")
    local version = "?"
    if info then
      version = info:match("version%s*=%s*(%S+)") or "?"
    end
    print(e.name .. " " .. version)
  end
end

-- ---- search ----

local function search(term)
  local repos = load_repos()
  local found = false
  for _, repo in ipairs(repos) do
    -- local dir repo: url = file:///path
    local dir = repo.url:match("^file://(.+)$")
    if dir then
      local entries = readdir(dir)
      if entries then
        for _, e in ipairs(entries) do
          if e.name:match("%.cone$") and (not term or e.name:find(term, 1, true)) then
            print(repo.name .. "/" .. e.name)
            found = true
          end
        end
      end
    end
  end
  if not found then log("no matches for '" .. tostring(term) .. "'") end
end

-- ---- install from repo ----

local function install_from_repo(pkg)
  local repos = load_repos()
  for _, repo in ipairs(repos) do
    local dir = repo.url:match("^file://(.+)$")
    if dir then
      local entries = readdir(dir)
      if entries then
        for _, e in ipairs(entries) do
          if e.name:match("^" .. pkg .. "%-.*%.cone$") then
            -- copy repo file to cache, then install
            ensure_dir(CACHE)
            local src = dir .. "/" .. e.name
            local dst = CACHE .. "/" .. e.name
            local s = open(src, "r")
            if s then
              local data = read(s, 65536)
              close(s)
              write_all(dst, data)
            end
            return install_file(dst)
          end
        end
      end
    end
  end
  return nil, "package " .. pkg .. " not found in any repo"
end

-- ---- main ----

local args = { ... }
local cmd = args[1]

if cmd == "-U" then
  local ok, err = install_file(args[2])
  if not ok then log("error: " .. tostring(err)) end
elseif cmd == "-S" then
  local ok, err = install_from_repo(args[2])
  if not ok then log("error: " .. tostring(err)) end
elseif cmd == "-R" then
  local ok, err = remove_pkg(args[2])
  if not ok then log("error: " .. tostring(err)) end
elseif cmd == "-Q" then
  query()
elseif cmd == "-Ss" then
  search(args[2])
else
  print("usage: pine -U <file.cone> | -S <pkg> | -R <pkg> | -Q | -Ss <term>")
end