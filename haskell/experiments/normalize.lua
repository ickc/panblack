-- candidate panblack normalizations, applied after reading
function Table(t)
  for i, spec in ipairs(t.colspecs) do t.colspecs[i] = {spec[1], nil} end
  return t:walk { SoftBreak = function() return pandoc.Space() end }
end
function CodeBlock(cb)
  cb.text = cb.text:gsub("^%s*\n", ""):gsub("\n%s*$", "")
  return cb
end
function Div(d)
  d.content = d.content:map(function(b) return b.t == "Plain" and pandoc.Para(b.content) or b end)
  return d
end
function RawBlock(r)
  if r.format == "html" and r.text:match("^<!%-%-%s*%-%->$") then return {} end
end
