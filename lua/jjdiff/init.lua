local config = require("jjdiff.config")
local diff = require("jjdiff.diff")
local highlights = require("jjdiff.highlights")
local inline = require("jjdiff.inline")
local jj = require("jjdiff.jj")
local radar = require("jjdiff.radar")
local state = require("jjdiff.state")

local M = {}

local STATUSCOLUMN_EXPR = "%!v:lua.require('jjdiff.gutter').render()"

M._setup_called = false
M._highlights_ready = false
M._mapped_lhs = vim.g._jjdiff_default_mapped_lhs
M._runtime_active = false

local dp_ns = vim.api.nvim_create_namespace("jjdiff_win_sync")

---Normalize winid (0 or nil -> current window).
---@param winid? integer
---@return integer
local function resolve_win(winid)
  if not winid or winid == 0 then
    return vim.api.nvim_get_current_win()
  end
  return winid
end

---Ensure highlight groups and ColorScheme listener are initialized without duplicating autocmds.
---@param force? boolean
local function ensure_highlights(force)
  if force or not M._highlights_ready then
    highlights.apply()
    M._highlights_ready = true
    local color_augroup = vim.api.nvim_create_augroup("JJDiffColors", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = color_augroup,
      callback = function()
        highlights.apply()
      end,
    })
  end
end

---Install or update the Normal-mode toggle keymap.
---@param lhs string|false|nil
local function apply_keymap(lhs)
  if M._mapped_lhs and M._mapped_lhs ~= lhs then
    pcall(vim.keymap.del, "n", M._mapped_lhs)
    M._mapped_lhs = nil
    vim.g._jjdiff_default_mapped_lhs = nil
  end
  if type(lhs) == "string" and lhs ~= "" then
    vim.keymap.set("n", lhs, "<Plug>(JJDiffToggle)", {
      silent = true,
      desc = "Toggle jj diff HUD",
    })
    M._mapped_lhs = lhs
  end
end

---Disable jjdiff HUD in all active windows displaying bufnr.
---@param bufnr integer
local function disable_buf_windows(bufnr)
  local to_disable = {}
  for active_win, ws in pairs(state.wins) do
    if ws.bufnr == bufnr then
      to_disable[#to_disable + 1] = active_win
    end
  end
  for _, active_win in ipairs(to_disable) do
    M.disable(active_win)
  end
end

---Shift a 1-based line-keyed map after an `on_lines` buffer edit.
---@generic V
---@param map table<integer, V>
---@param lastline integer 0-based exclusive end of replaced range
---@param new_lastline integer 0-based exclusive end of new range
---@param delta integer
---@param new_line_count integer
---@return table<integer, V>
local function shift_line_map(map, lastline, new_lastline, delta, new_line_count)
  local out = {}
  for lnum, val in pairs(map) do
    if lnum > lastline then
      local nl = lnum + delta
      if nl >= 1 and nl <= new_line_count then
        out[nl] = val
      end
    elseif delta > 0 or lnum <= new_lastline then
      if lnum >= 1 and lnum <= new_line_count then
        out[lnum] = val
      end
    end
  end
  return out
end

---Shift hunk buffer line anchors after an `on_lines` buffer edit.
---@param hunks JJDiffHunk[]
---@param lastline integer
---@param new_lastline integer
---@param delta integer
---@param new_line_count integer
---@return JJDiffHunk[]
local function shift_hunks(hunks, lastline, new_lastline, delta, new_line_count)
  local function shift_pos(lnum, is_end)
    local res
    if lnum > lastline then
      res = lnum + delta
    elseif delta < 0 and lnum > new_lastline then
      res = is_end and new_lastline or (new_lastline + 1)
    else
      res = lnum
    end
    return math.max(1, math.min(res, new_line_count))
  end

  local out = {}
  for i, h in ipairs(hunks) do
    local copy = vim.tbl_extend("force", {}, h)
    local ns = shift_pos(h.buf_start, false)
    local ne = shift_pos(h.buf_end, true)
    if ne < ns then
      ne = ns
    end
    copy.buf_start = ns
    copy.buf_end = ne
    out[i] = copy
  end
  return out
end

---Attach live line-shift tracking to bufnr once per active buffer session.
---@param bufnr integer
local function attach_buf_sync(bufnr)
  if state.buf_attached[bufnr] then
    return
  end
  local ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, _, lastline, new_lastline)
      if not state.buf_refs[buf] then
        state.buf_attached[buf] = nil
        return true
      end
      local delta = new_lastline - lastline
      if delta == 0 then
        return false
      end

      local new_line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
      local new_hunks, new_status, new_vlines
      for _, ws in pairs(state.wins) do
        if ws.bufnr == buf then
          if not new_hunks then
            new_hunks = shift_hunks(ws.hunks, lastline, new_lastline, delta, new_line_count)
            new_status = shift_line_map(ws.line_status or {}, lastline, new_lastline, delta, new_line_count)
            new_vlines = shift_line_map(ws.virt_lines_lnums or {}, lastline, new_lastline, delta, new_line_count)
          end
          ws.hunks = new_hunks
          ws.line_status = new_status
          ws.virt_lines_lnums = new_vlines
          ws._last_radar_key = nil
        end
      end

      if new_hunks then
        vim.schedule(function()
          if not state.buf_refs[buf] or not vim.api.nvim_buf_is_valid(buf) then
            return
          end
          local live_vlines = {}
          local ems = vim.api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })
          for _, em in ipairs(ems) do
            if em[4] and em[4].virt_lines then
              live_vlines[em[2] + 1] = true
            end
          end
          for _, ws in pairs(state.wins) do
            if ws.bufnr == buf then
              ws.virt_lines_lnums = live_vlines
              radar.update(ws)
            end
          end
        end)
      end

      return false
    end,
    on_detach = function(_, buf)
      state.buf_attached[buf] = nil
    end,
  })
  if ok then
    state.buf_attached[bufnr] = true
  end
