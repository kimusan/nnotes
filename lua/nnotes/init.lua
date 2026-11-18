local M = {}

local _config = nil

local defaults = {
  global_dir = vim.fn.stdpath("data") .. "/nnotes",
  project_dir = ".nnotes",
  project_root_patterns = { ".git", ".neoconf.json" },
  filename_pattern = "%Y-%m-%d",
  link_style = "wiki",
  templates_dir = nil,
  default_template = { global = "daily", project = "project" },
  sidebar = { win = { position = "left", width = 25 } },
  notifications = {
    enabled = true,
    lead_time = "1d",
    quiet_hours = { "22:00", "07:00" },
  },
  sync = {
    enabled = false,
    remotes = { global = nil, project = nil },
    auto_commit = true,
    encryption = { enabled = false, recipient_file = nil, key_file = nil },
  },
  keys = {
    new = "<leader>nn",
    today = "<leader>nt",
    new_template = "<leader>nN",
    search = "<leader>nf",
    recent = "<leader>nr",
    tags = "<leader>ny",
    backlinks = "<leader>nb",
    follow_link = "<leader>lj",
    make_link = "<leader>nk",
    sidebar = "<leader>ns",
    toc = "<leader>nT",
    deadlines = "<leader>nd",
    rename = "<leader>nm",
    delete = "<leader>nx",
    move = "<leader>nM",
    sync = "<leader>nS",
    sync_status = "<leader>ng",
  },
}

-- vim.keymap.set expands <leader> at set-time, so a binding written as
-- "<leader>nN" sticks to whatever mapleader is when setup() runs. Bind the
-- expanded raw key, and re-apply when the leader changes (BufReadPost fires
-- on every buffer load, which catches a leader set in a file read after
-- setup). Same pattern as mywords.
local function expand_leader(lhs)
  return lhs
    :gsub("<leader>", function()
      return vim.g.mapleader or "\\"
    end)
    :gsub("<LocalLeader>", function()
      return vim.g.maplocalleader or "\\"
    end)
end

local function leader_sig()
  return (vim.g.mapleader or "\\") .. "|" .. (vim.g.maplocalleader or "\\")
end

local applied, applied_leader = {}, nil

local function apply_keymaps(cfg)
  for _, m in ipairs(applied) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  applied = {}
  applied_leader = leader_sig()

  local picker = require("nnotes.picker")
  local deadlines = require("nnotes.deadlines")
  local sidebar = require("nnotes.sidebar")
  local sync = require("nnotes.sync")
  local links = require("nnotes.links")
  local entries = {
    { mode = "n", lhs = cfg.keys.new, rhs = function() picker.new() end, desc = "Nnotes: New note" },
    { mode = "n", lhs = cfg.keys.today, rhs = function() picker.today() end, desc = "Nnotes: Today's note" },
    { mode = "n", lhs = cfg.keys.new_template, rhs = function() picker.new_from_template() end, desc = "Nnotes: New note from template" },
    { mode = "n", lhs = cfg.keys.search, rhs = function() picker.search() end, desc = "Nnotes: Search notes" },
    { mode = "n", lhs = cfg.keys.recent, rhs = function() picker.recents() end, desc = "Nnotes: Recent notes" },
    { mode = "n", lhs = cfg.keys.tags, rhs = function() picker.tags() end, desc = "Nnotes: Tags" },
    { mode = "n", lhs = cfg.keys.backlinks, rhs = function() picker.backlinks() end, desc = "Nnotes: Backlinks" },
    { mode = "n", lhs = cfg.keys.follow_link, rhs = function() links.follow_link() end, desc = "Nnotes: Follow link" },
    { mode = "n", lhs = cfg.keys.make_link, rhs = function() links.make_link() end, desc = "Nnotes: Make link" },
    { mode = "n", lhs = cfg.keys.deadlines, rhs = function() deadlines.pick() end, desc = "Nnotes: Upcoming deadlines" },
    { mode = "n", lhs = cfg.keys.sidebar, rhs = function() sidebar.toggle() end, desc = "Nnotes: Toggle sidebar" },
    { mode = "n", lhs = cfg.keys.rename, rhs = function() picker.rename() end, desc = "Nnotes: Rename note" },
    { mode = "n", lhs = cfg.keys.delete, rhs = function() picker.delete() end, desc = "Nnotes: Delete note" },
    { mode = "n", lhs = cfg.keys.move, rhs = function() picker.move() end, desc = "Nnotes: Move note" },
    { mode = "n", lhs = cfg.keys.sync, rhs = function() sync.sync_current() end, desc = "Nnotes: Sync" },
    { mode = "n", lhs = cfg.keys.sync_status, rhs = function() sync.status_current() end, desc = "Nnotes: Sync status" },
  }
  for _, e in ipairs(entries) do
    if e.lhs and e.lhs ~= "" then
      local lhs = expand_leader(e.lhs)
      vim.keymap.set(e.mode, lhs, e.rhs, { desc = e.desc })
      table.insert(applied, { mode = e.mode, lhs = lhs })
    end
  end
end

M.setup = function(opts)
  opts = opts or {}
  _config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if not vim.loop.fs_stat(_config.global_dir) then
    vim.fn.mkdir(_config.global_dir, "p")
  end

  local store = require("nnotes.store")
  store.init(_config)
  require("nnotes.formatting").setup(_config)
  require("nnotes.deadlines").setup()

  apply_keymaps(_config)
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("nnotes", {}),
    callback = function()
      if applied_leader ~= leader_sig() then
        apply_keymaps(_config)
      end
    end,
  })

  return M
end

M.config = function()
  if not _config then
    M.setup({})
  end
  return _config
end

M.word_count = function()
  return require("nnotes.formatting").word_count()
end

return M
