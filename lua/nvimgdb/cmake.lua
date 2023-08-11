local uv = vim.loop
local log = require'nvimgdb.log'

local CMake = {}

---Select executables when editing command line
---@return string user decision
function CMake.select_executable()
  log.debug({"CMake.select_executable"})
  -- Identify the prefix of the required executable path: scan to the left until the nearest space
  local curcmd = vim.fn.getcmdline()
  local pref_end = vim.fn.getcmdpos() - 1
  local prefix = curcmd:sub(1, pref_end):match('.*%s(.*)')
  log.debug({"prefix", prefix})
  local execs = CMake.get_executables(prefix)
  if not next(execs) then
    print("No relevant executable detected")
    return curcmd
  end
  local msg = {"Select executable:"}
  local i = 1
  for exe, _ in pairs(execs) do
    msg[#msg+1] = i .. '. ' .. exe
    i = i + 1
  end
  local idx = vim.fn.inputlist(msg)
  if idx <= 0 or idx > #execs then
    return curcmd
  end
  local selection = execs[idx]
  vim.fn.setcmdpos(pref_end - #prefix + 1 + #selection)
  return curcmd:sub(1, pref_end - #prefix) .. selection .. curcmd:sub(pref_end + 1)
end

---Find executables with the given path prefix
---@param prefix string path prefix
---@return string[] paths of found executables
function CMake.find_executables(prefix)
  log.debug({'CMake.find_executables', prefix = prefix})
  local function is_executable(file_path)
    local stat = uv.fs_stat(file_path)
    if stat and stat.type == 'file' then
      return bit.band(stat.mode, 73) > 0   -- 73 == 0111
    end
    return false
  end
  if #prefix == 0 then
    prefix = './'
  end
  local prefix_path = uv.fs_realpath(prefix)
  local prefix_dir = vim.fs.dirname(prefix_path)
  if prefix:sub(#prefix):match('[/\\]') then
    prefix_path = prefix_path .. prefix:sub(#prefix)
  end
  local escaped_prefix_path = string.gsub(prefix_path, "[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")

  local progress_path = ''
  local found_executables = vim.fs.find(function(name, path)
    if path:find('[/\\]CMakeFiles[/\\]') then
      return false
    end
    if progress_path ~= path then
      print("Scanning " .. path)
      progress_path = path
    end
    local file_path = path .. '/' .. name
    if not file_path:find(escaped_prefix_path) then
      return false
    end
    if not is_executable(file_path) then
      return false
    end
    local mime = vim.fn.system({'file', '--brief', '--mime-encoding', file_path})
    if not mime:match('binary') then
      return false
    end
    return true
  end, {limit = 1000, type = 'file', path = prefix_dir})

  local execs = {}
  for _, e in ipairs(found_executables) do
    local exe = e:gsub(escaped_prefix_path, prefix)
    execs[exe] = true
  end
  return execs
end

---Get paths of executables from both cmake and directory scanning
---@param prefix string path prefix
---@return {[string]: boolean} set of found executables
function CMake.get_executables(prefix)
  log.debug({'CMake.get_executables', prefix = prefix})
  -- Use CMake
  local execs = CMake.executables_of_buffer(prefix)
  local found = CMake.find_executables(prefix)
  for exe, _ in pairs(found) do
    execs[exe] = true
  end
  return execs
end

-- targets structure is:
-- [{artifacts:[...], 
--   link: {commandFragments: [{fragment:"<file_name>", ...}, ...], ...}, 
--   sources: [{path:"<file_name>", ...}...]
--  }, ...]
-- Library files (*.a, *.so) are in commandFragments and source files (*.c,
-- *.cpp) are in sources
---Filter targets keeping those that reference the given file_name
---@param targets table
---@param file_name string
---@return string[] artifact paths
function CMake.artifacts_of_files(targets, file_name)
  local artifacts = {}
  local function filter_targets(pred)
    for _, target in ipairs(targets) do
      if pred(target) then
        for _, artifact in ipairs(target.artifacts) do
          artifacts[#artifacts+1] = artifact.path
        end
      end
    end
  end
  if string.find(file_name, '%.cp?p?$') then
    filter_targets(function(target)
      for _, source in ipairs(target.sources) do
        if vim.fn.match(source.path, file_name) >= 0 then
          return true
        end
      end
    end)
  elseif string.match(file_name, '%.so$') or string.match(file_name, '%.a$') then
    local basename = file_name:find('([^/\\]+)$')
    filter_targets(function(target)
      for _, command_fragment in ipairs(target.link.commandFragments) do
        if vim.fn.match(command_fragment.fragment, basename) >= 0 then
          return true
        end
      end
    end)
  end
  return artifacts
end

---Get cmake build directory for a given path
---@param path string
---@return string? full path
function CMake.in_cmake_dir(path)
  -- normalize path
  --"echom "Is " . a:path . " in a CMake Directory?"
  path = uv.fs_realpath(path)
  -- check if a CMake Directory
  while '/' ~= path do
    if uv.fs_access(path .. '/CMakeCache.txt', 'R') then
      return path
    end
    path = uv.fs_realpath(path .. '/..')
  end
  return nil
end

function CMake.get_cmake_reply_dir(cmake_build_dir)
  return cmake_build_dir .. '/.cmake/api/v1/reply/'
end

local function is_dir_empty(path)
  local dir = uv.fs_opendir(path, nil, 1)
  if not dir then return true end
  if dir:readdir() then
    return false
  end
  return true
end

function CMake.query(cmake_build_dir)
  if is_dir_empty(cmake_build_dir) then
    return 1
  end
  local cmake_api_query_dir = cmake_build_dir .. '/.cmake/api/v1/query/client-nvim-gdb/'
  vim.fn.mkdir(cmake_api_query_dir, "p")
  local cmake_api_query_file = cmake_api_query_dir .. "query.json"
  local cmake_api_query = {'{ "requests": [ { "kind": "codemodel" , "version": 2 } ] }'}
  vim.fn.writefile(cmake_api_query, cmake_api_query_file)
  local reply_dir = CMake.get_cmake_reply_dir(cmake_build_dir)
  if is_dir_empty(reply_dir) then
    vim.fn.system("cmake -B " .. cmake_build_dir)
  end
  return vim.v.shell_error
end

---Find cmake directories by scanning proj_dir
---@param proj_dir string path to the directory to scan
---@return {[string]: boolean }
function CMake.get_cmake_dirs(proj_dir)
  local cmake_cache_txt = 'CMakeCache.txt'
  local progress_path = ''
  local cache_files = vim.fs.find(function(name, path)
    if progress_path ~= path then
      print("Scanning " .. path)
      progress_path = path
    end
    return name == cmake_cache_txt
  end, {limit = 1000, type = 'file', path = proj_dir})
  local cmake_dirs = {}
  for _, cache_file in ipairs(cache_files) do
    local cmake_dir = cache_file:sub(1, -(2 + #cmake_cache_txt))
    cmake_dirs[cmake_dir] = true
  end
  return cmake_dirs
end

function CMake.executable_of_file_helper(targets, file_name)
  if not (file_name:find('%.c$') or file_name:find('%.cpp$') or file_name:find('%.a$') or file_name:find('%.so$')) then
    -- assume executable found
    return {file_name}
  end
  -- recurse on all artifacts until executable is found
  local ret = {}
  local artifacts = CMake.artifacts_of_files(targets, file_name)
  for _, artifact in ipairs(artifacts) do
    for _, a in ipairs(CMake.executable_of_file_helper(targets, artifact)) do
      ret[#ret+1] = a
    end
  end
  return ret
end

local function readfile(file_path)
  local file = io.open(file_path, "r")
  if file then
    local content = file:read("*all")
    file:close()
    return content
  else
    return nil
  end
end

local function get_relative_path(file_path, base_dir)
  local base_len = #base_dir
  if base_len > 0 then
    if base_dir:sub(-1) ~= "/" then
      base_dir = base_dir .. "/"
      base_len = base_len + 1
    end
    if file_path:sub(1, base_len) == base_dir then
      return file_path:sub(base_len + 1)
    end
  end
  return nil
end

function CMake.executable_of_buffer(cmake_build_dir)
  if CMake.query(cmake_build_dir) ~= 0 then
    return {}
  end
  local reply_dir = CMake.get_cmake_reply_dir(cmake_build_dir)
  -- Decode all target_file JSONS into Dictionaries
  local targets = vim.fn.split(vim.fn.glob(reply_dir .. "target*"))
  for i, target in ipairs(targets) do
    targets[i] = vim.json.decode(readfile(target))
  end
  local cmake_source = vim.json.decode(readfile(vim.fn.glob(reply_dir .. "codemodel*json"))).paths.source
  -- Get the source relative path
  local buffer_path = uv.fs_realpath(vim.fn.bufname())
  if not buffer_path then
    return {}
  end
  local buffer_base_name = get_relative_path(buffer_path, uv.fs_realpath(cmake_source))
  local execs = CMake.executable_of_file_helper(targets, buffer_base_name)
  for i, exe in ipairs(execs) do
    execs[i] = cmake_build_dir .. '/' .. exe
  end
  return execs
end

function CMake.executables_of_buffer(prefix)
  -- Test prefix for CMake directories
  local this_dir = uv.fs_realpath('.')

  local prefix_dir = prefix:match('(.*)[/\\].*')
  local prefix_base = prefix
  if prefix_dir then
    prefix_base = prefix:sub(#prefix_dir + 2)
  else
    prefix_dir = '.'
  end
  prefix_dir = uv.fs_realpath(prefix_dir)
  local progress_path = ''
  local dirs = vim.fs.find(function(name, path)
    if progress_path ~= path then
      print("Scanning " .. path)
      progress_path = path
    end
    -- depth = 0
    if path:sub(#prefix_dir + 1):find('[/\\]') then
      return false
    end
    return name:sub(1, #prefix_base) == prefix_base
  end, {limit = 1000, type = 'directory', path = prefix_dir})

  -- Filter non-CMake directories out
  ---@type {[string]: boolean}
  local cmake_dirs = {}
  for _, dir in ipairs(dirs) do
    local cmake_dir = CMake.in_cmake_dir(dir)
    if cmake_dir then
      cmake_dirs[cmake_dir] = true
    end
  end
  -- Look for CMake directories below this one
  for dir in pairs(CMake.get_cmake_dirs(prefix_dir)) do
    cmake_dirs[dir] = true
  end
  -- Get binaries from CMake directories
  local execs = {}
  for dir, _ in pairs(cmake_dirs) do
    for _, exe in ipairs(CMake.executable_of_buffer(dir)) do
      execs[get_relative_path(exe, this_dir)] = true
    end
  end
  return execs
end

return CMake