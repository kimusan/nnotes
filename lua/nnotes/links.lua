local store = require("nnotes.store")
local M = {}

-- parse a note body, return a list of {kind="wiki"|"md", target=string,
-- line=number, start=number, finish=number}
local function iter_line(line, pattern, out, kind)
  local pos = 1
  while true do
    local s, e, target = line:find(pattern, pos)
    if not s then
      break
    end
    table.insert(out, {
      kind = kind,
      target = target:match("^%s*(.-)%s*$"),
      start = s,
      finish = e,
    })
    pos = e + 1
  end
end

M.parse = function(text)
  local out = {}
  for line_no, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local before = #out
    iter_line(line, "%[%[([^%]%|]+)%|?[^%]]*%]%]", out, "wiki")
    iter_line(line, "%[[^%]]*%]%(([%w%.][%w%.%/%-]*%.md)%)", out, "md")
    for i = before + 1, #out do
      out[i].line = line_no
    end
  end
  table.sort(out, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.start < b.start
  end)
  return out
end

-- resolve a link target to an absolute note path.
--   wiki: match by title or filename stem (case-insensitive)
--   md:   resolve the relative path against `from_dir`
M.resolve = function(target, link, from_dir)
  if link.kind == "md" then
    local base = from_dir or vim.fn.getcwd()
    local p
    if target:match("^[/]") then
      p = target
    else
      p = vim.fs.joinpath(base, target)
    end
    if vim.loop.fs_stat(p) then
      return vim.fs.abspath(p)
    end
    if vim.loop.fs_stat(p .. ".md") then
      return vim.fs.abspath(p .. ".md")
    end
    return nil
  end

  local rec = store.get_by_title(target)
  if rec then
    return rec.path
  end
  for _, r in ipairs(store.index()) do
    if vim.fn.fnamemodify(r.path, ":t:r"):lower() == target:lower() then
      return r.path
    end
  end
  return nil
end

-- notes whose body links to `path`
M.backlinks = function(path)
  local out = {}
  for _, rec in ipairs(store.index()) do
    if rec.path == path then
      -- skip the target itself; keep scanning the rest
    else
      for _, link in ipairs(M.parse(rec.body or "")) do
        local resolved = M.resolve(link.target, link, vim.fs.dirname(rec.path))
        if resolved == path then
          table.insert(out, rec)
          break
        end
      end
    end
  end
  return out
end

-- rewrite every reference to `old_path` in all notes to `new_path`;
-- handles [[wiki]] (with optional |alias) and markdown links using the stem.
-- Call before the store is refreshed so old titles still resolve to old_path.
M.rewrite_references = function(old_path, new_path, new_title)
  local old_stem = vim.fn.fnamemodify(old_path, ":t")
  local new_stem = vim.fn.fnamemodify(new_path, ":t")
  local count = 0

  for _, rec in ipairs(store.index()) do
    if rec.path == old_path then
      -- skip the renamed note itself; keep scanning the rest
    else
      local changed = false
      local lines = vim.fn.readfile(rec.path)
      for i, line in ipairs(lines) do
        local new = line:gsub("%[%[([^%]]*)%]%]", function(inner)
          local target = inner:match("^%s*([^%|%]]+)")
          local alias = inner:match("^%s*[^%|%]]+%s*%|(.*)$")
          if not target then
            return "[[" .. inner .. "]]"
          end
          local r = M.resolve(target, { kind = "wiki" }, vim.fs.dirname(rec.path))
          if r == old_path then
            changed = true
            local label = (new_title or vim.fn.fnamemodify(new_path, ":t:r"))
              :gsub("%]%[", "% ")
            return "[[" .. label .. (alias ~= nil and alias ~= "" and ("|" .. alias) or "") .. "]]"
          end
          return "[[" .. inner .. "]]"
        end)
        if new ~= line then
          lines[i] = new
          new = lines[i]
        end
        if new_stem ~= old_stem then
          local new2 = new:gsub(vim.pesc(old_stem), vim.pesc(new_stem))
          if new2 ~= new then
            lines[i] = new2
            changed = true
          end
        end
      end
      if changed then
        vim.fn.writefile(lines, rec.path)
        count = count + 1
      end
    end
  end
  return count
end

-- the link whose span contains a 0-based column on a single line, or nil
M.link_at = function(line, col)
  for _, l in ipairs(M.parse(line)) do
    if col >= l.start - 1 and col <= l.finish - 1 then
      return l
    end
  end
  return nil
end

-- relative path from `from_dir` to `to_path` (POSIX). No built-in
-- vim.fs.relative, so compute it from normalized components.
local function relpath(from_dir, to_path)
  local function split(p)
    return vim.split(vim.fs.normalize(p), "/", { plain = true, trimempty = true })
  end
  local a, b = split(from_dir), split(to_path)
  local i = 1
  while i <= #a and i <= #b and a[i] == b[i] do
    i = i + 1
  end
  local parts = {}
  for j = i, #a do
    table.insert(parts, "..")
  end
  for j = i, #b do
    table.insert(parts, b[j])
  end
  return #parts == 0 and "." or table.concat(parts, "/")
end

-- link text pointing at `rec` as written from `from_dir`, per `style`
-- ("wiki" -> [[Title]], "markdown" -> [Title](relative path))
M.render_link = function(rec, from_dir, style)
  if style == "markdown" then
    local base = from_dir or vim.fn.getcwd()
    return ("[%s](%s)"):format(rec.title, relpath(base, rec.path))
  end
  return ("[[%s]]"):format(rec.title)
end

-- open the note the link under the cursor points to; unresolved links are
-- left as candidates for a future note
M.follow_link = function()
  local line = vim.api.nvim_get_current_line()
  local link = M.link_at(line, vim.fn.col(".") - 1)
  if not link then
    vim.notify("No link under cursor", vim.log.INFO)
    return
  end
  local resolved = M.resolve(link.target, link,
    vim.fs.dirname(vim.api.nvim_buf_get_name(0)))
  if not resolved then
    vim.notify("Unresolved: " .. link.target, vim.log.INFO)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(resolved))
end

-- insert a link to the current note at the cursor, per link_style
M.make_link = function()
  local name = vim.api.nvim_buf_get_name(0)
  local rec = store.get_by_path(name)
  if not rec then
    vim.notify("Not a note buffer", vim.log.WARN)
    return
  end
  local text = M.render_link(rec, vim.fs.dirname(name),
    require("nnotes").config().link_style)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1], cur[2]
  vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { text })
  vim.api.nvim_win_set_cursor(0, { row - 1, col + #text })
end

return M
