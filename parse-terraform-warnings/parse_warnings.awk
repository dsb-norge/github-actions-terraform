# State-machine parser for terraform 'Warning:' diagnostic blocks.
#
# Required variables (passed via -v):
#   step_label  - 'init' | 'validate' | 'plan'; used in annotation titles
#                 ("init warning", etc.) so reviewers can tell which step
#                 emitted a warning from the run-page annotations panel.
#   md_out      - Path to write per-block markdown bodies to. Each block
#                 ends with a "---" separator line. Bash main wraps the
#                 file with a "### From terraform <step>" header.
#   annot_out   - Path to write annotations to. Bash main cats this to
#                 stdout so GitHub picks the lines up as workflow commands.
#   count_out   - Path to write the final integer warning-count to.
#
# Counting model: terraform shows ONE example per warning category and
# appends '(and N more similar warnings elsewhere)' for the suppressed
# rest. We emit one annotation per shown block (only the one example has
# source context anyway) but sum (1 + N) into warning-count so the cell
# in the PR table reflects total occurrences, not categories.
#
# Block boundaries: ^Warning: starts a block; next ^Warning: or ^Error:
# or EOF ends it. Blank lines and indented context lines stay inside the
# block. 'Plan:' is NOT a terminator — terraform plan logs put warnings
# AFTER the 'Plan: N to add…' summary line.

function escape_attr(s,   r) {
  # Escapes for use in name=value attribute pairs in workflow commands.
  # Order matters: % first so subsequent %xx sequences aren't re-escaped.
  r = s
  gsub(/%/, "%25", r)
  gsub(/\r/, "%0D", r)
  gsub(/\n/, "%0A", r)
  gsub(/:/, "%3A", r)
  gsub(/,/, "%2C", r)
  return r
}

function escape_msg(s,   r) {
  # Escapes for the message portion (after ::). Only %, \r, \n are special.
  r = s
  gsub(/%/, "%25", r)
  gsub(/\r/, "%0D", r)
  gsub(/\n/, "%0A", r)
  return r
}

function emit_block(   message_oneline, message_escaped, title_escaped, file_escaped, annotation, md) {
  # Annotation: one line per block. Use newline-joined message in the
  # actual workflow-command (encoded as %0A) so the GitHub UI shows the
  # full body when hovering the annotation.
  message_oneline = message
  # Trim trailing newlines
  sub(/\n+$/, "", message_oneline)
  message_escaped = escape_msg(message_oneline)
  title_escaped = escape_attr("terraform " step_label " warning: " title)

  if (file != "" && line != "") {
    file_escaped = escape_attr(file)
    annotation = "::warning file=" file_escaped ",line=" line ",title=" title_escaped "::" message_escaped
  } else {
    annotation = "::warning title=" title_escaped "::" message_escaped
  }
  print annotation > annot_out

  # Markdown block. Wrapping the message in '> ' blockquote so it renders
  # cleanly inside the outer <details> collapser without triple-backtick
  # collisions on user-supplied terraform output.
  md = "**Warning: " title "**\n"
  if (file != "") {
    if (line != "") {
      md = md "- source: `" file ":" line "`\n"
    } else {
      md = md "- source: `" file "`\n"
    }
  }
  if (suppressed > 0) {
    md = md "- (and " suppressed " more similar warnings elsewhere)\n"
  }
  md = md "\n"
  # Blockquote each non-empty line of the message
  n = split(message_oneline, lines, "\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] == "") {
      md = md ">\n"
    } else {
      md = md "> " lines[i] "\n"
    }
  }
  md = md "\n---\n\n"
  printf "%s", md > md_out

  total_count += 1 + suppressed
}

BEGIN {
  in_block = 0
  title = ""
  file = ""
  line = ""
  message = ""
  suppressed = 0
  total_count = 0
}

# Block start
/^Warning: / {
  if (in_block) emit_block()
  in_block = 1
  body_started = 0
  title = $0
  sub(/^Warning: /, "", title)
  file = ""
  line = ""
  message = ""
  suppressed = 0
  next
}

# Error terminates the current block
/^Error: / {
  if (in_block) { emit_block(); in_block = 0 }
  next
}

# Inside a block
in_block {
  # Aggregator suffix can appear after message body — match before
  # falling into the body-collection branch.
  if (match($0, /^\(and [0-9]+ more similar warnings elsewhere\)/)) {
    s = $0
    sub(/^\(and /, "", s)
    sub(/ more similar warnings elsewhere\).*/, "", s)
    suppressed = s + 0
    next
  }

  # Until the body starts, blank lines and indented context lines are
  # skipped. Terraform's context block (the "  with module…", "  on file
  # line N…", "   <N>: <code>" lines) is always indented; the message
  # body always starts at column 1. Extract file/line from any "  on …
  # line <N>" we see during this skipping phase.
  if (!body_started) {
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^[[:space:]]/) {
      if (file == "" && match($0, /^[[:space:]]+on .+ line [0-9]+/)) {
        s = $0
        sub(/^[[:space:]]+on /, "", s)
        if (match(s, / line [0-9]+/)) {
          file = substr(s, 1, RSTART - 1)
          rest = substr(s, RSTART + 6)  # skip " line "
          if (match(rest, /^[0-9]+/)) {
            line = substr(rest, RSTART, RLENGTH)
          }
        }
      }
      next
    }
    # First non-indented non-blank line — start of message body.
    body_started = 1
  }

  message = message $0 "\n"
}

END {
  if (in_block) emit_block()
  printf "%d", total_count > count_out
}
