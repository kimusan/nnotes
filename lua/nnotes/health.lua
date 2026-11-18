local M = {}

function M.check()
  local ok, err = pcall(require, "nnotes")
  vim.health.start("nnotes")
  if not ok then
    vim.health.error("nnotes failed to load: " .. tostring(err))
    return
  end
  local nnotes = require("nnotes")
  local store = require("nnotes.store")
  local cfg = nnotes.config()

  vim.health.ok(("Config loaded, global_dir=%s"):format(cfg.global_dir))
  if vim.loop.fs_stat(cfg.global_dir) then
    vim.health.ok("Global notes directory exists")
  else
    vim.health.warn("Global notes directory missing: " .. cfg.global_dir)
  end

  -- template dir: bundled always ships; a user templates_dir should exist
  local templates = require("nnotes.templates")
  if vim.loop.fs_stat(templates.bundled_dir()) then
    vim.health.ok("Bundled templates present")
  else
    vim.health.warn("Bundled templates dir missing: " .. templates.bundled_dir())
  end
  if cfg.templates_dir then
    if vim.loop.fs_stat(cfg.templates_dir) then
      vim.health.ok("User templates_dir present")
    else
      vim.health.warn("templates_dir does not exist: " .. cfg.templates_dir)
    end
  end

  -- age presence: required only when encryption is enabled
  if cfg.sync.encryption.enabled then
    if vim.fn.executable("age") == 1 then
      vim.health.ok("age binary found")
    else
      vim.health.error("age not found; install it for encrypted sync (e.g. apt install age)")
    end
  end

  -- git repo state per scope
  local function repo_status(dir, label)
    if not dir or not vim.loop.fs_stat(dir) then
      vim.health.warn(label .. ": directory missing")
      return
    end
    if vim.loop.fs_stat(dir .. "/.git") then
      local remote = vim.fn.system({ "git", "-C", dir, "remote", "get-url", "origin" })
      if vim.v.shell_error == 0 and remote ~= "" then
        vim.health.ok(("%s: git repo, remote %s"):format(label, remote))
      else
        vim.health.info(("%s: git repo (no remote)"):format(label))
      end
    else
      vim.health.info(("%s: not yet a git repo (run init_scope)"):format(label))
    end
  end
  repo_status(store.global_dir(), "Global scope")
  local root = store.find_project_root(vim.api.nvim_buf_get_name(0))
  if root then
    repo_status(store.project_dir(root), "Project scope")
  end

  -- snacks availability
  local ok_snacks = pcall(require, "snacks")
  if ok_snacks then
    vim.health.ok("snacks.nvim available (picker/explorer/notifier)")
  else
    vim.health.warn("snacks.nvim not available; falling back to vim.ui.select")
  end
end

return M
