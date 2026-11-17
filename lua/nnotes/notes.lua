local store = require("nnotes.store")
local M = {}

local function config()
  return require("nnotes").config()
end

local function today()
  return os.date("%Y-%m-%d")
end

-- "Hello World!" -> "hello-world"
M.slug = function(title)
  local s = title:lower()
  s = s:gsub("[^%w]+", " ")
  s = s:gsub("%s+", "-")
  s = s:gsub("^-", ""):gsub("-$", "")
  return s
end

M.trash_dir = function()
  local d = vim.fs.joinpath(config().global_dir, ".trash")
  vim.fn.mkdir(d, "p")
  return d
end

M.new_note = function(opts)
  opts = opts or {}
  local scope = opts.scope or "global"
  local title = opts.title or "Untitled"
  local meta = {
    title = title,
    created = today(),
    updated = today(),
    tags = opts.tags or {},
    status = opts.status or "idea",
  }
  if opts.deadline then
    meta.deadline = opts.deadline
  end
  if opts.recurs then
    meta.recurs = opts.recurs
  end
  if scope == "project" then
    meta.project = opts.project_name or opts.project_root or "project"
  end

  local dir
  if scope == "global" then
    dir = store.global_dir()
  else
    local root = opts.project_root or store.find_project_root(vim.api.nvim_buf_get_name(0))
      or config().global_dir
    dir = store.project_dir(root)
  end
  vim.fn.mkdir(dir, "p")

  local fname = os.date(config().filename_pattern) .. "-" .. (M.slug(title) or "untitled") .. ".md"
  local path = vim.fs.joinpath(dir, fname)
  -- avoid clobbering an existing same-day note
  local i = 1
  while vim.loop.fs_stat(path) do
    path = vim.fs.joinpath(dir, os.date(config().filename_pattern) .. "-" .. M.slug(title) .. "-" .. i .. ".md")
    i = i + 1
  end

  M.write(path, meta, opts.body or "")
  store.refresh(0)
  return path
end

M.write = function(path, meta, body)
  meta = meta or {}
  local existing = {}
  if vim.loop.fs_stat(path) then
    local m, _ = store.parse(table.concat(vim.fn.readfile(path), "\n"))
    existing = m
  end
  local merged = vim.tbl_extend("force", existing, meta)
  merged.updated = today()
  if merged.title == nil then
    merged.title = vim.fn.fnamemodify(path, ":t:r")
  end
  local text = store.serialize(merged, body)
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  store.refresh(0)
  return path
end

M.read = function(path)
  local text = table.concat(vim.fn.readfile(path), "\n")
  return store.parse(text)
end

M.duplicate = function(path)
  local meta, body = M.read(path)
  local dir = vim.fs.dirname(path)
  local base = os.date(config().filename_pattern) .. "-" .. M.slug(meta.title or "copy") .. "-copy.md"
  local target = vim.fs.joinpath(dir, base)
  local i = 1
  while vim.loop.fs_stat(target) do
    target = vim.fs.joinpath(dir, os.date(config().filename_pattern) .. "-" .. M.slug(meta.title or "copy") .. "-copy-" .. i .. ".md")
    i = i + 1
  end
  local m2 = vim.deepcopy(meta)
  m2.title = (m2.title or "Untitled") .. " (copy)"
  M.write(target, m2, body)
  return target
end

M.delete = function(path)
  if not vim.loop.fs_stat(path) then
    return nil
  end
  local trash = M.trash_dir()
  local stem = vim.fn.fnamemodify(path, ":t:r")
  local target = vim.fs.joinpath(trash, stem)
  local i = 1
  while vim.loop.fs_stat(target) do
    target = vim.fs.joinpath(trash, stem .. "-" .. i)
    i = i + 1
  end
  vim.fn.rename(path, target)
  store.refresh(0)
  return target
end

-- move a note to the other scope; returns the new path
M.move = function(path, target_scope)
  local dir
  if target_scope == "global" then
    dir = store.global_dir()
  else
    local root = store.find_project_root(vim.api.nvim_buf_get_name(0))
    if not root then
      return nil
    end
    dir = store.project_dir(root)
  end
  vim.fn.mkdir(dir, "p")
  local target = vim.fs.joinpath(dir, vim.fn.fnamemodify(path, ":t"))
  local i = 1
  while vim.loop.fs_stat(target) do
    target = vim.fs.joinpath(dir, vim.fn.fnamemodify(path, ":t:r") .. "-" .. i .. ".md")
    i = i + 1
  end
  vim.fn.rename(path, target)
  store.refresh(0)
  return target
end

return M
