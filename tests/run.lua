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

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit")
end
