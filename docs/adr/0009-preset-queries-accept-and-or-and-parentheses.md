# 9. Preset queries accept AND, OR and parentheses

Date: 2026-09-16

## Context

[ADR 0008](0008-preset-queries-use-github-search-syntax-locally.md) left out `AND`, `OR` and parentheses
because the page it relied on,
[searching issues and pull requests](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests),
does not mention them. GitHub documents them on a different page,
[filtering and searching issues and pull requests](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/filtering-and-searching-issues-and-pull-requests):
`AND`, `OR`, a space treated as `AND`, and parentheses nested up to five levels deep.

So `assignee:@me AND (assignee:franta-dxh OR assignee:lumir-sokol)`, written straight from GitHub's own examples,
was rejected with `Unknown qualifier "(assignee"`. That is exactly what 0008 wanted to avoid: people learn the
field from GitHub's syntax, not from ours.

## Decision

`SearchQuery` parses a tree instead of a flat list of terms:

```
or    := and ("OR" and)*
and   := unary ("AND"? unary)*
unary := "(" or ")" | term
```

- **`AND` binds tighter than `OR`.** GitHub's documentation gives no precedence, but its
  [engineering post on the new search](https://github.blog/developer-skills/application-development/github-issues-search-now-supports-nested-queries-and-boolean-operators-heres-how-we-rebuilt-it/)
  shows a grammar where OR is built from AND. `label:a OR label:b label:c` is `a OR (b AND c)`.
- **Operators are `AND` and `OR` in capitals, unquoted.** `and`, `or` and `"OR"` stay plain words, so a title
  search for them still works.
- **Five levels of parentheses at most**, GitHub's limit.
- **No `NOT` and no minus in front of a group.** GitHub has neither: `NOT` is an ordinary word, `-(…)` is a
  validation error. Gitwall rejects `-(…)` with a message that tells the user to negate each term instead. The
  leading `-` on one term and the comma OR from 0008 stay.
- **A bare `@login` is an error** that suggests `assignee:login`. On GitHub it is not text either: on its own it is
  a validation error, and inside `OR` it turns the whole query into zero results, which is how
  `assignee:@me AND (assignee:franta-dxh OR @lumir-sokol)` came back empty. A quoted `"@lumir-sokol"` is text in
  both places.
- **A leading `@` on a login value is ignored**: `assignee:@octocat` reads as `assignee:octocat`, as it does on
  GitHub.

Every malformed shape has its own message under the field: an unclosed or unmatched parenthesis, an operator
without a term on one side, empty parentheses, nesting deeper than five levels.

## Checked against GitHub

On 2026-09-16, through `GET /search/issues` with `advanced_search=true`, the REST form of GitHub's advanced issue
search:

| Query | Result |
|---|---|
| `assignee:@me assignee:franta-dxh OR assignee:lumir-sokol` | 580, the same as `(… …) OR …`; `… (… OR …)` gives 5, so AND binds tighter |
| `assignee:@franta-dxh` / `assignee:franta-dxh` | 52 / 52 |
| `@lumir-sokol` | validation error; inside `OR` the query returns 0 |
| `"@lumir-sokol"` | 29, text |
| `assignee:@me assignee:franta-dxh,lumir-sokol` | 497, the same as `assignee:@me` alone: the list is ignored |
| `… or …` (lowercase) | 0, `or` is a word |
| `-(… OR …)`, `(…`, `()` | validation error |
| `((((((…))))))`, six levels | accepted, although the documentation says five |
| `assignee:@me AND` | 497, the trailing `AND` is ignored |

Gitwall keeps the documented limit of five levels and rejects a dangling `AND`/`OR`. Both are stricter than the API,
and both point at a mistake rather than guess what was meant.

## Consequences

- The paragraph on keywords and parentheses in 0008 no longer holds; the rest of 0008 does (local evaluation,
  the qualifier list, an unreadable query matching nothing).
- Queries that could only be factored with commas can now be written as GitHub writes them, and most paste
  into GitHub's issue search unchanged.
- `FilterEngine` is untouched: it still parses once per preset and asks `matches`.
- Two ways to say OR now exist, `OR` and the comma. The comma is kept because older `config.json` files use it,
  but it is Gitwall's own: GitHub ignores a comma list for `assignee:`, so the README and the examples lead with
  `OR`. 0008's claim that the factored comma form pastes into GitHub does not hold.
