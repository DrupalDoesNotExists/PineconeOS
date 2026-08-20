-- head: output first N lines
-- Usage: head [-n N] [file]
local function usage()
    print("usage: head [-n lines] [file]")
    exit(1)
end

local function read_all(fd)
    local chunks = {}
    while true do
        local data = read(fd, 65536)
        if not data or #data == 0 then break end
        chunks[#chunks+1] = data
    end
    return table.concat(chunks)
end

local function head_lines(data, n)
    local count = 0
    local pos = 1
    while count < n and pos <= #data do
        local nl = data:find("\n", pos, true)
        if nl then
            write(1, data:sub(pos, nl))
            pos = nl + 1
        else
            write(1, data:sub(pos))
            pos = #data + 1
        end
        count = count + 1
    end
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end

local nlines = 10
local file = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "-n" then
        i = i + 1
        if i > #args then usage() end
        nlines = tonumber(args[i])
        if not nlines then
            print("head: invalid number: '"..args[i].."'")
            usage()
        end
    elseif a:sub(1,2) == "-n" then
        nlines = tonumber(a:sub(3))
        if not nlines then
            print("head: invalid number: '"..a:sub(3).."'")
            usage()
        end
    elseif a == "-" then
        file = file  -- stdin, already nil
    elseif a:sub(1,1) == "-" and #a > 1 then
        -- combine flags like -5
        local num = tonumber(a:sub(2))
        if num then
            nlines = num
        else
            print("head: unknown option: "..a)
            usage()
        end
    else
        file = a
    end
    i = i + 1
end

local data
if file then
    local fd, err = open(file, 0)
    if not fd then
        print("head: "..file..": "..err)
        exit(1)
    end
    data = read_all(fd)
    close(fd)
else
    data = read_all(0)
end

head_lines(data, nlines)
