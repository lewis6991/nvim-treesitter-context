return function(node, check_default_pattern)
  local advance_nodes = {}

  local node_type = node:type()
  if
    -- class, method, constructor, record, enum
    node_type == 'class_declaration'
    or node_type == 'method_declaration'
    or node_type == 'constructor_declaration'
    or node_type == 'record_declaration'
    or node_type == 'enum_declaration'
  then
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      begin_with = node:field('name')[1],
      end_with = node:field('body')[1]:child(0),
    }
  elseif
    -- for, do while, for(enhanced), while, try, catch, lambda
    node_type == 'for_statement'
    or node_type == 'do_statement'
    or node_type == 'while_statement'
    or node_type == 'enhanced_for_statement'
    or node_type == 'try_statement'
    or node_type == 'catch_clause'
    or node_type == 'lambda_expression'
    or node_type == 'switch_expression'
  then
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      end_with = node:field('body')[1]:child(0),
    }
  elseif node_type == 'if_statement' then
    -- if
    advance_nodes[#advance_nodes + 1] = {
      node = node,
      end_with = node:field('consequence')[1]:child(0),
    }
    -- else
    local else_node = node:field('alternative')[1]
    if else_node and else_node:type() == 'block' then
      advance_nodes[#advance_nodes + 1] = {
        node = node,
        begin_with = else_node,
      }
    end
  elseif node_type == 'switch_block_statement_group' then
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
