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
- **No `NOT` and no minus in front of a group.** GitHub documents neither; `-(…)` is a parse error that tells
  the user to negate each term instead. The leading `-` on one term and the comma OR from 0008 stay.
- **A bare `@login` is text**, as on GitHub. `@lumir-sokol` without a qualifier searches titles; it does not
  mean an assignee.
- **A leading `@` on a login value is ignored**: `assignee:@octocat` reads as `assignee:octocat`. No login can
  contain `@`, and the alternative is a query that silently matches nothing.

Every malformed shape has its own message under the field: an unclosed or unmatched parenthesis, an operator
without a term on one side, empty parentheses, nesting deeper than five levels.

## Consequences

- The paragraph on keywords and parentheses in 0008 no longer holds; the rest of 0008 does (local evaluation,
  the qualifier list, an unreadable query matching nothing).
- Queries that could only be factored with commas can now be written as GitHub writes them, and most paste
  into GitHub's issue search unchanged.
- `FilterEngine` is untouched: it still parses once per preset and asks `matches`.
- Two ways to say OR now exist, `OR` and the comma. The comma is kept because older `config.json` files use it
  and it keeps short queries short.
