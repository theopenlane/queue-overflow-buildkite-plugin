# Removes the given agent tags from every `agents:` block whose queue is set
# from the queue variable. Other blocks are passed through untouched.
#
# Usage: awk -v var=QUEUE_VAR -v tags="size,arch" -f strip-tags.awk pipeline.yml
#
# Only block-style `agents:` maps are rewritten; flow style
# (`agents: { queue: ... }`) and list style (`- "queue=..."`) are left as is.

function indent_of(s) { match(s, /^[ \t]*/); return RLENGTH }

function flush(   i, keep_line, k) {
  for (i = 1; i <= n; i++) {
    keep_line = 1
    if (uses_var) {
      for (k in strip) {
        if (buf[i] ~ ("^[ \t]*[\"']?" k "[\"']?[ \t]*:")) { keep_line = 0; break }
      }
    }
    if (keep_line) print buf[i]
  }
  n = 0; in_block = 0; uses_var = 0
}

BEGIN {
  split(tags, parts, ",")
  for (i in parts) if (parts[i] != "") strip[parts[i]] = 1
  queue_re = "^[ \t]*[\"']?queue[\"']?[ \t]*:[ \t]*[\"']?\\$\\{?" var "([^A-Za-z0-9_]|$)"
  n = 0; in_block = 0; uses_var = 0
}

{
  if (in_block) {
    if ($0 ~ /^[ \t]*$/ || indent_of($0) > block_indent) {
      buf[++n] = $0
      if ($0 ~ queue_re) uses_var = 1
      next
    }
    flush()
  }
  print
  if ($0 ~ /^[ \t]*(- )?agents:[ \t]*(#.*)?$/) {
    in_block = 1
    block_indent = indent_of($0)
    if ($0 ~ /^[ \t]*- /) block_indent += 2
  }
}

END { if (in_block) flush() }
