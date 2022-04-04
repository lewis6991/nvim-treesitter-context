return function(node)
  local ctx_nodes = {}

  local node_type = node:type()
  if
    -- class, method, constructor, record, enum
    node_type == 'class_declaration'
    or node_type == 'method_declaration'
    or node_type == 'constructor_declaration'
    or node_type == 'record_declaration'
    or node_type == 'enum_declaration'
  then
    ctx_nodes[#ctx_nodes + 1] = {
      node = node,
      begin_with = node:field('name')[1],
      end_before = node:field('body')[1],
      end_before_extend_col = 1,
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
    ctx_nodes[#ctx_nodes + 1] = {
      node = node,
      end_before = node:field('body')[1],
      end_before_extend_col = 1,
    }
  elseif node_type == 'if_statement' then
    -- if
    ctx_nodes[#ctx_nodes + 1] = {
      node = node,
      end_before = node:field('consequence')[1],
      end_before_extend_col = 1,
    }
    -- else
    local else_node = node:field('alternative')[1]
    if else_node and else_node:type() == 'block' then
      ctx_nodes[#ctx_nodes + 1] = {
        node = node,
        begin_with = else_node,
      }
    end
  -- elseif node_type == 'switch_block' then
  --   -- all case of switch
  --   local child_count = node:child_count()
  --   for i = 0, child_count - 1  do
  --     ctx_nodes[#ctx_nodes + 1] = {
  --       node = node,
  --       begin_with = node:child(i),
  --     }
  --   end
  elseif node_type == 'switch_block_statement_group' then
    -- current case of switch
    ctx_nodes[#ctx_nodes + 1] = {
      node = node,
    }
  end

  return ctx_nodes
end
