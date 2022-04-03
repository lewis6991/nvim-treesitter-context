local api = vim.api
local ts_utils = require'nvim-treesitter.ts_utils'
local highlighter = vim.treesitter.highlighter
-- local ts_query = require('nvim-treesitter.query')
local parsers = require'nvim-treesitter.parsers'
local utils = require'treesitter-context.utils'
local slice = utils.slice
local word_pattern = utils.word_pattern
local advances = require('treesitter-context.advances')

local defaultConfig = {
  enable = true,
  throttle = false,
  max_lines = 0, -- no limit
  auto_max_lines = false,
  auto_max_lines_padding = 0,
  fake_relative_number = false,
}

local config = {}

-- Constants

-- Tells us at which node type to stop when highlighting a multi-line
-- node. If not specified, the highlighting stops after the first line.
local last_types = {
  [word_pattern('function')] = {
    c = 'function_declarator',
    cpp = 'function_declarator',
    lua = 'parameters',
    python = 'parameters',
    rust = 'parameters',
    javascript = 'formal_parameters',
    typescript = 'formal_parameters',
  },
}

-- Tells us which leading child node type to skip when highlighting a
-- multi-line node.
local skip_leading_types = {
  [word_pattern('class')] = {
    php = 'attribute_list',
  },
  [word_pattern('method')] = {
    php = 'attribute_list',
  },
}

-- There are language-specific
local DEFAULT_TYPE_PATTERNS = {
  -- These catch most generic groups, eg "function_declaration" or "function_block"
  default = {
    'class',
    'function',
    'method',
    'for',
    'while',
    'if',
    'switch',
    'case',
  },
  rust = {
    'impl_item',
  },
  vhdl = {
    'process_statement',
    'architecture_body',
    'entity_declaration',
  },
  exact_patterns = {},
}
local INDENT_PATTERN = '^%s+'

-- Script variables

local did_setup = false
local enabled = false
local gutter_winid, context_winid
local gutter_bufnr, context_bufnr -- Don't access directly, use get_bufs()
local ns = api.nvim_create_namespace('nvim-treesitter-context')
local previous_nodes

local get_root_node = function()
  local tree = parsers.get_parser():parse()[1]
  return tree:root()
end

local is_valid = function(node, filetype)
  local node_type = node:type()
  for _, rgx in ipairs(config.patterns.default) do
    if node_type:find(rgx) then
      return true, rgx
    end
  end
  local filetype_patterns = config.patterns[filetype]
  for _, rgx in ipairs(filetype_patterns or {}) do
    if node_type:find(rgx) then
      return true, rgx
    end
  end
  return false
end

local get_type_pattern = function(node, type_patterns)
  local node_type = node:type()
  for _, rgx in ipairs(type_patterns) do
    if node_type:find(rgx) then
      return rgx
    end
  end
end

local function find_node(node, type)
  local children = ts_utils.get_named_children(node)
  for _, child in ipairs(children) do
    if child:type() == type then
      return child
    end
  end
  for _, child in ipairs(children) do
    local deep_child = find_node(child, type)
    if deep_child ~= nil then
      return deep_child
    end
  end
end

