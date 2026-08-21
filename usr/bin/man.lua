-- man: display manual pages for PineconeOS
-- Usage: man <page>             show <page> (search all sections)
--        man <section> <page>   show <page> in the given section
--        man -l                 list all available pages
-- Reads /usr/share/man/man<section>/<page>.<section> and prints with paging.

local SECTIONS = { 1, 2, 3, 4, 5, 6, 7, 8 }

local function read_file(path)
  local fd = open(path, "r")
  if not fd then return nil end
  local chunks = {}
  while true do
    local data = read(fd, 4096)
    if not data or #data == 0 then break end
    chunks[#chunks + 1] = data
  end
  close(fd)
  return table.concat(chunks)
end

local function list_pages()
  local found = false
  for _, sec in ipairs(SECTIONS) do
    local dir = "/usr/share/man/man" .. sec
    local fd = readdir(dir)
    if fd then
      local pages = {}
      for _, entry in ipairs(fd) do
        if entry.name and entry.name:match("%." .. sec .. "$") then
          pages[#pages + 1] = entry.name:gsub("%." .. sec .. "$", "")
        end
      end
      table.sort(pages)
      if #pages > 0 then
        found = true
        print("Section " .. sec .. ":")
        for _, name in ipairs(pages) do
          print("  " .. name .. "(" .. sec .. ")")
        end
        print("")
      end
    end
  end
  if not found then
    print("man: no manual pages found in /usr/share/man")
  end
end

local function simple_pager(text)
  local lines = {}
  for line in text:gmatch("([^\n]*)\n?") do
    lines[#lines + 1] = line
  end
  local PAGE = 23
  local i = 1
  while i <= #lines do
    local stop = math.min(i + PAGE - 1, #lines)
    for j = i, stop do
      write(1, lines[j] .. "\n")
    end
    i = stop + 1
    if i <= #lines then
      write(1, "--More-- (press Enter, q to quit) ")
      local input = read(0, 256)
      if input and input:match("^q") then return end
    end
  end
end

local args = {}
for i = 1, select("#", ...) do args[i] = select(i, ...) end

if #args < 1 then
  print("usage: man <page>")
  print("       man <section> <page>")
  print("       man -l    (list available pages)")
  exit(1)
end

local page = args[1]
if page == "-l" or page == "--list" then
  list_pages()
  exit(0)
end

local section, name
if #args >= 2 and tonumber(args[1]) then
  section = tonumber(args[1])
  name = args[2]
else
  name = page
end

local candidates = {}
if section then
  candidates[#candidates + 1] = "/usr/share/man/man" .. section .. "/" .. name .. "." .. section
else
  for _, sec in ipairs(SECTIONS) do
    candidates[#candidates + 1] = "/usr/share/man/man" .. sec .. "/" .. name .. "." .. sec
  end
end

local content
for _, path in ipairs(candidates) do
  content = read_file(path)
  if content then break end
end

if not content or content == "" then
  print("No manual entry for " .. name .. (section and " in section " .. section or ""))
  print("Use 'man -l' to list available pages.")
  exit(1)
end

simple_pager(content)
exit(0)
