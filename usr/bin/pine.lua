--[[
  PineconeOS package manager (pine)
  ================================
  Line-based .cone format. Minimal DB. Bytecode support.
  Runs as system process with load/io/os available.
  Uses syscall wrappers for file I/O.
]]

-- ---- args ----
local args = {}
for i = 1, select("#", ...) do args[i] = select(i, ...) end

-- ---- constants ----
local DB_DIR     = "/var/lib/pine/db"
local CONF_DIR   = "/var/lib/pine/conffiles"
local STAGE_DIR  = "/var/lib/pine/stage"
local REPO_INDEX = "/usr/share/pine/repo/PINEINDEX"
local REPO_DIR   = "/usr/share/pine/repo"
local PINE_CONF  = "/etc/pine.conf"
local REPO_BASE_DEFAULT = "https://raw.githubusercontent.com/DrupalDoesNotExists/PineconeOS-distrorepo/master"
local REPO_BASE  = REPO_BASE_DEFAULT
local LOCK_DIR   = "/var/lib/pine/lock"
local SEP = ","

-- ---- config ----
do
  local fd = open(PINE_CONF, "r")
  if fd then
    local data = read(fd, 4096)
    close(fd)
    if data then
      for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        local k, v = line:match("^([A-Z_]+)%s*=%s*(.+)$")
        if k == "REPO_BASE" and v ~= "" then
          REPO_BASE = v
        end
      end
    end
  end
end

-- ---- flags ----
local flag_force     = false
local flag_nohook    = false
local flag_dryrun    = false
local flag_keepcache = false

-- Track which .cone files were fetched this session (for cleanup after install)
local fetched_cones = {}

