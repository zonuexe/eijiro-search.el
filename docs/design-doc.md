# eijiro-search.el Design Document

This document summarizes the current design and implementation state of `eijiro-search.el`, including decisions made during iterative refinement.

## 0. Ideal Product Vision

### 0.1 Primary Goal

Provide a practical, high-speed, interactive search UI for EIJIRO text data in Emacs, with:

- low-latency incremental lookup
- high recall (including redirects/references)
- readable rendering for dense dictionary entries
- tunable ranking that matches user intuition

### 0.2 UX Principles

- Search should feel immediate (delegate heavy scanning to `rg`).
- Result ranking should prioritize likely intent (exact/prefix/word-boundary first).
- Dense EIJIRO formatting should be visually structured (row splitting, continuation glyphs, semantic faces).
- Redirected knowledge should be visible inline, but not corrupt primary ranking semantics.

### 0.3 Current Scope

- Target dictionary: EIJIRO Ver.144.10 text (`EIJIRO144-10.TXT`) converted to UTF-8/LF.
- Emacs UI framework: [`vui.el`](https://github.com/d12frosted/vui.el).
- Search backend: `rg` only.

### 0.5 Backend Choice: Why `rg`

The current target dataset is large enough that backend choice directly affects UX:

- EIJIRO Ver.144.10 contains **2,577,796** line records.
- The UTF-8 converted text file is about **177 MB**.

For some dictionary formats, converting source data into a structured intermediate
store (custom index, DB, cache) is justified.  EIJIRO, however, is fundamentally
line-oriented and regular enough to query effectively with regex-based lookup.

Given this data shape, `rg` was chosen for the following reasons:

- It is highly optimized for scanning large plain-text files.
- It handles line-oriented matching naturally without requiring a heavy parser.
- It enables fast incremental lookup for interactive UI updates.
- It avoids explicit management of external indexes/caches in the current design.

In practice, this produced the expected low-friction responsiveness for user input
without introducing additional storage or indexing complexity.

### 0.4 Non-goals (for now)

- support for non-`rg` backends
- persistent index database
- remote/network lookup
- editable dictionary data from UI

### 0.6 Versioning / Stability Policy (Current)

Current package version is `0.0.1`.

At this stage, all behavior and specification details are considered provisional.
Any feature, ranking rule, rendering rule, or query behavior may change without
prior notice while iterating toward a stable public contract.

## 1. EIJIRO Dictionary Format Notes

Reference: <https://www.eijiro.jp/spec.htm>

### 1.1 Record Structure (line-oriented)

Typical line shape:

```text
■headword : meaning
```

Observed variants in actual data:

- headword variants with metadata suffixes: `headword  {名-1}`, `{形}`, etc.
- in-meaning separators: `◆`
- in-meaning semantic markers: `《...》`, `［...］`, `【...】`, `〈...〉`, `〔...〕`
- redirects:
  - `<→foo>`
  - `＝<→foo>`
  - `〈英〉→foo` / `→foo`
- references:
  - `【参考】foo`
  - `【参考】foo ; bar` (multi-target)

### 1.2 Encoding / Newline

Input sold data is typically Shift_JIS (CP932) + CRLF and must be converted to UTF-8 + LF before use.

### 1.3 Parsing Model Used by This App

Each matched raw line is parsed into:

- `:line-number` (source line number from `rg`)
- `:term` (headword section before ` : `)
- `:meaning` (meaning section after ` : `)
- `:raw` (trimmed source line without leading `■`)

## 2. Input Modes / Options and Regex Compilation

### 2.1 User Inputs

State fields:

- `query` (text)
- `search-mode` (`text` / `fuzzy` / `regex`)
- `include-description` (bool)
- `case-sensitive` (bool)

### 2.2 Search Modes

#### `text`

- compile via `regexp-quote(query)`
- intended as literal search

#### `fuzzy`

- candidate regex: subsequence style (`p.*r.*t.*y`) from whitespace-stripped query
- rerank with heuristic fuzzy scoring (`eijiro-search--fuzzy-score`)

#### `regex`

- pass through `rg` regex, with app-specific rewrites:
  - leading `^` -> `^■...` (line-start scoped to EIJIRO entries)
  - trailing `$` expands to support EIJIRO headword tails
  - when `include-description=t`, trailing `$` also treats `◆` boundaries as terminal points

### 2.3 Regex Compilation Targets

Two compilation targets exist to avoid regex dialect mismatch:

- `target='rg'`: PCRE-like syntax for ripgrep execution
- `target='headword'`: Emacs-regexp-compatible syntax for local headword filter

This split prevents runtime regexp errors and keeps mode semantics aligned.

### 2.4 Mode/Option Interaction

- `include-description=nil`:
  - fetch by mode
  - then apply headword-only post-filter
- `include-description=t`:
  - full-line semantics retained
  - description matching and `◆` terminal behavior enabled in regex mode

### 2.5 Design Decisions (User-Driven)

- Regex mode is EIJIRO-aware: `^`/`$` are rewritten so users can search headword-anchored patterns without manually accounting for the leading `■` and headword suffix forms.
- Regex input is treated as ripgrep regex directly.  An `rx`-based input model was tested conceptually but discarded to avoid extra conversion rules and user confusion.
- `$` behaves differently when description search is enabled.  In that mode, `◆` boundaries are also treated as terminal points so queries like `発音$` work as expected on meaning fragments.
- Pattern compilation is split by execution target (`rg` vs local headword filtering) to avoid regex-dialect mismatches and runtime errors.

### 2.6 Current Regex Compilation Behavior (Normative)

This section defines the current implementation behavior as a concrete spec.

Compilation entry point:

- function: `eijiro-search--query-pattern(query, search-mode, target, include-description)`
- `search-mode`:
  - `text` -> `regexp-quote(query)`
  - `fuzzy` -> subsequence regex from whitespace-stripped query
  - `regex` -> rewritten regex (target-dependent)

`fuzzy` compilation details:

- normalize query by removing `[[:space:]]+`
- convert each character to escaped token and join by `.*`
- examples:
  - `party` -> `p.*a.*r.*t.*y`
  - `pa ty` -> `p.*a.*t.*y`
  - empty/whitespace-only -> `.*`

`regex` compilation details for `target='rg'`:

1. Start from raw `query` string.
2. If query starts with `^`, rewrite only the first char:
   - `^foo` -> `^■foo`
3. If query ends with `$`, replace terminal `$` with EIJIRO-aware end pattern:
   - headword-only (`include-description=nil`):
     - suffix: `(?:$|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)`
   - include description (`include-description=t`):
     - suffix: `(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)`
4. Both rewrites can apply in one query.

Examples (`target='rg'`):

- `^Lisp` -> `^■Lisp`
- `lisp$` (headword-only) ->
  `lisp(?:$|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)`
- `発音$` (include-description) ->
  `発音(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)`
- `^lisp$` (include-description) ->
  `^■lisp(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)`

`regex` compilation details for `target='headword'`:

- only trailing `$` is rewritten:
  - `$` -> `\\(?:$\\|[[:space:]]*[{][^}]+[}][[:space:]]*$\\)`
- leading `^` is not rewritten for this target.

Example (`target='headword'`):

- `lisp$` -> `lisp\\(?:$\\|[[:space:]]*[{][^}]+[}][[:space:]]*$\\)`

How compiled patterns are used:

- `rg` execution always uses `target='rg'` pattern:
  - command shape:
    - `rg --no-heading --line-number --max-count <N> [-i] -e <PATTERN> -- <FILE>`
- when `include-description=nil`, local post-filter is applied on parsed headword:
  - filter pattern uses `target='headword'` compilation
  - matcher: Emacs `string-match-p` with `case-fold-search` from `case-sensitive`

Case handling:

- `case-sensitive=nil` adds `-i` to `rg`.
- local headword post-filter uses `case-fold-search=t` when `case-sensitive=nil`.
- regex text itself is not lowercased/rewritten for case; case behavior is delegated
  to `rg -i` and Emacs match flags.

### 2.7 Known Regex Edge Cases (Unresolved)

The following cases are known and intentionally left for later hardening.

- Escaped anchors:
  - input like `\\^foo` or `foo\\$` may still be interpreted by the simple
    prefix/suffix rewrite checks, because rewrite is based on string boundary
    inspection, not full regex AST parsing.
  - current policy: accepted as-is; no special escape-aware anchor analysis.

- Character-class boundary ambiguity:
  - patterns that end with class constructs near `$` (for example, complex
    grouped tails) are rewritten mechanically when the final character is `$`.
  - current policy: EIJIRO-aware suffix is appended/replaced deterministically.

- Multiline semantics:
  - EIJIRO matching is line-oriented; newline-aware regex intent is not modeled.
  - current policy: rely on `rg` default line-based behavior.

- Headword-only post-filter dialect gaps:
  - `target='headword'` uses Emacs regexp, while `target='rg'` uses `rg` regexp.
  - some advanced constructs can behave differently between the two engines.
  - current policy: keep dual-target compilation; avoid promising full dialect
    equivalence.

- Performance guardrails for pathological regex:
  - very expensive user regex patterns are not yet constrained.
  - current policy: deferred (see 5.3 TODO on regex guardrails).

- Anchor rewrite scope:
  - only leading `^` and trailing `$` are EIJIRO-aware rewritten.
  - anchors in the middle of patterns or more complex anchoring intent are not
    transformed.
  - current policy: minimal rewrite to preserve predictable behavior.

## 3. Internal Representation, Ranking, and Redirect Resolution

### 3.1 Primary Data Flow

1. Build pattern from UI state.
2. Run `rg` with max count.
3. Parse lines into entry plists.
4. Optional post-filter (headword-only mode).
5. Optional refinement merge (prefix search fallback when needed).
6. Sort/rerank.
7. Resolve redirect/references into side-map for display insertion.

### 3.2 Ranking Strategy

Ranking uses explicit tiers, then tie-breakers:

Current ranking order is part of the product specification (fixed policy):

1. Exact match (case-sensitive)
2. Exact match (case-insensitive normalized)
3. Prefix match (case-sensitive)
4. Contains match at token boundary (case-sensitive)
5. Prefix match (case-insensitive normalized)
6. Contains match at token boundary (case-insensitive normalized)
7. Contains match embedded inside token (case-sensitive)
8. Contains match embedded inside token (case-insensitive normalized)
9. Others

("boundary" means at least one side of the match is not `[[:alnum:]]`.)

Additional rules:

- headword core stripping (`{...}` suffix removed) participates in normalized exact handling
- tie-break prefers plain exact headword over metadata variants
- final fallback: source `:line-number`

### 3.3 Fuzzy Reranking

For `fuzzy` mode, score emphasizes:

- earlier start position
- contiguous matches
- smaller gaps
- token-boundary bonuses

Then uses shared rank/tiebreak fallback for stable order.

Current `fuzzy` behavior is provisional.  It is expected to evolve significantly
as more real-world query patterns are evaluated.

### 3.4 Redirect / Reference Resolution

Extract targets from meaning text:

- `<→...>` and `<→...` (lenient close bracket)
- `〈英〉→...` / bare `→...`
- `【参考】...` with `;` or `；` split

Resolution policy:

- aggregate unresolved targets
- single `rg` query with alternation `^■(a|b|c)...`
- include keys normalized both by full term and headword-core
- do not include resolved entries in primary result set
- insert resolved entry rows directly after the source row for rendering only

### 3.5 Design Decisions (User-Driven)

- The backend is intentionally `rg`-only for consistent behavior and predictable performance.
- Ranking is rule-based (exact/prefix/boundary/embedded) because raw match order and line order were repeatedly judged unintuitive.
- Metadata-suffixed headwords such as `lisp  {名-1}` are normalized by core headword to keep them near exact-intent results.
- Token-embedded matches (e.g., `alisphenoid` for `lisp`) are intentionally pushed down to reduce noise in top results.
- When result caps may hide important prefixes, an extra prefix refinement/merge step is used to recover relevant entries.
- Redirect resolution is batched: targets are aggregated and fetched with one alternation query, which is faster and avoids duplicate fetch paths.
- Redirect parsing covers real-world EIJIRO forms (`<→...>`, `＝<→...>`, arrow forms, and `【参考】... ; ...`).
- Resolved redirect entries are injected only in rendering, not merged into the primary ranked set, so search ranking remains stable and interpretable.
- Redirect lookup keys include both full headword and normalized headword-core forms to handle `{...}` variants correctly.

## 4. Table Rendering and Propertization

### 4.1 Row Expansion

Single logical entry can expand into multiple visual rows.
This is a deliberate layout strategy, not just string formatting.

#### 4.1.1 Why newline insertion alone was rejected

An early idea was to insert newline characters directly into the meaning text.
However, for records like `foo,bar◆bar`, that approach breaks table alignment:

```text
# ideal
foo | bar
    | bar

# actual with embedded newline
foo | bar
bar
```

Once a raw newline is inserted inside a cell, the second line no longer inherits
the table column offset, so it starts at column 0 and visually detaches from the row.

#### 4.1.2 Adopted approach: row-level expansion

Instead of embedding newlines, delimiters are converted into additional table rows.
This preserves column padding because each continuation line is rendered as a normal
table row with explicit headword/meaning cells.

Current split rules:

- `◆`: split point; delimiter itself is hidden
- `■`: split point; delimiter is shown, except `■・...` where leading `■` is suppressed

#### 4.1.3 Continuation visibility

Row expansion improves alignment but makes continuity less obvious.
To communicate that subsequent rows belong to the same logical record,
the headword cell receives continuation markers:

- middle continuation rows: `│`
- final continuation row: `└`

These markers use the built-in `line-number` face so they stay visible
without being visually heavy.  This gives a subtle but reliable indication
of both continuation and record termination.

### 4.2 Column Policy

- Columns: `Headword`, `Meaning`
- Headword width customizable via:
  - `eijiro-search-headword-max-width` (default `45`)
- current table setting uses `:grow t` for headword column

### 4.3 Semantic Face Mapping

Headword:

- `{...}` -> `font-lock-variable-use-face`
- `__`, `＿` -> `font-lock-variable-name-face`

Meaning:

- `《...》` -> `font-lock-function-name-face`
- `［...］` -> `font-lock-comment-face`
- `【...】` -> `font-lock-constant-face`
- `〈...〉` -> `font-lock-type-face`
- `〔...〕` -> `font-lock-keyword-face`
- `<→...>` -> `font-lock-builtin-face`
- `__`, `＿` -> `font-lock-variable-name-face`
- `[US]` / `[UK]` shown via `display` property as `🇺🇸` / `🇬🇧` (hardcoded, no generic `[]` conversion)

Redirected headword insertion rows:

- full headword styled with `font-lock-builtin-face`

### 4.4 Hover Support

Headword cells attach `help-echo` containing full original headword text.

### 4.5 Design Decisions (User-Driven)

- A custom major mode is not enabled, because it interfered with expected `vui` behavior in practice.
- The table keeps two columns (`Headword`, `Meaning`) for lexical focus; the previous line-number column was removed.
- Metadata is not split into extra columns.  Multi-row expansion was chosen instead to avoid excessive table width.
- Continuation markers (`│`, `└`) in `line-number` face improve scanability compared with blank continuation rows.
- Meaning/headword text is semantically propertized so dense marker syntax is readable at a glance.
- `[US]` and `[UK]` are rendered via `display` properties (not text replacement), preserving source text while improving visual clarity.
- Redirected insertions are visually distinguished by highlighting redirected headwords with `font-lock-builtin-face`.

## 5. Open Items / Placeholders

These are intentionally left as placeholders for later decisions.

### 5.1 Product / UX Decisions Needed

- [RESOLVED] Header naming policy: keep current `Headword` / `Meaning`.
  Rationale: no strong preference and current labels are sufficiently clear.
- [RESOLVED] Ranking policy: fixed by product intent and user validation.
  The current order is the normative behavior (see 3.2).
  Future enhancement options:
  - expose user-selectable ranking/custom variables
  - delegate part of ranking behavior to external matching/ranking ecosystems
    (for example, Orderless or Prescient-style customization models)
- [TODO] `fuzzy` behavior redesign.
  Current implementation is intentionally lightweight and may be replaced.
  Candidate direction: abbreviation/acronym-friendly matching such as
  `wysiwyg` matching "What You See Is What You Get".
  Clarification:
  - unlike non-fuzzy ranking tiers, `fuzzy` ordering is not considered fixed yet
    and may change aggressively as heuristics are improved.
- [RESOLVED] Redirect insertion visibility: always show inserted redirect rows.
  Rationale: current rendering is not considered visually noisy, so toggle/collapse
  UI is not needed for now.
- [DECIDED-PENDING-IMPLEMENTATION] Deep redirect chains: keep one-hop resolution
  for now.
  Note: recursive resolution with cycle detection is feasible and likely affordable,
  but intentionally deferred.
- [CANDIDATE] Auto-search mode from buffer/input context.
  Reference: <https://www.eijiro.jp/kensaku2/jidokensaku.htm>
  Scope idea: optional mode that automatically issues search without explicit
  submission.
  Candidate sub-modes:
  - auto-search within current `eijiro-search` input interface
  - watch mode that tracks external buffer text/point and queries from there
- [CANDIDATE] EIJIRO query expression language support.
  Reference: <https://www.eijiro.jp/kensaku2/index-ga.htm>
  Scope idea: parse and execute EIJIRO-style query operators in addition to
  current `text` / `fuzzy` / `regex` modes.
- [CANDIDATE] Structured filters by lexical metadata labels.
  Reference: <https://www.eijiro.jp/kensaku2/kensaku-option.htm>
  Scope idea: add filtering UI and query constraints for SVL, part-of-speech,
  speech level, and domain labels.
- [CANDIDATE] Partial support for EIJIRO-style "ambiguous search" behavior.
  Reference: <https://www.eijiro.jp/kensaku2/aimai0501.htm>
  Scope idea: selectively adopt compatible matching heuristics where they improve
  practical recall/precision without overcomplicating the current query model.

### 5.2 Spec Alignment Tasks

- [TODO] Verify full EIJIRO spec edge cases from the official spec page.
  This is planned as a dedicated follow-up step.
- [TODO] Enumerate unsupported marker patterns and expected fallback behavior.
  This is planned as a dedicated follow-up step.

Known gaps (already identified, not yet implemented):

- Deep redirect chain resolution:
  currently one-hop only; recursive resolution with cycle detection is deferred.
- Marker extraction coverage:
  redirect/reference extraction currently targets common forms
  (`<→...>`, arrow forms, `【参考】...`) but is not yet validated against the
  complete marker vocabulary in the official EIJIRO spec.
- Regex rewrite scope:
  regex-mode `^`/`$` rewrites are pragmatic and EIJIRO-aware, but not yet proven
  against all spec-defined headword edge cases.
- Fuzzy semantics:
  acronym/abbreviation-aware expansion is not implemented
  (e.g., `wysiwyg` -> "What You See Is What You Get").
- Rendering semantics:
  current row expansion rules (`◆`, `■`) are practical defaults; additional
  marker-specific rendering behavior may be required after full spec review.

Observed redirect graph facts (from current dataset scan):

- dataset scanned: `EIJIRO144-10.TXT` (UTF-8 conversion in this repository)
- extracted unique redirect-like edges: `350,962`
- source nodes with outgoing edges: `346,729`
- nodes with one-hop depth: `338,597`
- nodes with depth >= 2 (multi-hop present): `3,911`
- cyclic strongly connected components detected: `1,189`
- implication:
  - multi-hop and cycles are real data characteristics, not theoretical only
  - current one-hop policy is therefore a deliberate simplification

Current implementation coverage (explicitly documented):

- redirect-like extraction:
  - supported: `<→...>`, `＝<→...>`, `〈英〉→...`, `→...`, `【参考】...`
  - supported delimiter in `【参考】`: `;` and `；`
  - `【参考】` lookup target policy:
    - normalized by removing trailing parenthetical note (`（...）` / `(...)`)
    - accepted only when matching `^[A-Za-z][A-Za-z0-9' -]*$`
    - rationale from dataset scan:
      - this strict form covers about 99.1% of case-insensitive resolvable
        `【参考】` targets in current EIJIRO data
      - remaining resolvable outliers are mostly punctuation-heavy or
        non-standard forms and are intentionally excluded for now
  - not yet supported as first-class behavior: multi-hop recursive expansion,
    cycle-aware chain expansion, or marker-specific precedence rules beyond
    current regex extraction
- row expansion:
  - supported split markers: `◆`, `■`
  - supported visual suppression: `■・...` leading `■` hidden
  - not yet supported: marker-specific split policies outside `◆`/`■`
- semantic propertization:
  - supported: `《...》`, `［...］`, `【...】`, `〈...〉`, `〔...〕`, `<→...>`,
    `{...}` in headword, `__`, `＿`, and `[US]/[UK]` display substitution
  - not yet supported: comprehensive marker vocabulary validation against the
    full EIJIRO spec page

Expected fallback behavior for unsupported/unknown markers (current behavior):

- Parsing:
  - unknown marker patterns are kept as plain text in the headword/meaning
    strings; no parse error is raised.
- Ranking:
  - unknown markers do not trigger special ranking tiers.
  - ranking uses existing headword normalization and match tiers only.
- Redirect/reference expansion:
  - if a marker does not match current redirect/reference extraction regexes,
    no additional lookup is performed for that marker.
- Rendering:
  - unsupported markers are displayed literally with default cell styling
    unless they incidentally match an existing propertization rule.
  - no extra row split is performed unless the text contains `◆` or `■`.

Spec verification checklist (next step plan):

1. Build a marker inventory from the official spec page and current dataset samples.
   Done when:
   - every marker/signature from the spec is listed in a tracking table, and
   - each marker has one of `supported` / `partially-supported` / `unsupported`.

2. Map each marker to pipeline stages (`parse`, `search`, `ranking`, `redirect`,
   `render`, `propertize`) and document current behavior.
   Done when:
   - every marker row in the tracking table has stage-by-stage behavior notes, and
   - unknown/ambiguous behaviors are explicitly flagged as open decisions.

3. Define expected fallback per unsupported marker category.
   Done when:
   - fallback is written as deterministic rules (not prose only), and
   - no marker category is left with implicit behavior.

4. Validate regex rewrite edge cases (`^`, `$`) against spec-defined headword forms.
   Done when:
   - representative patterns are enumerated for headword-only and
     include-description modes, and
   - pass/fail expectations are documented for each pattern.

5. Validate redirect/reference extraction coverage against spec examples.
   Done when:
   - extraction test cases include `<→...>`, `＝<→...>`, `→...`, `〈英〉→...`,
     and `【参考】...` (single/multi target), and
   - unresolved formats are listed with proposed implementation priority.

6. Decide implementation priority and freeze scope for next milestone.
   Done when:
   - TODO items are split into `MUST` / `SHOULD` / `MAY`, and
   - a concrete implementation order is written in this document.

### 5.3 Performance / Reliability

- [TODO] Benchmark on full dataset for each mode + options matrix.
  (Explicitly deferred for future work.)
- [TODO] Guardrails for pathological regex input in `regex` mode.
  (Explicitly deferred for future work.)
- [RESOLVED] Optional cache strategy for repeated queries: not required at present.
  Rationale: current `rg` performance is already sufficiently fast, and an internal
  cache is not expected to improve practical responsiveness.

### 5.4 Testing / QA

- [TODO] add automated tests for:
  - regex rewrite behavior (`^`, `$`, include-description)
  - redirect extraction variants
  - sorting tiers and tie-breaks
  - row expansion and continuation markers
  - propertization expectations

### 5.5 Implementation Readiness Checklist

These items should be documented before broader feature expansion.

- [TODO] Expected behavior table for representative queries.
  Format:
  - input query
  - compiled `rg` pattern
  - hit condition (headword-only / include-description)
  - expected ranking order (tier-level expectation)
  Purpose:
  - provide a regression oracle for query compilation and ranking behavior.

- [TODO] Marker compatibility matrix.
  Format:
  - marker pattern
  - support level (`supported` / `partial` / `unsupported`)
  - fallback behavior
  - test case reference
  Purpose:
  - make spec alignment auditable against official EIJIRO marker definitions.

- [TODO] Performance acceptance criteria.
  Minimum requirements to define:
  - dataset assumption (EIJIRO Ver.144.10 UTF-8, ~177MB)
  - execution environment assumptions
  - target latency bands for typical queries (cold/warm)
  - max-result and option-mode impact expectations
  Purpose:
  - prevent performance regressions while adding query/features complexity.

- [TODO] Test strategy split and fixture policy.
  Scope split:
  - unit tests: pattern compilation, redirect extraction, ranking, normalization
  - snapshot/integration tests: final table rows and propertization output
  Fixture policy:
  - maintain a minimal deterministic fixture set for fast CI and precise diffs
  Purpose:
  - keep validation fast, stable, and actionable during frequent spec changes.

### 5.5.1 Expected Behavior Table (Initial Draft)

Status:
- This table is an initial baseline for regression checks.
- Because version is `0.0.1`, rows may be revised as behavior evolves.

| Mode | Include Description | Case Sensitive | Input Query | Compiled `rg` Pattern | Hit Condition | Expected Ranking Notes |
|---|---|---|---|---|---|---|
| `text` | `nil` | `nil` | `Party` | `Party` (literal via `regexp-quote`) | `rg -i` finds full lines; then headword post-filter with literal headword match | Exact/prefix/contains tiers apply; case-insensitive exact ranks above prefix/contains |
| `text` | `nil` | `t` | `Party` | `Party` (literal) | case-sensitive headword-only literal behavior | Case-sensitive exact and prefix for `Party...` rank above normalized matches |
| `text` | `t` | `nil` | `発音` | `発音` (literal) | full-line search includes meaning/description | Ranking remains headword-centric after parse; description inclusion affects recall |
| `fuzzy` | `nil` | `nil` | `party` | `p.*a.*r.*t.*y` | headword-only fuzzy candidate + fuzzy score rerank | Fuzzy score first, then shared rank/tiebreak fallback |
| `fuzzy` | `t` | `nil` | `wysiwyg` | `w.*y.*s.*i.*w.*y.*g` | full-line fuzzy target (`:raw`) | Current behavior is subsequence-only; acronym expansion is future work |
| `regex` | `nil` | `nil` | `^Lisp` | `^■Lisp` | EIJIRO headword-line anchor rewrite | Headword entries starting with `Lisp` are recalled first by rank tiers |
| `regex` | `nil` | `nil` | `lisp$` | `lisp(?:$|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)` | tail-aware rewrite to include headwords like `lisp  {名-1} : ...` | `lisp` exact should rank above metadata variants (`lisp  {..}`) |
| `regex` | `t` | `nil` | `発音$` | `発音(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)` | `$` can match before `◆` when description included | Meaning fragments ending at `◆` boundary are matched |
| `regex` | `t` | `nil` | `^lisp$` | `^■lisp(?:$|◆|[[:space:]]*(?:\\{[^}]+\\})?[[:space:]]*:)` | combined `^` + `$` rewrite for EIJIRO records | Exact `lisp` first, then normalized exact-like metadata variants |

Notes:
- Prefix refinement merge can add missing prefix entries when capped results
  hide exact/prefix-intent results.
- Redirect-resolved rows are display-only insertions and are not merged into
  the primary ranked set.

### 5.5.2 Marker Compatibility Matrix (Initial Draft)

Status:
- Initial matrix based on currently observed/implemented markers.
- Official spec-wide verification is still pending (see 5.2).

| Marker / Pattern | Stage | Support Level | Current Behavior | Fallback | Test Case Seed |
|---|---|---|---|---|---|
| `◆` | render/split | `supported` | split into continuation rows; marker hidden | if split fails, text remains literal | `発音$` meaning fragments |
| `■` (in-cell) | render/split | `supported` | split into continuation rows; marker kept | no split outside detected marker | `word,meaning■foo■bar` |
| `■・...` | render/split | `supported` | leading `■` suppressed for that segment | literal text shown if pattern not matched | entries with `■・` sub-item |
| `{...}` (headword) | rank/render | `supported` | core normalization + face on headword metadata | treated as plain text if unmatched | `lisp  {名-1}` |
| `__` / `＿` | render | `supported` | `font-lock-variable-name-face` | literal text shown | placeholders in headword/meaning |
| `<→...>` | redirect/render | `supported` | redirect target extraction + builtin face | no redirect lookup if parse miss | `chilispiked` |
| `＝<→...>` | redirect/render | `supported` | extracted via `<→...>` pattern span | no redirect lookup if parse miss | `helispherical` |
| `〈英〉→...` | redirect | `supported` | extracted as arrow redirect target | no redirect lookup if parse miss | regional redirect entries |
| `→...` | redirect | `supported` | extracted as bare arrow redirect target | no redirect lookup if parse miss | generic redirect entries |
| `【参考】foo ; bar` | redirect | `supported` | split by `;`/`；`, batch lookup | unmatched refs stay as text only | multi-reference examples |
| `《...》` | propertize | `supported` | `font-lock-function-name-face` | literal text shown | usage markers |
| `［...］` | propertize | `supported` | `font-lock-comment-face` | literal text shown | alternative gloss notes |
| `【...】` | propertize | `supported` | `font-lock-constant-face` | literal text shown | `【発音】`, `【語源】` |
| `〈...〉` | propertize | `supported` | `font-lock-type-face` | literal text shown | style/region labels |
| `〔...〕` | propertize | `supported` | `font-lock-keyword-face` | literal text shown | semantic hints |
| `[US]` / `[UK]` | propertize/display | `supported` | display property as 🇺🇸/🇬🇧 | literal `[US]/[UK]` if property unavailable | pronunciation blocks |
| other unknown markers | parse/render | `unsupported` (explicit) | no special parse/rank/render logic | keep literal text; no extra lookup | to be enumerated in 5.2 |

### 5.5.3 Performance Acceptance Criteria (Draft)

Measurement baseline:

- dataset: EIJIRO Ver.144.10 (UTF-8), approximately 177MB
- backend: local `rg` command
- max results: use current `eijiro-search-max-results`
- modes to measure: `text`, `fuzzy`, `regex`
- options matrix:
  - include-description: on/off
  - case-sensitive: on/off
- run classes:
  - cold: first query after Emacs/package load
  - warm: repeated queries in same session

Acceptance template (to be filled after benchmark):

| Scenario | Query Example | Target P50 | Target P95 | Status |
|---|---|---|---|---|
| text, headword-only, warm | `party` | TBD | TBD | TODO |
| text, include-description, warm | `発音` | TBD | TBD | TODO |
| regex with anchor rewrite, warm | `^lisp$` | TBD | TBD | TODO |
| fuzzy, headword-only, warm | `wysiwyg` | TBD | TBD | TODO |
| text, headword-only, cold | `order` | TBD | TBD | TODO |

Guardrails:

- Any change that degrades P95 beyond agreed threshold requires review.
- Benchmark method and machine profile must be recorded with results.

### 5.5.4 Test Strategy and Fixture Policy (Draft)

Test layers:

1. Unit tests (pure logic):
   - query pattern compilation (`text`/`fuzzy`/`regex`, `^`/`$` rewrites)
   - headword core normalization and ranking tiers
   - redirect target extraction (`<→...>`, `＝<→...>`, arrow forms, `【参考】`)
   - row split logic (`◆`, `■`, `■・...`)
   - propertization spans and faces (including `[US]/[UK]` display property)

2. Integration/snapshot tests:
   - input state -> parsed entries -> final table rows
   - continuation markers (`│`, `└`) placement and order
   - redirect insertion placement (display-only, non-primary ranking)

Fixture policy:

- Maintain minimal deterministic fixtures under version control.
- Do not redistribute official EIJIRO source data in fixtures.
- Use reconstructed/synthetic mini datasets for tests.
- current seed fixture: `test/fixtures/sample-eijiro.txt`
- Include at least:
  - basic exact/prefix/contains ranking fixture
  - metadata suffix fixture (`{名-1}`-style variants)
  - redirect/reference fixture (single and multi target)
  - meaning split fixture (`◆`) and headword split fixture (`■`)
  - style marker fixture (`《》`, `［］`, `【】`, `〈〉`, `〔〕`, `[US]`/`[UK]`)
- Keep fixtures small enough for fast local and CI runs.

Execution policy:

- unit tests should run on every change
- snapshot tests should run on CI and before release tagging
- when behavior intentionally changes, update snapshot and expected behavior table
  in the same change set

### 5.6 Clarifications to Freeze (Current Behavior)

This section records current behavior as-is for `0.0.1`.
It is descriptive, not a long-term guarantee.

#### 5.6.1 Search Trigger / Update Policy

- current behavior:
  - search is triggered by `vui-use-effect` on state changes
    (`query`, `search-mode`, `include-description`, `case-sensitive`)
  - effectively, query update causes immediate re-search (no debounce/wait)
- deferred option:
  - introducing input-to-search wait/debounce is a valid future optimization, but
    not required now because current responsiveness is acceptable.

#### 5.6.2 `max-results` Behavior

- `rg` is invoked with `--max-count eijiro-search-max-results`.
- primary result set may be capped by `rg`.
- non-`regex` modes can run prefix refinement when either:
  - primary `rg` hit count reached the cap, or
  - exact headword is not present in current primary set.
- refined prefix results are merged by line-number deduplication, then sorted.
- final displayed entries are truncated again to `eijiro-search-max-results`.
- guarantee level (current):
  - best-effort recovery for exact/prefix-intent under capped results
  - no guarantee of exhaustive recall beyond configured max count.

#### 5.6.3 Error Handling Contract

- dictionary file unreadable:
  - entrypoint validation raises user-facing error:
    `Dictionary file is not readable: ...`
- `rg` command missing:
  - search raises user-facing error:
    `RG is required but was not found`
- invalid regex / `rg` runtime failure:
  - non-zero status other than `1` is surfaced as:
    `<program> failed with status <code>`
  - UI catches error and renders error text in status line
- no-match case:
  - `rg` exit status `1` is treated as normal empty result (not an error).

#### 5.6.4 Redirect Insertion Order

- target extraction order follows marker scan order in each entry meaning text.
- duplicate targets are removed after aggregation.
- resolved entries are fetched in one batched `rg` lookup.
- insertion order in rendering:
  - resolved redirect rows are inserted in encounter order, but each resolved
    entry is inserted at most once globally in a result view.
- if a target is already present in the primary set, it is excluded from
  redirect lookup and therefore not duplicated.
- future multi-hop note:
  - if recursive resolution is introduced, traversal should stop on cycle
    detection and terminate silently (no dedicated cycle message).

#### 5.6.5 Normalization Scope (Current)

- query text is passed to `rg` as-is except for mode-specific compilation
  (`text` quote, `fuzzy` subsequence pattern, `regex` anchor rewrites).
- built-in normalization currently covers case only (when case-insensitive mode).
- no built-in normalization for:
  - full-width/half-width variants
  - punctuation variants
  - Unicode canonical equivalence differences
- extensibility note:
  - future customization may allow query pre-processing through hook/advice style
    extension points.

#### 5.6.6 Display Property Fallback (`[US]` / `[UK]`)

- current intent:
  - keep source text `[US]` / `[UK]` unchanged and overlay flag emoji via
    `display` text property.
- if `display` rendering is unavailable/ignored, raw `[US]` / `[UK]` remains
  visible, so semantic information is preserved.
- handling policy:
  - keep current behavior as-is.
  - no additional fallback or compatibility handling is required at this stage.
- possible environments where this can happen:
  - terminal/font setups without usable emoji glyph coverage
  - environments that do not render the specific display substitution as intended
    (display engine/font fallback differences)
  - tools/workflows that strip text properties.

#### 5.6.7 External Process Boundary

- per query, current process model is:
  - one `rg` process for primary search
  - zero or one additional `rg` for prefix refinement (non-`regex` only, conditional)
  - zero or one additional `rg` for batched redirect resolution (conditional)
- this behavior is accepted as operational baseline for current version.

#### 5.6.8 Release Gate Toward `0.1.0` (Draft Direction)

- planned milestone signal:
  - implement auto-search mode
  - then stabilize quality before version promotion.
- version promotion should be considered after:
  - behavior is judged stable in practical use
  - core regression checks from sections 5.2/5.5 are in place.

### 5.7 Additional Future Option Candidates

- [CANDIDATE] Opt-out custom variable for emoji display substitution.
  Scope idea:
  - add a custom variable to disable `[US]/[UK]` -> flag emoji `display`
    substitution for users who prefer raw tokens.

## 6. Current Constraints

- Requires local `rg` command.
- Assumes UTF-8 converted EIJIRO text file.
- UI is rendered in an Emacs text buffer via vui (not via pixel-based GUI components).

## 7. References

- EIJIRO format reference: <https://www.eijiro.jp/spec.htm>
- Package README (EN): `README.md`
- Package README (JA): `README-ja.md`
- Main implementation: `eijiro-search.el`
