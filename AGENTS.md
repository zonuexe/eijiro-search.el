# AGENTS.md

Implementation notes for `eijiro-search.el`.

## Scope and Stability

- Current version is `0.0.1`.
- All behavior is provisional and may change without notice.

## Core Constraints

- Backend is `rg` only (no grep backend).
- Do not enable a custom major mode for the result buffer.
  - Keep compatibility with `vui` behavior.
- Dictionary input is UTF-8/LF text converted from EIJIRO source data.

## Search Model

- Modes:
  - `text`: literal search (`regexp-quote`)
  - `fuzzy`: subsequence pattern (`.*` between characters), heuristic rerank
  - `regex`: pass ripgrep regex with EIJIRO-aware `^`/`$` rewrites
- Options:
  - include description (`include-description`)
  - case sensitive (`case-sensitive`)
- Trigger policy:
  - current UI re-searches immediately on state change (no debounce).

## Regex Rewrite Rules (Current)

- Leading `^` in regex mode is rewritten for rg as `^■...`.
- Trailing `$` is rewritten to also match EIJIRO headword tails (`{...} :`).
- When description search is enabled, `$` also matches before `◆`.
- Query text is otherwise passed as-is (no extra Unicode normalization).

## Ranking Policy (Non-fuzzy)

Current tier order is intentional:

1. Case-sensitive exact
2. Case-insensitive normalized exact
3. Case-sensitive prefix
4. Case-sensitive contains (token boundary)
5. Case-insensitive normalized prefix
6. Case-insensitive normalized contains (token boundary)
7. Case-sensitive embedded contains
8. Case-insensitive normalized embedded contains
9. Others

Additional rules:

- Headword core normalization removes trailing `{...}` for normalized exact.
- Plain exact headword is preferred over metadata variants in ties.
- Line number is final tie-break.

`fuzzy` ordering is not fixed and may change aggressively.

## Max Results and Refinement

- `rg` runs with `--max-count eijiro-search-max-results`.
- In non-regex modes, prefix refinement/merge may run when:
  - primary hits reached max count, or
  - exact headword is missing from current primary set.
- Final display is truncated to max results again.

## Redirect / Reference Resolution

- Extracted target forms:
  - `<→...>`
  - `＝<→...>`
  - `〈英〉→...`
  - `→...`
  - `【参考】...` (split by `;` / `；`)
- `【参考】` targets are restricted to ASCII-like lexical forms:
  - `^[A-Za-z][A-Za-z0-9' -]*$`
  - Japanese-only references are not used for lookup.
  - based on dataset scan, this strict pattern covers ~99.1% of
    case-insensitive resolvable `【参考】` targets.
- Resolution is one-hop only.
- Resolved entries are inserted for display only, not merged into primary ranking.
- In one result view, each resolved entry is inserted at most once globally.
- If target already exists in primary results, do not duplicate.

## Rendering Rules

- Table columns: `Headword`, `Meaning`.
- Remove line-number column from UI.
- Multi-line expansion:
  - split on `◆` (marker hidden)
  - split on `■` (marker shown)
  - for `■・...`, suppress displayed leading `■`
- Continuation markers in headword column:
  - middle: `│`
  - last: `└`
  - face: `line-number`
- Headword cell has `help-echo` with full headword text.

## Propertization Rules

- Headword:
  - `{...}` -> `font-lock-variable-use-face`
  - `__`, `＿` -> `font-lock-variable-name-face`
- Meaning:
  - `《...》` -> `font-lock-function-name-face`
  - `［...］` -> `font-lock-comment-face`
  - `【...】` -> `font-lock-constant-face`
  - `〈...〉` -> `font-lock-type-face`
  - `〔...〕` -> `font-lock-keyword-face`
  - `<→...>` -> `font-lock-builtin-face`
  - `__`, `＿` -> `font-lock-variable-name-face`
  - `[US]`, `[UK]` are shown via `display` property as flags
- Redirect-inserted headwords use `font-lock-builtin-face`.

## Test and Fixture Policy

- Do not redistribute official EIJIRO source data in tests.
- Use synthetic/reconstructed fixtures under `test/fixtures/`.
- Current seed fixture:
  - `test/fixtures/sample-eijiro.txt`
- Run tests:
  - `emacs --batch -Q -L . -L test -l test/eijiro-search-test.el -f ert-run-tests-batch-and-exit`
