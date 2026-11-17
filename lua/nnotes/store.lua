local M = {}

local config = nil
local index = {}        -- list of note records
local by_path = {}      -- path -> record
local by_title = {}     -- lower(title) -> record (first wins)
local by_tag = {}       -- tag -> { [path] = true }

------------------------------
-- Scope resolution
------------------------------
M.find_project_root = function(path)
  if not path or path == "" then
    return nil
  end
  local dir = vim.fs.dirname(path)
  local root = vim.fs.root(dir, config.project_root_patterns)
  -- vim.fs.root returns the filesystem root ("/" or "C:\") when no marker is
  -- found, so verify a marker actually exists at the candidate before trusting it.
  if root and #root > 1 then
    for _, pat in ipairs(config.project_root_patterns) do
      if vim.loop.fs_stat(vim.fs.joinpath(root, pat)) then
        return root
      end
    end
  end
  return nil
end

M.global_dir = function()
  return config.global_dir
end

M.project_dir = function(root)
  return vim.fs.joinpath(root, config.project_dir)
end

------------------------------
-- Frontmatter (YAML subset)
-- Supports: scalar strings/numbers, inline lists `key: [a, b]`
-- and block lists:
--   key:
--     - a
--     - b
------------------------------
local function unquote(s)
  s = s:match("^%s*(.-)%s*$")
  if #s >= 2 and (s:sub(1, 1) == '"' and s:sub(-1) == '"'
    or s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    return s:sub(2, -2)
  end
  return s
end

local function parse_scalar(v)
  v = unquote(v)
  if v == "true" then
    return true
  end
  if v == "false" then
    return false
  end
  if v:match("^%d+$") then
    return tonumber(v)
  end
  return v
end

local function parse_list(v)
  local inner = v:match("^%s*[([](.*)[)]]%s*$")
  if not inner then
    return {}
  end
  local out = {}
  for item in inner:gmatch("[^,]+") do
    item = unquote(item)
    if item ~= "" then
      table.insert(out, item)
    end
  end
  return out
end

M.parse = function(text)
  local meta = {}
  if text:sub(1, 3) ~= "---" then
    return meta, text
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[1]:match("^%s*---%s*$") == nil then
    return {}, text
  end

  local end_idx = nil
  for i = 2, #lines do
    if lines[i]:match("^%s*---%s*$") then
      end_idx = i
      break
    end
  end
  if not end_idx then
    return {}, text
  end

  local i = 2
  while i < end_idx do
    local line = lines[i]
    local key, inline = line:match("^%s*([%w_]+):%s*(.*)$")
    if key then
      inline = inline:match("^%s*(.-)%s*$")
      if inline ~= "" then
        if inline:sub(1, 1) == "[" then
          meta[key] = parse_list(inline)
        else
          meta[key] = parse_scalar(inline)
        end
        i = i + 1
      else
        -- block list (or empty)
        local list = {}
        local j = i + 1
        local is_list = false
        while j < end_idx and lines[j]:match("^%s*-%s+") do
          local val = unquote(lines[j]:match("^%s*-%s*(.-)%s*$"))
          table.insert(list, val)
          is_list = true
          j = j + 1
        end
        if is_list then
          meta[key] = list
          i = j
        else
          meta[key] = nil
          i = i + 1
        end
      end
    else
      i = i + 1
    end
  end

  local body = table.concat(vim.list_slice(lines, end_idx + 1, #lines), "\n")
  body = body:match("\n?(.*)$") or ""
  return meta, body
end

M.serialize = function(meta, body)
  local out = { "---" }
  local order = { "title", "created", "updated", "project", "deadline", "recurs", "status", "tags" }
  local emitted = {}
  for _, key in ipairs(order) do
    local v = meta[key]
    if v ~= nil then
      emitted[key] = true
      if type(v) == "table" then
        table.insert(out, key .. ":")
        for _, item in ipairs(v) do
          table.insert(out, "  - " .. tostring(item))
        end
      else
        table.insert(out, key .. ": " .. tostring(v))
      end
    end
  end
  for key, v in pairs(meta) do
    if not emitted[key] then
      if type(v) == "table" then
        table.insert(out, key .. ":")
        for _, item in ipairs(v) do
          table.insert(out, "  - " .. tostring(item))
        end
      else
        table.insert(out, key .. ": " .. tostring(v))
      end
    end
  end
  table.insert(out, "---")
  if body ~= "" and body:sub(1, 1) ~= "\n" then
    table.insert(out, "")
  end
  return table.concat(out, "\n") .. body
end

------------------------------
-- Index
------------------------------
local function scan_dir(dir, scope, acc)
  if not vim.loop.fs_stat(dir) then
    return
  end
  local files = vim.fn.glob(vim.fn.fnameescape(dir) .. "/**/*.md", false, true)
  for _, f in ipairs(files) do
    local content = vim.fn.readfile(f)
    local text = table.concat(content, "\n")
    local meta, body = M.parse(text)
    local title = meta.title or vim.fn.fnamemodify(f, ":t:r")
    local st = vim.loop.fs_stat(f)
    local mtime
    if st and st.mtime then
      mtime = st.mtime.sec + (st.mtime.nsec or 0) / 1e9
    end
    local rec = {
      path = vim.fs.abspath(f),
      title = title,
      scope = scope,
      tags = meta.tags or {},
      deadline = meta.deadline,
      recurs = meta.recurs,
      status = meta.status,
      body = body,
      mtime = mtime,
    }
    table.insert(acc, rec)
  end
end

M.refresh = function(bufnr)
  index = {}
  by_path = {}
  by_title = {}
  by_tag = {}

  scan_dir(config.global_dir, "global", index)
  local buf = bufnr or 0
  local root = M.find_project_root(vim.api.nvim_buf_get_name(buf))
  if root then
    scan_dir(M.project_dir(root), "project", index)
  end

  for _, rec in ipairs(index) do
    by_path[rec.path] = rec
    local lt = rec.title:lower()
    if not by_title[lt] then
      by_title[lt] = rec
    end
    for _, tag in ipairs(rec.tags) do
      by_tag[tag] = by_tag[tag] or {}
      by_tag[tag][rec.path] = true
    end
  end
end

M.index = function()
  return index
end

M.get_by_path = function(path)
  return by_path[vim.fs.abspath(path)]
end

M.get_by_title = function(title)
  return by_title[title:lower()]
end

M.search = function(query)
  query = query:lower()
  local out = {}
  for _, rec in ipairs(index) do
    local hay = (rec.title .. " " .. (rec.body or "") .. " "
      .. table.concat(rec.tags, " ")):lower()
    if query == "" or hay:find(query, 1, true) then
      table.insert(out, rec)
    end
  end
  return out
end

M.all_tags = function()
  local seen = {}
  local out = {}
  for tag in pairs(by_tag) do
    if not seen[tag] then
      seen[tag] = true
      table.insert(out, tag)
    end
  end
  table.sort(out)
  return out
end

M.tags_of = function(tag)
  local set = by_tag[tag] or {}
  local out = {}
  for path in pairs(set) do
    table.insert(out, by_path[path])
  end
  return out
end

M.init = function(cfg)
  config = cfg
  M.refresh(0)
end

return M
