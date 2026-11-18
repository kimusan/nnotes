local store = require("nnotes.store")
local M = {}

local function config()
  return require("nnotes").config()
end

-- the directory the sidebar should show: the project's notes dir when the
-- current buffer is inside a project, else the global notes dir
M.scope_dir = function()
  local root = store.find_project_root(vim.api.nvim_buf_get_name(0))
  if root then
    local d = store.project_dir(root)
    vim.fn.mkdir(d, "p")
    return d
  end
  return store.global_dir()
end

-- rename/delete routed through the plugin so links, frontmatter and the
-- index stay consistent (the explorer's built-in actions bypass all of that)
local function notes_rename(picker, item)
  local file = item and item.file
  if not file or not vim.loop.fs_stat(file) then
    return false
  end
  local ok, new_name = pcall(vim.ui.input, {
    prompt = "New title: ",
    default = vim.fn.fnamemodify(file, ":t:r"),
  })
  if not ok or not new_name or new_name == "" then
    return false
  end
  local new_path = require("nnotes.notes").rename(file, new_name)
  if new_path then
    require("snacks.explorer.actions").update(picker, { refresh = true })
  end
  return true
end

local function notes_delete(picker, item)
  local file = item and item.file
  if not file or not vim.loop.fs_stat(file) then
    return false
  end
  if vim.fn.confirm("Delete this note? (moved to trash)", "Yes\nNo") ~= 1 then
    return false
  end
  require("nnotes.notes").delete(file)
  require("snacks.explorer.actions").update(picker, { refresh = true })
  return true
end

-- open the explorer rooted at the active scope
M.open = function()
  local dir = M.scope_dir()
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.explorer then
    vim.notify("snacks.nvim not available; sidebar disabled", vim.log.WARN)
    return nil
  end
  local win = (config().sidebar or {}).win or {}
  return Snacks.explorer.open({
    cwd = dir,
    layout = { position = win.position or "left", width = win.width },
    actions = {
      explorer_rename = notes_rename,
      explorer_del = notes_delete,
    },
  })
end

M.toggle = function()
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.picker then
    local existing = Snacks.picker.get({ source = "explorer" })
    if existing and #existing > 0 then
      existing[1]:close()
      return
    end
  end
  M.open()
end

return M
