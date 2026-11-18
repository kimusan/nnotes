local store = require("nnotes.store")
local M = {}

-- one line of display text per note record
local function format_item(rec)
  local tags = {}
  for _, t in ipairs(rec.tags) do
    table.insert(tags, "#" .. t)
  end
  local line = rec.title .. "  (" .. rec.scope .. ")"
  if #tags > 0 then
    line = line .. "  " .. table.concat(tags, " ")
  end
  if rec.deadline then
    line = line .. "  due " .. tostring(rec.deadline)
  end
  return line
end

-- list of picker items for the whole index, sorted by title
M.items = function(query)
  local recs = store.search(query or "")
  local items = {}
  for _, rec in ipairs(recs) do
    table.insert(items, {
      text = format_item(rec),
      file = rec.path,
      rec = rec,
    })
  end
  table.sort(items, function(a, b)
    return a.text:lower() < b.text:lower()
  end)
  return items
end

M.recent = function()
  local recs = store.index()
  table.sort(recs, function(a, b)
    return (a.mtime or 0) > (b.mtime or 0)
  end)
  return recs
end

local function open_note(path)
  if not path or not vim.loop.fs_stat(path) then
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function has_snacks()
  return pcall(require, "snacks")
end

local function fallback_select(title, items, on_pick)
  vim.ui.select(items, {
    prompt = title,
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    if choice then
      on_pick(choice)
    end
  end)
end

M.open = function(title, items, on_pick)
  if #items == 0 then
    vim.notify("No notes found", vim.log.INFO)
    return
  end
  if has_snacks() then
    local Snacks = require("snacks")
    local picker_items = {}
    for i, it in ipairs(items) do
      table.insert(picker_items, { text = it.text, file = it.file, idx = i })
    end
    Snacks.picker.pick({
      items = picker_items,
      format = function(item)
        -- snacks expects a highlight line: a list of {text, hl} segments, not
        -- a bare string (highlight.resolve ipairs's the returned line).
        return { { item.text } }
      end,
      confirm = function(item)
        on_pick(items[item.idx] or { file = item.file })
      end,
    })
  else
    fallback_select(title, items, on_pick)
  end
end

M.search = function(query)
  query = query or ""
  M.open("Nnotes search", M.items(query), function(it)
    open_note(it.file)
  end)
end

M.recents = function()
  local items = {}
  for _, rec in ipairs(M.recent()) do
    table.insert(items, { text = format_item(rec), file = rec.path })
  end
  M.open("Recent notes", items, function(it)
    open_note(it.file)
  end)
end

-- template picker: choose a template, then a title, then create the note
-- in the scope of the current buffer (project when inside a project, else
-- global)
M.new_from_template = function()
  local templates = require("nnotes.templates")
  local names = templates.list()
  if #names == 0 then
    vim.notify("No templates found", vim.log.WARN)
    return
  end
  local scope = store.find_project_root(vim.api.nvim_buf_get_name(0)) and "project" or "global"
  M.open("New note from template", { { text = table.concat(names, "\n"), file = "" } }, function()
    vim.ui.select(names, { prompt = "Template: " }, function(name)
      if not name then
        return
      end
      vim.ui.input({ prompt = "Title: " }, function(title)
        local notes = require("nnotes.notes")
        local path = notes.from_template(scope, name, title)
        if path then
          open_note(path)
        end
      end)
    end)
  end)
end

-- new note: pick a scope, then a title
M.new = function()
  local notes = require("nnotes.notes")
  local in_proj = store.find_project_root(vim.api.nvim_buf_get_name(0)) ~= nil
  local opts = in_proj and { "project", "global" } or { "global", "project" }
  vim.ui.select(opts, { prompt = "Scope: " }, function(s)
    if not s then
      return
    end
    vim.ui.input({ prompt = "Title: ", default = "Untitled" }, function(title)
      if not title or title == "" then
        title = "Untitled"
      end
      local path = notes.new_note({ scope = s, title = title })
      open_note(path)
    end)
  end)
end

-- open (or create) today's global note, titled with today's date
M.today = function()
  local notes = require("nnotes.notes")
  local date = os.date(require("nnotes").config().filename_pattern)
  local existing = store.get_by_title(date)
  if existing then
    open_note(existing.path)
    return
  end
  open_note(notes.new_note({ scope = "global", title = date }))
end

-- picker of distinct tags with note counts; picking one opens its notes
M.tags = function()
  local tags = store.all_tags()
  if #tags == 0 then
    vim.notify("No tags found", vim.log.INFO)
    return
  end
  local items = {}
  for _, t in ipairs(tags) do
    table.insert(items, { text = ("#%s  (%d)"):format(t, #store.tags_of(t)), file = "", tag = t })
  end
  M.open("Notes by tag", items, function(it)
    local recs = store.tags_of(it.tag)
    local sub = {}
    for _, r in ipairs(recs) do
      table.insert(sub, { text = format_item(r), file = r.path, rec = r })
    end
    M.open(("#%s — %d notes"):format(it.tag, #sub), sub, function(ch)
      open_note(ch.file)
    end)
  end)
end

-- picker of notes that link to the current note
M.backlinks = function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or not path:match("%.md$") then
    vim.notify("Open a note first", vim.log.INFO)
    return
  end
  local backs = require("nnotes.links").backlinks(path)
  local rec = store.get_by_path(path)
  local items = {}
  for _, r in ipairs(backs) do
    table.insert(items, { text = format_item(r), file = r.path, rec = r })
  end
  M.open(("Backlinks for " .. (rec and rec.title or "note")), items, function(it)
    open_note(it.file)
  end)
end

-- rename the current note (rewrites incoming links)
M.rename = function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or not path:match("%.md$") then
    vim.notify("Not a note buffer", vim.log.WARN)
    return
  end
  local notes = require("nnotes.notes")
  local meta = notes.read(path)
  vim.ui.input({ prompt = "New title: ", default = meta.title }, function(new)
    if not new or new == "" then
      return
    end
    local newpath = notes.rename(path, new)
    if newpath then
      open_note(newpath)
    end
  end)
end

-- delete the current note (moved to trash, never rm)
M.delete = function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or not path:match("%.md$") then
    vim.notify("Not a note buffer", vim.log.WARN)
    return
  end
  if vim.fn.confirm("Delete this note? (moved to trash)", "Yes\nNo") ~= 1 then
    return
  end
  local trash = require("nnotes.notes").delete(path)
  if trash then
    vim.notify("Moved to trash: " .. trash, vim.log.INFO)
  end
end

-- move the current note to the other scope
M.move = function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or not path:match("%.md$") then
    vim.notify("Not a note buffer", vim.log.WARN)
    return
  end
  local notes = require("nnotes.notes")
  local cur = store.get_by_path(path)
  local to = (cur and cur.scope == "project") and "global" or "project"
  local newpath = notes.move(path, to)
  if newpath then
    open_note(newpath)
  else
    vim.notify("Could not move (no project root in view?)", vim.log.WARN)
  end
end

return M
