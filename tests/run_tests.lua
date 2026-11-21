-- Headless integration test suite for jjdiff.nvim
-- Run: nvim --headless -u NONE --cmd "set rtp+=." -l tests/run_tests.lua

-- Ensure runtime plugin/jjdiff.lua is sourced even before -l
vim.cmd("runtime! plugin/jjdiff.lua")

local jjdiff = require("jjdiff")
local inline = require("jjdiff.inline")
local state = require("jjdiff.state")
local gutter = require("jjdiff.gutter")

-- Capture vim.notify calls for assertions
local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = msg, level = level }
end

local function clear_notifications()
  notifications = {}
end

local function run_cmd(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(
    res.code == 0,
    string.format("command failed (%s): %s\nstderr: %s", tostring(res.code), table.concat(cmd, " "), res.stderr or "")
  )
  return res.stdout or ""
end

local function write_disk(path, lines)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, path)
end

local function pass(name)
  print("PASS: " .. name)
end

-- Create isolated temp jj repo
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local outside_file = vim.fn.tempname() .. "_outside.txt"
local sym_tmp = vim.fn.tempname()

local ok, err = xpcall(function()
  run_cmd({ "jj", "--no-pager", "git", "init" }, tmpdir)
  run_cmd({ "jj", "--no-pager", "config", "set", "--repo", "user.name", "Test User" }, tmpdir)
  run_cmd({ "jj", "--no-pager", "config", "set", "--repo", "user.email", "test@example.com" }, tmpdir)

  -- Configure deterministic 15-row window and baseline options
  vim.o.lines = 17
  vim.o.columns = 100
  vim.o.laststatus = 2
  vim.o.cmdheight = 1
  vim.wo.number = true
  vim.wo.wrap = true
  vim.wo.scrolloff = 0
  vim.wo.statuscolumn = ""

  -- Build baseline 125-line file and commit it in jj
  local main_file = tmpdir .. "/app.ts"
  local orig_lines = {
    "// top line 1 (will be deleted)",
    "// top line 2 (will be deleted)",
    "// header kept 1",
    "// header kept 2",
  }
  for i = 5, 125 do
    if i == 6 then
      orig_lines[i] = "const long_wrap_line = '" .. string.rep("w", 140) .. "'"
    elseif i == 25 then
      orig_lines[i] = "const port = 3000"
    elseif i == 60 then
      orig_lines[i] = "const alpha = 1"
    elseif i == 61 then
      orig_lines[i] = "const beta = 2"
    elseif i == 62 then
      orig_lines[i] = "const gamma = 3"
    elseif i == 124 then
      orig_lines[i] = "// line 124 kept"
    elseif i == 125 then
      orig_lines[i] = "// eof line 125 (will be deleted)"
    else
      orig_lines[i] = string.format("const item_%03d = %d", i, i)
    end
  end
  write_disk(main_file, orig_lines)

  -- Special character path in nested directory
  local special_file = tmpdir .. "/nested/(group)/[id]+page.ts"
  write_disk(special_file, { "export const title = 'old'", "export const count = 1" })

  run_cmd({ "jj", "--no-pager", "commit", "-m", "baseline" }, tmpdir)

  -- 1. Keymap & Command Registration
  do
    local maps = vim.api.nvim_get_keymap("n")
    local leader = vim.g.mapleader or "\\"
    local expected_lhs = leader .. "jj"
    local found_map = false
    for _, m in ipairs(maps) do
      if m.lhs == expected_lhs or m.lhs == "<Space>jj" then
        found_map = true
        break
      end
    end
    assert(found_map, "expected Normal-mode <leader>jj keymap to be registered")

    local cmds = vim.api.nvim_get_commands({})
    assert(cmds.JJDiff ~= nil, "expected :JJDiff user command to be registered")
    pass("1. Keymap & Command Registration")
  end

  -- Open main_file in a deterministic 15-row split window
  vim.cmd("split " .. vim.fn.fnameescape(main_file))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, 15)
  local bufnr = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_win_get_height(win) == 15, "expected window height 15, got " .. vim.api.nvim_win_get_height(win))

  -- 2. Unsaved Buffer Guard
  do
    clear_notifications()
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "// unsaved modification" })
    assert(vim.bo[bufnr].modified == true, "buffer should be marked modified")
    local active = jjdiff.toggle(win)
    assert(active == false and not jjdiff.is_active(win), "toggle must not activate on modified buffer")
    assert(#notifications == 1, "expected 1 error notification")
    assert(notifications[1].level == vim.log.levels.ERROR, "expected ERROR notification level")
    assert(notifications[1].msg:find(":w", 1, true) ~= nil, "expected error message to mention :w")
    -- Revert unsaved change
    vim.cmd("edit!")
    assert(vim.bo[bufnr].modified == false)
    pass("2. Unsaved Buffer Guard")
  end

  -- 3. Clean File Check
  do
    clear_notifications()
    local active = jjdiff.toggle(win)
    assert(active == false and not jjdiff.is_active(win), "toggle must remain inactive when file has no jj diff")
    assert(#notifications == 1, "expected 1 info notification")
    assert(notifications[1].level == vim.log.levels.INFO, "expected INFO notification level")
    pass("3. Clean File Check")
  end

  -- Prepare multi-hunk edits and save to disk:
  -- - Delete top 2 lines
  -- - Pure 3-line addition after line 38 (becomes around line 36-38, off-screen from row 1)
  -- - Inline change on "const port = 3000" -> "const port = 8080"
  -- - Multi-line replacement with surplus deleted line (alpha, beta, gamma -> alpha_v2, beta_v2)
  -- - Pure deletion at EOF (delete "// eof line 125 (will be deleted)")
  local edited_lines = {}
  for i = 3, #orig_lines - 1 do
    local line = orig_lines[i]
    if i == 25 then
      edited_lines[#edited_lines + 1] = "const port = 8080"
    elseif i == 40 then
      edited_lines[#edited_lines + 1] = line
      edited_lines[#edited_lines + 1] = "const added_1 = true"
      edited_lines[#edited_lines + 1] = "const added_2 = true"
      edited_lines[#edited_lines + 1] = "const added_3 = true"
    elseif i == 60 then
      edited_lines[#edited_lines + 1] = "const alpha = 100"
    elseif i == 61 then
      edited_lines[#edited_lines + 1] = "const beta = 200"
    elseif i == 62 then
      -- surplus deleted line (gamma removed)
    else
      edited_lines[#edited_lines + 1] = line
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, edited_lines)
  vim.cmd("silent write")
  assert(vim.bo[bufnr].modified == false)

  -- 4. Full Diff Rendering (Gutter + Virtual Deletions + Inline Word-Diff)
  do
    clear_notifications()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    -- Trigger via <leader>jj keymap
    local leader = vim.g.mapleader or "\\"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(leader .. "jj", true, false, true), "tx", false)
    assert(jjdiff.is_active(win) == true, "expected <leader>jj to activate jjdiff")

    local ws = state.wins[win]
    assert(ws ~= nil, "expected window state to be populated")
    assert(#ws.hunks >= 5, "expected at least 5 hunks, got " .. #ws.hunks)

    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, inline.ns, 0, -1, { details = true })
    assert(#extmarks > 0, "expected buffer extmarks")

    local found_virt_above = false
    local found_virt_eof = false
    local found_inline_del_3000 = false
    local found_inline_add_8080 = false

    for _, em in ipairs(extmarks) do
      local row, col, details = em[2], em[3], em[4]
      if details.virt_lines then
        if details.virt_lines_above then
          found_virt_above = true
        else
          found_virt_eof = true
        end
      end
      if details.virt_text_pos == "inline" and details.virt_text then
        for _, chunk in ipairs(details.virt_text) do
          if chunk[1] == "3000" and chunk[2] == "JJDiffDeleteInline" then
            found_inline_del_3000 = true
          end
        end
      end
      if details.hl_group == "JJDiffAddInline" and details.end_col then
        local text = vim.api.nvim_buf_get_text(bufnr, row, col, row, details.end_col, {})[1]
        if text == "8080" then
          found_inline_add_8080 = true
        end
      end
    end

    assert(found_virt_above, "expected virt_lines_above = true extmark for top/surplus deletions")
    assert(found_virt_eof, "expected virt_lines_above = false extmark for EOF deletion")
    assert(found_inline_del_3000, "expected inline deleted token '3000' with JJDiffDeleteInline")
    assert(found_inline_add_8080, "expected inline added range '8080' with JJDiffAddInline")

    -- Force full redraw across real, wrapped, and virtual lines and confirm gutter renders cleanly
    local captured_gutter = {}
    local orig_render = gutter.render
    gutter.render = function()
      local out = orig_render()
      captured_gutter[#captured_gutter + 1] = {
        win = vim.g.statusline_winid,
        lnum = vim.v.lnum,
        virtnum = vim.v.virtnum,
        out = out,
      }
      return out
    end

    -- Redraw top (wrapped line 4), hunk 3 (add), hunk 4 (surplus virt_lines_above), and EOF (EOF virt_lines)
    vim.cmd("redraw!")
    vim.api.nvim_win_set_cursor(win, { ws.hunks[3].buf_start, 0 })
    vim.cmd("redraw!")
    vim.api.nvim_win_set_cursor(win, { ws.hunks[4].buf_start, 0 })
    vim.cmd("normal! zz")
    vim.cmd("redraw!")
    vim.cmd("normal! Gzz")
    vim.cmd("redraw!")
    gutter.render = orig_render

    local last_lnum = vim.api.nvim_buf_line_count(bufnr)
    local saw_virt_above = false
    local saw_virt_eof = false
    local saw_wrapped_sep = false
    local saw_colored_nr = false

    for _, entry in ipairs(captured_gutter) do
      if entry.win == win then
        if entry.virtnum < 0 and entry.lnum < last_lnum and entry.out:find("JJDiffGutterDeleteNr", 1, true) then
          saw_virt_above = true
        elseif entry.virtnum < 0 and entry.lnum == last_lnum and entry.out:find("JJDiffGutterDeleteNr", 1, true) then
          saw_virt_eof = true
        elseif entry.virtnum > 0 and entry.out:find("JJDiffGutterSep", 1, true) then
          saw_wrapped_sep = true
        elseif
          entry.virtnum == 0
          and (entry.out:find("JJDiffGutterAddNr", 1, true) or entry.out:find("JJDiffGutterChangeNr", 1, true))
        then
          saw_colored_nr = true
        end
      end
    end

    assert(saw_virt_above, "expected statuscolumn to render JJDiffGutterDeleteNr on virt_lines_above rows")
    assert(saw_virt_eof, "expected statuscolumn to render JJDiffGutterDeleteNr on EOF virtual rows")
    assert(saw_wrapped_sep, "expected statuscolumn to render JJDiffGutterSep on wrapped continuation rows")
    assert(saw_colored_nr, "expected statuscolumn to render colored line numbers on diff rows")

    pass("4. Full Diff Rendering (Gutter + Virtual Deletions + Inline Word-Diff)")
  end

  -- 5. Radar Bars Auto-Hide & Exact <N>j / <N>k Cursor Jump Math
  do
    local ws = state.wins[win]
    local function sync_redraw()
      vim.cmd("redraw!")
      vim.wait(50, function()
        return not (state.wins[win] and state.wins[win]._radar_scheduled)
      end, 1)
    end

    -- Position cursor at line 1 and redraw so w0/w$ and radar are up to date
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    sync_redraw()

    local top_cfg = vim.api.nvim_win_get_config(ws.top_win)
    local bot_cfg = vim.api.nvim_win_get_config(ws.bot_win)
    assert(top_cfg.hide == true, "expected top radar bar hidden at top of file")
    assert(bot_cfg.hide == false, "expected bottom radar bar visible when off-screen hunks exist below")

    local bot_line_text = vim.api.nvim_buf_get_lines(ws.bot_buf, 0, 1, false)[1] or ""
    local down_dist_str = bot_line_text:match("▼ (%d+)")
    assert(down_dist_str ~= nil, "expected bottom radar bar to contain '▼ <dist>', got: " .. bot_line_text)
    local down_dist = tonumber(down_dist_str)

    -- Find expected nearest off-screen hunk below
    local bot_edge = vim.api.nvim_win_call(win, function()
      return vim.fn.line("w$")
    end)
    local expected_down_target = nil
    for _, h in ipairs(ws.hunks) do
      if h.buf_start > bot_edge then
        expected_down_target = h.buf_start
        break
      end
    end
    assert(expected_down_target ~= nil, "expected at least one off-screen hunk below")

    vim.cmd("normal! " .. tostring(down_dist) .. "j")
    local landed_down = vim.api.nvim_win_get_cursor(win)[1]
    assert(
      landed_down == expected_down_target,
      string.format("expected %dj to land on line %d, landed on %d", down_dist, expected_down_target, landed_down)
    )

    -- Jump to EOF and verify bottom bar hides while top bar shows exact ▲ <N>k jump
    vim.cmd("normal! G")
    sync_redraw()

    top_cfg = vim.api.nvim_win_get_config(ws.top_win)
    bot_cfg = vim.api.nvim_win_get_config(ws.bot_win)
    assert(bot_cfg.hide == true, "expected bottom radar bar hidden at EOF")
    assert(top_cfg.hide == false, "expected top radar bar visible at EOF")

    local top_line_text = vim.api.nvim_buf_get_lines(ws.top_buf, 0, 1, false)[1] or ""
    local up_dist_str = top_line_text:match("▲ (%d+)")
    assert(up_dist_str ~= nil, "expected top radar bar to contain '▲ <dist>', got: " .. top_line_text)
    local up_dist = tonumber(up_dist_str)

    local top_edge = vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0")
    end)
    local expected_up_target = nil
    for _, h in ipairs(ws.hunks) do
      if h.buf_end < top_edge then
        expected_up_target = h.buf_start
      end
    end
    assert(expected_up_target ~= nil, "expected at least one off-screen hunk above")

    vim.cmd("normal! " .. tostring(up_dist) .. "k")
    local landed_up = vim.api.nvim_win_get_cursor(win)[1]
    assert(
      landed_up == expected_up_target,
      string.format("expected %dk to land on line %d, landed on %d", up_dist, expected_up_target, landed_up)
    )

    pass("5. Radar Bars Auto-Hide & Exact <N>j / <N>k Cursor Jump Math")
  end

  -- 6. Fileset Special-Character Path Safety
  do
    vim.cmd("edit " .. vim.fn.fnameescape(special_file))
    local sbuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(sbuf, 0, 1, false, { "export const title = 'updated'" })
    vim.cmd("silent write")
    local active = jjdiff.toggle(win)
    assert(active == true and jjdiff.is_active(win), "expected jjdiff to activate on special-char path")
    local sws = state.wins[win]
    assert(#sws.hunks == 1 and sws.hunks[1].kind == "change", "expected change hunk on special-char path")
    -- Also verify :w (BufWritePost) auto-refreshes active jjdiff view asynchronously
    vim.api.nvim_buf_set_lines(sbuf, 1, 2, false, { "export const count = 2" })
    vim.cmd("silent write")
    local refreshed = vim.wait(3000, function()
      local cur_ws = state.wins[win]
      return cur_ws ~= nil and #cur_ws.hunks == 1 and cur_ws.hunks[1].new_count == 2
    end, 10)
    assert(refreshed, "expected BufWritePost to asynchronously refresh hunks")
    jjdiff.disable(win)
    pass("6. Fileset Special-Character Path Safety")
  end

  -- 7. Clean Toggle Off & Buffer-Switch Cleanup
  do
    vim.cmd("edit " .. vim.fn.fnameescape(main_file))
    local mbuf = vim.api.nvim_get_current_buf()
    local orig_sc = vim.wo[win].statuscolumn
    local orig_so = vim.wo[win].scrolloff

    assert(jjdiff.enable(win) == true)
    assert(jjdiff.is_active(win) == true)
    local ws = state.wins[win]
    local top_win, bot_win = ws.top_win, ws.bot_win

    -- Also verify toggling OFF still works even if buffer becomes modified
    vim.api.nvim_buf_set_lines(mbuf, 5, 6, false, { "// temporary edit while active" })
    assert(vim.bo[mbuf].modified == true)
    jjdiff.toggle(win)
    assert(jjdiff.is_active(win) == false, "toggle off must deactivate even when buffer is modified")
    assert(vim.wo[win].statuscolumn == orig_sc, "expected statuscolumn restored")
    assert(vim.wo[win].scrolloff == orig_so, "expected scrolloff restored")
    assert(#vim.api.nvim_buf_get_extmarks(mbuf, inline.ns, 0, -1, {}) == 0, "expected 0 extmarks after toggle off")
    assert(not vim.api.nvim_win_is_valid(top_win) and not vim.api.nvim_win_is_valid(bot_win), "expected radar floats closed")

    -- Re-save clean edits and test :enew buffer-switch auto cleanup
    vim.cmd("silent edit!")
    assert(jjdiff.enable(win) == true)
    assert(jjdiff.is_active(win) == true)
    vim.cmd("enew")
    assert(jjdiff.is_active(win) == false, "expected :enew to auto-disable jjdiff in window")
    assert(vim.wo[win].statuscolumn == orig_sc, "expected statuscolumn restored after :enew")

    pass("7. Clean Toggle Off & Buffer-Switch Cleanup")
  end

  -- 8. Small Window (height < 3) No Infinite Redraw Loop
  do
    vim.cmd("edit " .. vim.fn.fnameescape(main_file))
    vim.cmd("silent edit!")
    assert(jjdiff.enable(win) == true)
    local ws = state.wins[win]
    local radar = require("jjdiff.radar")
    local orig_update = radar.update
    local update_calls = 0
    radar.update = function(arg)
      update_calls = update_calls + 1
      return orig_update(arg)
    end

    local orig_h = vim.api.nvim_win_get_height(win)
    vim.api.nvim_win_set_height(win, 2)
    for _ = 1, 5 do
      vim.cmd("redraw!")
      vim.wait(15)
    end
    radar.update = orig_update

    assert(update_calls == 1, "expected radar.update to settle in 1 call on height<3, got " .. update_calls)
    assert(vim.api.nvim_win_get_config(ws.top_win).hide == true, "expected top radar hidden on height<3")
    assert(vim.api.nvim_win_get_config(ws.bot_win).hide == true, "expected bot radar hidden on height<3")
    vim.api.nvim_win_set_height(win, orig_h)
    jjdiff.disable(win)
    pass("8. Small Window No Infinite Redraw Loop")
  end

  -- 9. Winbar Bottom Radar Positioning
  do
    vim.wo[win].winbar = "TEST_WINBAR"
    vim.api.nvim_win_set_height(win, 10)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("redraw!")
    assert(jjdiff.enable(win) == true)
    vim.cmd("redraw!")
    vim.wait(30, function()
      return not (state.wins[win] and state.wins[win]._radar_scheduled)
    end, 1)

    local ws = state.wins[win]
    local info = vim.fn.getwininfo(win)[1]
    local bot_cfg = vim.api.nvim_win_get_config(ws.bot_win)
    local bot_pos = vim.api.nvim_win_get_position(ws.bot_win)
    local expected_bot_screen_row = (info.winrow - 1) + info.winbar + info.height - 1
    assert(bot_cfg.hide == false, "expected bottom radar visible with winbar")
    assert(
      bot_cfg.row == info.height - 1,
      string.format("expected bot row=%d (text height - 1), got %s", info.height - 1, tostring(bot_cfg.row))
    )
    assert(
      bot_pos[1] == expected_bot_screen_row,
      string.format("expected bot screen row inside text area (%d), got %d", expected_bot_screen_row, bot_pos[1])
    )
    jjdiff.disable(win)
    vim.wo[win].winbar = ""
    pass("9. Winbar Bottom Radar Positioning")
  end

  -- 10. Split Window (:vsplit) Option Isolation
  do
    local prev_sc = vim.wo[win].statuscolumn
    local prev_so = vim.wo[win].scrolloff
    vim.wo[win].statuscolumn = "CUSTOM_SC"
    vim.wo[win].scrolloff = 1
    assert(jjdiff.enable(win) == true)

    vim.cmd("vsplit")
    local split_win = vim.api.nvim_get_current_win()
    assert(not jjdiff.is_active(split_win), "new split window must not be marked active")
    assert(
      vim.wo[split_win].statuscolumn == "CUSTOM_SC",
      "new split must preserve original statuscolumn, got: " .. vim.wo[split_win].statuscolumn
    )
    assert(vim.wo[split_win].scrolloff == 1, "new split must preserve original scrolloff")

    jjdiff.disable(win)
    assert(vim.wo[win].statuscolumn == "CUSTOM_SC")
    assert(vim.wo[split_win].statuscolumn == "CUSTOM_SC")
    vim.api.nvim_win_close(split_win, true)
    vim.api.nvim_set_current_win(win)
    vim.wo[win].statuscolumn = prev_sc
    vim.wo[win].scrolloff = prev_so
    pass("10. Split Window Option Isolation")
  end

  -- 11. ColorScheme Deduplication & Highlight Overrides
  do
    jjdiff.setup({})
    jjdiff.setup({
      highlights = {
        JJDiffAddLine = { link = "DiffAdd" },
        JJDiffChangeLine = { bg = "NONE" },
      },
    })
    local aus = vim.api.nvim_get_autocmds({ group = "JJDiffColors" })
    assert(#aus == 1, "expected exactly 1 ColorScheme autocmd, got " .. #aus)

    local add_hl = vim.api.nvim_get_hl(0, { name = "JJDiffAddLine", link = true })
    assert(add_hl.link == "DiffAdd" and add_hl.bg == nil, "expected clean link-only JJDiffAddLine override")

    local chg_hl = vim.api.nvim_get_hl(0, { name = "JJDiffChangeLine", link = true })
    assert(chg_hl.bg == nil and chg_hl.ctermbg == nil, "expected bg='NONE' override to clear ctermbg")

    jjdiff.setup({})
    pass("11. ColorScheme Deduplication & Highlight Overrides")
  end

  -- 12. Symlink Inside Repo & :only Float Recovery
  do
    local jj_mod = require("jjdiff.jj")
    vim.fn.mkdir(sym_tmp, "p")
    run_cmd({ "jj", "--no-pager", "git", "init" }, sym_tmp)
    run_cmd({ "jj", "--no-pager", "config", "set", "--repo", "user.name", "Test User" }, sym_tmp)
    run_cmd({ "jj", "--no-pager", "config", "set", "--repo", "user.email", "test@example.com" }, sym_tmp)
    write_disk(outside_file, { "external v1" })
    local link_path = sym_tmp .. "/tracked_link.txt"
    assert(vim.uv.fs_symlink(outside_file, link_path))
    run_cmd({ "jj", "--no-pager", "commit", "-m", "add symlink" }, sym_tmp)
    -- Before the fix, fs_realpath(link_path) escaped the jj repo and errored; now it stays in-repo.
    local sres_same = jj_mod.diff_file(link_path)
    assert(sres_same.ok == true, "expected symlink inside repo not to escape jj repo: " .. tostring(sres_same.err))
    assert(vim.uv.fs_unlink(link_path))
    assert(vim.uv.fs_symlink(outside_file .. "_v2", link_path))
    local sres = jj_mod.diff_file(link_path)
    assert(sres.ok == true and (sres.diff or "") ~= "", "expected symlink target change inside repo to diff cleanly")

    -- Test :only recovery on an active window
    vim.cmd("edit " .. vim.fn.fnameescape(main_file))
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    assert(jjdiff.enable(win) == true)
    local ws = state.wins[win]
    local old_top = ws.top_win
    local old_bot = ws.bot_win
    vim.cmd("only")
    assert(not vim.api.nvim_win_is_valid(old_top) and not vim.api.nvim_win_is_valid(old_bot))
    vim.cmd("redraw!")
    local recovered = vim.wait(1000, function()
      local cur = state.wins[win]
      return cur ~= nil
        and cur.top_win ~= nil
        and cur.bot_win ~= nil
        and vim.api.nvim_win_is_valid(cur.top_win)
        and vim.api.nvim_win_is_valid(cur.bot_win)
    end, 10)
    assert(recovered, "expected :only to automatically recover radar floats")
    jjdiff.disable(win)
    pass("12. Symlink Inside Repo & :only Float Recovery")
  end

  -- 13. Live Edit Sync, Foreign Virt-Lines, Word-Diff Cap, Radar Packing, Multi-Win Refresh & Completion
  do
    local diff_mod = require("jjdiff.diff")
    local jj_mod = require("jjdiff.jj")
    local radar = require("jjdiff.radar")

    -- 13a. Live unsaved insert/delete line shifts
    vim.cmd("edit " .. vim.fn.fnameescape(main_file))
    local mbuf = vim.api.nvim_get_current_buf()
    assert(jjdiff.enable(win) == true)
    local ws = state.wins[win]
    local orig_hunk3_start = ws.hunks[3].buf_start
    assert(ws.line_status[orig_hunk3_start] == "add")
    vim.api.nvim_buf_set_lines(mbuf, 5, 5, false, { "// inserted 1", "// inserted 2" })
    assert(ws.hunks[3].buf_start == orig_hunk3_start + 2, "expected hunk buf_start to shift +2 on insert")
    assert(ws.line_status[orig_hunk3_start + 2] == "add", "expected line_status to shift +2 on insert")
    vim.api.nvim_buf_set_lines(mbuf, 5, 7, false, {})
    assert(ws.hunks[3].buf_start == orig_hunk3_start, "expected hunk buf_start to shift back on delete")

    -- 13b. Foreign virt_lines are not styled as deleted jjdiff lines; wrap lines use signs.wrap & LineNr
    local foreign_ns = vim.api.nvim_create_namespace("foreign_diag_test")
    local clean_row = 9
    assert(not (ws.virt_lines_lnums and ws.virt_lines_lnums[clean_row + 1]))
    vim.api.nvim_buf_set_extmark(mbuf, foreign_ns, clean_row, 0, {
      virt_lines = { { { "E: diagnostic virtual line", "ErrorMsg" } } },
      virt_lines_above = true,
    })
    local captured = {}
    local orig_render = gutter.render
    gutter.render = function()
      local out = orig_render()
      captured[#captured + 1] = { lnum = vim.v.lnum, virtnum = vim.v.virtnum, out = out }
      return out
    end
    vim.api.nvim_win_set_cursor(win, { clean_row + 1, 0 })
    vim.cmd("redraw!")
    gutter.render = orig_render
    vim.api.nvim_buf_clear_namespace(mbuf, foreign_ns, 0, -1)

    local saw_foreign_neutral = false
    local saw_wrap_linenr = false
    for _, e in ipairs(captured) do
      if e.virtnum < 0 and e.lnum == clean_row + 1 then
        assert(not e.out:find("JJDiffGutterDeleteNr", 1, true), "foreign virt_lines must not use JJDiffGutterDeleteNr")
        saw_foreign_neutral = true
      elseif e.virtnum > 0 and e.out:find("%#LineNr#", 1, true) then
        saw_wrap_linenr = true
      end
    end
    assert(saw_foreign_neutral, "expected foreign virt_lines to render neutrally")
    assert(saw_wrap_linenr, "expected wrapped line padding to use LineNr highlight")
    jjdiff.disable(win)
    vim.cmd("silent edit!")

    -- 13c. Minified line word-diff cap
    local long_a = string.rep("x ", 600)
    local long_b = string.rep("x ", 599) .. "y "
    local wd_cap = diff_mod.compute_word_diff(long_a, long_b, 0.25)
    assert(wd_cap.similar == false and #wd_cap.ops == 0, "expected oversized line to bypass word diff")

    -- 13d. Radar narrow-window non-overflow & no premature truncation
    local fake_hunks = {
      { kind = "add", old_count = 0, new_count = 2, buf_start = 30, buf_end = 31 },
      { kind = "add", old_count = 0, new_count = 3, buf_start = 40, buf_end = 42 },
      { kind = "add", old_count = 0, new_count = 4, buf_start = 50, buf_end = 53 },
    }
    vim.cmd("vsplit")
    local nw = vim.api.nvim_get_current_win()
    vim.wo[nw].number = false
    vim.wo[nw].signcolumn = "no"
    vim.wo[nw].foldcolumn = "0"
    vim.api.nvim_win_set_width(nw, 14)
    vim.cmd("redraw!")
    local rws = { winid = nw, bufnr = vim.api.nvim_win_get_buf(nw), hunks = fake_hunks }
    radar.update(rws)
    local narrow_txt = vim.api.nvim_buf_get_lines(rws.bot_buf, 0, 1, false)[1] or ""
    assert(vim.fn.strdisplaywidth(narrow_txt) <= 14, "expected narrow radar width <= 14, got: " .. narrow_txt)
    vim.api.nvim_win_set_width(nw, 35)
    vim.cmd("redraw!")
    radar.update(rws)
    local fit_txt = vim.api.nvim_buf_get_lines(rws.bot_buf, 0, 1, false)[1] or ""
    assert(not fit_txt:find("more", 1, true), "expected all 3 pills to fit in width 35 without premature truncation: " .. fit_txt)
    radar.close(rws)
    vim.api.nvim_win_close(nw, true)
    vim.api.nvim_set_current_win(win)

    -- 13e. Multi-window sibling cleanup on refresh error & directory guard
    assert(jj_mod.diff_file(tmpdir).ok == false, "expected directory diff to fail cleanly")
    vim.cmd("vsplit")
    local win2 = vim.api.nvim_get_current_win()
    assert(jjdiff.enable(win) == true and jjdiff.enable(win2) == true)
    local orig_diff_file = jj_mod.diff_file
    jj_mod.diff_file = function()
      return { ok = false, err = "simulated failure" }
    end
    assert(jjdiff.refresh(win) == false)
    jj_mod.diff_file = orig_diff_file
    assert(not jjdiff.is_active(win) and not jjdiff.is_active(win2), "expected refresh failure to disable all sibling windows")
    vim.api.nvim_win_close(win2, true)
    vim.api.nvim_set_current_win(win)

    -- 13f. :JJDiff completion filters by arglead
    local comp = vim.fn.getcompletion("JJDiff r", "cmdline")
    assert(#comp == 1 and comp[1] == "refresh", "expected :JJDiff r completion to return {'refresh'}")

    pass("13. Live Edit Sync, Foreign Virt-Lines, Caps, Radar Packing, Multi-Win & Completion")
  end

  -- 14. Lazy Startup & Pre-Existing <leader>jj Non-Clobber
  do
    local script = [[
      vim.keymap.set("n", "<leader>jj", ":echo 'user_map'<CR>", { silent = true })
      vim.opt.rtp:prepend(".")
      vim.cmd("runtime! plugin/jjdiff.lua")
      assert(package.loaded["jjdiff"] == nil, "plugin/jjdiff.lua must not eagerly require jjdiff")
      local map = vim.fn.maparg("<leader>jj", "n", false, true)
      assert(map and map.rhs and map.rhs:find("user_map", 1, true), "must not clobber existing <leader>jj mapping")
      require("jjdiff").setup({ keymap = false })
      local map2 = vim.fn.maparg("<leader>jj", "n", false, true)
      assert(map2 and map2.rhs and map2.rhs:find("user_map", 1, true), "setup({ keymap = false }) must not delete user's <leader>jj")
      vim.cmd("qa!")
    ]]
    local res = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", "-" }, { stdin = script, text = true }):wait()
    assert(res.code == 0, "lazy startup subprocess failed: " .. (res.stderr or ""))
    pass("14. Lazy Startup & Pre-Existing Keymap Non-Clobber")
  end

  print("ALL TESTS PASSED")
end, debug.traceback)

pcall(vim.fn.delete, tmpdir, "rf")
pcall(vim.fn.delete, sym_tmp, "rf")
pcall(vim.fn.delete, outside_file)

if not ok then
  io.stderr:write("TEST FAILURE:\n" .. tostring(err) .. "\n")
  vim.cmd("cq 1")
end

vim.cmd("qa!")
