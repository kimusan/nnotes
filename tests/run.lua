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

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit")
end
