-- cp: copy files
-- Usage: cp <src> <dst>  OR  cp <src...> <dir>
local function usage()
    write(2, "usage: cp <source> <dest>\n")
    write(2, "       cp <source...> <dir>\n")
    exit(1)
end

local function read_file(path)
    local fd, err = open(path, 0)  -- O_RDONLY
    if not fd then
        write(2, "cp: cannot open '"..path.."': "..(err or "unknown error").."\n")
        exit(1)
    end
    local chunks = {}
    while true do
        local data = read(fd, 65536)
        if not data then break end
        if #data == 0 then break end
        chunks[#chunks+1] = data
    end
    close(fd)
    return table.concat(chunks)
end

local function write_file(path, data)
    local fd, err = open(path, "w")  -- kernel vfs.open uses string flags, not numeric O_*
    if not fd then
        write(2, "cp: cannot create '"..path.."': "..(err or "unknown error").."\n")
        exit(1)
    end
    local off = 1
    while off <= #data do
        local chunk = data:sub(off, off + 65535)
        write(fd, chunk)
        off = off + 65536
    end
    close(fd)
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end
if #args < 2 then usage() end

local dst = args[#args]
local srcs = {}
for i=1,#args-1 do srcs[#srcs+1] = args[i] end

-- Check if dst is a directory
local dst_st = stat(dst)
if #srcs > 1 then
    -- multiple sources: dst must be a directory (or we can't handle file->file multiple)
    if not dst_st or dst_st.type ~= "directory" then
        write(2, "cp: target '"..dst.."' is not a directory\n")
        exit(1)
    end
end

for _, src in ipairs(srcs) do
    local src_st = stat(src)
    if not src_st then
        write(2, "cp: cannot stat '"..src.."': No such file or directory\n")
        exit(1)
    end
    local dest_path
    if #srcs > 1 or (dst_st and dst_st.type == "directory") then
        -- copy into directory
        local base = src:match("([^/]+)$") or src
        dest_path = dst.."/"..base
    else
        dest_path = dst
    end
    local data = read_file(src)
    write_file(dest_path, data)
end
