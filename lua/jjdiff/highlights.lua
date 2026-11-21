local config = require("jjdiff.config")

local M = {}

---Convert a 24-bit integer RGB color to #rrggbb hex string.
---@param color integer
---@return string
local function int_to_hex(color)
  return string.format("#%06x", color)
end

---Parse a #rrggbb hex color into r, g, b components (0-255).
---@param hex string
---@return integer, integer, integer
local function hex_to_rgb(hex)
  local clean = hex:gsub("^#", "")
  local r = tonumber(clean:sub(1, 2), 16) or 0
  local g = tonumber(clean:sub(3, 4), 16) or 0
  local b = tonumber(clean:sub(5, 6), 16) or 0
  return r, g, b
end

---Format r, g, b components (clamped 0-255) into #rrggbb.
---@param r number
---@param g number
---@param b number
---@return string
local function rgb_to_hex(r, g, b)
  local clamp = function(v)
    return math.max(0, math.min(255, math.floor(v + 0.5)))
  end
  return string.format("#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
end

---Blend foreground hex onto background hex with alpha in [0, 1].
---@param fg_hex string
---@param bg_hex string
---@param alpha number
---@return string
function M.blend(fg_hex, bg_hex, alpha)
  local fr, fg, fb = hex_to_rgb(fg_hex)
  local br, bg, bb = hex_to_rgb(bg_hex)
  local r = fr * alpha + br * (1 - alpha)
  local g = fg * alpha + bg * (1 - alpha)
  local b = fb * alpha + bb * (1 - alpha)
  return rgb_to_hex(r, g, b)
end

---Detect the active Normal background hex color.
---@return string, boolean is_light
local function detect_base_bg()
  local is_light = vim.o.background == "light"
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if normal and normal.bg then
    local hex = int_to_hex(normal.bg)
    local r, g, b = hex_to_rgb(hex)
    local luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return hex, luma > 140
  end
  return is_light and "#ffffff" or "#181820", is_light
end

---Build and apply all JJDiff* highlight groups, adapting to the active colorscheme.
function M.apply()
  local base_bg, is_light = detect_base_bg()
  local opts = config.get()

  -- Palette anchors tuned for dark and light backgrounds
  local green = is_light and "#1a7f37" or "#3fb950"
  local green_nr = is_light and "#248f42" or "#56d364"
  local red = is_light and "#cf222e" or "#f85149"
  local red_muted = is_light and "#a40e26" or "#ffa198"
  local amber = is_light and "#9a6700" or "#d29922"
  local amber_nr = is_light and "#b07800" or "#e3b341"
  local sep_fg = is_light and "#8c959f" or "#484f58"
  local elevate_target = is_light and "#d0d7de" or "#ffffff"
  local pill_dim_fg = is_light and "#424a53" or "#c9d1d9"
  local more_fg = is_light and "#24292f" or "#e6edf3"
  local pill_dark_fg = is_light and "#ffffff" or "#0d1117"

  local radar_bg = M.blend(elevate_target, base_bg, is_light and 0.35 or 0.06)
  local pill_add_dim_bg = M.blend(green, base_bg, is_light and 0.16 or 0.20)
  local pill_del_dim_bg = M.blend(red, base_bg, is_light and 0.16 or 0.20)
  local pill_chg_dim_bg = M.blend(amber, base_bg, is_light and 0.16 or 0.20)
  local pill_more_bg = M.blend(elevate_target, base_bg, is_light and 0.50 or 0.14)

  local groups = {
    -- Gutter (right-extended number column)
    JJDiffGutterAddNr = { fg = green_nr, bold = true, ctermfg = "Green" },
    JJDiffGutterAddBar = { fg = green, bold = true, ctermfg = "Green" },
    JJDiffGutterChangeNr = { fg = amber_nr, bold = true, ctermfg = "Yellow" },
    JJDiffGutterChangeBar = { fg = amber, bold = true, ctermfg = "Yellow" },
    JJDiffGutterDeleteNr = { fg = red, bold = true, ctermfg = "Red" },
    JJDiffGutterDeleteBar = { fg = red, bold = true, ctermfg = "Red" },
    JJDiffGutterSep = { fg = sep_fg, ctermfg = "DarkGray" },

    -- In-buffer line washes & inline tokens
    JJDiffAddLine = { bg = M.blend(green, base_bg, 0.10), ctermbg = "DarkGreen" },
    JJDiffChangeLine = { bg = M.blend(amber, base_bg, 0.07), ctermbg = "DarkYellow" },
    JJDiffDeleteVirtLine = {
      fg = red_muted,
      bg = M.blend(red, base_bg, 0.13),
      ctermfg = "LightRed",
      ctermbg = "DarkRed",
    },
    JJDiffDeletePrefix = {
      fg = red,
      bg = M.blend(red, base_bg, 0.13),
      bold = true,
      ctermfg = "Red",
      ctermbg = "DarkRed",
    },
    JJDiffAddInline = {
      fg = is_light and "#116329" or "#aff5b4",
      bg = M.blend(green, base_bg, 0.26),
      bold = true,
      ctermfg = "LightGreen",
      ctermbg = "DarkGreen",
    },
    JJDiffDeleteInline = {
      fg = is_light and "#a40e26" or "#ffdcd7",
      bg = M.blend(red, base_bg, 0.26),
      strikethrough = true,
      ctermfg = "LightRed",
      ctermbg = "DarkRed",
    },

    -- Radar HUD & Pills
    JJDiffRadarBar = { bg = radar_bg, fg = pill_dim_fg, ctermbg = "DarkGray" },
    JJDiffPillAdd = { fg = pill_dark_fg, bg = green, bold = true, ctermfg = "Black", ctermbg = "Green" },
    JJDiffPillAddDim = { fg = green_nr, bg = pill_add_dim_bg, bold = true, ctermfg = "Green", ctermbg = "DarkGray" },
    JJDiffPillDelete = { fg = pill_dark_fg, bg = red, bold = true, ctermfg = "Black", ctermbg = "Red" },
    JJDiffPillDeleteDim = { fg = red_muted, bg = pill_del_dim_bg, bold = true, ctermfg = "Red", ctermbg = "DarkGray" },
    JJDiffPillChange = { fg = pill_dark_fg, bg = amber, bold = true, ctermfg = "Black", ctermbg = "Yellow" },
    JJDiffPillChangeDim = { fg = amber_nr, bg = pill_chg_dim_bg, bold = true, ctermfg = "Yellow", ctermbg = "DarkGray" },
    JJDiffPillChangeAdd = { fg = green_nr, bg = pill_chg_dim_bg, bold = true, ctermfg = "Green", ctermbg = "DarkGray" },
    JJDiffPillChangeDel = { fg = red_muted, bg = pill_chg_dim_bg, bold = true, ctermfg = "Red", ctermbg = "DarkGray" },
    JJDiffPillMore = { fg = more_fg, bg = pill_more_bg, bold = true, ctermfg = "White", ctermbg = "DarkGray" },
  }

  local overrides = opts.highlights or {}
  for name, spec in pairs(groups) do
    local ov = overrides[name]
    if ov then
      if ov.link ~= nil then
        vim.api.nvim_set_hl(0, name, ov)
      else
        local merged = vim.tbl_extend("force", spec, ov)
        if ov.bg == "NONE" and ov.ctermbg == nil then
          merged.ctermbg = nil
        end
        if ov.fg == "NONE" and ov.ctermfg == nil then
          merged.ctermfg = nil
        end
        vim.api.nvim_set_hl(0, name, merged)
      end
    else
      vim.api.nvim_set_hl(0, name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not groups[name] then
      vim.api.nvim_set_hl(0, name, spec)
    end
  end
end

return M
