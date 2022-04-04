local api = vim.api
local ts_utils = require('nvim-treesitter.ts_utils')
local utils = require('treesitter-context.utils')
local slice = utils.slice

local DEFAULT_ADVANCE_PATTERNS = {
  enable = false,
  languages = {
    java = require('treesitter-context.advances.java'),
    ecma = require('treesitter-context.advances.ecma'),
    typescript = 'ecma',
    typescriptreact = 'ecma',
    javascript = 'ecma',
    javascriptreact = 'ecma',
  },
}

local function is_advance(config, buf_ft)
  return config.advances.enable and config.advances.languages[buf_ft]
end

local function get_default_pattern_advance_nodes(node, check_default_pattern)
  local advance_nodes = {}
  if check_default_pattern(node) then
    advance_nodes[#advance_nodes + 1] = { node = node }
  end
  return advance_nodes
end

local function get_parent_matches(
  config,
  node,
  buf_ft,
  max_topline,
  topline,
  max_lines,
  check_default_pattern
)
  local parent_matches = {}
  local possible_parent_matches = {}
  local full_parent_matches = {}
  local lines = 0
  local last_row = -1

  local get_advance_nodes
  if is_advance(config, buf_ft) then
    get_advance_nodes = config.advances.languages[buf_ft]
  else
    get_advance_nodes = get_default_pattern_advance_nodes
  end

  local not_break = true
  while not_break and node do
    local advance_nodes = get_advance_nodes(node, check_default_pattern)

    for i = #advance_nodes, 1, -1 do
      local advance_node = advance_nodes[i]
      local begin_node
      if advance_node.begin_with then
        begin_node = advance_node.begin_with
      else
        begin_node = advance_node.node
      end
      if begin_node then
        local row = begin_node:start()

        if row >= 0 and row ~= last_row and row < (max_topline - 1) then
          last_row = row

          if row < (topline - 1) then
            lines = lines + 1
            parent_matches[#parent_matches + 1] = advance_node

            if max_lines > 0 and lines >= max_lines then
              not_break = false
              break
            end
          else
            possible_parent_matches[#possible_parent_matches + 1] = advance_node
          end
        end
      end
    end
    node = node:parent()
  end

  local real_topline = topline
  for _ = 1, #parent_matches do
    real_topline = utils.get_next_line(real_topline)
  end
  lines = 0

  for i = #possible_parent_matches, 1, -1 do
    local possible_parent_node = possible_parent_matches[i]
    local begin_node
    if possible_parent_node.begin_with then
      begin_node = possible_parent_node.begin_with
    else
      begin_node = possible_parent_node.node
    end
    if begin_node then
      local row = begin_node:start()
      -- check if line is not visible
      if row then
        if row < (real_topline - 1) then
          table.insert(full_parent_matches, 1, possible_parent_node)
          real_topline = utils.get_next_line(real_topline)
          lines = lines + 1
          if max_lines > 0 and lines >= max_lines then
            break
          end
        else -- else break when line is visible
          break
        end
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

  return utils.reverse_table(full_parent_matches)
end

local function get_text_for_node(advance_node)
  local node = advance_node.node
  if not node then
    return
  end

  local start_row, start_col = node:start()
  local end_row, end_col = node:end_()

  local lines = ts_utils.get_node_text(node)

  if start_col ~= 0 then
    lines[1] = api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  end
  start_col = 0

  -- TODO: Write documentation
  local begin_with_node = advance_node.begin_with
  local end_before_node = advance_node.end_before
  local end_with_node = advance_node.end_with

  local last_position

  if begin_with_node then
    local new_start_row = begin_with_node:start()
    local begin_index = new_start_row - start_row
    lines = slice(lines, begin_index + 1, #lines)
    start_row = new_start_row
  end

  if end_before_node then
    last_position = { end_before_node:start() }
  elseif end_with_node then
    last_position = { end_with_node:end_() }
  end

  if last_position then
    end_row = last_position[1]
    end_col = last_position[2]
    local last_index = end_row - start_row
    lines = slice(lines, 1, last_index + 1)
    lines[#lines] = slice(lines[#lines], 1, end_col)
  else
    lines = slice(lines, 1, 1)
    end_row = start_row
    end_col = #lines[1]
  end

  local range = { start_row, start_col, end_row, end_col }

  return node, lines, range
end

return {
  DEFAULT_ADVANCE_PATTERNS = DEFAULT_ADVANCE_PATTERNS,
  is_advance = is_advance,
  get_parent_matches = get_parent_matches,
  get_text_for_node = get_text_for_node,
}