end

---Install runtime autocmds when at least one window has jjdiff active.
local function ensure_runtime_autocmds()
  if M._runtime_active then
    return
  end
  M._runtime_active = true
  local group = vim.api.nvim_create_augroup("JJDiffRuntime", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(ev)
      for winid, ws in pairs(state.wins) do
        if ws.bufnr == ev.buf and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == ev.buf then
          radar.update(ws)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(ev)
      local scrolled_win = tonumber(ev.match)
      if scrolled_win and state.wins[scrolled_win] then
        radar.update(state.wins[scrolled_win])
        return
      end
      for _, ws in pairs(state.wins) do
        radar.update(ws)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for _, ws in pairs(state.wins) do
        radar.update(ws)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function()
      local new_win = vim.api.nvim_get_current_win()
      if state.wins[new_win] or not vim.api.nvim_win_is_valid(new_win) then
        return
      end
      if vim.wo[new_win].statuscolumn ~= STATUSCOLUMN_EXPR then
        return
      end

      local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))
      local source_ws = state.wins[prev_win]
      if not source_ws then
        local new_buf = vim.api.nvim_win_get_buf(new_win)
        for _, ws in pairs(state.wins) do
          if ws.bufnr == new_buf then
            source_ws = ws
            break
          end
        end
      end

      if source_ws then
        vim.wo[new_win].statuscolumn = source_ws.orig_opts.statuscolumn
        vim.wo[new_win].number = source_ws.orig_opts.number
        vim.wo[new_win].scrolloff = source_ws.orig_opts.scrolloff
      else
        vim.wo[new_win].statuscolumn = vim.go.statuscolumn
        vim.wo[new_win].scrolloff = vim.go.scrolloff
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed_win = tonumber(ev.match)
      if closed_win and state.wins[closed_win] then
        M.disable(closed_win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      local stale = {}
      for winid, ws in pairs(state.wins) do
        if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= ws.bufnr then
          stale[#stale + 1] = winid
        end
      end
      for _, winid in ipairs(stale) do
        M.disable(winid)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      disable_buf_windows(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      for winid, ws in pairs(state.wins) do
        if ws.bufnr == ev.buf then
          M.refresh(winid, { async = true })
          break
        end
      end
    end,
  })

  vim.api.nvim_set_decoration_provider(dp_ns, {
    on_win = function(_, winid)
      local ws = state.wins[winid]
      if not ws or ws._radar_scheduled then
        return false
      end
      if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= ws.bufnr then
        return false
      end
      local info = vim.fn.getwininfo(winid)[1]
      local win_w = vim.api.nvim_win_get_width(winid)
      local text_h = (info and info.height) or vim.api.nvim_win_get_height(winid)
      local textoff = (info and info.textoff) or 6
      local key = string.format(
        "%d:%d:%d:%d:%d:%d",
        vim.fn.line("w0", winid),
        vim.fn.line("w$", winid),
        vim.api.nvim_win_get_cursor(winid)[1],
        win_w,
        text_h,
        textoff
      )
      local floats_missing = text_h >= 3
        and win_w >= 10
        and (
          not (ws.top_win and vim.api.nvim_win_is_valid(ws.top_win))
          or not (ws.bot_win and vim.api.nvim_win_is_valid(ws.bot_win))
        )
      if key ~= ws._last_radar_key or floats_missing then
        ws._radar_scheduled = true
        vim.schedule(function()
          if state.wins[winid] == ws then
            radar.update(ws)
          end
        end)
      end
      return false
    end,
  })
end

---Configure jjdiff.nvim.
---@param opts? table
function M.setup(opts)
  M._setup_called = true
  vim.g._jjdiff_setup_called = true
  local cfg = config.setup(opts)
  ensure_highlights(true)

  local explicit_keymap = opts and opts.keymap ~= nil
  if explicit_keymap then
    apply_keymap(cfg.keymap)
  elseif not vim.g.jjdiff_no_default_maps and type(cfg.keymap) == "string" and cfg.keymap ~= "" then
    if
      M._mapped_lhs == cfg.keymap
      or (vim.fn.hasmapto("<Plug>(JJDiffToggle)", "n") == 0 and vim.fn.maparg(cfg.keymap, "n") == "")
    then
      apply_keymap(cfg.keymap)
    end
  end
end

---Return true if jjdiff HUD is active in winid (defaults to current window).
---@param winid? integer
---@return boolean
function M.is_active(winid)
  local w = resolve_win(winid)
  return state.wins[w] ~= nil
end

---Enable jjdiff HUD in winid (defaults to current window).
---@param winid? integer
---@return boolean
function M.enable(winid)
  local w = resolve_win(winid)
  if not vim.api.nvim_win_is_valid(w) then
    return false
  end
  if state.wins[w] then
    return true
  end

  local bufnr = vim.api.nvim_win_get_buf(w)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or bufname == "" then
    vim.notify("jjdiff: current buffer is not a file on disk", vim.log.levels.WARN)
    return false
  end

  if vim.bo[bufnr].modified then
    vim.notify("jjdiff: file has unsaved changes — please :w first", vim.log.levels.ERROR)
    return false
  end

  ensure_highlights()

  local res = jj.diff_file(bufname)
  if not res.ok then
    vim.notify(res.err or "jjdiff: failed to run jj diff", vim.log.levels.ERROR)
    return false
  end
  if res.binary then
    vim.notify("jjdiff: binary file diff is not supported", vim.log.levels.WARN)
    return false
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local hunks = diff.parse_git_diff(res.diff, line_count)
  if #hunks == 0 then
    vim.notify("jjdiff: no changes in " .. vim.fn.fnamemodify(bufname, ":t"), vim.log.levels.INFO)
    return false
  end

  local cfg = config.get()
  local rendered = inline.render(bufnr, hunks, cfg.inline_similarity_threshold)
  state.buf_refs[bufnr] = (state.buf_refs[bufnr] or 0) + 1

  for _, ws in pairs(state.wins) do
    if ws.bufnr == bufnr then
      ws.filepath = bufname
      ws.hunks = hunks
      ws.line_status = rendered.line_status
      ws.virt_lines_lnums = rendered.virt_lines_lnums
      ws._last_radar_key = nil
      radar.update(ws)
    end
  end

  local orig_opts = {
    statuscolumn = vim.wo[w].statuscolumn,
    number = vim.wo[w].number,
    scrolloff = vim.wo[w].scrolloff,
  }

  vim.wo[w].number = true
  vim.wo[w].scrolloff = math.max(orig_opts.scrolloff or 0, cfg.min_scrolloff or 2)
  vim.wo[w].statuscolumn = STATUSCOLUMN_EXPR

  ---@type JJDiffWinState
  local win_state = {
    winid = w,
    bufnr = bufnr,
    filepath = bufname,
    hunks = hunks,
    line_status = rendered.line_status,
    virt_lines_lnums = rendered.virt_lines_lnums,
    orig_opts = orig_opts,
  }
  state.wins[w] = win_state

  attach_buf_sync(bufnr)
  radar.ensure_floats(win_state)
  radar.update(win_state)
  ensure_runtime_autocmds()

  return true
end

---Disable jjdiff HUD in winid (defaults to current window).
---@param winid? integer
---@return boolean
function M.disable(winid)
  local w = resolve_win(winid)
  local win_state = state.wins[w]
  if not win_state then
    return false
  end

  radar.close(win_state)

  if vim.api.nvim_win_is_valid(w) then
    local orig = win_state.orig_opts
    vim.wo[w].statuscolumn = orig.statuscolumn
    vim.wo[w].number = orig.number
    vim.wo[w].scrolloff = orig.scrolloff
  end

  local bufnr = win_state.bufnr
  local refs = (state.buf_refs[bufnr] or 1) - 1
  if refs <= 0 then
    state.buf_refs[bufnr] = nil
    state.buf_refresh_seq[bufnr] = nil
    inline.clear(bufnr)
  else
    state.buf_refs[bufnr] = refs
  end

  state.wins[w] = nil

  if next(state.wins) == nil then
    M._runtime_active = false
    vim.api.nvim_create_augroup("JJDiffRuntime", { clear = true })
    vim.api.nvim_set_decoration_provider(dp_ns, {})
  end

  return true
end

---Apply a completed diff result across all active windows viewing bufnr.
---@param bufnr integer
---@param bufname string
---@param res { ok: boolean, diff?: string, binary?: boolean, err?: string }
---@return boolean
local function apply_refresh(bufnr, bufname, res)
  if not res.ok or res.binary then
    if not res.ok then
      vim.notify(res.err or "jjdiff: failed to refresh jj diff", vim.log.levels.ERROR)
    end
    disable_buf_windows(bufnr)
    return false
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local hunks = diff.parse_git_diff(res.diff, line_count)
  if #hunks == 0 then
    vim.notify("jjdiff: no changes remaining", vim.log.levels.INFO)
    disable_buf_windows(bufnr)
    return false
  end

  local cfg = config.get()
  local rendered = inline.render(bufnr, hunks, cfg.inline_similarity_threshold)
  for _, ws in pairs(state.wins) do
    if ws.bufnr == bufnr then
      ws.filepath = bufname
      ws.hunks = hunks
      ws.line_status = rendered.line_status
      ws.virt_lines_lnums = rendered.virt_lines_lnums
      ws._last_radar_key = nil
      radar.update(ws)
    end
  end

  return true
end

---Refresh diff data and overlays for an active window and any sibling windows on the same buffer.
---@param winid? integer
---@param opts? { async?: boolean }
---@return boolean
function M.refresh(winid, opts)
  local w = resolve_win(winid)
  local win_state = state.wins[w]
  if not win_state then
    return false
  end

  if not vim.api.nvim_win_is_valid(w) or not vim.api.nvim_buf_is_valid(win_state.bufnr) then
    M.disable(w)
    return false
  end

  local bufnr = win_state.bufnr
  if vim.bo[bufnr].modified then
    return false
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if opts and opts.async then
    local seq = (state.buf_refresh_seq[bufnr] or 0) + 1
    state.buf_refresh_seq[bufnr] = seq
    jj.diff_file_async(bufname, function(res)
      if
        state.buf_refresh_seq[bufnr] ~= seq
        or not state.buf_refs[bufnr]
        or not vim.api.nvim_buf_is_valid(bufnr)
        or vim.bo[bufnr].modified
      then
        return
      end
      apply_refresh(bufnr, vim.api.nvim_buf_get_name(bufnr), res)
    end)
    return true
  end

  local res = jj.diff_file(bufname)
  return apply_refresh(bufnr, bufname, res)
end

---Toggle jjdiff HUD in winid (defaults to current window).
---@param winid? integer
---@return boolean
function M.toggle(winid)
  local w = resolve_win(winid)
  if M.is_active(w) then
    M.disable(w)
    return false
  end
  return M.enable(w)
end

return M
