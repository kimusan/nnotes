# nnotes.nvim

A markdown scratchpad and journal for Neovim. Global and per-project notes,
wiki-links with backlinks, templates, deadlines with notifications, a
sidebar, and optional GitHub sync with client-side age encryption. Builds on
[snacks.nvim](https://github.com/folke/snacks.nvim) where it helps and works
without it.

## Features

- Global notes in `stdpath("data")/nnotes`, project notes in `<root>/.nnotes`.
- Note CRUD: create, rename (rewrites incoming links), duplicate, move,
  delete to trash (never `rm`).
- `[[Wiki Links]]` and `[md links](rel.md)`, resolved against a live index,
  with a backlinks picker and follow/make-link commands.
- Markdown formatting keymaps (insert + normal, markdown files only): bold,
  italic, underline, strikethrough, headings, list/task/quote toggles,
  auto-continue on Enter, table of contents, and a statusline word count.
- Templates with `{{date}}`, `{{datetime}}`, `{{title}}`, `{{project}}`,
  `{{scope}}` placeholders, plus bundled daily/weekly/project/meeting/scratch.
- Deadlines with recurring roll-forward, lead-time and quiet-hour aware
  notifications, and an upcoming-deadlines picker.
- A sidebar (snacks.explorer) rooted at the active scope, with rename/delete
  routed through the plugin.
- Optional GitHub sync per scope with age client-side encryption.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kimusan/nnotes.nvim",
  opts = {},
  -- For local development, use the dev path instead:
  -- { "/home/you/Projects/nnotes", opts = {} }
}
```

snacks.nvim is optional. With it you get the picker and explorer UIs; without
it, nnotes falls back to `vim.ui.select` and the sidebar shows a notice.

## Setup

All options are optional and shown with defaults:

```lua
require("nnotes").setup({
  global_dir = vim.fn.stdpath("data") .. "/nnotes",
  project_dir = ".nnotes",
  project_root_patterns = { ".git", ".neoconf.json" },
  filename_pattern = "%Y-%m-%d",        -- date prefix for new notes
  link_style = "wiki",                   -- "wiki" | "markdown"
  templates_dir = nil,                   -- default: <global_dir>/templates
  templates = {},                        -- inline templates: { name = "..." }
  default_template = { global = "daily", project = "project" },
  sidebar = { win = { position = "left", width = 25 } },
  notifications = {
    enabled = true,
    lead_time = "1d",                    -- notify this many days before due
    quiet_hours = { "22:00", "07:00" },
  },
  sync = {
    enabled = false,
    remotes = { global = nil, project = nil },  -- git remote URLs
    auto_commit = true,
    encryption = {
      enabled = false,
      recipient_file = nil,
      key_file = nil,
    },
  },
  keys = {
    new = "<leader>nn", today = "<leader>nt",
    new_template = "<leader>nN", search = "<leader>nf",
    recent = "<leader>nr", tags = "<leader>ny",
    backlinks = "<leader>nb", follow_link = "<leader>lj",
    make_link = "<leader>nk", sidebar = "<leader>ns",
    toc = "<leader>nT", deadlines = "<leader>nd",
    rename = "<leader>nm", delete = "<leader>nx", move = "<leader>nM",
    sync = "<leader>nS", sync_status = "<leader>ng",
  },
})
```

Set any key to `""` to disable it. The markdown formatting keymaps are fixed
(`<M-b>` etc.) and only active in markdown buffers.

## Notes on disk

Each note is a markdown file named `YYYY-MM-DD-slug.md` with a small YAML
frontmatter subset:

```markdown
---
title: My Note
created: 2026-11-18
updated: 2026-11-18
project: myproject      # project-scope notes only
deadline: 2026-12-01    # optional
recurs: weekly          # none | daily | weekly | monthly, with deadline
status: active          # idea | active | done
tags:
  - work
  - idea
---

