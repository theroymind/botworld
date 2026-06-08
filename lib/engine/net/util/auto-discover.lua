-- Convention-based module discovery: load every non-test, non-underscore module
-- in a directory by `require`-ing it. Botworld keeps botlands' registry
-- convention so message sets are discovered the same way. Copied as-is; only the
-- require path changed to the net-engine namespace.
local file_reader = require("lib.engine.net.util.file-reader")

local function is_skipped_entry(basename)
  return basename:match("^_") or basename:match("_test$") or basename:match("^%.")
end

local function contains(items, target)
  for _, item in ipairs(items) do
    if item == target then
      return true
    end
  end
  return false
end

local function load_modules(dir, package_prefix)
  local modules = {}
  for _, filename in ipairs(file_reader.list_directory(dir)) do
    local basename = filename:match("^(.+)%.lua$")
    if basename and not is_skipped_entry(basename) then
      local module_path = package_prefix .. basename
      package.loaded[module_path] = nil
      modules[basename] = require(module_path)
    end
  end
  return modules
end

local function load_submodules(dir, package_prefix, submodule_name)
  local target_filename = submodule_name .. ".lua"
  local modules = {}
  for _, entry in ipairs(file_reader.list_directory(dir)) do
    if not entry:match("%.lua$") and not is_skipped_entry(entry) then
      local subdir_contents = file_reader.list_directory(dir .. "/" .. entry)
      if contains(subdir_contents, target_filename) then
        local module_path = package_prefix .. entry .. "." .. submodule_name
        package.loaded[module_path] = nil
        modules[entry] = require(module_path)
      end
    end
  end
  return modules
end

local function list_subdirectories(dir)
  local names = {}
  for _, entry in ipairs(file_reader.list_directory(dir)) do
    if not entry:match("%.lua$") and not is_skipped_entry(entry) then
      table.insert(names, entry)
    end
  end
  return names
end

local function list_module_names(dir)
  local names = {}
  for _, entry in ipairs(file_reader.list_directory(dir)) do
    if not is_skipped_entry(entry) then
      local basename = entry:match("^(.+)%.lua$")
      if basename then
        if basename ~= "init" and not is_skipped_entry(basename) then
          table.insert(names, basename)
        end
      else
        local subdir_contents = file_reader.list_directory(dir .. "/" .. entry)
        if contains(subdir_contents, "init.lua") then
          table.insert(names, entry)
        end
      end
    end
  end
  return names
end

local function load_all_modules(dir, package_prefix)
  local modules = {}
  for _, name in ipairs(list_module_names(dir)) do
    local module_path = package_prefix .. name
    package.loaded[module_path] = nil
    modules[name] = require(module_path)
  end
  return modules
end

return {
  load_modules = load_modules,
  load_submodules = load_submodules,
  list_subdirectories = list_subdirectories,
  list_module_names = list_module_names,
  load_all_modules = load_all_modules,
}
