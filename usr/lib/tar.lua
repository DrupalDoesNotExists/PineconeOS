--[[
  PineconeOS tar archive library
  ==============================
  Minimal ustar (POSIX tar) reader/writer in pure Lua, using only KNUCK
  syscalls (open/read/write/stat/readdir/mkdir/symlink). Used by pine for
  the .cone package format.

  Layout: 512-byte header blocks, data padded to 512, two zero blocks at end.
]]

local tar = {}

-- ---- helpers ----

local function oct(n, width)
  -- encode n as a zero-padded octal string of `width` chars
  local s = ""
  n = math.floor(n or 0)
  if n < 0 then n = 0 end
  repeat
    s = (n % 8) .. s
    n = math.floor(n / 8)
  until n == 0
  while #s < width do s = "0" .. s end
  return s
end

local function oct_to_num(s)
  local n = 0
  for i = 1, #s do
    local c = s:byte(i)
    if c >= 48 and c <= 55 then  -- '0'..'7'
      n = n * 8 + (c - 48)
    else
      break
    end
  end
  return n
end

local function pad512(n)
  local rem = n % 512
  if rem == 0 then return "" end
  return string.rep("\0", 512 - rem)
end

-- ---- header encode/decode ----

local function encode_header(entry)
  local name = entry.name or ""
  local prefix = ""
  if #name > 100 then
    -- split into prefix (155) + name (100)
    prefix = name:sub(1, #name - 100)
    name = name:sub(#name - 99)
  end
  local typeflag = entry.typeflag or "0"
  local size = entry.size or 0
  local mode = entry.mode or 0x1A4
  local mtime = entry.mtime or 0
  local linkname = entry.linkname or ""

  local function field(s, width)
    if #s >= width then return s:sub(1, width) end
    return s .. string.rep("\0", width - #s)
  end

  local h = field(name, 100)
  h = h .. field(oct(mode, 7) .. "\0", 8)
  h = h .. field(oct(0, 7) .. "\0", 8)          -- uid
  h = h .. field(oct(0, 7) .. "\0", 8)          -- gid
  h = h .. field(oct(size, 11) .. " ", 12)      -- size
  h = h .. field(oct(mtime, 11) .. " ", 12)     -- mtime
  h = h .. "        "                           -- checksum placeholder (8)
  h = h .. typeflag
  h = h .. field(linkname, 100)
  h = h .. "ustar\0" .. "00"                    -- magic + version
  h = h .. field("", 32)                        -- uname
  h = h .. field("", 32)                        -- gname
  h = h .. field(oct(0, 7) .. "\0", 8)          -- devmajor
  h = h .. field(oct(0, 7) .. "\0", 8)          -- devminor
  h = h .. field(prefix, 155)
  h = h .. field("", 12)                        -- pad to 512

  -- checksum: sum of bytes with checksum field as spaces
  local sum = 0
  for i = 1, 512 do
    local c = h:byte(i)
    if i >= 149 and i <= 156 then c = 32 end  -- checksum field = spaces
    sum = sum + (c or 0)
  end
  local cksum = oct(sum, 6) .. "\0 "
  h = h:sub(1, 148) .. cksum .. h:sub(157)
  return h
end

local function decode_header(block)
  local name = block:sub(1, 100):gsub("\0.*$", "")
  local size = oct_to_num(block:sub(125, 136))
  local typeflag = block:sub(157, 157)
  local linkname = block:sub(158, 257):gsub("\0.*$", "")
  local prefix = block:sub(346, 500):gsub("\0.*$", "")
  local mode = oct_to_num(block:sub(101, 108))
  if prefix ~= "" then name = prefix .. "/" .. name end
  return {
    name = name,
    size = size,
    typeflag = typeflag,
    linkname = linkname,
    mode = mode,
  }
end

-- ---- write ----

-- tar.create(entries, outpath)
--   entries: list of { name, path, typeflag?, linkname? }
--   For regular files, `path` is the source file to read.
--   For dirs, typeflag="5". For symlinks, typeflag="2" + linkname.
function tar.create(entries, outpath)
  local out = open(outpath, "w")
  if not out then return nil, "cannot open " .. outpath end

  local function write_block(data)
    write(out, data)
  end

  for _, e in ipairs(entries) do
    local typeflag = e.typeflag or "0"
    local size = 0
    local data = ""
    if typeflag == "0" then
      local f = open(e.path, "r")
      if not f then close(out) return nil, "cannot read " .. e.path end
      data = read(f, 65536) or ""
      close(f)
      size = #data
    end
    local hdr = encode_header({
      name = e.name, typeflag = typeflag, size = size,
      mode = e.mode, linkname = e.linkname,
    })
    write_block(hdr)
    if typeflag == "0" then
      write_block(data)
      write_block(pad512(size))
    end
  end

  -- two zero blocks = end of archive
  write_block(string.rep("\0", 512))
  write_block(string.rep("\0", 512))
  close(out)
  return true
end

-- ---- read ----

-- tar.extract(archive_path, dest)
--   Extracts all entries under `dest` (dest must exist).
function tar.extract(archive_path, dest)
  local f = open(archive_path, "r")
  if not f then return nil, "cannot open " .. archive_path end

  local function read_block()
    local d = read(f, 512)
    if not d or #d < 512 then return nil end
    return d
  end

  local count = 0
  while true do
    local block = read_block()
    if not block then break end
    -- end of archive: two zero blocks
    if block:find("[^\0]") == nil then
      -- consume the second zero block
      read_block()
      break
    end
    local e = decode_header(block)
    local target = dest .. "/" .. e.name
    if e.typeflag == "5" then
      mkdir(target)
    elseif e.typeflag == "2" then
      symlink(e.linkname, target)
    elseif e.typeflag == "0" then
      -- read data
      local data = ""
      local remaining = e.size
      while remaining > 0 do
        local chunk = read(f, math.min(remaining, 65536))
        if not chunk then break end
        data = data .. chunk
        remaining = remaining - #chunk
      end
      -- skip padding
      local pad = pad512(e.size)
      if #pad > 0 then read(f, #pad) end
      -- write file
      local dir = target:match("^(.*)/[^/]+$")
      if dir and dir ~= "" then mkdir(dir) end
      local w = open(target, "w")
      if w then
        write(w, data)
        close(w)
      end
    end
    count = count + 1
  end
  close(f)
  return count
end

-- tar.list(archive_path) -> list of { name, typeflag, size }
function tar.list(archive_path)
  local f = open(archive_path, "r")
  if not f then return nil, "cannot open " .. archive_path end
  local out = {}
  local function read_block()
    local d = read(f, 512)
    if not d or #d < 512 then return nil end
    return d
  end
  while true do
    local block = read_block()
    if not block then break end
    if block:find("[^\0]") == nil then read_block() break end
    local e = decode_header(block)
    out[#out + 1] = { name = e.name, typeflag = e.typeflag, size = e.size }
    if e.typeflag == "0" then
      local remaining = e.size
      while remaining > 0 do
        local chunk = read(f, math.min(remaining, 65536))
        if not chunk then break end
        remaining = remaining - #chunk
      end
      local pad = pad512(e.size)
      if #pad > 0 then read(f, #pad) end
    end
  end
  close(f)
  return out
end

-- tar.read_entry(archive_path, name) -> data string or nil
function tar.read_entry(archive_path, name)
  local f = open(archive_path, "r")
  if not f then return nil, "cannot open " .. archive_path end
  local function read_block()
    local d = read(f, 512)
    if not d or #d < 512 then return nil end
    return d
  end
  while true do
    local block = read_block()
    if not block then break end
    if block:find("[^\0]") == nil then read_block() break end
    local e = decode_header(block)
    if e.name == name and e.typeflag == "0" then
      local data = ""
      local remaining = e.size
      while remaining > 0 do
        local chunk = read(f, math.min(remaining, 65536))
        if not chunk then break end
        data = data .. chunk
        remaining = remaining - #chunk
      end
      close(f)
      return data
    end
    if e.typeflag == "0" then
      local remaining = e.size
      while remaining > 0 do
        local chunk = read(f, math.min(remaining, 65536))
        if not chunk then break end
        remaining = remaining - #chunk
      end
      local pad = pad512(e.size)
      if #pad > 0 then read(f, #pad) end
    end
  end
  close(f)
  return nil
end

return tar