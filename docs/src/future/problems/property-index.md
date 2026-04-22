# Property Index for Cypher Query Seeds

## Problem

Cypher queries like `MATCH (n) WHERE n.name = "Alice"` need a way to find
starting nodes. Without a property index, there is no mechanism to resolve
unconstrained patterns — the only option is a full scan of every node, which
is O(N) and unacceptable at scale.

## Current MVP Constraint

The MVP planner requires callers to provide explicit `node_ids` hints via the
REST API. Queries without hints and without inline property constraints fail
with a "no seed nodes" error. This is intentional — it avoids building scan
infrastructure that would be thrown away once a real index exists.

## Future Directions

1. **Secondary property index** — maintain a reverse map from (property_key,
   property_value) to Set<QuineId>. Updated on SetProp/RemoveProp mutations.
   Stored in the persistence layer (redb). Enables ScanByProperty planner step.

2. **Label index** — special case of property index for the `__labels` key.
   Enables `MATCH (n:Person)` without hints.

3. **Full-text search** — integration with an external search index (tantivy,
   meilisearch) for CONTAINS/STARTS WITH predicates.

4. **Composite index** — multi-property index for compound WHERE clauses.

## Impact

Until a property index exists:
- All Cypher queries require `node_ids` parameter or inline `{key: value}` constraints
- No support for exploratory queries ("find all Person nodes")
- Standing queries (STANDING MATCH) are unaffected — they trigger on ingest, not query-time scans
