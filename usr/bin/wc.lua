-- wc: word, line, byte count
-- Usage: wc [file...]
local function read_all(fd)
    local chunks = {}
    while true do
        local data = read(fd, 65536)
        if not data or #data == 0 then break end
        chunks[#chunks+1] = data
    end
    return table.concat(chunks)
end

local function wc(data)
    local lines = 0
    local words = 0
    local bytes = #data
    local in_word = false
    for i = 1, #data do
        local c = data:sub(i, i)
        if c == "\n" then
            lines = lines + 1
        end
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            in_word = false
        else
            if not in_word then
                words = words + 1
                in_word = true
            end
        end
    end
    return lines, words, bytes
end

local args = {}
for i=1,select("#",...) do args[i]=select(i,...) end

-- no flags in simple wc, just files
if #args == 0 then
    -- stdin
    local data = read_all(0)
    local lines, words, bytes = wc(data)
    print(string.format("%7d %7d %7d", lines, words, bytes))
else
    local total_l, total_w, total_b = 0, 0, 0
    for _, path in ipairs(args) do
        local fd, err = open(path, 0)
        if not fd then
            print("wc: "..path..": "..err)
            exit(1)
        end
        local data = read_all(fd)
        close(fd)
        local lines, words, bytes = wc(data)
        total_l = total_l + lines
        total_w = total_w + words
        total_b = total_b + bytes
        print(string.format("%7d %7d %7d %s", lines, words, bytes, path))
    end
    if #args > 1 then
        print(string.format("%7d %7d %7d total", total_l, total_w, total_b))
    end
end
