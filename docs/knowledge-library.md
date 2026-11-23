# Knowledge Library

A `native-knowledge-library` instance exposes blocks tagged with its configured
knowledge tag or a descendant. The blocks are not copies: an edit also changes
what other consumers of that block see. Existing and new libraries are read-only
by default. The tool owner can enable `create_block`, `edit_block` and
`delete_block` independently on the **Functions** tab. Sharing the tool or its
bot grants access to the library's enabled reads, never to its writes. Copying
someone else's tool does not copy its tag or its write permissions.

- `create_block(name, content, version?)` creates a new Markdown block and tags
  it with the configured root in the same operation. Duplicate names are allowed.
- `edit_block(block_id, expected_revision, name?, version?, replacements?,
  append_text?)` changes only the supplied fields. Each `{old_text, new_text}`
  replaces exactly one literal occurrence in the visible source. Use more context
  for an ambiguous match, or an empty `new_text` to remove the match. Replacements
  run in order; `append_text` is applied last. If a replacement fails, nothing
  is saved, including metadata changes.
- `delete_block(block_id, expected_revision)` permanently deletes the block, not
  just its tag. It returns `block_in_use` rather than cascading through tags outside
  the library, references (bots, handoffs, chats, profiles or LLM configurations),
  shares, an image, file attachments or managed secrets. There is no force option.

Use `list_blocks` to find the numeric `block_id`. Before editing text, call
`read_block` with `{"block_id":42,"view":"edit"}`. Its paged `fragments` are
JSON strings that preserve whitespace and line endings. Hidden `//// ` comment
lines separate fragments; neither comments nor attachment placeholders are
replacement targets. A replacement cannot remove the line break protecting a
hidden comment. When appending after an unterminated comment, the library starts
a new line. Normal reads and searches retain their original pagination.

Copy the `revision` from a list, read or successful write into the next edit or
delete call. It is an opaque token, distinct from the optional `version` label.
For example, supplying `replacements: [{"old_text":"30 days","new_text":"90 days"}]`
changes just those words. On `revision_conflict`, reread the block and reconsider
the change rather than retrying with a new token blindly.
