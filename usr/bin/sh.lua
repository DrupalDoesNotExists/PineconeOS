--[[
  PineconeOS shell (sh) — xv6 sh port
  ===================================
  Supports: simple commands, pipelines (|), redirection (<, >, >>),
  background (&), sequential lists (;), quotes. Builtins: cd, exit.

  No fork: pipelines use spawn with fd wiring (child stdin/stdout set to
  pipe/file ends via the spawn fds table).
]]

-- ---- tokenizer ----

local function tokenize(line)
  local tokens = {}
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    elseif c == ">" and line:sub(i + 1, i + 1) == ">" then
      tokens[#tokens + 1] = ">>"
      i = i + 2
    elseif c:match("[|<>;&]") then
      tokens[#tokens + 1] = c
      i = i + 1
    elseif c == '"' or c == "'" then
      local quote, j, buf = c, i + 1, {}
      while j <= n and line:sub(j, j) ~= quote do
        buf[#buf + 1] = line:sub(j, j)
        j = j + 1
      end
      tokens[#tokens + 1] = table.concat(buf)
      i = j + 1
    else
      local j, buf = i, {}
      while j <= n and not line:sub(j, j):match("[%s|<>;&]") do
        buf[#buf + 1] = line:sub(j, j)
        j = j + 1
      end
      tokens[#tokens + 1] = table.concat(buf)
      i = j
    end
  end
  return tokens
end

-- ---- parser ----
-- Produces a list of commands. Each command is a list of pipeline stages.
-- Each stage: { argv = {...}, in = <file|nil>, out = <file|nil>, append = bool }

local function parse(tokens)
  local commands = {}   -- list of pipelines
  local pipeline = {}   -- current pipeline (list of stages)
  local stage = { argv = {} }
  local i, n = 1, #tokens

  local function push_stage()
    if #stage.argv > 0 or stage.stdin or stage.stdout then
      pipeline[#pipeline + 1] = stage
    end
    stage = { argv = {} }
  end
  local function push_pipeline()
    push_stage()
    if #pipeline > 0 then
      commands[#commands + 1] = pipeline
    end
    pipeline = {}
  end

  while i <= n do
    local t = tokens[i]
    if t == "|" then
      push_stage()
    elseif t == ";" then
      push_pipeline()
    elseif t == "&" then
      if #commands == 0 then push_pipeline() end
      commands[#commands].bg = true
    elseif t == "<" then
      i = i + 1
      stage.stdin = tokens[i]
    elseif t == ">" or t == ">>" then
      i = i + 1
      stage.stdout = tokens[i]
      stage.append = (t == ">>")
    else
      stage.argv[#stage.argv + 1] = t
    end
    i = i + 1
  end
  push_pipeline()
  return commands
end

-- ---- executor ----

local function run_stage(stage, stdin_fd, stdout_fd)
  -- spawn a single stage with optional stdin/stdout wiring
  local fds = {}
  if stdin_fd then fds[0] = stdin_fd end
  if stdout_fd then fds[1] = stdout_fd end
  -- resolve command name to a path via PATH env var (no fork: spawn loads a file)
  local cmd = stage.argv[1]
  local path = cmd
  if not cmd:find("/", 1, true) then
    local path_env = getenv("PATH") or "/bin:/usr/bin"
    for dir in path_env:gmatch("[^:]+") do
      local cand = dir .. "/" .. cmd .. ".lua"
      local f = open(cand, "r")
      if f then close(f); path = cand; break end
    end
  end
  local pid = spawn(path, table.unpack(stage.argv, 2), fds)
  return pid
end

local function run_pipeline(pipeline)
  local n = #pipeline
  local pids = {}
  local prev_read = nil

  for i, stage in ipairs(pipeline) do
    -- resolve redirections
    local in_fd, out_fd = prev_read, nil
    if stage.stdin then
      local f = open(stage.stdin, "r")
      if f then in_fd = f end
    end
    if stage.stdout then
      local f = open(stage.stdout, stage.append and "a" or "w")
      if f then out_fd = f end
    end

    -- create pipe to next stage if not last
    local next_read = nil
    if i < n then
      local r, w = pipe()
      if r then
        next_read = r
        if not out_fd then out_fd = w end
      end
    end

    local pid = run_stage(stage, in_fd, out_fd)
    if pid then pids[#pids + 1] = pid end

    -- close parent's copies
    if prev_read then close(prev_read) end
    if out_fd and i < n then close(out_fd) end
    prev_read = next_read
  end
  if prev_read then close(prev_read) end

  -- wait for foreground pipeline
  if not pipeline.bg then
    for _, pid in ipairs(pids) do
      waitpid(pid)
    end
  end
end

-- ---- builtins ----

local function run_builtin(argv)
  if argv[1] == "cd" then
    local dir = argv[2] or "/"
    local ok = chdir(dir)
    if not ok then print("sh: cd: " .. dir .. ": no such directory") end
    return true
  elseif argv[1] == "exit" then
    exit(tonumber(argv[2]) or 0)
    return true
  elseif argv[1] == "source" or argv[1] == "." then
    source_file(argv[2])
    return true
  end
  return false
end

-- ---- main loop ----

local function getcwd_str()
  local c = getcwd()
  return c or "/"
end

-- Run a single input line (used by the interactive loop and by source).
local function run_line(line)
  line = line:gsub("\r?\n$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return end
  local commands = parse(tokenize(line))
  for _, pipeline in ipairs(commands) do
    -- builtins run in the shell itself
    local first = pipeline[1]
    if first and #first.argv > 0 and run_builtin(first.argv) then
      -- done
    else
      run_pipeline(pipeline)
    end
  end
end

-- Source a startup file (run its lines as shell commands).
function source_file(path)
  if not path then return false end
  local f = open(path, "r")
  if not f then return false end
  local data = read(f, 1048576)
  close(f)
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do
      run_line(line)
    end
  end
  return true
end

print("PineconeOS sh")

-- Source system-wide and user rc files at startup.
source_file("/etc/profile")
local home = getenv("HOME")
if home then source_file(home .. "/.shrc") end

while true do
  write(1, getcwd_str() .. "> ")
  local line = read(0, 4096)
  if not line then break end
  run_line(line)
end