local get_text_for_node = function(node)
  local filetype = vim.bo.filetype

  if advances.is_advance(config, filetype) then
    return advances.get_text_for_node(node)
  end

  local type = get_type_pattern(node, config.patterns.default) or node:type()

  local skip_leading_type = (skip_leading_types[type] or {})[filetype]
  if skip_leading_type then
    local children = ts_utils.get_named_children(node)
    for _, child in ipairs(children) do
      if child:type() ~= skip_leading_type then
        node = child
        break
      end
    end
  end

  local start_row, start_col = node:start()
  local end_row, end_col     = node:end_()

  local lines = ts_utils.get_node_text(node)

  if start_col ~= 0 then
    lines[1] = api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  end
  start_col = 0

  local last_type = (last_types[type] or {})[filetype]

  local last_position

  if last_type then
    local child = find_node(node, last_type)

    if child then
      last_position = {child:end_()}

      end_row = last_position[1]
      end_col = last_position[2]
      local last_index = end_row - start_row
      lines = slice(lines, 1, last_index + 1)
      lines[#lines] = slice(lines[#lines], 1, end_col)
    end
  end

  if not last_position then
    lines = slice(lines, 1, 1)
    end_row = start_row
    end_col = #lines[1]
  end

  local range = {start_row, start_col, end_row, end_col}

  return node, lines, range
end

-- Merge lines, removing the indentation after 1st line
local merge_lines = function(lines)
  local text = { lines[1] }
  for i = 2, #lines do
    text[i] = lines[i]:gsub(INDENT_PATTERN, '')
  end
  return table.concat(text, ' ')
end

-- Get indentation for lines except first
local get_indents = function(lines)
  local indents = vim.tbl_map(function(line)
    local indent = line:match(INDENT_PATTERN)
    return indent and #indent or 0
  end, lines)
  -- Dont skip first line indentation
  indents[1] = 0
  return indents
end

local get_gutter_width = function()
  return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
end

local nvim_augroup = function(group_name, definitions)
  vim.cmd('augroup ' .. group_name)
  vim.cmd('autocmd!')
  for _, def in ipairs(definitions) do
    local command = table.concat({'autocmd', unpack(def)}, ' ')
    if api.nvim_call_function('exists', {'##' .. def[1]}) ~= 0 then
      vim.cmd(command)
    end
  end
  vim.cmd('augroup END')
end

local cursor_moved_vertical
do
  local line
  cursor_moved_vertical = function()
    local newline = vim.api.nvim_win_get_cursor(0)[1]
    if newline ~= line then
      line = newline
      return true
    end
    return false
  end
end

local function get_bufs()
  if not context_bufnr or not api.nvim_buf_is_valid(context_bufnr) then
    context_bufnr = api.nvim_create_buf(false, true)
  end

  if not gutter_bufnr or not api.nvim_buf_is_valid(gutter_bufnr) then
    gutter_bufnr = api.nvim_create_buf(false, true)
  end

  return gutter_bufnr, context_bufnr
end

local function delete_bufs()
  if context_bufnr and api.nvim_buf_is_valid(context_bufnr) then
    api.nvim_buf_delete(context_bufnr, { force = true })
  end
  context_bufnr = nil

  if gutter_bufnr and api.nvim_buf_is_valid(gutter_bufnr) then
    api.nvim_buf_delete(gutter_bufnr, { force = true })
  end
  gutter_bufnr = nil
end

local function display_window(bufnr, winid, width, height, col, ty, hl)
  if not winid or not api.nvim_win_is_valid(winid) then
    winid = api.nvim_open_win(bufnr, false, {
      relative = 'win',
      width = width,
      height = height,
      row = 0,
      col = col,
      focusable = false,
      style = 'minimal',
      noautocmd = true,
    })
    api.nvim_win_set_var(winid, ty, true)
    api.nvim_win_set_option(winid, 'winhl', 'NormalFloat:'..hl)
    api.nvim_win_set_option(winid, 'foldenable', false)
  else
    api.nvim_win_set_config(winid, {
      win = api.nvim_get_current_win(),
      relative = 'win',
      width = width,
      height = height,
      row = 0,
      col = col,
    })
  end
  return winid
end

-- Exports

local M = {
  config = config,
}

function M.do_au_cursor_moved_vertical()
  if cursor_moved_vertical() then
    vim.cmd [[doautocmd <nomodeline> User CursorMovedVertical]]
  end
end

local function reverse_table(t)
  local r = {}

  if t then
    r = {}
    for i = #t, 1, -1 do
      r[#r+1] = t[i]
    end
  end

  return r
end

local function process_relativeline_data(line, higher_line, last_relativeline)
  local relativeline_count = last_relativeline
  local i = line
  while i < higher_line do
    local foldend = api.nvim_call_function('foldclosedend', { i })
    if (foldend ~= -1) then
      i = foldend + 1
    else
      i = i + 1
    end
    relativeline_count = relativeline_count + 1
  end
  return relativeline_count, line, relativeline_count
end


local function get_parent_matches()
  if not parsers.has_parser() then
    return
  end

  local lnum, col = unpack(api.nvim_win_get_cursor(0))

  local node = get_root_node():named_descendant_for_range(lnum-1, col, lnum-1, col)
  if not node then
    return
  end

  local buf_ft = vim.bo.filetype
  local relative_topline = process_relativeline_data(vim.fn.line('w0'), lnum, 0)
  local topline = lnum - relative_topline

  local max_lines = config.max_lines
  if config.auto_max_lines then
    local padding = config.auto_max_lines_padding
    max_lines = math.max(lnum - topline - padding, 1)
  end

  if advances.is_advance(config, buf_ft) then
    return advances.get_parent_matches(config, node, buf_ft, topline, max_lines)
  end

  local possible_parent_matches = {}
  local parent_matches = {}
  local full_parent_matches = {}
  local lines = 0
  local last_row = -1

  while node do
    local row = node:start()

    if is_valid(node, buf_ft)
        and row >= 0
        and row ~= last_row then
      last_row = row

      if row < (topline - 1) then
        lines = lines + 1
        parent_matches[#parent_matches+1] = node
      else
        possible_parent_matches[#possible_parent_matches+1] = node
      end

      if max_lines > 0 and lines >= max_lines then
        break
      end
    end
    node = node:parent()
  end

  local real_topline = topline + #parent_matches
  lines = 0

  for i = #possible_parent_matches, 1, -1 do
    local row = possible_parent_matches[i]:start()

    -- check if line is not visible
    if row then
      if row < (real_topline - 1) then
        table.insert(full_parent_matches, 1, possible_parent_matches[i])
        real_topline = real_topline + 1
        lines = lines + 1
        if max_lines > 0 and lines >= max_lines then
          break
        end
      else -- else break when line is visible
        break
      end
    end
  end

  -- Merge with origin parents if exist
  if #full_parent_matches == 0 then
    full_parent_matches = parent_matches
  else
    for _, parent in ipairs(parent_matches) do
      -- check max_lines first because can be lines > 0
      if max_lines > 0 and lines >= max_lines then
        break
      end
      table.insert(full_parent_matches, parent)
      lines = lines + 1
    end
  end

  return reverse_table(full_parent_matches)
end


do
  local running = false

  function M.throttled_update_context()
    if running then return end
    running = true
    vim.defer_fn(function()
      local status, err = pcall(M.update_context)

      if not status then
        print('Failed to get context: ' .. err)
      end

      running = false
    end, 100)
  end
end

function M.close()
  previous_nodes = nil
  -- Can't close other windows when the command-line window is open
  if api.nvim_call_function('getcmdwintype', {}) ~= '' then
    return
  end

  if context_winid ~= nil and api.nvim_win_is_valid(context_winid) then
    api.nvim_win_close(context_winid, true)
  end
  context_winid = nil

  if gutter_winid and api.nvim_win_is_valid(gutter_winid) then
    api.nvim_win_close(gutter_winid, true)
  end
  gutter_winid = nil
end

local function set_lines(bufnr, lines)
  local clines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local redraw = false
  if #clines ~= #lines then
    redraw = true
  else
    for i, l in ipairs(clines) do
      if l ~= lines[i] then
        redraw = true
        break
      end
    end
  end

  if redraw then
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  return redraw
end

local function highlight_contexts(bufnr, ctx_bufnr, contexts)
  api.nvim_buf_clear_namespace(ctx_bufnr, ns, 0, -1)

  local buf_highlighter = highlighter.active[bufnr]

  if not buf_highlighter then
    -- Use standard highlighting when TS highlighting is not available
    local current_ft = vim.bo.filetype
    if current_ft ~= vim.bo[ctx_bufnr].filetype then
      api.nvim_buf_set_option(ctx_bufnr, 'filetype', current_ft)
    end
    return
  end

  local buf_query = buf_highlighter:get_query(vim.bo.filetype)

  local query = buf_query:query()
  local root = get_root_node()

  for i, context in ipairs(contexts) do
    local start_row, _, end_row, end_col = unpack(context.range)
    local indents = context.indents
    local lines = context.lines

    -- local start_row_abs = context.node:start()
    local start_row_abs = start_row -- advacnce made node start changed

    for capture, node in query:iter_captures(root, bufnr, start_row, context.node:end_()) do
      local node_start_row, node_start_col, node_end_row, node_end_col = node:range()

      if node_end_row > end_row or
        (node_end_row == end_row and node_end_col > end_col) then
        break
      end

      if node_start_row >= start_row_abs then
        local intended_start_row = node_start_row - start_row_abs

        -- Add 1 for each space added between lines when
        -- we replace "\n" with " "
        local offset = intended_start_row
        -- Add the length of each preceding lines
        for j = 1, intended_start_row do
          offset = offset + #lines[j] - indents[j]
        end
        -- Remove the indentation negative offset for current line
        offset = offset - indents[intended_start_row + 1]

        local row = i - 1
        api.nvim_buf_set_extmark(ctx_bufnr, ns, row, node_start_col + offset, {
          end_line = row,
          end_col = node_end_col + offset,
          hl_group = buf_query.hl_cache[capture]
        })
      end
    end
  end
end

local function build_lno_str(lnum, width)
  return string.format('%'..width..'d', lnum)
end

local function open(ctx_nodes)
  local bufnr = api.nvim_get_current_buf()

  local gutter_width = get_gutter_width()
  local win_width  = math.max(1, api.nvim_win_get_width(0) - gutter_width)
  local win_height = math.max(1, #ctx_nodes)

  local gbufnr, ctx_bufnr = get_bufs()

  gutter_winid = display_window(
    gbufnr, gutter_winid, gutter_width, win_height, 0,
    'treesitter_context_line_number', 'TreesitterContextLineNumber')

  context_winid = display_window(
    ctx_bufnr, context_winid, win_width, win_height, gutter_width,
    'treesitter_context', 'TreesitterContext')

  -- Set text

  local context_text = {}
  local lno_text = {}
  local lno = {} -- store only number
  local contexts = {}

  for _, node in ipairs(ctx_nodes) do
    local ctx_node, lines, range = get_text_for_node(node)
    local text = merge_lines(lines)

    contexts[#contexts+1] = {
      node = ctx_node,
      lines = lines,
      range = range,
      indents = get_indents(lines),
    }

    context_text[#context_text+1] = text
    lno[#lno+1] = range[1]+1 -- for later using
  end

  -- use complex algorithm to solve relative number with folding
  if config.fake_relative_number
      and vim.api.nvim_win_get_option(0, 'relativenumber') then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local last_line = cursor_line
    local last_relativeline = 0 -- for relative line can reuse higher line
    -- loop in reverse to get line near cursor line first
    for i=#lno,1,-1 do
      lno[i], last_line, last_relativeline
        = process_relativeline_data(lno[i], last_line, last_relativeline)
    end
  end

  for _, ln in ipairs(lno) do
    lno_text[#lno_text+1] = build_lno_str(ln, gutter_width-1)
  end

  set_lines(gbufnr, lno_text) -- set number regardless of context not changing
  if not set_lines(ctx_bufnr, context_text) then
    -- Context didn't change, can return here
    return
  end

  highlight_contexts(bufnr, ctx_bufnr, contexts)
end

function M.update_context()
  if vim.bo.buftype ~= '' or
      vim.fn.getwinvar(0, '&previewwindow') ~= 0 then
    M.close()
    return
  end

  local context = get_parent_matches()

  if context and #context ~= 0 then
    if context == previous_nodes then
      return
    end

    previous_nodes = context

    open(context)
  else
    M.close()
  end
end

function M.enable()
  local pfx = 'silent lua require("treesitter-context").'
  local throttle = config.throttle and 'throttled_' or ''
  local update = pfx..throttle..'update_context()'

  nvim_augroup('treesitter_context_update', {
    {'WinScrolled', '*',                   update},
    {'BufEnter',    '*',                   update},
    {'WinEnter',    '*',                   update},
    {'User',        'CursorMovedVertical', update},
    {'CursorMoved', '*',                   pfx..'do_au_cursor_moved_vertical()'},
    {'WinLeave',    '*',                   pfx..'close()'},
    {'VimResized',  '*',                   update},
    {'User',        'SessionSavePre',      pfx..'close()'},
    {'User',        'SessionSavePost',     update},
  })

  M.throttled_update_context()
  enabled = true
end

function M.disable()
  nvim_augroup('treesitter_context_update', {})
  M.close()
  delete_bufs()
  enabled = false
end

function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.onVimEnter()
  if did_setup then
    return
  end

  -- Setup with default options if user didn't call setup()
  M.setup()
end

function M.setup(options)
  did_setup = true

  local userOptions = options or {}

  config                = vim.tbl_deep_extend("force", {}, defaultConfig, userOptions)
  config.patterns       = vim.tbl_deep_extend("force", {}, DEFAULT_TYPE_PATTERNS, userOptions.patterns or {})
  config.exact_patterns = vim.tbl_deep_extend("force", {}, userOptions.exact_patterns or {})
  config.advances       = vim.tbl_deep_extend("force", {}, advances.DEFAULT_ADVANCE_PATTERNS, userOptions.advances or {})

  for filetype, patterns in pairs(config.patterns) do
    -- Map with word_pattern only if users don't need exact pattern matching
    if not config.exact_patterns[filetype] then
      config.patterns[filetype] = vim.tbl_map(word_pattern, patterns)
    end
  end

  if config.enable then
    M.enable()
  else
    M.disable()
  end
end

vim.cmd('command! TSContextEnable  lua require("treesitter-context").enable()')
vim.cmd('command! TSContextDisable lua require("treesitter-context").disable()')
vim.cmd('command! TSContextToggle  lua require("treesitter-context").toggle()')

vim.cmd('highlight default link TreesitterContext NormalFloat')
vim.cmd('highlight default link TreesitterContextLineNumber LineNr')

nvim_augroup('treesitter_context', {
  {'VimEnter', '*', 'lua require("treesitter-context").onVimEnter()'},
})

return M
