local uv = vim.loop

local Utils = {}
Utils.__index = Utils

local function get_plugin_dir()
  local path = debug.getinfo(1).source:match("@(.*/)")
  return uv.fs_realpath(path .. '/../..')
end

-- Full path to the plugin directory
Utils.plugin_dir = get_plugin_dir()

local function get_path_separator()
  local sep = '/'
  if uv.os_uname().sysname == "Windows" then
    sep = '\\'
  end
  return sep
end

Utils.fs_separator = get_path_separator()

Utils.path_join = function(path, ...)
  for _, name in ipairs({...}) do
    path = path .. Utils.fs_separator .. name
  end
  return path
end

Utils.get_plugin_file_path = function(...)
  return Utils.path_join(Utils.plugin_dir, ...)
end

return Utils
