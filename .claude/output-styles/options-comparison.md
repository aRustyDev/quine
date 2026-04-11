---
name: Options Comparison
description: Use when presenting 2+ alternative approaches and the user needs to choose between them. Produces a dense comparison table followed by a decisive recommendation grounded in the concrete use case.
---

# Options Comparison Style

## When to use this style

Use this output format whenever you are presenting multiple options (architectural choices, API designs, library choices, data structure alternatives, implementation strategies) and the user needs enough information to pick one. Do NOT use this for yes/no questions or for single-path explanations.

## Structure

Each comparison has three parts in this order:

1. **The comparison table**
2. **The deciding factor** section
3. **Recommendation with reasoning**

## Part 1: The comparison table

Build a markdown table where:

- The first column lists **aspects** being compared — concrete, use-case-relevant qualities. Not generic ("pros/cons") — specific qualities that matter for this decision (e.g., "Storage efficiency", "Lookup perf for 'all events for node X'", "Complexity after wrapper defined").
- Subsequent columns are the options (A, B, C...) with short descriptive labels.
- Cells contain terse, direct ratings or descriptions. Use concrete terms: "O(1) outer lookup", "Best (1 hash)", "Medium — Dict overhead per outer entry". Avoid vague words like "good" alone — qualify them.
- **Bold the cell that is clearly the best for that row.** Don't bold everything. If it's a tie, don't bold anything in that row.
- Aim for 6-9 aspect rows. Fewer and the table feels thin; more and it becomes exhausting.

### Aspects to consider (pick relevant ones)

- Simplicity / complexity for the reader
- Power/capability for the dominant access pattern (name the pattern)
- Power/capability for common secondary operations
- Idiomatic-ness in the target language/ecosystem
- Storage efficiency (if memory/disk matters)
- Performance characteristics (with Big-O where applicable)
- Testability / mockability
- Maintenance burden
- Maturity / ecosystem support
- Coupling / dependency implications

Only include aspects that actually differ between options. A row where every column is "same" is noise.

## Part 2: "The deciding factor" section

This is a short prose section (2-5 sentences) after the table, titled "### The deciding factor" or similar.

It should:

- Name the **dominant access pattern** or use case that the system actually cares about
- Explain which option handles that pattern best and why, grounded in the table's data
- Be specific and concrete: use numbers, scenarios, or code paths. Not "Option A is better for performance" but "Option A makes node wake-up O(1) while B and C require scanning the entire store on every wake"
- Call out the trade-off that gets accepted by the recommendation

## Part 3: Recommendation with reasoning

After the deciding factor, give a clear recommendation:

- State the pick directly: "**Recommendation: Option X**" or similar in bold
- Give 2-4 bullet-pointed reasons grounded in the table and the deciding factor
- End with a question inviting the user to agree or push back

## Example output

When the user asks "how should events and snapshots be keyed in the in-memory store?" with three options (A: nested dicts, B: opaque composite key, C: serialized key), the response should look like this:

### Example (verbatim)

> **Comparison (ignoring cost that's the same across options):**
>
> | Aspect | A: Nested Dicts | B: Opaque composite key | C: Serialized key |
> |---|---|---|---|
> | **Simplicity** | Medium — outer+inner operations | Simple after wrapper defined | Complex — encode/decode everywhere |
> | **Power — "all events for node X"** | **O(1) outer lookup + inner scan** | O(total_events) full scan | O(total_events) full scan |
> | **Power — exact "event at (qid, time)"** | 2 lookups | **1 lookup (best)** | 1 lookup + encode |
> | **Power — "delete all for node X"** | **O(1) outer remove** | O(total) scan+filter | O(total) scan+filter |
> | **Idiomatic-ness (FP)** | **High — nested maps are standard** | Medium | Low — workaround feel |
> | **Storage efficiency** | Medium — Dict overhead per outer entry | High — flat | High — flat |
> | **Lookup/write perf (exact)** | ~same | **Best (1 hash)** | Worst (encode cost per op) |
>
> ### The deciding factor
>
> The **dominant access pattern for a persistence layer is "get all events/snapshots for node X"** — this happens every time a sleeping node wakes up. That's the hottest code path.
>
> - **A** makes this O(1) outer lookup → direct access to the inner dict → iterate its entries.
> - **B and C** both require scanning the *entire* persistence store and filtering. If you have a million events across 10k nodes, waking one node means looking at a million entries to find its ~100. That's a 10,000x overhead on the hottest operation.
>
> The "one lookup" advantage of B/C only matters for exact-time lookups, which we rarely do — even `getLatestSnapshot` finds the max time *within a node's snapshots*, which is exactly the nested pattern.
>
> **Recommendation: Option A (nested Dicts).** The access patterns strongly favor node-major layout, not key-major.
>
> Does that resolve the concern? Or do you want to think more about B given its flat simplicity?

## Principles for good comparisons

- **Ground every claim in the user's actual use case.** A comparison that ignores what the system does is worthless. Name the dominant access pattern, the critical constraint, the scaling concern — whatever actually matters.
- **Be decisive.** Don't give wishy-washy recommendations. The user is asking for help deciding; help them decide. If you genuinely think it's a tie, say so and explain what would break the tie.
- **Bold judiciously.** Only bold cells where one option is clearly the best for that aspect. Bolding everything (or nothing) defeats the visual purpose.
- **Avoid the "it depends" trap.** Every option depends on context. Your job is to apply the user's context and pick one.
- **Name what you're trading off.** Every choice sacrifices something. Make the sacrifice explicit so the user can judge whether they're willing to accept it.

## When NOT to use this style

- Single-option answers ("how do I do X") — just explain X.
- Yes/no questions — answer with reasoning, not a table.
- Questions where the "options" are actually sequential steps, not alternatives.
- Trivial choices where a sentence suffices ("should I use snake_case or camelCase?" — just answer based on project conventions, don't build a table).
