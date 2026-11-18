local store = require("nnotes.store")
local M = {}

local function config()
  return require("nnotes").config()
end

-- run `git -C dir <args...>` (list form, no shell) and return stdout
local function git(dir, ...)
  local a = { "git", "-C", dir }
  for _, x in ipairs({ ... }) do
    table.insert(a, x)
  end
  local out = vim.fn.system(a)
  return out, vim.v.shell_error
end

local function is_repo(dir)
  return vim.loop.fs_stat(dir .. "/.git") ~= nil
end

-- the working tree for a scope: the project's .nnotes dir when scope is
-- project and a project root is in view, else the global dir
M.scope_dir = function(scope)
  if scope == "project" then
    local root = store.find_project_root(vim.api.nvim_buf_get_name(0))
    if not root then
      return nil
    end
    local d = store.project_dir(root)
    vim.fn.mkdir(d, "p")
    return d
  end
  return store.global_dir()
end

M.current_scope = function()
  return store.find_project_root(vim.api.nvim_buf_get_name(0)) and "project" or "global"
end

M.age_available = function()
  return vim.fn.executable("age") == 1
end

-- wire the age clean/smudge filters and .gitattributes. Returns false with a
-- notice when age is missing, so sync can proceed without encryption.
M.setup_age_filters = function(dir)
  if not M.age_available() then
    vim.notify("[nnotes] age not found; install it to enable encryption. "
      .. "Syncing without encryption.", vim.log.WARN)
    return false
  end
  vim.fn.writefile({ "*.md filter=agecrypt" }, dir .. "/.gitattributes")
  git(dir, "config", "filter.agecrypt.clean", 'age -r "$NNOTES_AGE_RECIPIENT" -o -')
  git(dir, "config", "filter.agecrypt.smudge", 'age -d -i "$NNOTES_AGE_KEY" -o -')
  return true
end

-- ensure a commit identity exists without overriding one the user set
local function ensure_identity(dir)
  local _, rc = git(dir, "config", "user.email")
  if rc ~= 0 then
    git(dir, "config", "user.name", "nnotes")
    git(dir, "config", "user.email", "nnotes@localhost")
  end
end

-- first-run: git init, optional remote, optional age filters, initial commit
M.init_scope = function(scope, remote_url)
  local dir = M.scope_dir(scope)
  if not dir then
    return nil, "no project root for project scope"
  end
  if not is_repo(dir) then
    git(dir, "init", "-b", "main")
    ensure_identity(dir)
  end
  if remote_url then
    local _, rc = git(dir, "remote", "get-url", "origin")
    if rc ~= 0 then
      git(dir, "remote", "add", "origin", remote_url)
    end
  end
  local enc = (config().sync or {}).encryption or {}
  if enc.enabled then
    M.setup_age_filters(dir)
  end
  local _, rc = git(dir, "log", "-1", "--oneline")
  if rc ~= 0 then
    git(dir, "add", "-A")
    git(dir, "commit", "--allow-empty", "-m", "nnotes: initial commit")
  end
  return dir
end

-- stage everything and commit if there is anything to commit; returns count
M.commit_changes = function(dir)
  git(dir, "add", "-A")
  local status = git(dir, "status", "--porcelain")
  local n = 0
  for _ in status:gmatch("[^\n]+") do
    n = n + 1
  end
  if n == 0 then
    return 0
  end
  git(dir, "commit", "-m", ("nnotes: %s %d changes"):format(os.date("%Y-%m-%d"), n))
  return n
end

-- add -A, auto-commit, ff-only pull, push. Never force-pushes.
M.sync = function(scope)
  local dir = M.scope_dir(scope)
  if not dir then
    return nil, "no project root"
  end
  if not is_repo(dir) then
    vim.notify("[nnotes] scope is not a git repo; run init first", vim.log.WARN)
    return "not-a-repo"
  end
  M.commit_changes(dir)
  local _, rc = git(dir, "remote", "get-url", "origin")
  if rc ~= 0 then
    return "ok-local"
  end
  -- push first so a fresh remote (no main yet) works, then ff-only pull to
  -- pick up any remote commits
  local push_out = git(dir, "push", "origin", "main")
  if vim.v.shell_error ~= 0 then
    vim.notify("[nnotes] push failed:\n" .. push_out, vim.log.ERROR)
    return "push-failed"
  end
  local pull_out = git(dir, "pull", "--ff-only", "origin", "main")
  if vim.v.shell_error ~= 0 then
    vim.notify("[nnotes] pull failed (diverged or conflict); resolve manually.\n" .. pull_out, vim.log.ERROR)
    return "pull-failed"
  end
  return "ok"
end

-- status text for a scope: remote plus a short status
M.status = function(scope)
  local dir = M.scope_dir(scope)
  if not dir then
    return "no project root"
  end
  if not is_repo(dir) then
    return "not a git repo"
  end
  local remote, rc = git(dir, "remote", "get-url", "origin")
  if rc ~= 0 then
    remote = "(no remote)"
  end
  return ("remote: %s\n%s"):format(remote, git(dir, "status", "-sb"))
end

-- keymap entry points for the current buffer's scope
M.sync_current = function()
  local scope = M.current_scope()
  local result = M.sync(scope)
  if result == "ok" or result == "ok-local" then
    vim.notify("[nnotes] synced (" .. scope .. ")", vim.log.INFO)
  end
end

M.status_current = function()
  local scope = M.current_scope()
  vim.notify("[nnotes] " .. scope .. "\n" .. M.status(scope), vim.log.INFO)
end

return M
