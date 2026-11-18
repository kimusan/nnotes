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
    sync_status = "<leader>ns",
  },
}

M.setup = function(opts)
  opts = opts or {}
  _config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if not vim.loop.fs_stat(_config.global_dir) then
    vim.fn.mkdir(_config.global_dir, "p")
  end

  local store = require("nnotes.store")
  store.init(_config)
  require("nnotes.formatting").setup(_config)

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
