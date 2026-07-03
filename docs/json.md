# JSON output and import

Every command supports `--json` (before or after the subcommand). Output is
one JSON object on stdout, designed to compose with `jq`.

## Shapes

Single-record commands (`get`, `create`, `set`, `unset`, `rm`) wrap the
record in `{"record": ...}`; mutations add a `status`:

```sh
$ agent-store --json get 7f0owa
{"record":{"created_at":"2026-07-03T09:16:49.608Z","fields":{"status":"done","title":"ship v0.1"},"id":"7f0owa","kind":"task","updated_at":"2026-07-03T09:16:49.612Z"}}

$ agent-store --json set 7f0owa status=done
{"record":{...},"status":"updated"}      # "created" / "removed" for create / rm
```

List commands wrap records in `{"records":[...]}`:

```sh
$ agent-store --json find kind=task
{"records":[{"created_at":"...","fields":{...},"id":"7f0owa","kind":"task","updated_at":"..."}]}
```

Other envelopes: `links <id>` emits `{"links":[{"direction","rel","record_id"}],"record_id"}`;
`hook runs` emits `{"hook_runs":[...]}`; `ctx` emits the summary as an
object (`fields_by_kind`, `recent_records`, counts, `latest_activity_at`).

Records always include `created_at` and `updated_at`.

## Importing with `create --stdin`

`create --stdin` bulk-imports JSONL: one object per line of the shape
`{"kind":"...","fields":{"k":"v"}}` — the same record shape `find --json`
emits. Extra keys (`id`, `created_at`, `updated_at`) are ignored, so exports
round-trip. Number, boolean, and null field values are stored as their raw
text, just like argv `key=value` input. Empty lines are skipped.

```sh
$ printf '%s\n' \
    '{"kind":"task","fields":{"title":"imported","status":"pending"}}' \
    '{"kind":"note","fields":{"text":"from jsonl"}}' \
  | agent-store create --stdin
ybnj1c
uxssc1
```

One ID prints per line in input order (`--json` prints a `records` array
instead), and hooks fire per created record. Every line is validated before
any record is created — an invalid line exits non-zero naming the line
number, with nothing imported:

```sh
$ printf '{"kind":"note","fields":{"text":"ok"}}\nnot json\n' | agent-store create --stdin
error: stdin line 2: invalid JSON: expected ident at line 1 column 2
```

## Pipeline recipes

Copy records between stores (round-trip export/import):

```sh
agent-store find kind=task --json | jq -c '.records[]' | (cd ../other-project && agent-store create --stdin)
```

Extract IDs for scripting:

```sh
agent-store find 'kind=task and status=pending' --json | jq -r '.records[].id'
```

Batch-create from plain lines:

```sh
while IFS= read -r line; do
  agent-store create note text="$line"
done < notes.txt
```

Capture command output into a record:

```sh
agent-store create log command=test output="$(cargo test 2>&1)"
```

Prefer the built-in `--sort`, `--desc`, `--limit`, and `--count` flags over
shell-side `sort`, `head`, or `wc -l`:

```sh
agent-store find kind=log --sort updated_at --desc --limit 10
agent-store find kind=note --count
```
