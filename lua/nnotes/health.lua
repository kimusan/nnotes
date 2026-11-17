local M = {}

function M.check()
  local ok = pcall(require, "nnotes")
  vim.health.start("nnotes")
  if ok then
    local nnotes = require("nnotes")
    local cfg = nnotes.config()
    vim.health.ok(("Config loaded, global_dir=%s"):format(cfg.global_dir))
    if vim.loop.fs_stat(cfg.global_dir) then
      vim.health.ok("Global notes directory exists")
    else
      vim.health.warn("Global notes directory missing: " .. cfg.global_dir)
    end
    if cfg.sync.encryption.enabled then
      if vim.fn.executable("age") then
        vim.health.ok("age binary found")
      else
        vim.health.error("age not found; install it for encrypted sync (e.g. apt install age)")
      end
    end
    local ok_snacks = pcall(require, "snacks")
    if ok_snacks then
      vim.health.ok("snacks.nvim available (picker/explorer/notifier)")
    else
      vim.health.warn("snacks.nvim not available; falling back to vim.ui.select")
    end
  else
    vim.health.error("nnotes failed to load: " .. tostring(ok))
  end
end

return M