local function parse_flags()
  local filtered = {}
  for _, a in ipairs(args) do
    if a == "--force" then flag_force = true
    elseif a == "--no-hooks" then flag_nohook = true
    elseif a == "--dry-run" then flag_dryrun = true
    elseif a == "--keep-cache" then flag_keepcache = true
    else filtered[#filtered + 1] = a
    end
  end
  return filtered
end

args = parse_flags()
local cmd = args[1]

-- ---- bit lib (Lua 5.2: bit32; KNUCK: may provide bit) ----
local bit = (function()
  local ok, b = pcall(require, "bit")
  if ok and b and b.bxor then return b end
  ok, b = pcall(require, "bit32")
  if ok and b and b.bxor then return b end
  -- fallback: pure-arithmetic bxor for 32-bit values
  local bxor_impl
  bxor_impl = function(a, b)
    if a == 0 then return b end
    if b == 0 then return a end
    local r, p = 0, 1
    for _ = 1, 32 do
      local ab, bb = a % 2, b % 2
      if ab ~= bb then r = r + p end
      a, b = math.floor(a / 2), math.floor(b / 2)
      p = p * 2
      if a == 0 and b == 0 then break end
    end
    return r
  end
  return { bxor = bxor_impl }
end)()

-- ---- helpers ----

local function err(msg)
  write(2, "pine: " .. tostring(msg) .. "\n")
end

local function die(msg)
  error(msg, 0)
end

-- ---- lock ----

local function acquire_lock()
  local ok = mkdir(LOCK_DIR)
  if ok then
    local fd = open(LOCK_DIR .. "/pid", "w")
    if fd then write(fd, tostring(getpid())); close(fd) end
    return true
  end
  -- lock held — check if owner is still alive
  local fd = open(LOCK_DIR .. "/pid", "r")
  if fd then
    local pid_str = read(fd, 32)
    close(fd)
    if pid_str then
      local pid = tonumber(pid_str)
      if pid and kill(pid, 0) then
        die("another pine instance is running (pid " .. pid .. ")")
      end
    end
  end
  -- stale lock — clean up and retry once
  unlink(LOCK_DIR .. "/pid")
  rmdir(LOCK_DIR)
  ok = mkdir(LOCK_DIR)
  if not ok then die("cannot acquire lock") end
  fd = open(LOCK_DIR .. "/pid", "w")
  if fd then write(fd, tostring(getpid())); close(fd) end
  return true
end

local function release_lock()
  unlink(LOCK_DIR .. "/pid")
  rmdir(LOCK_DIR)
end

local function msg(msg)
  write(1, "pine: " .. tostring(msg) .. "\n")
end

-- read entire file, loop until EOF
local function read_all(path)
  local fd = open(path, "r")
  if not fd then return nil end
  local parts = {}
  while true do
    local chunk = read(fd, 4096)
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  close(fd)
  return table.concat(parts)
end

-- mkdir_p: walk path components, mkdir each missing
local function mkdir_p(path, mode)
  mode = mode or 493 -- 0755
  if stat(path) then return true end
  -- build list of components to create
  local stack = {}
  local cur = path
  while cur and cur ~= "" and not stat(cur) do
    stack[#stack + 1] = cur
    cur = cur:match("^(.+)/[^/]+$")
  end
    -- create from top down
    for i = #stack, 1, -1 do
      mkdir(stack[i], mode)
    end
    return stat(path) ~= nil
end

local function write_all(path, data)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then mkdir_p(dir) end
  local fd = open(path, "w")
  if not fd then return false end
  write(fd, data)
  close(fd)
  return true
end

-- write file with mkdir_p for parents
local function write_file(path, data, mode)
  mode = mode or 493
  local dir = path:match("^(.+)/[^/]+$")
  if dir then mkdir_p(dir, mode) end
  local fd = open(path, "w")
  if not fd then return false end
  write(fd, data)
  close(fd)
  if mode then chmod(path, mode) end
  return true
end

local function file_exists(path)
  return stat(path) ~= nil
end

local function split_csv(s)
  local t = {}
  if not s or s == "" then return t end
  for item in s:gmatch("[^" .. SEP .. "]+") do
    t[#t + 1] = item:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return t
end

-- ---- FNV-1a ----
-- Try libcrypto first, then libbase; fall back to inline implementation.
local fnv1a
do
  local ok, crypto = pcall(require, "libcrypto")
  if ok and crypto and crypto.fnv1a then
    fnv1a = crypto.fnv1a
  else
    local ok2, libbase = pcall(require, "libbase")
    if ok2 and libbase and libbase.fnv1a then
      fnv1a = libbase.fnv1a
    else
      -- Inline fallback (16-bit-split multiply to avoid float precision loss)
      fnv1a = function(data)
      local h = 0x811c9dc5
      for i = 1, #data do
        h = bit.bxor(h, string.byte(data, i))
        local lo = h % 0x10000
        local hi = (h - lo) / 0x10000
        local plo = 0x01000193 % 0x10000
        local phi = (0x01000193 - plo) / 0x10000
        local r = lo * plo + ((lo * phi + hi * plo) % 0x10000) * 0x10000
        h = r % 0x100000000
      end
      return string.format("%08x", h)
    end
    end
  end
end

-- ---- version compare ----
local function ver_split(v)
  local maj, min, pat = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if maj then return tonumber(maj), tonumber(min), tonumber(pat) end
  return nil
end

local function ver_cmp(a, b)
  local am, ai, ap = ver_split(a)
  local bm, bi, bp = ver_split(b)
  if not am or not bm then return 0 end
  if am ~= bm then return am < bm and -1 or 1 end
  if ai ~= bi then return ai < bi and -1 or 1 end
  if ap ~= bp then return ap < bp and -1 or 1 end
  return 0
end

-- version_satisfies: "" or "*" -> true; ops: >= > <= < = ~> (compatible)
local function version_satisfies(installed, constraint)
  if not constraint or constraint == "" or constraint == "*" then return true end
  local op, ver = constraint:match("^(>=?|<=?|=|~>?)%s*(.+)$")
  if not op then
    -- bare name -> exact match
    return installed == constraint
  end
  local c = ver_cmp(installed, ver)
  if op == ">=" then return c >= 0
  elseif op == ">" then return c > 0
  elseif op == "<=" then return c <= 0
  elseif op == "<" then return c < 0
  elseif op == "=" or op == "==" then return c == 0
  elseif op == "~>" then
    -- compatible: same major, installed >= constraint
    local am, ai, ap = ver_split(installed)
    local bm, bi, bp = ver_split(ver)
    if am ~= bm then return false end
    return c >= 0
  end
  return false
end

-- ---- DB operations ----

local function db_path(name)
  return DB_DIR .. "/" .. name
end

local function read_db(name)
  local data = read_all(db_path(name))
  if not data then return nil end
  local db = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^([^=]+)%s*=%s*(.+)$")
    if k then db[k] = v end
  end
  return db
end

local function write_db(name, db)
  mkdir_p(DB_DIR, 493)
  local parts = {}
  for k, v in pairs(db) do
    parts[#parts + 1] = k .. "=" .. v
  end
  return write_all(db_path(name), table.concat(parts, "\n") .. "\n")
end

local function delete_db(name)
  local path = db_path(name)
  unlink(path)
end

local function list_installed()
  local entries = readdir(DB_DIR)
  if not entries then return {} end
  local pkgs = {}
  for _, e in ipairs(entries) do
    if not e.is_dir or e.name:sub(1, 1) ~= "." then
      pkgs[#pkgs + 1] = e.name
    end
  end
  table.sort(pkgs)
  return pkgs
end

-- find which package owns a given file path
local function find_file_owner(target_path)
  local pkgs = list_installed()
  for _, name in ipairs(pkgs) do
    local db = read_db(name)
    if db and db.installed_files then
      for _, f in ipairs(split_csv(db.installed_files)) do
        if f == target_path then return name end
      end
    end
  end
  return nil
end

-- check if a package is installed
local function is_installed(name)
  return file_exists(db_path(name))
end

-- ---- .cone parsing (length-prefixed binary-safe) ----

local function parse_pine(data)
  local manifest = {}
  local files = {}
  local chunks = {} -- hook chunks keyed by hook name
  local pos = 1
  local dlen = #data

  -- expect ---PINEPKG v1--- (plain find: dashes are literal, not pattern quantifiers)
  local he, hs = data:find("---PINEPKG v1---", pos, true)
  if not hs or he ~= 1 then return nil, "invalid package format (missing header)" end
  pos = hs + 1

  -- read manifest fields until ---END MANIFEST---
  while pos <= dlen do
    -- find next line
    local le = data:find("\n", pos)
    local line
    if le then
      line = data:sub(pos, le - 1)
      pos = le + 1
    else
      line = data:sub(pos)
      pos = dlen + 1
    end
    if line == "---END MANIFEST---" then
      break
    end
    local k, v = line:match("^([^=]+)%s*=%s*(.*)$")
    if k then manifest[k] = v end
  end

  -- parse hooks from manifest strings
  for _, hk in ipairs({"preinst", "postinst", "prerem", "postrem"}) do
    if manifest[hk] and manifest[hk] ~= "" then
      chunks[hk] = manifest[hk]
    end
  end

  -- read FILE entries (length-prefixed: exactly size bytes follow each header)
  while pos <= dlen do
    -- check for ---FILE at current position (we're always at a block boundary)
    if data:sub(pos, pos + 7) ~= "---FILE " then break end
    local fe = pos + 7 -- past "---FILE "
    -- find end of header line
    local hline_end = data:find("\n", fe + 1)
    if not hline_end then return nil, "malformed FILE header (no newline)" end
    local hline = data:sub(fe + 1, hline_end - 1)
    pos = hline_end + 1 -- now pointing at start of content bytes

    -- strip trailing --- delimiter (last 3 chars)
    if hline:sub(-3) ~= "---" then
      return nil, "malformed FILE header (no --- delimiter): " .. hline
    end
    hline = hline:sub(1, -4)

    local fpath, fmode, fsize_s, fchk, ftype = hline:match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not fpath then return nil, "bad FILE header fields: " .. hline end
    local fsize = tonumber(fsize_s)
    if not fsize then return nil, "bad file size: " .. fsize_s end

    -- extract exactly fsize raw bytes
    if pos + fsize - 1 > dlen then
      return nil, "truncated content for " .. fpath .. " (need " .. fsize .. " bytes)"
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

  -- validate required fields
  if not manifest.name then return nil, "missing package name" end
  if not manifest.version then return nil, "missing package version" end
  if not manifest.files then return nil, "missing files count" end

  return {
    manifest = manifest,
    files = files,
    chunks = chunks,
  }
end

-- read and parse a .cone file
local function read_cone_file(path)
  local data = read_all(path)
  if not data then return nil, "cannot read " .. path end
  return parse_pine(data)
end

-- ---- Repo index ----

local function parse_repo_index(data)
  local pkgs = {}
  -- split by --- on its own line
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
      pkgs[pkg.name] = pkg
    end
  end
  return pkgs
end

local function load_repo_index()
  local data = read_all(REPO_INDEX)
  if not data then return {} end
  -- validate header
  local first_line = data:match("([^\n]+)")
  if first_line ~= "---PINEINDEX v1---" then return {} end
  return parse_repo_index(data)
end

-- find .cone file path for a package from repo
local function find_repo_pkg(name, version)
  local index = load_repo_index()
  local pkg = index[name]
  if not pkg then return nil, "package " .. name .. " not found in repo" end
  if version and pkg.version ~= version then
    -- check if repo version satisfies
    if not version_satisfies(pkg.version, ">=" .. version) then
      return nil, "repo version " .. pkg.version .. " does not match required " .. version
    end
  end
  -- look for the .cone file in REPO_DIR
  local cone_file = pkg.file or (name .. "-" .. pkg.version .. ".cone")
  local path = REPO_DIR .. "/" .. cone_file
  if not file_exists(path) then
    -- try name-version.cone pattern
    local entries = readdir(REPO_DIR)
    if entries then
      for _, e in ipairs(entries) do
        if e.name:match("^" .. name:gsub("%-", "%%-") .. "%-.*%.cone$") then
          path = REPO_DIR .. "/" .. e.name
          break
        end
      end
    end
  end
  if not file_exists(path) then
    -- backward compat: try .pine extension
    local pine_file = pkg.file and pkg.file:gsub("%.cone$", ".pine") or (name .. "-" .. pkg.version .. ".pine")
    local pine_path = REPO_DIR .. "/" .. pine_file
    if file_exists(pine_path) then
      path = pine_path
    end
  end
  if not file_exists(path) then
    return nil, "cone file not found for " .. name
  end
  return path, false
end

-- Download .cone from remote repo via HTTP, save to REPO_DIR
-- Returns (path, was_fetched) or (nil, error)
local function fetch_cone_http(name, version)
  local index = load_repo_index()
  local pkg = index[name]
  if not pkg then return nil, "package " .. name .. " not found in repo index" end

  local filename = pkg.file or (name .. "-" .. pkg.version .. ".cone")
  local url = REPO_BASE .. "/" .. filename

  msg("fetching " .. filename .. " from repo via AF_HTTP...")
  local data, ferr = fetch_url_afhttp(url)
  if not data then
    return nil, "failed to download " .. filename .. ": " .. tostring(ferr)
  end

  if #data == 0 then
    return nil, "downloaded package is empty"
  end

  -- Save to REPO_DIR
  mkdir_p(REPO_DIR)
  local path = REPO_DIR .. "/" .. filename
  if not write_file(path, data) then
    return nil, "failed to write " .. path
  end

  fetched_cones[path] = true
  return path, true
end

-- ---- hooks ----

local function run_hook(pkg_name, hook_name, code_str, stage_dir)
  if flag_nohook then return true end
  if not load then
    err("hooks disabled (no load)")
    return true
  end
  if not code_str or code_str == "" then return true end

  -- build restricted environment
  local env = {
    string = string,
    table = table,
    math = math,
    open = open,
    read = read,
    write = write,
    close = close,
    stat = stat,
    mkdir = mkdir,
    unlink = unlink,
    rename = rename,
    readdir = readdir,
    PKG_NAME = pkg_name,
    HOOK = hook_name,
    PKG_STAGE = stage_dir or "",
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      write(1, table.concat(parts, "\t") .. "\n")
    end,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    pairs = pairs,
    ipairs = ipairs,
    pcall = pcall,
    error = error,
  }
  setmetatable(env, { __index = _G })

  local fn, compile_err = load(code_str, "=" .. hook_name, "t", env)
  if not fn then
    err("hook compile error (" .. hook_name .. "): " .. tostring(compile_err))
    return false
  end

  local ok, run_err = pcall(fn)
  if not ok then
    err("hook runtime error (" .. hook_name .. "): " .. tostring(run_err))
    return false
  end
  return true
end

-- ---- install ----

local install_depth = 0  -- track recursive depth for cleanup

local function do_install(target, resolved_set)
  resolved_set = resolved_set or {}
  local name, version, force_dep

  install_depth = install_depth + 1
  local depth_at_entry = install_depth

  local ok, install_err = pcall(function()

  -- determine if target is a .cone/.pine file or a package name
  if target:match("%.cone$") or target:match("%.pine$") then
    -- local file
    local pkg, err = read_cone_file(target)
    if not pkg then die("parse error: " .. tostring(err)) end
    name = pkg.manifest.name
    version = pkg.manifest.version

    -- version check
    local old_db = read_db(name)
    if old_db and old_db.version and not flag_force then
      local cmp = ver_cmp(old_db.version, version)
      if cmp >= 0 then
        msg(name .. " " .. old_db.version .. " is already up to date")
        return
      end
    end

    -- dep resolution
    local deps = split_csv(pkg.manifest.deps)
    for _, dep_spec in ipairs(deps) do
      local dep_name, dep_con = dep_spec:match("^([^@]+)@?(.*)$")
      if dep_con == "" then dep_con = nil end
      if not resolved_set[dep_name] then
        resolved_set[dep_name] = true
        if is_installed(dep_name) then
          local dep_db = read_db(dep_name)
          if dep_db and dep_db.version and dep_con then
            if not version_satisfies(dep_db.version, dep_con) then
              msg("dependency " .. dep_name .. " version mismatch, reinstalling...")
              do_install(dep_name, resolved_set)
            end
          end
        else
          msg("installing dependency: " .. dep_name)
          do_install(dep_name, resolved_set)
        end
      end
    end

    -- conflict check
    for _, f in ipairs(pkg.files) do
      local owner = find_file_owner(f.path)
      if owner and owner ~= name and not flag_force then
        die("file " .. f.path .. " is owned by " .. owner .. " (use --force)")
      end
    end

    -- backup conffiles
    local conffiles = split_csv(pkg.manifest.conffiles)
    if old_db and #conffiles > 0 then
      mkdir_p(CONF_DIR, 493)
      for _, cf in ipairs(conffiles) do
        local basename = cf:match("([^/]+)$")
        local bak = CONF_DIR .. "/" .. name .. "." .. basename
        local data = read_all(cf)
        if data then write_all(bak, data) end
      end
    end

    if flag_dryrun then
      msg("[dry-run] would install " .. name .. " " .. version .. " (" .. #pkg.files .. " files)")
      for _, f in ipairs(pkg.files) do
        msg("  " .. f.path)
      end
      return
    end

    -- extract to staging
    local stage_base = STAGE_DIR .. "/" .. name
    for _, f in ipairs(pkg.files) do
      local stage_path = stage_base .. f.path
      write_file(stage_path, f.content, f.mode)
    end

    -- preinst hook
    run_hook(name, "preinst", pkg.chunks.preinst, stage_base)

    -- place files
    for _, f in ipairs(pkg.files) do
      local stage_path = stage_base .. f.path
      local target_path = f.path
      local data = read_all(stage_path)
      if data then
        mkdir_p(target_path:match("^(.+)/[^/]+$") or "/", 493)
        write_file(target_path, data, f.mode)
      end
    end

    -- postinst hook
    run_hook(name, "postinst", pkg.chunks.postinst, stage_base)

    -- write DB entry (include hook chunks for removal hooks)
    local file_paths = {}
    for _, f in ipairs(pkg.files) do file_paths[#file_paths + 1] = f.path end
    local db = {
      name = name,
      version = version,
      arch = pkg.manifest.arch or "any",
      essential = pkg.manifest.essential or "",
      maintainer = pkg.manifest.maintainer or "",
      description = pkg.manifest.description or "",
      license = pkg.manifest.license or "",
      deps = pkg.manifest.deps or "",
      provides = pkg.manifest.provides or "",
      conffiles = pkg.manifest.conffiles or "",
      installed_files = table.concat(file_paths, SEP),
      installed_at = tostring(time()),
      prerem = pkg.manifest.prerem or "",
      postrem = pkg.manifest.postrem or "",
    }
    if not write_db(name, db) then
      die("failed to write package database for " .. name .. " (check permissions on " .. DB_DIR .. ")")
    end

    -- cleanup staging
    for _, f in ipairs(pkg.files) do
      unlink(STAGE_DIR .. "/" .. name .. f.path)
    end

    msg("installed " .. name .. " " .. version .. " (" .. #pkg.files .. " files)")

  else
    -- repo install by name
    -- version check first if installed
    local old_db = read_db(target)
    if old_db and old_db.version and not flag_force then
      -- check if repo has newer
      local index = load_repo_index()
      local repo_pkg = index[target]
      if repo_pkg then
        local cmp = ver_cmp(old_db.version, repo_pkg.version)
        if cmp >= 0 then
          msg(target .. " " .. old_db.version .. " is already up to date")
          return
        end
      end
    end

    -- Try local cache first, then fetch from remote (refresh index if needed)
    local pine_path, find_err = find_repo_pkg(target)
    if not pine_path then
      fetch_repo_index()
      pine_path, find_err = find_repo_pkg(target)
    end
    if not pine_path then
      -- Not cached locally — fetch via HTTP
      local fetch_path, fetch_err = fetch_cone_http(target)
      if not fetch_path then
        die(tostring(fetch_err or find_err))
      end
      pine_path = fetch_path
    end
    do_install(pine_path, resolved_set)
  end

  end) -- end pcall

  install_depth = install_depth - 1

  -- At top-level install: clean up fetched .cone files (unless --keep-cache)
  if depth_at_entry == 1 and not flag_keepcache then
    for path, _ in pairs(fetched_cones) do
      unlink(path)
    end
    fetched_cones = {}
  end

  if not ok then error(install_err, 0) end
end

-- ---- remove ----

local function do_remove(name)
  local db = read_db(name)
  if not db then die("package " .. name .. " is not installed") end

  if db and db.essential == "yes" and not flag_force then
    die(name .. " is an essential package (use --force to remove)")
  end
  if db and db.essential == "yes" and flag_force then
    msg("warning: removing essential package " .. name .. " — system may not boot")
  end

  -- reverse-dep check
  local pkgs = list_installed()
  for _, other in ipairs(pkgs) do
    if other ~= name then
      local odb = read_db(other)
      if odb and odb.deps then
        for _, dep_spec in ipairs(split_csv(odb.deps)) do
          local dep_name = dep_spec:match("^([^@]+)@?.*$")
          if dep_name == name and not flag_force then
            die("required by " .. other .. " (use --force)")
          end
        end
      end
    end
  end

  -- prerem hook (need to read hook code from the package's original manifest)
  -- For simplicity, hooks are stored in DB or we skip if not available
  -- We store hook code in the DB as well for removal
  local prerem_code = db.prerem
  local postrem_code = db.postrem

  if flag_dryrun then
    msg("[dry-run] would remove " .. name)
    local files = split_csv(db.installed_files)
    for _, f in ipairs(files) do
      local owner = find_file_owner(f)
      if owner == name then
        msg("  " .. f)
      end
    end
    return
  end

  run_hook(name, "prerem", prerem_code, nil)

  -- remove files
  local files = split_csv(db.installed_files)
  for _, f in ipairs(files) do
    local owner = find_file_owner(f)
    if owner == name then
      unlink(f)
    end
  end

  run_hook(name, "postrem", postrem_code, nil)

  -- conffiles cleanup
  local conffiles = split_csv(db.conffiles)
  for _, cf in ipairs(conffiles) do
    local basename = cf:match("([^/]+)$")
    local bak = CONF_DIR .. "/" .. name .. "." .. basename
    local current = read_all(cf)
    local backup = read_all(bak)
    if current and backup and current == backup then
      unlink(cf)
    end
    unlink(bak)
  end

  -- delete DB
  delete_db(name)
  msg("removed " .. name)
end

-- ---- list ----

local function do_list()
  local pkgs = list_installed()
  if #pkgs == 0 then
    msg("no packages installed")
    return
  end
  for _, name in ipairs(pkgs) do
    local db = read_db(name)
    local ver = db and db.version or "?"
    local desc = db and db.description or ""
    local nfiles = 0
    if db and db.installed_files then
      for _ in db.installed_files:gmatch("[^" .. SEP .. "]+") do nfiles = nfiles + 1 end
    end
    local line = string.format("%-20s %-12s [%d files]", name, ver, nfiles)
    if desc ~= "" then
      line = line .. " " .. desc
    end
    write(1, line .. "\n")
  end
end

-- ---- files ----

local function do_files(name)
  local db = read_db(name)
  if not db then die("package " .. name .. " is not installed") end
  local files = split_csv(db.installed_files)
  for _, f in ipairs(files) do
    write(1, f .. "\n")
  end
end

-- ---- owns ----

local function do_owns(path)
  local owner = find_file_owner(path)
  if owner then
    msg(path .. " is owned by " .. owner)
  else
    msg(path .. " is not owned by any package")
  end
end

-- ---- info ----

local function do_info(name)
  local db = read_db(name)
  if not db then die("package " .. name .. " is not installed") end
  local fields = {"name", "version", "arch", "maintainer", "description", "license", "deps", "provides", "conffiles"}
  for _, f in ipairs(fields) do
    if db[f] and db[f] ~= "" then
      write(1, f .. ": " .. db[f] .. "\n")
    end
  end
  local nfiles = 0
  if db.installed_files then
    for _ in db.installed_files:gmatch("[^" .. SEP .. "]+") do nfiles = nfiles + 1 end
  end
  write(1, "files: " .. nfiles .. "\n")
  if db.installed_at then
    write(1, "installed_at: " .. db.installed_at .. "\n")
  end
end

-- ---- search ----

local function do_search(pattern)
  local index = load_repo_index()
  local found = false
  local names = {}
  for name, _ in pairs(index) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local pkg = index[name]
    if name:find(pattern, 1, true) or (pkg.desc and pkg.desc:find(pattern, 1, true)) then
      local line = string.format("%-20s %-12s %s", name, pkg.version or "?", pkg.desc or "")
      write(1, line .. "\n")
      found = true
    end
  end
  if not found then
    msg("no matches for '" .. pattern .. "'")
  end
end

-- ---- update (fetch remote index) ----

-- Fetch remote PINEINDEX via AF_HTTP socket (no raw http global, kernel provides external HTTP via AF_HTTP)
-- Returns true on success, nil+err on failure.
local function fetch_url_afhttp(url)
  local fd, ferr = socket(AF_HTTP, SOCK_STREAM, 0)
  if not fd then return nil, "socket: " .. tostring(ferr) end
  local ok, cerr = connect(fd, url)
  if not ok then close(fd); return nil, "connect: " .. tostring(cerr) end
  local ok2, serr = send(fd, "")
  if not ok2 then close(fd); return nil, "send: " .. tostring(serr) end
  local data, rerr = recv(fd, 65536)
  close(fd)
  if not data then return nil, rerr or "recv failed" end
  local body = data:match("\r\n\r\n(.*)")
  if body then return body else return data end
end

local function fetch_repo_index()
  local url = REPO_BASE .. "/PINEINDEX"
  local data, err = fetch_url_afhttp(url)
  if not data then
    return nil, "failed to fetch PINEINDEX from " .. url .. ": " .. tostring(err)
  end
  if #data == 0 then
    return nil, "downloaded PINEINDEX is empty"
  end
  -- validate header
  local first_line = data:match("([^\n]+)")
  if first_line ~= "---PINEINDEX v1---" then
    return nil, "invalid PINEINDEX header"
  end
  -- write to local index
  mkdir_p(REPO_DIR)
  if not write_all(REPO_INDEX, data) then
    return nil, "failed to write " .. REPO_INDEX
  end
  return true
end

local function do_update()
  -- fetch remote PINEINDEX if HTTP available
  local ok, ferr = fetch_repo_index()
  if not ok then
    err("could not fetch remote index: " .. tostring(ferr or "unknown"))
  end
  -- re-read the (possibly updated) index
  local index = load_repo_index()
  local count = 0
  for _ in pairs(index) do count = count + 1 end
  msg("repo index loaded: " .. count .. " packages")
end

-- ---- upgrade ----

local function do_upgrade(target)
  -- fetch remote index first so version compare uses latest data
  local ok, ferr = fetch_repo_index()
  if not ok then
    err("could not fetch remote index: " .. tostring(ferr or "unknown"))
  end

  if target then
    -- upgrade single package
    local db = read_db(target)
    if not db then
      die("package " .. target .. " is not installed")
    end
    do_install(target)
  else
    -- upgrade all installed packages
    local pkgs = list_installed()
    if #pkgs == 0 then
      msg("no packages installed; nothing to upgrade")
      return
    end
    local upgraded = 0
    for _, name in ipairs(pkgs) do
      local db = read_db(name)
      if db and db.version then
        local index = load_repo_index()
        local repo_pkg = index[name]
        if repo_pkg and repo_pkg.version then
          if ver_cmp(db.version, repo_pkg.version) < 0 then
            msg("upgrading " .. name .. " " .. db.version .. " -> " .. repo_pkg.version)
            do_install(name)
            upgraded = upgraded + 1
          else
            msg(name .. " is up to date")
          end
        end
      end
    end
    msg("upgrade complete: " .. upgraded .. " package(s) upgraded, "
        .. (#pkgs - upgraded) .. " up to date")
  end
end

-- ---- clean ----

local function do_clean()
  local entries = readdir(REPO_DIR)
  if not entries then
    msg("repo dir not found or empty")
    return
  end
  local removed = 0
  for _, e in ipairs(entries) do
    if e.name:match("%.cone$") and e.name ~= "PINEINDEX" then
      local path = REPO_DIR .. "/" .. e.name
      unlink(path)
      removed = removed + 1
    end
  end
  msg("cleaned " .. removed .. " cached package(s) from " .. REPO_DIR)
end

-- ---- usage ----

-- Reconstruct the package DB from repo cones for packages already on disk.
-- Use after an install that did not seed /var/lib/pine/db, or to recover a
-- missing/corrupted DB. Downloads each repo cone, and if its files are present
-- on the filesystem, writes a DB entry mirroring a native install.
local function do_rebuild_db()
  local index = load_repo_index()
  if not index or not next(index) then
    die("no repo index; run 'pine update' first")
  end
  local count = 0
  for name, pkg in pairs(index) do
    local path, ferr = fetch_cone_http(name, pkg.version)
    if not path then
      warn("rebuild-db: could not fetch " .. name .. ": " .. tostring(ferr))
    else
      local cone, perr = read_cone_file(path)
      if not cone then
        warn("rebuild-db: cannot parse " .. name .. ": " .. tostring(perr))
      else
        local first = cone.files[1]
        if first and stat(first.path) then
          local file_paths = {}
          for _, f in ipairs(cone.files) do
            file_paths[#file_paths + 1] = f.path
          end
          local db = {
            name = name,
            version = cone.manifest.version,
            arch = cone.manifest.arch or "any",
            essential = cone.manifest.essential or "",
            maintainer = cone.manifest.maintainer or "",
            description = cone.manifest.description or "",
            license = cone.manifest.license or "",
            deps = cone.manifest.deps or "",
            provides = cone.manifest.provides or "",
            conffiles = cone.manifest.conffiles or "",
            installed_files = table.concat(file_paths, SEP),
            installed_at = tostring(time()),
            prerem = cone.manifest.prerem or "",
            postrem = cone.manifest.postrem or "",
          }
          if write_db(name, db) then
            count = count + 1
            msg("rebuilt DB for " .. name .. " " .. cone.manifest.version)
          end
        end
      end
    end
  end
  msg("rebuild-db: wrote " .. count .. " package DB entries")
end

local function usage()
  write(1, "Usage: pine <command> [options]\n")
  write(1, "Commands:\n")
  write(1, "  install <name|file.cone>  Install a package\n")
  write(1, "  remove <name>            Remove an installed package\n")
  write(1, "  list                     List installed packages\n")
  write(1, "  files <name>             List files owned by a package\n")
  write(1, "  owns <path>              Show which package owns a file\n")
  write(1, "  info <name>              Show package information\n")
  write(1, "  search <pattern>         Search repo for packages\n")
  write(1, "  update                   Update repo index\n")
  write(1, "  upgrade [name]           Upgrade package(s)\n")
  write(1, "  clean                    Delete cached .cone files (keeps PINEINDEX)\n")
  write(1, "  rebuild-db               Reconstruct package DB from repo cones for installed packages\n")
  write(1, "Options:\n")
  write(1, "  --force                  Force operation\n")
  write(1, "  --no-hooks               Skip pre/post install/remove hooks\n")
  write(1, "  --dry-run                Show what would happen without doing it\n")
  write(1, "  --keep-cache             Retain .cone files after install\n")
end

-- ---- main dispatch ----

acquire_lock()
local ok, res = pcall(function()
  if cmd == "install" then
    if not args[2] then die("usage: pine install <name|file.cone>") end
    do_install(args[2])
  elseif cmd == "remove" then
    if not args[2] then die("usage: pine remove <name>") end
    do_remove(args[2])
  elseif cmd == "list" then
    do_list()
  elseif cmd == "files" then
    if not args[2] then die("usage: pine files <name>") end
    do_files(args[2])
  elseif cmd == "owns" then
    if not args[2] then die("usage: pine owns <path>") end
    do_owns(args[2])
  elseif cmd == "info" then
    if not args[2] then die("usage: pine info <name>") end
    do_info(args[2])
  elseif cmd == "search" then
    if not args[2] then die("usage: pine search <pattern>") end
    do_search(args[2])
  elseif cmd == "update" then
    do_update()
  elseif cmd == "upgrade" then
    do_upgrade(args[2])
  elseif cmd == "clean" then
    do_clean()
  elseif cmd == "rebuild-db" then
    do_rebuild_db()
  else
    usage()
  end
end)
release_lock()
if not ok then err(res); exit(1) end
