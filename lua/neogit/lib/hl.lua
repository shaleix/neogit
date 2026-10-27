--#region TYPES

---@class HiSpec
---@field fg string
---@field bg string
---@field gui string
---@field sp string
---@field blend integer
---@field default boolean

---@class HiLinkSpec
---@field force boolean
---@field default boolean

--#endregion

local Color = require("neogit.lib.color").Color
local hl_store
local M = {}

-- Status banner gradient: the title fades left-to-right between the theme's
-- purple and blue across this many steps ("NeogitStatusBanner1" .. "N").
-- Exported so the status UI's per-column mapping cannot drift from the
-- highlight definitions.
M.STATUS_BANNER_GRADIENT_STEPS = 16

---@param dec number
---@return string
local function to_hex(dec)
  local hex = string.format("%x", dec)
  if #hex < 6 then
    return string.rep("0", 6 - #hex) .. hex
  else
    return hex
  end
end

---@param name string Syntax group name.
---@return string|nil
local function get_fg(name)
  local color = vim.api.nvim_get_hl(0, { name = name })
  if color["link"] then
    return get_fg(color["link"])
  elseif color["reverse"] and color["bg"] then
    return "#" .. to_hex(color["bg"])
  elseif color["fg"] then
    return "#" .. to_hex(color["fg"])
  end
end

---@param name string Syntax group name.
---@return string|nil
local function get_bg(name)
  local color = vim.api.nvim_get_hl(0, { name = name })
  if color["link"] then
    return get_bg(color["link"])
  elseif color["reverse"] and color["fg"] then
    return "#" .. to_hex(color["fg"])
  elseif color["bg"] then
    return "#" .. to_hex(color["bg"])
  end
end

---@class NeogitColorPalette
---@field bg0        string  Darkest background color
---@field bg1        string  Second darkest background color
---@field bg2        string  Second lightest background color
---@field bg3        string  Lightest background color
---@field grey       string  middle grey shade for foreground
---@field white      string  Foreground white (main text)
---@field red        string  Foreground red
---@field bg_red     string  Background red
---@field line_red   string  Cursor line highlight for red regions, like deleted hunks
---@field orange     string  Foreground orange
---@field bg_orange  string  background orange
---@field yellow     string  Foreground yellow
---@field bg_yellow  string  background yellow
---@field green      string  Foreground green
---@field bg_green   string  Background green
---@field line_green string  Cursor line highlight for green regions, like added hunks
---@field cyan       string  Foreground cyan
---@field bg_cyan    string  Background cyan
---@field blue       string  Foreground blue
---@field bg_blue    string  Background blue
---@field purple     string  Foreground purple
---@field bg_purple  string  Background purple
---@field md_purple  string  Background _medium_ purple. Lighter than bg_purple.
---@field inline_green string  Background for inline add word-diff highlights
---@field inline_red   string  Background for inline delete word-diff highlights
---@field italic     boolean enable italics?
---@field bold       boolean enable bold?
---@field underline  boolean enable underline?

-- stylua: ignore start
---@param config NeogitConfig
---@return NeogitColorPalette
local function make_palette(config)
  local bg        = Color.from_hex(get_bg("Normal") or (vim.o.bg == "dark" and "#22252A" or "#eeeeee"))
  local fg        = Color.from_hex((vim.o.bg == "dark" and "#fcfcfc" or "#22252A"))
  local red       = Color.from_hex(config.highlight.red or get_fg("ErrorMsg") or "#E06C75")
  local orange    = Color.from_hex(config.highlight.orange or get_fg("SpecialChar") or "#ffcb6b")
  local yellow    = Color.from_hex(config.highlight.yellow or get_fg("PreProc") or "#FFE082")
  local green     = Color.from_hex(config.highlight.green or get_fg("String") or "#C3E88D")
  local cyan      = Color.from_hex(config.highlight.cyan or get_fg("Operator") or "#89ddff")
  local blue      = Color.from_hex(config.highlight.blue or get_fg("Macro") or "#82AAFF")
  local purple    = Color.from_hex(config.highlight.purple or get_fg("Include") or "#C792EA")

  local bg_factor = vim.o.bg == "dark" and 1 or -1

  local default   = {
    bg0          = bg:to_css(),
    bg1          = bg:shade(bg_factor * 0.019):to_css(),
    bg2          = bg:shade(bg_factor * 0.065):to_css(),
    bg3          = bg:shade(bg_factor * 0.11):to_css(),
    grey         = bg:shade(bg_factor * 0.4):to_css(),
    white        = fg:to_css(),
    red          = red:to_css(),
    bg_red       = red:shade(bg_factor * -0.18):to_css(),
    line_red     = get_bg("DiffDelete") or red:shade(bg_factor * -0.6):set_saturation(0.4):to_css(),
    orange       = orange:to_css(),
    bg_orange    = orange:shade(bg_factor * -0.17):to_css(),
    yellow       = yellow:to_css(),
    bg_yellow    = yellow:shade(bg_factor * -0.17):to_css(),
    green        = green:to_css(),
    bg_green     = green:shade(bg_factor * -0.18):to_css(),
    line_green   = get_bg("DiffAdd") or green:shade(bg_factor * -0.72):set_saturation(0.2):to_css(),
    cyan         = cyan:to_css(),
    bg_cyan      = cyan:shade(bg_factor * -0.18):to_css(),
    blue         = blue:to_css(),
    bg_blue      = blue:shade(bg_factor * -0.18):to_css(),
    purple       = purple:to_css(),
    bg_purple    = purple:shade(bg_factor * -0.18):to_css(),
    md_purple    = purple:shade(0.18):to_css(),
    inline_green = green:shade(bg_factor * -0.2):set_saturation(0.65):to_css(),
    inline_red   = red:shade(bg_factor * 0.3):set_saturation(0.65):to_css(),
    italic       = true,
    bold         = true,
    underline    = true,
  }

  return vim.tbl_extend("keep", config.highlight or {}, default)
end
-- stylua: ignore end

-- https://github.com/lewis6991/gitsigns.nvim/blob/1e01b2958aebb79f1c33e7427a1bac131a678e0d/lua/gitsigns/highlight.lua#L250
--- @param hl_name string
--- @return boolean
local function is_set(hl_name)
  local exists, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
  if not exists then
    return false
  end

  return not vim.tbl_isempty(hl)
end

---@param config NeogitConfig
function M.setup(config)
  local palette = make_palette(config)

  -- "Success" green pair: derived from healthSuccess (the theme's standard
  -- green) rather than palette.green (the theme's String highlight, yellow
  -- on monokai-style colorschemes) or DiagnosticOk (deliberately loud).
  -- Used by the staged section and the loading banner.
  local ok_base = get_fg("healthSuccess") or "#82b762"
  local bg_factor = vim.o.bg == "dark" and 1 or -1
  local ok_green = ok_base
  local ok_bg = Color.from_hex(ok_base):shade(bg_factor * -0.35):to_css()

  -- Loading banner background: dark, muted yellow. Shaded deeper than the
  -- result banners (yellow reads perceptually brighter than green/red) and
  -- desaturated toward the editor background, so the full-width strip is
  -- noticeable without shouting for the whole duration of the work.
  local spinner_bg = Color.from_hex(palette.yellow):shade(bg_factor * -0.45):set_saturation(0.4):to_css()

  -- Indent-guide gray: deliberately dimmer than palette.grey (the graph
  -- gray, a 0.4 shade) - blended only 20% from the editor background
  -- toward the text direction, so the neo-tree style guide lines hug the
  -- background and stay subordinate to file names.
  local indent_guide = Color.from_hex(palette.bg0):shade(bg_factor * 0.2):to_css()

  -- Confirm dialog (buffers/confirm.lua): the panel shades NormalFloat one
  -- step so the dialog reads as a solid card over the backdrop; title bars
  -- carry a brightened level color with panel-colored text (inverted).
  local confirm_panel =
    Color.from_hex(get_bg("NormalFloat") or (vim.o.bg == "dark" and "#1a1b26" or "#eeeeee"))
      :shade(bg_factor * -0.18)
      :to_css()
  local confirm_title = function(c)
    return Color.from_hex(c):shade(0.3):to_css()
  end

  -- stylua: ignore
  hl_store = {
    NeogitGraphAuthor              = { fg = palette.orange, ctermfg = 3 },
    NeogitGraphRed                 = { fg = palette.red, ctermfg = 1 },
    NeogitGraphWhite               = { fg = palette.white, ctermfg = 7 },
    NeogitGraphYellow              = { fg = palette.yellow, ctermfg = 3 },
    NeogitGraphGreen               = { fg = palette.green, ctermfg = 2 },
    NeogitGraphCyan                = { fg = palette.cyan, ctermfg = 6 },
    NeogitGraphBlue                = { fg = palette.blue, ctermfg = 4 },
    NeogitGraphPurple              = { fg = palette.purple, ctermfg = 5 },
    NeogitGraphGray                = { fg = palette.grey, ctermfg = 7 },
    NeogitGraphOrange              = { fg = palette.orange, ctermfg = 3 },
    NeogitGraphBoldOrange          = { fg = palette.orange, bold = palette.bold, ctermfg = 3 },
    NeogitGraphBoldRed             = { fg = palette.red, bold = palette.bold, ctermfg = 1 },
    NeogitGraphBoldWhite           = { fg = palette.white, bold = palette.bold, ctermfg = 7 },
    NeogitGraphBoldYellow          = { fg = palette.yellow, bold = palette.bold, ctermfg = 3 },
    NeogitGraphBoldGreen           = { fg = palette.green, bold = palette.bold, ctermfg = 2 },
    NeogitGraphBoldCyan            = { fg = palette.cyan, bold = palette.bold, ctermfg = 6 },
    NeogitGraphBoldBlue            = { fg = palette.blue, bold = palette.bold, ctermfg = 4 },
    NeogitGraphBoldPurple          = { fg = palette.purple, bold = palette.bold, ctermfg = 5 },
    NeogitGraphBoldGray            = { fg = palette.grey, bold = palette.bold, ctermfg = 7 },
    -- File-tree indent guides (neo-tree style vertical lines) in the status
    -- buffer. Dim gray, blended toward the editor background (see
    -- indent_guide above) so the lines read as structure, not content.
    NeogitIndentGuide              = { fg = indent_guide, ctermfg = 8 },
    NeogitSubtleText               = { link = "Comment" },
    NeogitSignatureGood            = { link = "NeogitGraphGreen" },
    NeogitSignatureBad             = { link = "NeogitGraphBoldRed" },
    NeogitSignatureMissing         = { link = "NeogitGraphPurple" },
    NeogitSignatureNone            = { link = "NeogitSubtleText" },
    NeogitSignatureGoodUnknown     = { link = "NeogitGraphBlue" },
    NeogitSignatureGoodExpired     = { link = "NeogitGraphOrange" },
    NeogitSignatureGoodExpiredKey  = { link = "NeogitGraphYellow" },
    NeogitSignatureGoodRevokedKey  = { link = "NeogitGraphRed" },
    -- Upstream divergence counters on the status HEAD lines: ahead = local
    -- commits not pushed yet, behind = remote commits not pulled yet. The
    -- check mark replaces both when the branch is fully in sync. Bold, so
    -- the arrows and counts stand out from the branch/repo text.
    NeogitDivergenceAhead          = { link = "NeogitGraphBoldGreen" },
    NeogitDivergenceBehind         = { link = "NeogitGraphBoldRed" },
    NeogitDivergenceOk             = { fg = ok_green, bold = palette.bold, ctermfg = 2 },
    NeogitNormal                   = { link = "Normal" },
    NeogitNormalFloat              = { link = "NeogitNormal" },
    NeogitFloatBorder              = { link = "NeogitNormalFloat" },
    NeogitSignColumn               = { fg = "None", bg = "None" },
    NeogitCursorLine               = { link = "CursorLine" },
    NeogitCursorLineNr             = { link = "CursorLineNr" },
    NeogitHunkMergeHeader          = { fg = palette.bg2, bg = palette.grey, bold = palette.bold, ctermfg = 4 },
    NeogitHunkHeader               = { fg = palette.bg0, bg = palette.grey, bold = palette.bold, ctermfg = 3 },
    NeogitHunkHeaderHighlight      = { fg = palette.bg0, bg = palette.md_purple, bold = palette.bold, ctermfg = 3 },
    NeogitHunkHeaderCursor         = { fg = palette.bg0, bg = palette.md_purple, bold = palette.bold, ctermfg = 3 },
    NeogitDiffContext              = { bg = palette.bg1 },
    NeogitDiffContextHighlight     = { bg = palette.bg2 },
    NeogitDiffContextCursor        = { bg = palette.bg1 },
    NeogitDiffAdditions            = { fg = palette.bg_green, ctermfg = 2 },
    NeogitDiffAdd                  = { bg = palette.line_green, fg = palette.bg_green, ctermfg = 2 },
    NeogitDiffAddHighlight         = { bg = palette.line_green, fg = palette.green, ctermfg = 2 },
    NeogitDiffAddCursor            = { bg = palette.bg1, fg = palette.green, ctermfg = 2 },
    NeogitDiffDeletions            = { fg = palette.bg_red, ctermfg = 1 },
    NeogitDiffDelete               = { bg = palette.line_red, fg = palette.bg_red, ctermfg = 1 },
    NeogitDiffDeleteHighlight      = { bg = palette.line_red, fg = palette.red, ctermfg = 1 },
    NeogitDiffDeleteCursor         = { bg = palette.bg1, fg = palette.red, ctermfg = 1 },
    NeogitDiffAddInline            = { bg = palette.inline_green, fg = palette.line_green, bold = palette.bold },
    NeogitDiffDeleteInline         = { bg = palette.inline_red, fg = palette.bg0, bold = palette.bold },
    NeogitPopupSectionTitle        = { link = "Function" },
    NeogitPopupBranchName          = { link = "String" },
    NeogitPopupBold                = { bold = palette.bold },
    NeogitPopupSwitchKey           = { fg = palette.purple, ctermfg = 5 },
    NeogitPopupSwitchEnabled       = { link = "SpecialChar" },
    NeogitPopupSwitchDisabled      = { link = "NeogitSubtleText" },
    NeogitPopupOptionKey           = { fg = palette.purple, ctermfg = 5 },
    NeogitPopupOptionEnabled       = { link = "SpecialChar" },
    NeogitPopupOptionDisabled      = { link = "NeogitSubtleText" },
    NeogitPopupConfigKey           = { fg = palette.purple, ctermfg = 5 },
    NeogitPopupConfigEnabled       = { link = "SpecialChar" },
    NeogitPopupConfigDisabled      = { link = "NeogitSubtleText" },
    NeogitPopupActionKey           = { fg = palette.purple, ctermfg = 5 },
    NeogitPopupActionDisabled      = { link = "NeogitSubtleText" },
    NeogitFilePath                 = { fg = palette.blue, italic = palette.italic, ctermfg = 3 },
    NeogitCommitViewHeader         = { bg = palette.bg_cyan, fg = palette.bg0, ctermfg = 7 },
    NeogitCommitViewDescription    = { link = "String" },
    NeogitDiffHeader               = { bg = palette.bg3, fg = palette.blue, bold = palette.bold, ctermfg = 3 },
    NeogitDiffHeaderHighlight      = { bg = palette.bg3, fg = palette.orange, bold = palette.bold, ctermfg = 3 },
    NeogitCommandText              = { link = "NeogitSubtleText" },
    NeogitCommandTime              = { link = "NeogitSubtleText" },
    NeogitCommandCodeNormal        = { link = "String" },
    NeogitCommandCodeError         = { link = "Error" },
    NeogitBranch                   = { fg = palette.blue, bold = palette.bold, ctermfg = 4 },
    NeogitBranchHead               = { fg = palette.blue, bold = palette.bold, underline = palette.underline, ctermfg = 4 },
    NeogitRemote                   = { fg = palette.green, bold = palette.bold, ctermfg = 2 },
    NeogitObjectId                 = { link = "NeogitSubtleText" },
    NeogitStash                    = { link = "NeogitSubtleText" },
    NeogitRebaseDone               = { link = "NeogitSubtleText" },
    NeogitFoldColumn               = { fg = "None", bg = "None" },
    NeogitWinSeparator             = { link = "WinSeparator" },
    NeogitSectionHeader            = { fg = palette.bg_purple, bold = palette.bold, ctermfg = 5 },
    NeogitSectionHeaderCount       = {},
    -- Bottom-center loading indicator (lib/loading.lua): full-width banner.
    -- All states encode state in the background color with inverted (bg0)
    -- text; loading uses a muted dark yellow so it doesn't upstage the
    -- result states.
    NeogitSpinner                  = { fg = palette.bg0, bg = spinner_bg, bold = palette.bold, ctermfg = 0, ctermbg = 3 },
    NeogitSpinnerSuccess           = { fg = palette.bg0, bg = ok_bg, bold = palette.bold, ctermfg = 0, ctermbg = 2 },
    NeogitSpinnerWarn              = { fg = palette.bg0, bg = palette.bg_yellow, bold = palette.bold, ctermfg = 0, ctermbg = 3 },
    NeogitSpinnerError             = { fg = palette.bg0, bg = palette.bg_red, bold = palette.bold, ctermfg = 0, ctermbg = 1 },
    -- Section headers: each section carries its own icon color; users who
    -- preferred the old uniform look can re-link these to NeogitSectionHeader.
    NeogitUntrackedfiles           = { fg = palette.bg_cyan, bold = palette.bold, ctermfg = 6 },
    NeogitUnstagedchanges          = { fg = palette.bg_orange, bold = palette.bold, ctermfg = 3 },
    NeogitStagedchanges            = { fg = ok_bg, bold = palette.bold, ctermfg = 2 },
    NeogitStashes                  = { fg = palette.bg_yellow, bold = palette.bold, ctermfg = 3 },
    NeogitRecentcommits            = { fg = palette.bg_purple, bold = palette.bold, ctermfg = 5 },
    NeogitMerging                  = { fg = palette.bg_blue, bold = palette.bold, ctermfg = 4 },
    NeogitRebasing                 = { fg = palette.bg_red, bold = palette.bold, ctermfg = 1 },
    NeogitPicking                  = { fg = palette.md_purple, bold = palette.bold, ctermfg = 5 },
    NeogitReverting                = { fg = palette.bg_red, bold = palette.bold, ctermfg = 1 },
    NeogitBisecting                = { fg = palette.bg_yellow, bold = palette.bold, ctermfg = 3 },
    NeogitTagName                  = { fg = palette.yellow, ctermfg = 3 },
    NeogitFloatHeader              = { bg = palette.bg0, bold = palette.bold, ctermfg = 5 },
    NeogitFloatHeaderHighlight     = { bg = palette.bg2, fg = palette.cyan, bold = palette.bold, ctermfg = 5 },
    NeogitActiveItem               = { bg = palette.bg_orange, fg = palette.bg0, bold = palette.bold, ctermfg = 5 },
    -- Confirm Dialog levels: level-colored choice text, a dim unselected
    -- choice, the solid panel background (shared by the invisible border
    -- slots so the backdrop can't bleed through), inverted level title
    -- bars, and the pure-black backdrop pushed through winblend.
    NeogitConfirmDanger            = { fg = palette.red, bold = palette.bold, ctermfg = 1 },
    NeogitConfirmWarn              = { fg = palette.yellow, bold = palette.bold, ctermfg = 3 },
    NeogitConfirmInfo              = { fg = palette.blue, bold = palette.bold, ctermfg = 4 },
    -- fg only: the hint footer and unselected choices must not carry their
    -- own background - they inherit the border slot's / panel's background
    -- (linking to Comment would import theme backgrounds)
    NeogitConfirmDim               = { fg = palette.grey, ctermfg = 7 },
    -- The footer hint lives on the border slot: nvim composes footer cells
    -- from the chunk's highlight alone, so a bg-less group would fall back
    -- to something other than the panel. Pin the panel background here so
    -- the hint strip reads as part of the border.
    NeogitConfirmHint              = { fg = palette.grey, bg = confirm_panel, ctermfg = 7 },
    NeogitConfirmNormal            = { fg = palette.white, bg = confirm_panel },
    NeogitConfirmTitleDanger       = { fg = confirm_panel, bg = confirm_title(palette.red), bold = palette.bold },
    NeogitConfirmTitleWarn         = { fg = confirm_panel, bg = confirm_title(palette.yellow), bold = palette.bold },
    NeogitConfirmTitleInfo         = { fg = confirm_panel, bg = confirm_title(palette.blue), bold = palette.bold },
    NeogitConfirmBackdrop          = { bg = "#000000" },
  }

  -- Change-label highlights are composed at render time as
  -- "NeogitChange<mode><section>" (buffers/status/ui.lua), so the definitions
  -- reduce to a modes x sections loop with one color per section. The status
  -- parsers constrain which combinations are reachable: untracked entries
  -- always carry mode "?" (rendered "Untracked"), and the conflict modes
  -- (DD, UU, AA, DU, UD, AU, UA) only ever land in the unstaged section, so
  -- staged entries only ever carry single-letter modes. Staged uses the
  -- uniform "success" green ("ready to commit", no bold - the whole section
  -- reads as a block); unstaged and untracked use the state red (color
  -- encodes the change state, not the file type - the letter itself carries
  -- the type).
  -- stylua: ignore
  for _, mode in ipairs { "M", "A", "N", "D", "C", "U", "R", "T", "DD", "UU", "AA", "DU", "UD", "AU", "UA", "Untracked" } do
    hl_store["NeogitChange" .. mode .. "unstaged"] = { fg = palette.red, ctermfg = 1 }

    if #mode == 1 then
      hl_store["NeogitChange" .. mode .. "staged"] = { fg = ok_green, ctermfg = 2 }
    end

    if mode == "Untracked" then
      hl_store["NeogitChangeUntrackeduntracked"] = { fg = palette.red, ctermfg = 1 }
    end
  end

  -- Status banner gradient: the big ASCII title fades left-to-right across
  -- the theme's purple and blue (dashboard-style), one highlight group per
  -- step; the status UI maps each banner column to a step. Themes routinely
  -- link Include and Macro (the purple/blue sources) to the same group,
  -- which would flatten the fade to a single color - when the anchors
  -- collide, fade toward a shaded variant of the first instead so the
  -- title always keeps a visible sweep.
  local grad_from = Color.from_hex(palette.purple)
  local grad_to = Color.from_hex(palette.blue)

  if palette.purple == palette.blue then
    grad_to = grad_from:shade(vim.o.bg == "dark" and 0.35 or -0.35)
  end
  for i = 1, M.STATUS_BANNER_GRADIENT_STEPS do
    local t = (i - 1) / (M.STATUS_BANNER_GRADIENT_STEPS - 1)
    hl_store["NeogitStatusBanner" .. i] = {
      fg = Color(
        grad_from.red + (grad_to.red - grad_from.red) * t,
        grad_from.green + (grad_to.green - grad_from.green) * t,
        grad_from.blue + (grad_to.blue - grad_from.blue) * t
      ):to_css(),
      bold = palette.bold,
    }
  end

  for group, hl in pairs(hl_store) do
    if not is_set(group) then
      hl.default = true
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
end

return M
