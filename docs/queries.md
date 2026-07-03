# Query language

`find` (alias `ls`) and hook filters share one small query language. A query
is comparisons joined by `and`, `or`, `not`, and parentheses.

```sh
agent-store find 'kind=task and (status=pending or status=blocked) and not owner=bot'
```

Without a query, `find` lists every record in creation order, oldest first.

## Comparisons

`=`, `!=`, `<`, `<=`, `>`, `>=`, and `~=` compare the record kind (`kind=...`)
or a field value:

```sh
agent-store find kind=task status=pending
agent-store find 'priority<2'
agent-store find 'title~=parser'        # case-insensitive substring
```

`~=` matches when the right-hand side is a case-insensitive substring of the
field value (or of the kind, for `kind~=ta`).

A comparison on a field the record does not have never matches — not even
`!=`.

`kind` and `id` are reserved: in a query, `kind` always addresses the record
kind, and neither can be a field name.

### Value types

Values are typed by their text. `null`, `true`/`false`, dates
(`2026-01-02`), timestamps (`2026-01-02T03:04:05Z`), and numbers are
recognized; everything else is text. Ordering comparisons only match between
compatible types:

- Numbers compare numerically: `priority<2` does not match `priority=10`.
- Text compares lexicographically.
- Dates and timestamps compare on one timeline — a date counts as midnight
  UTC, so `stamp>2026-01-02` matches `2026-01-02T03:04:05Z`.
- Mixed types (e.g. text vs number) never match on `<`/`>`.

## Combinators

`and`, `or`, `not`, and parentheses. `and` binds tighter than `or`, so
`kind=note or kind=task and not status=done` means
`kind=note or (kind=task and not status=done)`.

Multiple bare arguments join with an implicit `and`:

```sh
agent-store find kind=task status=pending
# same as: agent-store find 'kind=task and status=pending'
```

Unquoted arguments that already spell out `and`/`or`/`not` keep their
meaning.

## Quoting

Quote values that contain spaces or operator characters, with single or
double quotes. Inside quotes a backslash escapes the next character
(`\'`, `\"`, `\\`). `''` matches fields stored as the empty string:

```sh
agent-store find "title='Fix parser'"
agent-store find "text=''"
```

## Timestamps

Every record carries `created_at` and `updated_at`. They compare like fields
unless shadowed by a real field with the same name:

```sh
agent-store find 'kind=task and created_at>2026-01-01'
```

Add `--timestamps` to append them to text output; `--json` always includes
them.

## Links

`link.out=<rel>` and `link.in=<rel>` match records with an outgoing or
incoming link of that relation:

```sh
agent-store link m4n3mi blocks 1ztocm
agent-store find 'link.out=blocks'    # m4n3mi
agent-store find 'link.in=blocks'     # 1ztocm
```

## Sorting and limits

`find`/`ls` also take:

| Flag | Effect |
| --- | --- |
| `--sort <field>` | Sort by a field or the built-ins `created_at`, `updated_at`, `kind`, `id`; records missing the field sort last |
| `--desc` | Reverse the order |
| `--limit <N>` | Output at most N records |
| `--count` | Print only the number of matches |
| `--timestamps` | Append `created_at=...`/`updated_at=...` to each line |

```sh
agent-store find kind=task --sort priority --desc --limit 5
agent-store find kind=task status=pending --count
```

Sorting is type-aware too: `--sort priority` orders `1, 2, 10` numerically.

See also: [FAQ](faq.md) — data format, concurrency, privacy, and limits.
