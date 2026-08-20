-- tail: output last N lines
-- Usage: tail [-n N] [file]
local function usage()
    print("usage: tail [-n lines] [file]")
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

local function split_lines(data)
    local lines = {}
    local pos = 1
    while pos <= #data do
        local nl = data:find("\n", pos, true)
        if nl then
            lines[#lines+1] = data:sub(pos, nl - 1)
            pos = nl + 1
        else
            if pos <= #data then
                lines[#lines+1] = data:sub(pos)
            end
            break
        end
    end
    return lines
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
            print("tail: invalid number: '"..args[i].."'")
            usage()
        end
    elseif a:sub(1,2) == "-n" then
        nlines = tonumber(a:sub(3))
        if not nlines then
            print("tail: invalid number: '"..a:sub(3).."'")
            usage()
        end
    elseif a == "-" then
        -- stdin
    elseif a:sub(1,1) == "-" and #a > 1 then
        local num = tonumber(a:sub(2))
        if num then
            nlines = num
        else
            print("tail: unknown option: "..a)
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
        print("tail: "..file..": "..err)
        exit(1)
    end
    data = read_all(fd)
    close(fd)
else
    data = read_all(0)
end

local lines = split_lines(data)
local start = #lines - nlines + 1
if start < 1 then start = 1 end
for j = start, #lines do
    write(1, lines[j].."\n")
end
