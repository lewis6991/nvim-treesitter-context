return function(node, check_default_pattern)
  local advance_nodes = {}

  local node_type = node:type()
  if
    node_type == 'class_declaration'
    or node_type == 'function_declaration'
    or node_type == 'generator_function_declaration'
    or node_type == 'function'
    or node_type == 'method_definition'
  then
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      begin_with = node:field('name')[1],
      end_before = node:field('body')[1]:child(1),
    }
  elseif
    -- for, do while, for(enhanced), while, try, catch, lambda
    node_type == 'for_statement'
    or node_type == 'for_in_statement'
    or node_type == 'while_statement'
    or node_type == 'try_statement'
    or node_type == 'switch_statement'
    or node_type == 'catch_clause'
    or node_type == 'arrow_function'
    or node_type == 'generator_function'
  then
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      end_before = node:field('body')[1]:child(1),
    }
  elseif node_type == 'if_statement' then
    -- if
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      end_before = node:field('consequence')[1]:child(1),
    }
    -- else
    local else_node = node:field('alternative')[1]
    if else_node and else_node:child(1):type() == 'statement_block' then
      advance_nodes[#advance_nodes + 1] = {
        node = node,
        begin_with = else_node,
      }
    end
  elseif node_type == 'object' then
    -- current case of switch
    advance_nodes[#advance_nodes + 1] = {
      node = node,
    }
  end
  -- (( Get all case of switch ))
  -- elseif node_type == 'switch_block' then
  --   local child_count = node:child_count()
  --   for i = 0, child_count - 1  do
  --     ctx_nodes[#ctx_nodes + 1] = {
  --       node = node,
  --       begin_with = node:child(i),
  --     }
  --   end
  -- end
  -- (( fallback to default pattern check ))
  -- elseif check_default_pattern(node) then
  --   advance_nodes[#advance_nodes + 1] = { node = node }
  -- end

  return advance_nodes
end
