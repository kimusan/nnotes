-- Run from the repo root: nvim -l tests/run.lua
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL: " .. name .. "\n")
  end
end

-- Creates a temp global dir and a temp project root (with a .git marker file).
local function fresh_env(name)
  local dir = vim.fn.tempname() .. "/" .. name
  vim.fn.mkdir(dir, "p")
  local proj = dir .. "/proj"
  vim.fn.mkdir(proj, "p")
  vim.fn.writefile({}, proj .. "/.git")
  return dir, proj
end

-- Task 1: scaffold smoke test
do
  local dir, proj = fresh_env("scaffold")
  local nnotes = require("nnotes")
  local ok = pcall(nnotes.setup, { global_dir = dir })
  check("setup: does not error", ok == true)
  check("setup: creates global dir", vim.loop.fs_stat(dir) ~= nil)
  check("config: defaults merged", nnotes.config().project_dir == ".nnotes")
  check("config: global_dir respected", nnotes.config().global_dir == dir)
  _ = proj
end

-- Task 2: scope resolution (global vs project)
do
  local dir, proj = fresh_env("scope")
  require("nnotes").setup({ global_dir = dir })
  local config = require("nnotes").config()
  local store = require("nnotes.store")
  store.init(config)

  local pdir = store.project_dir(proj)
  check("scope: project dir is <root>/.nnotes", pdir == vim.fs.joinpath(proj, ".nnotes"))
  check("scope: global dir from config", store.global_dir() == dir)

  -- find_project_root walks up to a .git marker
  vim.fn.mkdir(proj .. "/sub", "p")
  vim.fn.writefile({"x"}, proj .. "/sub/inner.md")
  local root = store.find_project_root(proj .. "/sub/inner.md")
  check("scope: root found by walking up", root == proj)

  -- a file with no matching marker anywhere up the tree has no root
  -- (use a marker that cannot exist, to be deterministic across machines)
  local orph = vim.fn.tempname() .. "/orph"
  vim.fn.mkdir(orph, "p")
  local o = orph .. "/note.md"
  vim.fn.writefile({"x"}, o)
  local saved = config.project_root_patterns
  config.project_root_patterns = { ".nnotes-root-marker-xyz" }
  check("scope: no root when no marker present", store.find_project_root(o) == nil)
  config.project_root_patterns = saved
end

-- Task 3: frontmatter parse/serialize round-trip
do
  local store = require("nnotes.store")
  local body = "# My Note\n\nSome **body** text.\n"
  local meta = {
    title = "My Note",
    created = "2026-11-17",
    updated = "2026-11-17",
    tags = { "work", "idea" },
    project = "nnotes",
    deadline = "2026-12-01",
    recurs = "weekly",
    status = "active",
  }
  local text = store.serialize(meta, body)
  check("fm: begins with --- fence", text:sub(1, 3) == "---")

  local m2, b2 = store.parse(text)
  check("fm: title round-trips", m2.title == "My Note")
  check("fm: tags round-trip as list", vim.deep_equal(m2.tags, { "work", "idea" }))
  check("fm: deadline round-trips", m2.deadline == "2026-12-01")
  check("fm: recurs round-trips", m2.recurs == "weekly")
  check("fm: status round-trips", m2.status == "active")
  check("fm: body preserved", b2 == body)

  -- no frontmatter -> empty meta, body intact
  local plain = "just a line\n"
  local m3, b3 = store.parse(plain)
  check("fm: plain body has empty meta", vim.tbl_isempty(m3))
  check("fm: plain body preserved", b3 == plain)
end

