-- rm: remove files/directories
-- Usage: rm [-r] [-f] <path...>
local function usage()
    print("usage: rm [-r] [-f] <file...>")
    exit(1)
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end

local recursive = false
local force = false
local paths = {}

for i=1,#args do
    local a = args[i]
    if a == "-r" or a == "-rf" or a == "-fr" then
        recursive = true
        force = true
    elseif a == "-f" then
        force = true
    elseif a:sub(1,1) == "-" and #a > 1 then
        for j=2,#a do
            local c = a:sub(j,j)
            if c == "r" then recursive = true
            elseif c == "f" then force = true
            else
                print("rm: unknown option: -"..c)
                usage()
            end
        end
    else
        paths[#paths+1] = a
    end
end

if #paths == 0 then usage() end

local function rm_path(p, recursive, force)
    local st = stat(p)
    if not st then
        if not force then
            print("rm: cannot remove '"..p.."': No such file or directory")
        end
        return
    end
    if st.type == "directory" then
        if not recursive then
            print("rm: cannot remove '"..p.."': Is a directory")
            exit(1)
        end
        -- recurse into directory
        local entries = readdir(p)
        if entries then
            for _, e in ipairs(entries) do
                if e.name ~= "." and e.name ~= ".." then
                    rm_path(p.."/"..e.name, true, force)
                end
            end
        end
        local ok, err = rmdir(p)
        if not ok and not force then
            print("rm: cannot remove '"..p.."': "..(err or "failed"))
        end
    else
        local ok, err = unlink(p)
        if not ok and not force then
            print("rm: cannot remove '"..p.."': "..(err or "failed"))
        end
    end
end

for _, p in ipairs(paths) do
    rm_path(p, recursive, force)
end
