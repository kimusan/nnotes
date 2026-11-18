local M = {}

local wraps = {
  bold = "**",
  italic = "*",
  underline = "__",
  strikethrough = "~~",
}

local line_ops = {
  list = { prefix = "- " },
  task = { prefix = "- [ ] " },
  quote = { prefix = "> " },
}

local TOC_HEADER = "## Table of Contents"

local function expand_leader(lhs)
  return lhs
    :gsub("<leader>", function()
      return vim.g.mapleader or "\\"
    end)
    :gsub("<LocalLeader>", function()
      return vim.g.maplocalleader or "\\"
    end)
end

-- current window cursor as (row, col). nvim_win_get_cursor returns a
-- [row, col] list, so it must be indexed rather than destructured.
local function get_cursor()
  local a, b = vim.api.nvim_win_get_cursor(0)
  if type(a) == "table" then
    return a[1], a[2]
  end
  return a, b
end

------------------------------
-- Pure transformations (unit-testable without editor state)
------------------------------

-- transform a single line for a line op. Headings toggle at `level`;
-- list/task/quote toggle their prefix.
M.transform_line = function(line, kind, level)
  if kind == "heading" then
    local indent, hashes, content = line:match("^(%s*)(#+)%s+(.*)$")
    content = (content or line):match("^(.-)%s*$")
    if not indent then
      indent, content = "", line:match("^(.-)%s*$")
    end
    if content == "" then
      return indent
    elseif hashes and #hashes == level then
      return indent .. content
    else
      return indent .. ("#"):rep(level) .. " " .. content
    end
  end
  local p = line_ops[kind].prefix
  if line:sub(1, #p) == p then
    return line:sub(#p + 1)
  end
  return p .. line
end

-- wrap a span of text with a marker (bold "**", italic "*", etc.)
M.wrap_text = function(text, marker)
  return marker .. text .. marker
end

-- apply a line op to the 1-based inclusive range [lo, hi]; returns new lines
M.apply_op = function(lines, lo, hi, kind, level)
  local out = {}
  for i = 1, #lines do
    if i >= lo and i <= hi then
      out[i] = M.transform_line(lines[i], kind, level)
    else
      out[i] = lines[i]
    end
  end
  return out
end

-- detect the leading block prefix of a line (task, list, or quote, with
-- optional indentation). Returns nil for a plain line.
local function detect_prefix(line)
  -- task (- [ ] / - [x]) before list, since a task line also starts like one
  local p = line:match("^([%s]*[-*+][%s]+%[[ xX]%][%s]*)")
  if p then
    return p
  end
  p = line:match("^([%s]*[-*+][%s]+)")
  if p then
    return p
  end
  return line:match("^([%s]*>[%s]+)")
end

-- given a line and the 0-based column where <CR> is pressed (insert mode:
-- number of chars before the cursor), return the two resulting lines and the
-- column to place the cursor on the new second line. When the item is empty
-- the prefix is removed (exit the list) and second is nil.
M.continue_line = function(line, col)
  local prefix = detect_prefix(line)
  local before, after = line:sub(1, col), line:sub(col + 1)
  if not prefix then
    return before, after, col
  end
  local rest = line:sub(#prefix + 1):match("^(.-)%s*$")
  if rest == "" then
    return "", nil, nil
  end
  return before, prefix .. after, #prefix
end

------------------------------
-- Editor-state handlers (thin wrappers over the pure functions)
------------------------------

local function op_lines(kind, level)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local lo, hi
  if vim.fn.mode() == "V" then
    lo, hi = vim.fn.line("<"), vim.fn.line(">")
  else
    lo, hi = vim.fn.line("."), vim.fn.line(".")
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, M.apply_op(lines, lo, hi, kind, level))
end

-- wrap the current selection (visual), word under cursor (normal) or the
-- cursor position (insert) with the marker
local function wrap(kind)
  local marker = wraps[kind]
  local mode = vim.fn.mode()

  if mode == "v" or mode == "V" then
    local a = vim.api.nvim_buf_get_mark(0, "<")
    local b = vim.api.nvim_buf_get_mark(0, ">")
    local ls = vim.api.nvim_buf_get_lines(0, a[1], b[1] + 1, false)
    if mode == "v" then
      if b[2] == 0 and b[1] > a[1] then
        ls = vim.list_slice(ls, 1, b[1] - a[1])
      elseif b[2] > 0 then
        ls[#ls] = ls[#ls]:sub(1, b[2])
      end
    end
    vim.api.nvim_buf_set_text(0, a[1], a[2], b[1], b[2],
      { marker .. table.concat(ls, "\n") .. marker })
    return
  end

  if mode == "i" then
    local row, col = get_cursor()
    vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { marker .. marker })
    vim.api.nvim_win_set_cursor(0, { row - 1, col + #marker })
    return
  end

  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  local row = vim.fn.line(".") - 1
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
  local c = vim.fn.col(".") - 1
  local s, e = line:find(word, 1, true)
  while s and (c < s - 1 or c > e - 1) do
    s, e = line:find(word, s + 1, true)
    if s then
      e = s + #word
    end
  end
  if not s then
    return
  end
  vim.api.nvim_buf_set_text(0, row, s - 1, row, s - 1, { marker })
  vim.api.nvim_buf_set_text(0, row, e + #marker, row, e + #marker, { marker })
end

-- <CR> in insert mode: continue list/task/quote prefixes on the new line, or
-- remove the prefix on an empty item to exit. The default <CR> is replaced,
-- so the newline is produced here by splitting the buffer line directly
-- (synchronous, no typeahead).
local function auto_continue()
  local row, col = get_cursor()
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  local first, second, newcol = M.continue_line(line, col)
  if second == nil then
    vim.api.nvim_buf_set_text(0, row - 1, 0, row - 1, #line, { first })
  else
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, { first, second })
    vim.api.nvim_win_set_cursor(0, { row, newcol })
  end
end

-- generate (or regenerate) a table of contents from the buffer's headings,
-- placed at the top of the body (after any frontmatter)
M.toc = function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  -- locate an existing TOC block so we can regenerate it in place and keep
  -- its header out of the heading scan
  local toc_start, toc_stop = nil, #lines
  for i, line in ipairs(lines) do
    if line == TOC_HEADER then
      toc_start = i
      for j = i + 1, #lines do
        if lines[j]:match("^%s*#") then
          toc_stop = j - 1
          break
        end
      end
      break
    end
  end

  local entries = {}
  for i, line in ipairs(lines) do
    if not (toc_start and i >= toc_start and i <= toc_stop) then
      local hashes, title = line:match("^(#+)%s+(.*)$")
      if hashes and title then
        table.insert(entries, { level = #hashes, title = title })
      end
    end
  end
  if #entries == 0 then
    vim.notify("No headings found", vim.log.INFO)
    return
  end

  local toc = { TOC_HEADER, "" }
  for _, e in ipairs(entries) do
    local anchor = e.title:lower()
      :gsub("[^%w]+", "-")
      :gsub("^-+", "")
      :gsub("-+$", "")
    table.insert(toc, ("%s- [%s](#%s)"):format(string.rep("  ", e.level - 1), e.title, anchor))
  end
  table.insert(toc, "")

  if toc_start then
    vim.api.nvim_buf_set_lines(0, toc_start - 1, toc_stop, false, toc)
    return
  end

  local start = 0
  if lines[1] and lines[1]:match("^%s*---%s*$") then
    for i = 2, #lines do
      if lines[i]:match("^%s*---%s*$") then
        start = i
        break
      end
    end
  end
  vim.api.nvim_buf_set_lines(0, start, start, false, toc)
end

-- word count of the buffer body (frontmatter excluded)
M.word_count = function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local in_fm, body = false, {}
  for i, line in ipairs(lines) do
    if i == 1 and line:match("^%s*---%s*$") then
      in_fm = true
    elseif in_fm and line:match("^%s*---%s*$") then
      in_fm = false
    elseif not in_fm then
      table.insert(body, line)
    end
  end
  local count = 0
  for _ in table.concat(body, "\n"):gmatch("%S+") do
    count = count + 1
  end
  return count
end

-- thin keymap handlers over the pure logic
M.bold = function()
  wrap("bold")
end
M.italic = function()
  wrap("italic")
end
M.underline = function()
  wrap("underline")
end
M.strikethrough = function()
  wrap("strikethrough")
end
M.heading = function(level)
  op_lines("heading", level)
end
M.list = function()
  op_lines("list")
end
M.task = function()
  op_lines("task")
end
M.quote = function()
  op_lines("quote")
end
M.auto_continue = auto_continue

-- register the markdown filetype keymaps. Uses Snacks.keymap for filetype
-- scoping when available, otherwise buffer-local keymaps applied from a
-- FileType autocmd (same pcall-fallback pattern as picker.lua).
M.setup = function(cfg)
  cfg = cfg or {}
  local keys = cfg.keys or {}

  local entries = {
    { mode = { "n", "i", "v" }, lhs = "<M-b>", rhs = M.bold, desc = "nnotes: Toggle bold" },
    { mode = { "n", "i", "v" }, lhs = "<M-i>", rhs = M.italic, desc = "nnotes: Toggle italic" },
    { mode = { "n", "i", "v" }, lhs = "<M-u>", rhs = M.underline, desc = "nnotes: Toggle underline" },
    { mode = { "n", "i", "v" }, lhs = "<M-s>", rhs = M.strikethrough, desc = "nnotes: Toggle strikethrough" },
    { mode = { "n", "v" }, lhs = "<M-l>", rhs = M.list, desc = "nnotes: Toggle list" },
    { mode = { "n", "v" }, lhs = "<M-t>", rhs = M.task, desc = "nnotes: Toggle task" },
    { mode = { "n", "v" }, lhs = "<M-q>", rhs = M.quote, desc = "nnotes: Toggle quote" },
    { mode = "i", lhs = "<CR>", rhs = auto_continue, desc = "nnotes: Auto-continue list/task/quote" },
    { mode = "n", lhs = keys.toc or "<leader>nT", rhs = function() M.toc() end, desc = "nnotes: Generate TOC" },
  }
  for lvl = 1, 6 do
    table.insert(entries, {
      mode = { "n", "v" },
      lhs = ("<M-h%d"):format(lvl),
      rhs = (function(l)
        return function()
          M.heading(l)
        end
      end)(lvl),
      desc = ("nnotes: Heading %d"):format(lvl),
    })
  end

  local function apply_to_buf(buf)
    for _, e in ipairs(entries) do
      local modes = type(e.mode) == "table" and e.mode or { e.mode }
      for _, m in ipairs(modes) do
        pcall(vim.keymap.set, m, expand_leader(e.lhs), e.rhs, { buffer = buf, desc = e.desc })
      end
    end
  end

  if pcall(require, "snacks") then
    local Snacks = require("snacks")
    for _, e in ipairs(entries) do
      local modes = type(e.mode) == "table" and e.mode or { e.mode }
      for _, m in ipairs(modes) do
        Snacks.keymap.set(m, expand_leader(e.lhs), e.rhs, { ft = "markdown", desc = e.desc })
      end
    end
    return
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
      apply_to_buf(buf)
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("nnotes.formatting", { clear = true }),
    pattern = "markdown",
    callback = function(ev)
      apply_to_buf(ev.buf)
    end,
  })
end

return M
