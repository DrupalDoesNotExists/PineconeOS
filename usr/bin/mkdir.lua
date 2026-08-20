-- mkdir: create directories
-- Usage: mkdir [-p] <path...>
local function usage()
    print("usage: mkdir [-p] <directory...>")
    exit(1)
end

local function mkdir_p(path)
    -- try mkdir first
    local ok = mkdir(path, 493)  -- 0755
    if ok then return true end
    -- check if already exists
    local st = stat(path)
    if st and st.type == "directory" then return true end
    return false
end

local function mkdir_parents(path)
    -- build path components, skip empty strings
    local parts = {}
    local cur = ""
    for part in (path .. "/"):gmatch("([^/]+)") do
        cur = cur .. "/" .. part
        mkdir_p(cur)
    end
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end

local parents = false
local paths = {}

for i=1,#args do
    local a = args[i]
    if a == "-p" then
        parents = true
    elseif a:sub(1,1) == "-" and #a > 1 then
        for j=2,#a do
            local c = a:sub(j,j)
            if c == "p" then parents = true
            else
                print("mkdir: unknown option: -"..c)
                usage()
            end
        end
    else
        paths[#paths+1] = a
    end
end

if #paths == 0 then usage() end

for _, p in ipairs(paths) do
    if parents then
        mkdir_parents(p)
    else
        local ok, err = mkdir(p, 493)
        if not ok then
            print("mkdir: cannot create directory '"..p.."': "..(err or "failed"))
            exit(1)
        end
    end
end
