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
        return item.text
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

return M