Body with [[Other Note]] or [links](sibling.md).
```

Only `updated` is touched automatically on save. A completed (`status: done`)
recurring note rolls its deadline forward to the next period the next time it
is opened.

## Keybindings

Global (normal mode, leader is your `mapleader`):

| Key             | Action                                |
| --------------- | ------------------------------------- |
| `<leader>nn`    | New note (scope + title prompt)       |
| `<leader>nt`    | Open or create today's note           |
| `<leader>nN`    | New note from a template              |
| `<leader>nf`    | Fuzzy search all notes                |
| `<leader>nr`    | Recent notes                          |
| `<leader>ny`    | Browse by tag                         |
| `<leader>nb`    | Backlinks for the current note        |
| `<leader>lj`    | Follow the link under the cursor      |
| `<leader>nk`    | Insert a link to the current note     |
| `<leader>ns`    | Toggle the notes sidebar              |
| `<leader>nT`    | Generate a table of contents (md)     |
| `<leader>nd`    | Upcoming deadlines                    |
| `<leader>nm`    | Rename the current note               |
| `<leader>nx`    | Delete the current note (to trash)    |
| `<leader>nM`    | Move the current note between scopes  |
| `<leader>nS`    | Sync (commit, push, ff-only pull)     |
| `<leader>ng`    | Sync status                           |

Markdown files (insert + normal; line ops also work on a visual line range):

| Key                     | Action                                     |
| ----------------------- | ------------------------------------------ |
| `<M-b>`                 | Toggle bold                                |
| `<M-i>`                 | Toggle italic                              |
| `<M-u>`                 | Toggle underline                           |
| `<M-s>`                 | Toggle strikethrough                       |
| `<M-h1>` to `<M-h6>`    | Toggle heading level 1 to 6                |
| `<M-l>`                 | Toggle list (`- `)                         |
| `<M-t>`                 | Toggle task (`- [ ]`)                      |
| `<M-q>`                 | Toggle quote (`> `)                        |
| `<CR>` (insert)         | Continue list/task/quote; blank item exits |

## Templates

Templates are looked up in this order: inline `opts.templates` strings, then
`opts.templates_dir`, then the bundled `templates/` directory. The bundled set
is `daily`, `weekly`, `project`, `meeting`, `scratch`. Available variables:

| Variable       | Value                               |
| -------------- | ----------------------------------- |
| `{{date}}`     | `YYYY-MM-DD` (today)                |
| `{{datetime}}` | `YYYY-MM-DD HH:MM` (now)            |
| `{{title}}`    | The note title                      |
| `{{project}}`  | Project root name (project scope)   |
| `{{scope}}`    | `global` or `project`               |

`<leader>nN` opens the template picker, then asks for a title and creates the
note. `notes.from_template(scope, name, title)` does the same programmatically.

## Sync and encryption

Each scope directory is its own git working tree. `<leader>nS` stages all
changes, auto-commits as `nnotes: YYYY-MM-DD <n> changes`, pushes, and does a
ff-only pull. It never force-pushes. `<leader>ng` shows the remote and a short
status.

To enable client-side encryption with [age](https://age-encryption.org), set
`sync.encryption.enabled = true` and export:

```sh
export NNOTES_AGE_RECIPIENT="age1...."   # recipient public key
export NNOTES_AGE_KEY=/path/to/identity  # key file path (age -d -i)
```

nnotes then adds a git clean/smudge filter and a `.gitattributes` line
(`*.md filter=agecrypt`) so note files are stored as age ciphertext and
decrypted on checkout. If the `age` binary is missing, sync degrades to a
notice and proceeds unencrypted. Run `require("nnotes.sync").init_scope(scope,
remote_url)` to set up a scope's repo, remote, and filters on first use.

## Healthcheck

Run `:checkhealth nnotes` to verify config, the notes directories, template
location, age presence (when encryption is on), git repo state per scope, and
snacks availability.

## API

```lua
local nnotes = require("nnotes")
nnotes.new(scope, title)        -- create a note
nnotes.open(note_or_path)
nnotes.rename(old, new)
nnotes.delete(note)
nnotes.search(query)
nnotes.deadlines()
nnotes.refresh()
nnotes.word_count()             -- current buffer body, frontmatter excluded
```
