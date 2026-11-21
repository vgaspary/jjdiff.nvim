local M = {}

---@class JJDiffSigns
---@field add string
---@field change string
---@field delete string
---@field wrap string
---@field sep string
---@field virt_nr string

---@class JJDiffArrows
---@field up string
---@field down string

---@class JJDiffConfig
---@field keymap string|false
---@field signs JJDiffSigns
---@field arrows JJDiffArrows
---@field winblend integer
---@field min_scrolloff integer
---@field inline_similarity_threshold number
---@field highlights table<string, table>
M.defaults = {
  keymap = "<leader>jj",
  signs = {
    add = "┃",
    change = "┃",
    delete = "▎",
    wrap = "┆",
    sep = "│",
    virt_nr = "··",
  },
  arrows = {
    up = "▲",
    down = "▼",
  },
  winblend = 8,
  min_scrolloff = 2,
  inline_similarity_threshold = 0.25,
  highlights = {},
}

---@type JJDiffConfig
M.options = vim.deepcopy(M.defaults)

---Merge user configuration into active options.
---@param opts? table
---@return JJDiffConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

---Return the active configuration table.
---@return JJDiffConfig
function M.get()
  return M.options
end

return M
