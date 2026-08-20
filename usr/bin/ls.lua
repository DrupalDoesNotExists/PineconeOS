-- ls: list directory contents
-- Usage: ls [-l] [-a] [path...]
local function parse_args(args)
    local flags = {long=false, all=false}
    local paths = {}
    for i=1,#args do
        local a = args[i]
        if a == "-l" then
            flags.long = true
        elseif a == "-a" then
            flags.all = true
        elseif a == "-la" or a == "-al" then
            flags.long = true
            flags.all = true
        elseif a:sub(1,1) == "-" and #a > 1 then
            for j=2,#a do
                local c = a:sub(j,j)
                if c == "l" then flags.long = true
                elseif c == "a" then flags.all = true
                else
                    print("ls: unknown option: -"..c)
                    exit(1)
                end
            end
        else
            paths[#paths+1] = a
        end
    end
    if #paths == 0 then paths[1] = "." end
    return flags, paths
end

local function format_mode(mode)
    local t = "?"
    -- extract file type from mode (bits 12-15)
    local ft = math.floor(mode / 4096) % 16
    if ft == 8 then t = "-"
    elseif ft == 4 then t = "d"
    elseif ft == 10 then t = "l"
    elseif ft == 6 then t = "b"
    elseif ft == 2 then t = "c"
    elseif ft == 1 then t = "p"
    end
    -- permissions (lower 9 bits)
    local s = {}
    local function rwx8(v)
        s[#s+1] = (v >= 4) and "r" or "-"
        s[#s+1] = (v >= 2) and "w" or "-"
        s[#s+1] = ((v % 2) == 1) and "x" or "-"
    end
    -- owner (bits 6-8)
    rwx8(math.floor(mode / 64) % 8)
    -- group (bits 3-5)
    rwx8(math.floor(mode / 8) % 8)
    -- other (bits 0-2)
    rwx8(mode % 8)
    return t..table.concat(s)
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end
local flags, paths = parse_args(args)

local function ls_dir(path)
    local entries = readdir(path)
    if not entries then
        print("ls: cannot access '"..path.."': No such file or directory")
        exit(1)
    end
    -- sort entries by name
    table.sort(entries, function(a,b) return a.name < b.name end)
    for _, e in ipairs(entries) do
        local name = e.name
        if not flags.all and name:sub(1,1) == "." then
            -- skip hidden
        else
            if flags.long then
                local m = format_mode(e.mode)
                local sz = e.size or 0
                local suffix = ""
                if e.is_dir then suffix = "/" end
                print(m.."  "..sz.."\t"..name..suffix)
            else
                local suffix = ""
                if e.is_dir then suffix = "/" end
                print(name..suffix)
            end
        end
    end
end

for _, p in ipairs(paths) do
    local st = stat(p)
    if not st then
        print("ls: cannot access '"..p.."': No such file or directory")
        exit(1)
    end
    if st.type == "directory" and (#paths > 1) then
        print(p..":")
    end
    ls_dir(p)
end
