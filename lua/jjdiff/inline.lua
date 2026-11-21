local diff = require("jjdiff.diff")

local M = {}

M.ns = vim.api.nvim_create_namespace("jjdiff_buf")

---Build virt_lines chunks for deleted lines with a full-width background wash.
---@param lines string[]
---@param pad_width integer
---@return table[]
local function build_virt_lines(lines, pad_width)
  local vlines = {}
  for _, text in ipairs(lines) do
    local display_w = vim.fn.strdisplaywidth(text) + 2
    local pad_len = math.max(0, pad_width - display_w)
    local chunks = {
      { "- ", "JJDiffDeletePrefix" },
      { text, "JJDiffDeleteVirtLine" },
    }
    if pad_len > 0 then
      chunks[#chunks + 1] = { string.rep(" ", pad_len), "JJDiffDeleteVirtLine" }
    end
    vlines[#vlines + 1] = chunks
  end
  return vlines
end

---Clear all jjdiff extmarks from a buffer.
---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

---Render line washes, virtual deleted lines, and inline word diffs into a buffer.
---@param bufnr integer
---@param hunks JJDiffHunk[]
---@param threshold? number
---@return { line_status: table<integer, "add"|"change">, virt_lines_lnums: table<integer, boolean> }
function M.render(bufnr, hunks, threshold)
  M.clear(bufnr)

  local buf_line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local pad_width = math.max(300, (vim.o.columns or 80) * 2)
  local line_status = {}
  local virt_lines_lnums = {}

  for _, hunk in ipairs(hunks) do
    if hunk.kind == "add" then
      for lnum = hunk.buf_start, hunk.buf_end do
        local row = lnum - 1
        if row >= 0 and row < buf_line_count then
          line_status[lnum] = "add"
          vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
            line_hl_group = "JJDiffAddLine",
            priority = 100,
          })
        end
      end
    elseif hunk.kind == "delete" then
      local vlines = build_virt_lines(hunk.old_lines, pad_width)
      local row = hunk.is_eof and (buf_line_count - 1) or math.max(0, math.min(hunk.buf_start - 1, buf_line_count - 1))
      local above = not hunk.is_eof
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
        virt_lines = vlines,
        virt_lines_above = above,
        priority = 150,
      })
      virt_lines_lnums[row + 1] = true
    elseif hunk.kind == "change" then
      local paired = diff.pair_change_hunk(hunk, threshold or 0.25, buf_line_count)

      for _, vb in ipairs(paired.virt_blocks) do
        local vlines = build_virt_lines(vb.lines, pad_width)
        local row = math.max(0, math.min(vb.lnum - 1, buf_line_count - 1))
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          virt_lines = vlines,
          virt_lines_above = vb.above,
          priority = 150,
        })
        virt_lines_lnums[row + 1] = true
      end

      for _, pl in ipairs(paired.line_ops) do
        local row = pl.lnum - 1
        if row >= 0 and row < buf_line_count then
          line_status[pl.lnum] = pl.status
          if pl.status == "add" then
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
              line_hl_group = "JJDiffAddLine",
              priority = 100,
            })
          else
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
              line_hl_group = "JJDiffChangeLine",
              priority = 100,
            })
            local buf_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
            local line_len = #buf_line
            for _, op in ipairs(pl.ops) do
              if op.kind == "del" and op.text and op.text ~= "" then
                local col = math.max(0, math.min(op.col, line_len))
                vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, col, {
                  virt_text = { { op.text, "JJDiffDeleteInline" } },
                  virt_text_pos = "inline",
                  hl_mode = "replace",
                  priority = 200,
                })
              elseif op.kind == "add" then
                local sc = math.max(0, math.min(op.start_col, line_len))
                local ec = math.max(sc, math.min(op.end_col, line_len))
                if ec > sc then
                  vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, sc, {
                    end_row = row,
                    end_col = ec,
                    hl_group = "JJDiffAddInline",
                    priority = 200,
                  })
                end
              end
            end
          end
        end
      end
    end
  end

  return {
    line_status = line_status,
    virt_lines_lnums = virt_lines_lnums,
  }
end

return M