-- Task 4: index collects notes from both scopes with metadata
do
  local dir, proj = fresh_env("index")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())

  local function write_note(scope_dir, fname, meta, body)
    vim.fn.mkdir(scope_dir, "p")
    local p = vim.fs.joinpath(scope_dir, fname)
    local f = io.open(p, "w")
    f:write(store.serialize(meta, body))
    f:close()
    return p
  end

  local gp = write_note(dir, "2026-11-17-glob.md",
    { title = "Glob", tags = { "a" }, deadline = "2026-12-01" }, "global body\n")
  local pp = write_note(vim.fs.joinpath(proj, ".nnotes"), "2026-11-18-proj.md",
    { title = "Proj", tags = { "b" } }, "project body\n")

  -- refresh scopes the project scan to the current buffer's project root
  vim.api.nvim_buf_set_name(0, proj .. "/main.md")
  store.refresh(0)
  local idx = store.index()
  local by_path = {}
  for _, n in ipairs(idx) do
    by_path[n.path] = n
  end
  check("index: two notes collected", #idx == 2)
  check("index: global note tagged", by_path[gp] and by_path[gp].scope == "global")
  check("index: project note tagged", by_path[pp] and by_path[pp].scope == "project")
  check("index: title read from frontmatter", by_path[gp] and by_path[gp].title == "Glob")
  check("index: deadline read", by_path[gp] and by_path[gp].deadline == "2026-12-01")
  check("index: tags read", by_path[pp] and vim.deep_equal(by_path[pp].tags, { "b" }))

  -- lookups
  check("index: get_by_title finds global", store.get_by_title("Glob") ~= nil)
  check("index: search by substring", #store.search("proj") >= 1)
  check("index: all_tags distinct", vim.tbl_contains(store.all_tags(), "a") and vim.tbl_contains(store.all_tags(), "b"))
end

-- Task 5: note CRUD
do
  local dir, proj = fresh_env("crud")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local notes = require("nnotes.notes")

  -- slug helper
  check("slug: lowercases and hyphenates", notes.slug("Hello World!") == "hello-world")
  check("slug: collapses spaces", notes.slug("a   b  c") == "a-b-c")

  -- new note in global scope gets a date-prefixed filename + frontmatter
  local p = notes.new_note({ scope = "global", title = "My First" })
  check("new: file exists", vim.loop.fs_stat(p) ~= nil)
  check("new: under global dir", p:find(dir, 1, true) == 1)
  check("new: filename has date prefix", p:match("%.md$") ~= nil and p:find(os.date("%Y-%m-%d"), 1, true) ~= nil)

  local m, b = store.parse(table.concat(vim.fn.readfile(p), "\n"))
  check("new: title in frontmatter", m.title == "My First")
  check("new: created date set", m.created == os.date("%Y-%m-%d"))

  -- read/write round-trip preserves meta + body
  notes.write(p, { title = "Renamed", tags = { "x" } }, "body line\n")
  local m2, b2 = store.parse(table.concat(vim.fn.readfile(p), "\n"))
  check("write: title updated", m2.title == "Renamed")
  check("write: body preserved", b2 == "body line\n")
  check("write: created kept", m2.created == os.date("%Y-%m-%d"))

  -- duplicate creates a new file, both remain
  local p2 = notes.duplicate(p)
  check("dup: new distinct path", p2 ~= p)
  check("dup: original still there", vim.loop.fs_stat(p) ~= nil)
  check("dup: copy exists", vim.loop.fs_stat(p2) ~= nil)

  -- delete moves to trash, not hard delete
  local trash = notes.delete(p2)
  check("delete: returns trash path", trash ~= nil and trash ~= "")
  check("delete: file gone from dir", vim.loop.fs_stat(p2) == nil)
  check("delete: content in trash", vim.loop.fs_stat(trash) ~= nil)

  -- move a project note into global scope
  local pp = notes.new_note({ scope = "project", title = "Proj One", project_root = proj })
  check("move: starts in project", pp:find(proj, 1, true) == 1)
  local moved = notes.move(pp, "global")
  check("move: now under global dir", moved:find(dir, 1, true) == 1)
  check("move: old project path gone", vim.loop.fs_stat(pp) == nil)
  check("move: new path exists", vim.loop.fs_stat(moved) ~= nil)
end

-- Task 6: picker item building + search/recent (vim.ui.select fallback)
do
  local dir, proj = fresh_env("picker")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local notes = require("nnotes.notes")
  local picker = require("nnotes.picker")

  local a = notes.new_note({ scope = "global", title = "Alpha" })
  local b = notes.new_note({ scope = "project", title = "Beta", project_root = proj })
  notes.new_note({ scope = "global", title = "Gamma" })
  vim.api.nvim_buf_set_name(0, proj .. "/main.md")
  store.refresh(0)

  -- item text shows title, scope and tags
  local items = picker.items()
  check("picker: three items", #items == 3)
  local text_by_title = {}
  for _, it in ipairs(items) do
    text_by_title[it.text:match("^%S+") or "?"] = it
  end
  local alpha = nil
  for _, it in ipairs(items) do
    if it.text:find("Alpha", 1, true) then
      alpha = it
    end
  end
  check("picker: alpha item present with global scope",
    alpha ~= nil and alpha.text:find("global", 1, true) ~= nil)
  check("picker: item carries file path", alpha ~= nil and alpha.file == a)

  -- search fallback lists matching notes and opening one loads the buffer
  local shown, cb = nil, nil
  local orig_select = vim.ui.select
  local orig_notify = vim.notify
  vim.notify = function()
  end
  vim.ui.select = function(it, _, c)
    shown, cb = it, c
  end
  picker.search("alpha")
  vim.ui.select = orig_select
  vim.notify = orig_notify
  check("picker: search narrows to match", type(shown) == "table" and #shown == 1)
  if shown and #shown == 1 then
    cb(shown[1])
    check("picker: confirm opens the note",
      vim.api.nvim_buf_get_name(0) == a)
  end

  -- recent: newest first by mtime (fresh buffer named as a project file so both scopes index)
  local probe = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(probe, proj .. "/probe.md")
  local function touch(path, t)
    vim.fn.system({ "touch", "-d", "@" .. tostring(t), path })
  end
  local now = math.floor(vim.loop.now() / 1000)
  touch(a, now - 3600)
  touch(b, now)
  store.refresh(probe)
  local rec = picker.recent()
  check("picker: recent returns notes", type(rec) == "table" and #rec >= 2)
  -- b (touched newest) must be ordered before a (touched oldest)
  local pos_a, pos_b
  for i, r in ipairs(rec) do
    if r.path == a then
      pos_a = i
    end
    if r.path == b then
      pos_b = i
    end
  end
  check("picker: most recent first", pos_b ~= nil and pos_a ~= nil and pos_b < pos_a)
end

-- Task 7: link parsing, resolution, backlinks, rename rewrite
do
  local dir, proj = fresh_env("links")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local notes = require("nnotes.notes")
  local links = require("nnotes.links")

  -- parse wiki + markdown links
  local text = "See [[My Note]] and [doc](./other.md) here.\nAlso [x](a/b.md)\n"
  local found = links.parse(text)
  local kinds = {}
  for _, l in ipairs(found) do
    kinds[l.kind] = kinds[l.kind] or {}
    table.insert(kinds[l.kind], l)
  end
  check("links: one wiki link", kinds.wiki and #kinds.wiki == 1)
  check("links: wiki target", kinds.wiki and kinds.wiki[1].target == "My Note")
  check("links: two markdown links", kinds.md and #kinds.md == 2)
  check("links: md target is relative path", kinds.md and kinds.md[1].target == "./other.md")

  -- resolution: wiki by title, md by relative path
  -- (a fresh buffer named as a project file is made current so refresh()
  --  indexes both scopes, since project scoping follows the current buffer)
  local cur = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(cur, proj .. "/links.md")
  vim.api.nvim_set_current_buf(cur)
  local target = notes.new_note({ scope = "global", title = "My Note" })
  store.refresh(0)
  local resolved = links.resolve("My Note", { kind = "wiki" }, dir)
  check("links: wiki resolves by title", resolved == target)

  local from = notes.new_note({ scope = "global", title = "From" })
  -- a markdown link to a sibling note resolves relative to the from-dir
  local rel = vim.fn.fnamemodify(target, ":t")
  local r2 = links.resolve(rel, { kind = "md" }, vim.fs.dirname(from))
  check("links: md resolves relative path", r2 == target)

  -- backlinks: notes linking to a target
  local b1 = notes.new_note({ scope = "global", title = "Back A" })
  notes.write(b1, { title = "Back A" }, "link to [[My Note]]\n")
  local b2 = notes.new_note({ scope = "project", title = "Back B", project_root = proj })
  notes.write(b2, { title = "Back B" }, "link to [[My Note]]\n")
  store.refresh(0)
  local backs = links.backlinks(target)
  local titles = {}
  for _, rec in ipairs(backs) do
    titles[rec.title] = true
  end
  check("backlinks: finds global backlink", titles["Back A"] == true)
  check("backlinks: finds project backlink", titles["Back B"] == true)
  check("backlinks: excludes self", titles["My Note"] ~= true)

  -- rename rewrites references in other notes (wiki + md)
  local r3 = notes.new_note({ scope = "global", title = "Refs" })
  notes.write(r3, { title = "Refs" },
    "wiki [[My Note]] and md [" .. vim.fn.fnamemodify(target, ":t") .. "](" .. vim.fn.fnamemodify(target, ":t") .. ")\n")
  store.refresh(0)

  local newpath = notes.rename(target, "Renamed Note")
  check("rename: returns new path", newpath ~= nil and newpath ~= target)
  check("rename: old path gone", vim.loop.fs_stat(target) == nil)
  check("rename: new path exists", vim.loop.fs_stat(newpath) ~= nil)

  local refs = table.concat(vim.fn.readfile(r3), "\n")
  check("rename: wiki ref rewritten", refs:find("[[Renamed Note]]", 1, true) ~= nil)
  check("rename: old wiki ref gone", refs:find("[[My Note]]", 1, true) == nil)
  check("rename: md ref rewritten to new file",
    refs:find(vim.fn.fnamemodify(newpath, ":t"), 1, true) ~= nil)
  check("rename: title frontmatter updated",
    notes.read(newpath).title == "Renamed Note")
end

-- Task 8: markdown formatting (pure transforms, TOC, word count, keymaps)
do
  local dir, proj = fresh_env("formatting")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local formatting = require("nnotes.formatting")

  -- line op transforms are toggles
  check("formatting: list toggle adds prefix",
    formatting.transform_line("item", "list") == "- item")
  check("formatting: list toggle removes prefix",
    formatting.transform_line("- item", "list") == "item")
  check("formatting: task toggle adds prefix",
    formatting.transform_line("do it", "task") == "- [ ] do it")
  check("formatting: quote toggle adds prefix",
    formatting.transform_line("note", "quote") == "> note")
  check("formatting: quote toggle removes prefix",
    formatting.transform_line("> note", "quote") == "note")

  -- heading toggle: plain -> heading, same level -> plain, other level -> swap
  check("formatting: heading 1 applied",
    formatting.transform_line("Title", "heading", 1) == "# Title")
  check("formatting: heading 1 removed on re-toggle",
    formatting.transform_line("# Title", "heading", 1) == "Title")
  check("formatting: heading level swaps",
    formatting.transform_line("# Title", "heading", 3) == "### Title")

  -- apply_op transforms only the given 1-based inclusive range
  local out = formatting.apply_op({ "a", "b", "c" }, 2, 3, "list")
  check("formatting: apply_op range only",
    out[1] == "a" and out[2] == "- b" and out[3] == "- c")

  -- continue_line: <CR> on a list item continues the prefix
  local first, second, newcol = formatting.continue_line("- item a", 8)
  check("formatting: enter continues list",
    first == "- item a" and second == "- " and newcol == 2)
  -- <CR> mid-item moves the remaining content to the new line
  first, second = formatting.continue_line("- item a", 2)
  check("formatting: enter mid-item keeps rest",
    first == "- " and second == "- item a" and newcol == 2)
  -- <CR> on an empty item exits the list
  first, second = formatting.continue_line("- ", 2)
  check("formatting: empty item exits list",
    first == "" and second == nil)
  -- task and quote continue too
  first, second = formatting.continue_line("- [ ] todo", 10)
  check("formatting: enter continues task",
    first == "- [ ] todo" and second == "- [ ] ")
  first, second = formatting.continue_line("> quoted", 8)
  check("formatting: enter continues quote",
    first == "> quoted" and second == "> ")
  -- a plain line just splits
  first, second, newcol = formatting.continue_line("hello", 2)
  check("formatting: plain line splits",
    first == "he" and second == "llo" and newcol == 2)

  -- wraps use the marker on both sides
  check("formatting: bold wrap", formatting.wrap_text("word", "**") == "**word**")
  check("formatting: italic wrap", formatting.wrap_text("word", "*") == "*word*")

  -- TOC + word_count operate on a buffer
  local lines = {
    "---",
    "title: Formatting",
    "created: 2026-11-18",
    "---",
    "",
    "one two three four five",
    "# First",
    "## Second",
    "# Third",
  }
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"

  -- word count skips frontmatter and counts body tokens
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---",
    "title: Formatting",
    "created: 2026-11-18",
    "---",
    "one two three four five",
  })
  check("formatting: word_count excludes frontmatter", formatting.word_count() == 5)

  -- TOC is generated from headings, indented by level, inserted after frontmatter
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  formatting.toc()
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local toc_idx = nil
  for i, l in ipairs(after) do
    if l == "## Table of Contents" then
      toc_idx = i
      break
    end
  end
  check("formatting: toc header inserted", toc_idx ~= nil)
  check("formatting: toc entries present",
    after[toc_idx + 2] == "- [First](#first)"
      and after[toc_idx + 3] == "  - [Second](#second)")
  check("formatting: headings preserved after toc",
    vim.tbl_contains(after, "# First") and vim.tbl_contains(after, "# Third"))

  -- keymaps are registered for the markdown buffer (fallback path)
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local found = false
  for _, m in ipairs(maps) do
    if m.lhs == "<M-l>" then
      found = true
      break
    end
  end
  check("formatting: buffer-local keymap registered", found)
end

-- Task 9: templates (render, list/load, from_template, picker, keymap)
do
  local dir, proj = fresh_env("templates")
  local nnotes = require("nnotes")
  nnotes.setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(nnotes.config())
  local notes = require("nnotes.notes")
  local templates = require("nnotes.templates")
  local picker = require("nnotes.picker")

  -- render substitutes known vars and blanks unknown ones
  local rendered = templates.render("# {{title}}\n\ndated {{date}}\n{{unknown}}", { title = "Hello" })
  check("templates: render title", rendered:find("# Hello", 1, true) ~= nil)
  check("templates: render date", rendered:find("dated " .. os.date("%Y-%m-%d"), 1, true) ~= nil)
  check("templates: render unknown is empty", rendered:find("{{", 1, true) == nil)

  -- list includes the five bundled templates
  local names = templates.list()
  for _, n in ipairs({ "daily", "weekly", "project", "meeting", "scratch" }) do
    check("templates: bundled " .. n .. " listed", vim.tbl_contains(names, n))
  end

  -- load returns bundled text; templates_dir overrides by name
  local custom_dir = vim.fn.tempname() .. "/tmpl"
  vim.fn.mkdir(custom_dir, "p")
  vim.fn.writefile({ "# {{title}}", "", "custom daily body" }, custom_dir .. "/daily.md")
  nnotes.setup({ global_dir = dir, templates_dir = custom_dir })
  check("templates: load bundled", (templates.load("weekly") or ""):find("Week of", 1, true) ~= nil)
  check("templates: templates_dir wins over bundled",
    (templates.load("daily") or ""):find("custom daily body", 1, true) ~= nil)

  -- inline strings in opts.templates win over files
  nnotes.setup({
    global_dir = dir,
    templates = { inline = "# {{title}}\n\ninline {{scope}}" },
  })
  check("templates: inline listed", vim.tbl_contains(templates.list(), "inline"))
  check("templates: inline loaded",
    (templates.load("inline") or ""):find("inline", 1, true) ~= nil)

  -- from_template creates a note with rendered content and single frontmatter
  nnotes.setup({ global_dir = dir })
  local p = notes.from_template("global", "daily", "My Note")
  check("templates: note created", p ~= nil and vim.loop.fs_stat(p) ~= nil)
  local text = table.concat(vim.fn.readfile(p), "\n")
  local fm = 0
  for _, l in ipairs(vim.fn.readfile(p)) do
    if l:match("^%s*---%s*$") then
      fm = fm + 1
    end
  end
  check("templates: frontmatter not duplicated", fm == 2)
  check("templates: title in frontmatter",
    notes.read(p).title == "My Note")
  check("templates: body rendered",
    text:find("# " .. os.date("%Y-%m-%d"), 1, true) ~= nil)
  check("templates: no unrendered vars", text:find("{{", 1, true) == nil)

  -- default template name per scope (global -> daily), title defaults to date
  local pd = notes.from_template("global")
  check("templates: default name used", pd ~= nil and notes.read(pd).title == os.date("%Y-%m-%d"))

  -- unknown template: notify (stubbed) and return nil
  local notified = false
  local orig_notify = vim.notify
  vim.notify = function()
    notified = true
  end
  local pn = notes.from_template("global", "nope")
  vim.notify = orig_notify
  check("templates: unknown returns nil", pn == nil and notified)

  -- picker flow: template picker -> title input -> note created and opened
  -- (current buffer is an unnamed scratch, so the scope resolves to global)
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  local sel1, sel2, sel1_cb, sel2_cb, input_cb = nil, nil, nil, nil, nil
  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, c)
    if not sel1 then
      sel1, sel1_cb = items, c
    else
      sel2, sel2_cb = items, c
    end
  end
  vim.ui.input = function(_, c)
    input_cb = c
  end
  picker.new_from_template()
  check("templates: outer picker shown", type(sel1) == "table" and #sel1 == 1)
  if sel1 and #sel1 == 1 then
    sel1_cb(sel1[1])
    check("templates: template list offered", type(sel2) == "table" and vim.tbl_contains(sel2, "daily"))
    if sel2 then
      sel2_cb("scratch")
      input_cb("Scratchy")
      vim.ui.select, vim.ui.input = orig_select, orig_input
      local found = false
      for _, rec in ipairs(store.index()) do
        if rec.title == "Scratchy" then
          found = true
        end
      end
      check("templates: note created via picker", found)
      check("templates: picker opened the note",
        vim.api.nvim_buf_get_name(0):find("scratchy", 1, true) ~= nil)
    end
  end
  vim.ui.select, vim.ui.input = orig_select, orig_input

  -- the <leader>nN keymap is registered (leader expanded)
  local kmaps = vim.api.nvim_get_keymap("n")
  local bound = false
  for _, m in ipairs(kmaps) do
    if m.desc == "Nnotes: New note from template" then
      bound = true
      break
    end
  end
  check("templates: new_template keymap registered", bound)
end

-- Task 10: deadlines and notifications
do
  local dir, proj = fresh_env("deadlines")
  local nnotes = require("nnotes")
  nnotes.setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(nnotes.config())
  local notes = require("nnotes.notes")
  local dl = require("nnotes.deadlines")

  -- date helpers
  check("deadlines: parse_date valid",
    vim.deep_equal(dl.parse_date("2026-11-18"), { year = 2026, month = 11, day = 18 }))
  check("deadlines: parse_date invalid", dl.parse_date("Nov 18") == nil)
  local today = dl.today()
  check("deadlines: days_between zero same day", dl.days_between(today, today) == 0)
  check("deadlines: days_between +1", dl.days_between(today, dl.add_days(today, 1)) == 1)
  check("deadlines: days_between -1", dl.days_between(today, dl.add_days(today, -1)) == -1)
  check("deadlines: month boundary",
    dl.days_between({ year = 2026, month = 11, day = 30 }, { year = 2026, month = 12, day = 1 }) == 1)
  check("deadlines: add_days month rollover",
    vim.deep_equal(dl.add_days({ year = 2026, month = 11, day = 30 }, 1), { year = 2026, month = 12, day = 1 }))
  check("deadlines: add_months clamps end of month",
    vim.deep_equal(dl.add_months({ year = 2026, month = 1, day = 31 }, 1), { year = 2026, month = 2, day = 28 }))
  check("deadlines: add_months year rollover",
    vim.deep_equal(dl.add_months({ year = 2026, month = 12, day = 18 }, 1), { year = 2027, month = 1, day = 18 }))
  check("deadlines: parse_duration 1d", dl.parse_duration("1d") == 1)
  check("deadlines: parse_duration 2w", dl.parse_duration("2w") == 14)
  check("deadlines: parse_duration bad unit", dl.parse_duration("2x") == nil)

  -- recurring roll-forward math
  check("deadlines: next daily", dl.next_deadline("2026-11-18", "daily") == "2026-11-19")
  check("deadlines: next weekly", dl.next_deadline("2026-11-18", "weekly") == "2026-11-25")
  check("deadlines: next monthly", dl.next_deadline("2026-11-18", "monthly") == "2026-12-18")
  check("deadlines: next none", dl.next_deadline("2026-11-18", "none") == nil)

  -- quiet hours (overnight window 22:00-07:00)
  check("deadlines: quiet at 23:00", dl.in_quiet_hours({ hour = 23, min = 0 }, { "22:00", "07:00" }) == true)
  check("deadlines: quiet at 03:00", dl.in_quiet_hours({ hour = 3, min = 0 }, { "22:00", "07:00" }) == true)
  check("deadlines: not quiet at 12:00", dl.in_quiet_hours({ hour = 12, min = 0 }, { "22:00", "07:00" }) == false)
  check("deadlines: quiet start exclusive of stop",
    dl.in_quiet_hours({ hour = 7, min = 0 }, { "22:00", "07:00" }) == false)

  -- due status: overdue / due / soon / future / done / no deadline
  local overdue = dl.due_status({ title = "t", deadline = "2026-11-15", status = "active" },
    { year = 2026, month = 11, day = 18 }, 1)
  check("deadlines: overdue status", overdue == "overdue")
  local due = dl.due_status({ title = "t", deadline = "2026-11-18", status = "active" },
    { year = 2026, month = 11, day = 18 }, 1)
  check("deadlines: due today status", due == "due")
  local soon = dl.due_status({ title = "t", deadline = "2026-11-20", status = "active" },
    { year = 2026, month = 11, day = 18 }, 3)
  check("deadlines: soon within lead time", soon == "soon")
  check("deadlines: future beyond lead",
    dl.due_status({ title = "t", deadline = "2026-12-01", status = "active" },
      { year = 2026, month = 11, day = 18 }, 1) == nil)
  check("deadlines: done notes never due",
    dl.due_status({ title = "t", deadline = "2026-11-18", status = "done" },
      { year = 2026, month = 11, day = 18 }, 1) == nil)

  -- describe builds message + level
  local desc = dl.describe({ title = "Task", deadline = "2026-11-15", status = "active" },
    { year = 2026, month = 11, day = 18 }, 1)
  check("deadlines: describe overdue message", desc ~= nil and desc.message == "Task 3d overdue")
  check("deadlines: describe overdue level", desc ~= nil and desc.level == "error")
  local desc2 = dl.describe({ title = "Task", deadline = "2026-11-20", status = "active" },
    { year = 2026, month = 11, day = 18 }, 3)
  check("deadlines: describe soon is info", desc2 ~= nil and desc2.level == "info")

  -- roll_forward: a done recurring note advances and reactivates
  local rp = notes.new_note({ scope = "global", title = "Recurring", deadline = "2026-11-18", recurs = "weekly" })
  local rm, rb = notes.read(rp)
  rm.status = "done"
  notes.write(rp, rm, rb)
  local next = dl.roll_forward(rp)
  check("deadlines: roll_forward advances weekly", next == "2026-11-25")
  local rm2 = notes.read(rp)
  check("deadlines: roll_forward sets deadline", rm2.deadline == "2026-11-25")
  check("deadlines: roll_forward reactivates", rm2.status == "active")
  -- active notes and non-recurring done notes do not roll
  check("deadlines: no roll for active", dl.roll_forward(rp) == nil)
  local np = notes.new_note({ scope = "global", title = "OneShot", deadline = "2026-11-18" })
  local nm, nb = notes.read(np)
  nm.status = "done"
  notes.write(np, nm, nb)
  check("deadlines: no roll without recurs", dl.roll_forward(np) == nil)

  -- picker items: all deadline notes, soonest first
  local od = dl.fmt_date(dl.add_days(today, -17))
  local dd = dl.fmt_date(today)
  local fu = dl.fmt_date(dl.add_days(today, 22))
  notes.new_note({ scope = "global", title = "Overdue One", deadline = od })
  notes.new_note({ scope = "global", title = "Due One", deadline = dd })
  notes.new_note({ scope = "global", title = "Future One", deadline = fu })
  local items = dl.deadlines()
  check("deadlines: picker has deadline notes", #items >= 3)
  local by_days = {}
  for _, it in ipairs(items) do
    by_days[it._days] = it
  end
  check("deadlines: items carry days-to-due",
    by_days[-17] ~= nil and by_days[0] ~= nil and by_days[22] ~= nil)
  local sorted = items[1]._days == -17
  for i = 1, #items - 1 do
    if items[i]._days > items[i + 1]._days then
      sorted = false
    end
  end
  check("deadlines: sorted soonest first", sorted)

  -- notifications: due note notifies outside quiet hours, suppressed inside
  local msgs = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(msgs, { msg = msg, level = level })
  end
  local due_rec = { title = "Due Note", deadline = dd, status = "active" }
  local noon = { year = today.year, month = today.month, day = today.day, hour = 12, min = 0 }
  dl.notify_for(due_rec, noon)
  check("deadlines: notifies when due", #msgs == 1 and msgs[1].level == vim.log.WARN)
  check("deadlines: message includes note", #msgs == 1 and msgs[1].msg:find("Due Note", 1, true) ~= nil)
  msgs = {}
  local night = { year = today.year, month = today.month, day = today.day, hour = 23, min = 0 }
  dl.notify_for(due_rec, night)
  check("deadlines: quiet hours suppress", #msgs == 0)
  vim.notify = orig_notify

  -- the <leader>nd keymap is registered (leader expanded)
  local kmaps = vim.api.nvim_get_keymap("n")
  local bound = false
  for _, m in ipairs(kmaps) do
    if m.desc == "Nnotes: Upcoming deadlines" then
      bound = true
      break
    end
  end
  check("deadlines: deadlines keymap registered", bound)
end

-- Task 11: notes sidebar (scope dir resolution + keymap)
do
  local dir, proj = fresh_env("sidebar")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local sidebar = require("nnotes.sidebar")

  -- outside a project the sidebar roots at the global dir. /tmp/.git may
  -- exist on the host, so swap in a marker that cannot be present to make
  -- the "no root" case deterministic (same trick as the scope test).
  local cfg = require("nnotes").config()
  local saved_patterns = cfg.project_root_patterns
  cfg.project_root_patterns = { ".nnotes-root-marker-xyz" }
  local gbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(gbuf, (vim.fn.tempname() .. "/sb-orphan") .. "/probe.md")
  vim.api.nvim_set_current_buf(gbuf)
  check("sidebar: global scope dir outside project", sidebar.scope_dir() == dir)
  cfg.project_root_patterns = saved_patterns

  -- inside a project it roots at <project>/.nnotes (creating it)
  local pbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(pbuf, proj .. "/note.md")
  vim.api.nvim_set_current_buf(pbuf)
  local pdir = sidebar.scope_dir()
  check("sidebar: project scope dir inside project",
    pdir == vim.fs.joinpath(proj, ".nnotes"))
  check("sidebar: project dir created", vim.loop.fs_stat(pdir) ~= nil)

  -- toggle/open degrade gracefully without snacks (notify, no error)
  local notified = false
  local orig_notify = vim.notify
  vim.notify = function()
    notified = true
  end
  local ok = pcall(sidebar.toggle)
  vim.notify = orig_notify
  check("sidebar: toggle does not error without snacks", ok)
  check("sidebar: toggle notifies when snacks missing", notified)

  -- the <leader>ns keymap is registered
  local kmaps = vim.api.nvim_get_keymap("n")
  local bound = false
  for _, m in ipairs(kmaps) do
    if m.desc == "Nnotes: Toggle sidebar" then
      bound = true
      break
    end
  end
  check("sidebar: sidebar keymap registered", bound)
end

-- Task 12: github sync (temp git repos) + age filter setup
do
  local dir, proj = fresh_env("sync")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local sync = require("nnotes.sync")

  -- scope dir resolution
  check("sync: global scope dir", sync.scope_dir("global") == dir)

  -- init_scope creates a git repo with an initial commit
  sync.init_scope("global")
  check("sync: repo initialized", vim.loop.fs_stat(dir .. "/.git") ~= nil)
  check("sync: initial commit present",
    (vim.fn.system({ "git", "-C", dir, "log", "-1", "--oneline" })):find("initial commit", 1, true) ~= nil)

  -- commit_changes stages and commits changed notes, returning the count
  vim.fn.writefile({ "# One" }, dir .. "/2026-11-18-a.md")
  vim.fn.writefile({ "# Two" }, dir .. "/2026-11-18-b.md")
  local n = sync.commit_changes(dir)
  check("sync: commit_changes counts changed files", n == 2)
  local msg = vim.fn.system({ "git", "-C", dir, "log", "-1", "--pretty=%s" })
  check("sync: commit message has date and count",
    msg:find(os.date("%Y-%m-%d"), 1, true) ~= nil and msg:find("2 changes", 1, true) ~= nil)

  -- sync with no remote commits and reports ok-local
  vim.fn.writefile({ "# Three" }, dir .. "/2026-11-18-c.md")
  check("sync: local-only sync", sync.sync("global") == "ok-local")

  -- add a bare remote; sync pulls (ff) and pushes
  local remote = vim.fn.tempname() .. "/remote.git"
  vim.fn.system({ "git", "init", "--bare", "-b", "main", remote })
  vim.fn.system({ "git", "-C", dir, "remote", "add", "origin", remote })
  vim.fn.writefile({ "# Four" }, dir .. "/2026-11-18-d.md")
  check("sync: sync with remote", sync.sync("global") == "ok")
  -- the pushed commit reached the remote
  local remote_log = vim.fn.system({ "git", "-C", remote, "log", "-1", "--oneline" })
  check("sync: commit pushed to remote", remote_log ~= "")

  -- status reports the remote url
  local st = sync.status("global")
  check("sync: status shows remote", st:find("remote:", 1, true) ~= nil)

  -- age filters: with age available, setup writes .gitattributes + config
  if sync.age_available() then
    check("sync: age filters applied", sync.setup_age_filters(dir) == true)
    local attrs = table.concat(vim.fn.readfile(dir .. "/.gitattributes"), "\n")
    check("sync: gitattributes filters md", attrs:find("filter=agecrypt", 1, true) ~= nil)
    local clean = vim.fn.system({ "git", "-C", dir, "config", "filter.agecrypt.clean" })
    local smudge = vim.fn.system({ "git", "-C", dir, "config", "filter.agecrypt.smudge" })
    check("sync: clean filter set", clean:find("age -r", 1, true) ~= nil)
    check("sync: smudge filter set", smudge:find("age -d", 1, true) ~= nil)
  else
    -- age absent: setup degrades (no filters, returns false)
    check("sync: age filters skipped when absent", sync.setup_age_filters(dir) == false)
  end

  -- age round-trip (skipped when age/age-keygen absent): clean encrypts the
  -- blob git stores, smudge decrypts it back on checkout
  if sync.age_available() and vim.fn.executable("age-keygen") == 1 then
    local tmp = vim.fn.tempname() .. "/agerepo"
    vim.fn.mkdir(tmp, "p")
    vim.fn.system({ "git", "-C", tmp, "init", "-b", "main" })
    vim.fn.system({ "git", "-C", tmp, "config", "user.name", "t" })
    vim.fn.system({ "git", "-C", tmp, "config", "user.email", "t@t" })
    local keyfile = tmp .. "/key.txt"
    vim.fn.system({ "age-keygen", "-o", keyfile })
    if vim.v.shell_error == 0 and vim.loop.fs_stat(keyfile) then
      local recipient
      for _, l in ipairs(vim.fn.readfile(keyfile)) do
        local pk = l:match("# public key: (%S+)")
        if pk then
          recipient = pk
          break
        end
      end
      -- NNOTES_AGE_KEY is the key file path (age -d -i), RECIPIENT the public key
      vim.env.NNOTES_AGE_KEY = keyfile
      vim.env.NNOTES_AGE_RECIPIENT = recipient
      sync.setup_age_filters(tmp)
      vim.fn.writefile({ "top secret note" }, tmp .. "/secret.md")
      vim.fn.system({ "git", "-C", tmp, "add", "secret.md" })
      vim.fn.system({ "git", "-C", tmp, "commit", "-m", "enc" })
      local stored = vim.fn.system({ "git", "-C", tmp, "cat-file", "-p", "HEAD:secret.md" })
      check("sync: age clean encrypts stored blob",
        stored:find("age-encryption.org", 1, true) ~= nil
        and stored:find("top secret note", 1, true) == nil)
      vim.fn.delete(tmp .. "/secret.md")
      vim.fn.system({ "git", "-C", tmp, "checkout", "--", "secret.md" })
      local back = table.concat(vim.fn.readfile(tmp .. "/secret.md"), "\n")
      check("sync: age smudge decrypts on checkout", back:find("top secret note", 1, true) ~= nil)
      vim.env.NNOTES_AGE_KEY = nil
      vim.env.NNOTES_AGE_RECIPIENT = nil
    end
  end

  -- the sync keymaps are registered
  local kmaps = vim.api.nvim_get_keymap("n")
  local have_sync, have_status = false, false
  for _, m in ipairs(kmaps) do
    if m.desc == "Nnotes: Sync" then
      have_sync = true
    end
    if m.desc == "Nnotes: Sync status" then
      have_status = true
    end
  end
  check("sync: sync keymap registered", have_sync)
  check("sync: sync_status keymap registered", have_status)
end

-- Task 13: command flows (link ops, note commands) + full keymap set
do
  local dir, proj = fresh_env("commands")
  require("nnotes").setup({ global_dir = dir })
  local store = require("nnotes.store")
  store.init(require("nnotes").config())
  local notes = require("nnotes.notes")
  local links = require("nnotes.links")
  local picker = require("nnotes.picker")

  -- render_link: wiki and markdown styles
  local rec = { title = "Target", path = dir .. "/2026-11-18-target.md" }
  check("commands: render_link wiki", links.render_link(rec, dir, "wiki") == "[[Target]]")
  check("commands: render_link markdown",
    links.render_link(rec, dir, "markdown") == "[Target](2026-11-18-target.md)")

  -- link_at: hit and miss
  local line = "See [[Target]] here."
  local hit = links.link_at(line, 8)
  check("commands: link_at finds link", hit ~= nil and hit.target == "Target")
  check("commands: link_at misses outside", links.link_at(line, 1) == nil)

  -- today: creates on first call, opens existing on second
  picker.today()
  local date = os.date("%Y-%m-%d")
  local first = store.get_by_title(date)
  check("commands: today creates note", first ~= nil)
  picker.today()
  check("commands: today opens existing",
    vim.api.nvim_buf_get_name(0) == (first and first.path or ""))

  -- tags: two notes share a tag; picking the tag lists both
  local ta = notes.new_note({ scope = "global", title = "Tag A", tags = { "work" } })
  local tb = notes.new_note({ scope = "global", title = "Tag B", tags = { "work" } })
  store.refresh(0)
  local sels = {}
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _, c)
    table.insert(sels, { items = items, cb = c })
  end
  picker.tags()
  check("commands: tags first level has the tag",
    #sels == 1 and sels[1].items[1].text:find("#work", 1, true) ~= nil)
  if #sels == 1 then
    sels[1].cb(sels[1].items[1])
    check("commands: tags second level lists notes", #sels == 2 and #sels[2].items == 2)
    if #sels == 2 then
      sels[2].cb(sels[2].items[1])
      check("commands: tags pick opens a note",
        vim.api.nvim_buf_get_name(0):match("%.md$") ~= nil)
    end
  end
  vim.ui.select = orig_select

  -- backlinks: a note linking to the target is found
  local target = notes.new_note({ scope = "global", title = "BL Target" })
  local src = notes.new_note({ scope = "global", title = "BL Source" })
  notes.write(src, { title = "BL Source" }, "see [[BL Target]]\n")
  store.refresh(0)
  local backs = links.backlinks(target)
  check("commands: backlinks found", #backs == 1 and backs[1].path == src)
  -- picker.backlists opens for the current note
  local bbuf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bbuf, target)
  vim.api.nvim_set_current_buf(bbuf)
  sels = {}
  vim.ui.select = function(items, _, c)
    table.insert(sels, { items = items, cb = c })
  end
  picker.backlinks()
  check("commands: backlinks picker lists the source",
    #sels == 1 and sels[1].items[1].text:find("BL Source", 1, true) ~= nil)
  vim.ui.select = orig_select

  -- follow_link: open the source note (it links to the target), put the
  -- cursor on the line holding the link, follow it to the target
  vim.cmd("edit " .. vim.fn.fnameescape(src))
  local src_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local linkline, linkcol = 1, 0
  for i, l in ipairs(src_lines) do
    local s = l:find("[[", 1, true)
    if s then
      linkline, linkcol = i, s - 1
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { linkline, linkcol })
  store.refresh(0)
  links.follow_link()
  check("commands: follow_link opens target", vim.api.nvim_buf_get_name(0) == target)

  -- make_link: open a note, insert a wiki link to it at a body cursor
  local mk = notes.new_note({ scope = "global", title = "Link Me" })
  vim.cmd("edit " .. vim.fn.fnameescape(mk))
  local nlines = #vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_win_set_cursor(0, { nlines, 0 })
  links.make_link()
  local mk_body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  check("commands: make_link inserts wiki link",
    mk_body:find("[[Link Me]]", 1, true) ~= nil)
  check("commands: make_link leaves frontmatter intact",
    vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---")

  -- rename: stub the input, expect the note renamed and links intact
  local rn = notes.new_note({ scope = "global", title = "Rename Me" })
  local rbuf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(rbuf, rn)
  vim.api.nvim_set_current_buf(rbuf)
  local orig_input = vim.ui.input
  vim.ui.input = function(_, c)
    c("Renamed Note")
  end
  picker.rename()
  vim.ui.input = orig_input
  check("commands: rename renamed the note",
    store.get_by_title("Renamed Note") ~= nil and vim.loop.fs_stat(rn) == nil)

  -- delete: stub confirm(Yes), expect the file gone
  local dl_path = notes.new_note({ scope = "global", title = "Delete Me" })
  local dbuf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(dbuf, dl_path)
  vim.api.nvim_set_current_buf(dbuf)
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  picker.delete()
  vim.fn.confirm = orig_confirm
  check("commands: delete removed the note", vim.loop.fs_stat(dl_path) == nil)

  -- move: a project note moves to the global scope. Name the buffer with
  -- the note's real path so get_by_path/move operate on it.
  local mv = notes.new_note({ scope = "project", title = "Mover", project_root = proj })
  local mbuf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(mbuf, mv)
  vim.api.nvim_set_current_buf(mbuf)
  store.refresh(mbuf)
  picker.move()
  store.refresh(mbuf)
  local mover = store.get_by_title("Mover")
  check("commands: move moved to global",
    vim.loop.fs_stat(mv) == nil and mover ~= nil and mover.scope == "global")

  -- all 16 global keymaps are registered
  local want = {
    "Nnotes: New note", "Nnotes: Today's note", "Nnotes: New note from template",
    "Nnotes: Search notes", "Nnotes: Recent notes", "Nnotes: Tags",
    "Nnotes: Backlinks", "Nnotes: Follow link", "Nnotes: Make link",
    "Nnotes: Upcoming deadlines", "Nnotes: Toggle sidebar",
    "Nnotes: Rename note", "Nnotes: Delete note", "Nnotes: Move note",
    "Nnotes: Sync", "Nnotes: Sync status",
  }
  local have = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    have[m.desc] = true
  end
  local all = true
  for _, d in ipairs(want) do
    if not have[d] then
      all = false
    end
  end
  check("commands: all global keymaps registered", all)
end

-- Task 14: public API surface
do
  local dir, proj = fresh_env("api")
  local nnotes = require("nnotes")
  nnotes.setup({ global_dir = dir })

  local p = nnotes.new("global", "API Note")
  check("api: new creates a note", p ~= nil and vim.loop.fs_stat(p) ~= nil)
  check("api: new sets title", nnotes.search("API Note")[1] ~= nil)

  check("api: open returns path", nnotes.open(p) == p)
  check("api: open missing returns nil", nnotes.open("/nope/none.md") == nil)

  local newp = nnotes.rename(p, "API Renamed")
  check("api: rename works", newp ~= nil and vim.loop.fs_stat(newp) ~= nil)

  check("api: search finds by body",
    #nnotes.search("api") >= 1)
  check("api: deadlines returns a list", type(nnotes.deadlines()) == "table")

  local d = nnotes.delete(newp)
  check("api: delete moves to trash", d ~= nil and vim.loop.fs_stat(newp) == nil)

  nnotes.refresh()
  check("api: refresh does not error", true)
  check("api: word_count is a number", type(nnotes.word_count()) == "number")
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit")
end
