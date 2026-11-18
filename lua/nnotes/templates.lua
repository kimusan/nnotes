local M = {}

local function config()
  return require("nnotes").config()
end

-- the plugin's bundled templates/ directory (repo root, two levels up from
-- lua/nnotes/)
M.bundled_dir = function()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(src), "..", "..", "templates"))
end

-- substitute {{var}} placeholders. date/datetime are always available;
-- title/project/scope (and anything else) come from `vars`. Unknown
-- placeholders render as empty strings.
M.render = function(text, vars)
  local v = vim.tbl_extend("force", {
    date = os.date("%Y-%m-%d"),
    datetime = os.date("%Y-%m-%d %H:%M"),
  }, vars or {})
  return (text:gsub("{{%s*([%w_]+)%s*}}", function(name)
    return tostring(v[name] or "")
  end))
end

-- template dirs in precedence order: opts.templates_dir first, then bundled
local function dirs()
  local cfg = config()
  local out, seen = {}, {}
  local function add(d)
    if d and not seen[d] and vim.loop.fs_stat(d) then
      seen[d] = true
      table.insert(out, d)
    end
  end
  add(cfg.templates_dir)
  add(M.bundled_dir())
  return out
end

-- sorted template names: inline strings in opts.templates plus the files in
-- templates_dir and the bundled dir; a name present in a higher-precedence
-- source still appears only once
M.list = function()
  local cfg = config()
  local names, order = {}, {}
  local function add(name)
    if not names[name] then
      names[name] = true
      table.insert(order, name)
    end
  end
  if type(cfg.templates) == "table" then
    for name in pairs(cfg.templates) do
      add(name)
    end
  end
  for _, d in ipairs(dirs()) do
    for _, f in ipairs(vim.fn.glob(vim.fn.fnameescape(d) .. "/*.md", false, true)) do
      add(vim.fn.fnamemodify(f, ":t:r"))
    end
  end
  table.sort(order)
  return order
end

-- load a template by name: inline strings in opts.templates win, then
-- templates_dir, then bundled. Returns nil when not found.
M.load = function(name)
  local cfg = config()
  if type(cfg.templates) == "table" and cfg.templates[name] then
    return cfg.templates[name]
  end
  for _, d in ipairs(dirs()) do
    local p = vim.fs.joinpath(d, name .. ".md")
    if vim.loop.fs_stat(p) then
      return table.concat(vim.fn.readfile(p), "\n")
    end
  end
  return nil
end

return M
