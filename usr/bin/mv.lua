-- mv: move files
-- Usage: mv <src> <dst>  OR  mv <src...> <dir>
local function usage()
    write(2, "usage: mv <source> <dest>\n")
    write(2, "       mv <source...> <dir>\n")
    exit(1)
end

local function read_file(path)
    local fd, err = open(path, 0)
    if not fd then
        write(2, "mv: cannot open '"..path.."': "..(err or "unknown error").."\n")
        exit(1)
    end
    local chunks = {}
    while true do
        local data = read(fd, 65536)
        if not data or #data == 0 then break end
        chunks[#chunks+1] = data
    end
    close(fd)
    return table.concat(chunks)
end

local function write_file(path, data)
    local fd, err = open(path, "w")
    if not fd then
        write(2, "mv: cannot create '"..path.."': "..(err or "unknown error").."\n")
        exit(1)
    end
    local off = 1
    while off <= #data do
        write(fd, data:sub(off, off + 65535))
        off = off + 65536
    end
    close(fd)
end

local function rm_file(path)
    unlink(path)
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end
if #args < 2 then usage() end

local dst = args[#args]
local srcs = {}
for i=1,#args-1 do srcs[#srcs+1] = args[i] end

local dst_st = stat(dst)
if #srcs > 1 and (not dst_st or dst_st.type ~= "directory") then
    write(2, "mv: target '"..dst.."' is not a directory\n")
    exit(1)
end

for _, src in ipairs(srcs) do
    local src_st = stat(src)
    if not src_st then
        write(2, "mv: cannot stat '"..src.."': No such file or directory\n")
        exit(1)
    end
    local dest_path
    if #srcs > 1 or (dst_st and dst_st.type == "directory") then
        local base = src:match("([^/]+)$") or src
        dest_path = dst.."/"..base
    else
        dest_path = dst
    end
    -- try rename first
    local ok, err = rename(src, dest_path)
    if not ok then
        -- fallback: copy + remove
        local data = read_file(src)
        write_file(dest_path, data)
        rm_file(src)
    end
end
