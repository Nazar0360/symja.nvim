local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  local ft = vim.bo.filetype
  return ft == "symja" or ft == "symja_mma"
end

function source:get_debug_name()
  return "symja"
end

function source:get_keyword_pattern()
  return [[\%([[:alnum:]_$`]\)\+]]
end

function source:get_trigger_characters()
  return { "`", "_" }
end

function source:complete(params, callback)
  local before = params.context.cursor_before_line or ""
  local prefix = before:match("([%w_$`]+)$") or ""

  require("symja").complete(prefix, function(symbols)
    local items = {}
    local seen = {}
    local lower_prefix = prefix:lower()

    for _, symbol in ipairs(symbols or {}) do
      local lower_symbol = symbol:lower()
      if lower_symbol:sub(1, #lower_prefix) == lower_prefix and not seen[symbol] then
        seen[symbol] = true
        items[#items + 1] = {
          label = symbol,
          kind = 3, -- Function; Symja's symbols can also be constants/variables.
          detail = "Symja symbol",
          sortText = lower_symbol,
        }
      end
    end

    callback({ items = items, isIncomplete = false })
  end)
end

-- nvim-cmp calls resolve() for the selected completion item. Fetching here
-- avoids downloading documentation for every candidate in the completion list.
function source:resolve(completion_item, callback)
  local symbol = type(completion_item.label) == "string" and completion_item.label or nil
  if not symbol then
    callback(completion_item)
    return
  end

  require("symja").get_documentation(symbol, function(lines)
    if lines and #lines > 0 then
      completion_item.documentation = {
        kind = "markdown",
        value = table.concat(lines, "\n"),
      }
    end
    callback(completion_item)
  end)
end

return source
