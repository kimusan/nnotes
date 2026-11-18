local M = {}
local store = require("nnotes.store")

local DAY = 86400

local function config()
  return require("nnotes").config()
end

local function date_epoch(t)
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
end

local function from_epoch(epoch)
  local t = os.date("*t", epoch)
  return { year = t.year, month = t.month, day = t.day }
end

------------------------------
-- Pure date helpers
------------------------------

-- parse "YYYY-MM-DD" -> {year, month, day} or nil
M.parse_date = function(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

M.fmt_date = function(t)
  return ("%04d-%02d-%02d"):format(t.year, t.month, t.day)
end

M.today = function(now)
  now = now or os.date("*t")
  return { year = now.year, month = now.month, day = now.day }
end

-- whole days from `from` to `to` (positive when to is later). noon anchors
-- keep this exact across DST transitions.
M.days_between = function(from, to)
  return math.floor((date_epoch(to) - date_epoch(from)) / DAY)
end

M.add_days = function(t, n)
  return from_epoch(date_epoch(t) + n * DAY)
end

local function last_day(y, m)
  local nm, ny = m + 1, y
  if nm > 12 then
    nm, ny = 1, y + 1
  end
  -- midnight of the 1st of next month, minus one second, is 23:59:59 of the
  -- last day of the target month. time fields are zeroed so "now" doesn't
  -- leak in and push the anchor forward within the day.
  return os.date("*t", os.time({ year = ny, month = nm, day = 1, hour = 0, min = 0, sec = 0 }) - 1).day
end

M.add_months = function(t, n)
  local total = (t.year * 12 + (t.month - 1)) + n
  local y = math.floor(total / 12)
  local m = total % 12 + 1
  return { year = y, month = m, day = math.min(t.day, last_day(y, m)) }
end

-- parse "1d" / "2w" / "30m" / "4h" into a number of days
M.parse_duration = function(s)
  if type(s) ~= "string" then
    return nil
  end
  local n, unit = s:match("^(%d+)%s*(%a+)$")
  if not n then
    return nil
  end
  local mult = { d = 1, w = 7, h = 1 / 24, m = 1 / (24 * 60) }
  if not mult[unit] then
    return nil
  end
  return tonumber(n) * mult[unit]
end

-- advance a deadline one period; nil when recurs is not a real period
M.next_deadline = function(deadline_str, recurs)
  local t = M.parse_date(deadline_str)
  if not t then
    return nil
  end
  if recurs == "daily" then
    return M.fmt_date(M.add_days(t, 1))
  elseif recurs == "weekly" then
    return M.fmt_date(M.add_days(t, 7))
  elseif recurs == "monthly" then
    return M.fmt_date(M.add_months(t, 1))
  end
  return nil
end

-- is `now` (a *t table) inside the quiet window? handles overnight ranges.
M.in_quiet_hours = function(now, hours)
  if not hours or #hours < 2 then
    return false
  end
  now = now or os.date("*t")
  local cur = now.hour * 60 + now.min
  local function to_min(s)
    local h, m = s:match("^(%d%d?):(%d%d)$")
    if not h then
      return nil
    end
    return tonumber(h) * 60 + tonumber(m)
  end
  local start, stop = to_min(hours[1]), to_min(hours[2])
  if not start or not stop then
    return false
  end
  if start < stop then
    return cur >= start and cur < stop
  end
  return cur >= start or cur < stop
end

-- "overdue" | "due" | "soon" | nil, plus the signed days-to-due
M.due_status = function(rec, today, lead_days)
  if rec.status == "done" then
    return nil
  end
  local dl = M.parse_date(rec.deadline)
  if not dl then
    return nil
  end
  today = today or M.today()
  lead_days = lead_days or 0
  local d = M.days_between(today, dl)
  if d < 0 then
    return "overdue", d
  elseif d == 0 then
    return "due", d
  elseif d <= lead_days then
    return "soon", d
  end
  return nil
end

-- {level, message, status, days} for a due note, else nil
M.describe = function(rec, today, lead_days)
  local status, d = M.due_status(rec, today, lead_days)
  if not status then
    return nil
  end
  local when
  if d < 0 then
    when = ("%dd overdue"):format(-d)
  elseif d == 0 then
    when = "due today"
  else
    when = ("due in %dd"):format(d)
  end
  local level = status == "overdue" and "error" or (status == "due" and "warn" or "info")
  return {
    level = level,
    message = ("%s %s"):format(rec.title or "note", when),
    status = status,
    days = d,
  }
end

------------------------------
-- Buffer / picker integration
------------------------------

-- advance a completed recurring note to its next period (status -> active)
M.roll_forward = function(path)
  local notes = require("nnotes.notes")
  local meta, body = notes.read(path)
  if not meta or meta.status ~= "done" then
    return nil
  end
  local next = M.next_deadline(meta.deadline, meta.recurs)
  if not next then
    return nil
  end
  meta.deadline = next
  meta.status = "active"
  notes.write(path, meta, body)
  return next
end

local function notify_level(level)
  if level == "error" then
    return vim.log.ERROR
  elseif level == "warn" then
    return vim.log.WARN
  end
  return vim.log.INFO
end

M.notify_for = function(rec, now)
  local n = config().notifications
  if not n or not n.enabled then
    return
  end
  now = now or os.date("*t")
  if M.in_quiet_hours(now, n.quiet_hours) then
    return
  end
  local lead = M.parse_duration(n.lead_time) or 1
  local info = M.describe(rec, M.today(now), lead)
  if not info then
    return
  end
  local msg = "[nnotes] " .. info.message
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.notifier then
    Snacks.notifier.notify(msg, info.level, { title = "nnotes" })
  else
    vim.notify(msg, notify_level(info.level))
  end
end

-- self-heal a completed recurring note, then notify if it is due
M.check_buffer = function(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  local rec = store.get_by_path(path)
  if not rec then
    return
  end
  M.roll_forward(path)
  rec = store.get_by_path(path)
  if not rec then
    return
  end
  M.notify_for(rec)
end

-- picker items for every note with a deadline, soonest first
M.deadlines = function()
  local today = M.today()
  local items = {}
  for _, rec in ipairs(store.index()) do
    local dl = M.parse_date(rec.deadline)
    if dl then
      local d = M.days_between(today, dl)
      local when
      if rec.status == "done" then
        when = "done"
      elseif d < 0 then
        when = ("%dd overdue"):format(-d)
      elseif d == 0 then
        when = "due today"
      else
        when = ("in %dd"):format(d)
      end
      table.insert(items, {
        text = ("%s  (%s)  %s  %s"):format(rec.title, rec.scope, rec.deadline, when),
        file = rec.path,
        rec = rec,
        _days = d,
      })
    end
  end
  table.sort(items, function(a, b)
    return a._days < b._days
  end)
  return items
end

M.pick = function()
  local items = M.deadlines()
  if #items == 0 then
    vim.notify("No notes with deadlines", vim.log.INFO)
    return
  end
  require("nnotes.picker").open("Upcoming deadlines", items, function(it)
    if it.file and vim.loop.fs_stat(it.file) then
      vim.cmd("edit " .. vim.fn.fnameescape(it.file))
    end
  end)
end

M.setup = function()
  M.check_buffer(0)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("nnotes.deadlines", { clear = true }),
    pattern = "*.md",
    callback = function(ev)
      M.check_buffer(ev.buf)
    end,
  })
end

return M
