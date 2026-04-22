module [
    QueryPlan,
    PlanStep,
    ProjectItem,
    plan,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import expr.Expr exposing [Expr]
import Ast exposing [CypherQuery, NodePattern, EdgePattern, ReturnItem]

## A flat sequence of operations for the Rust executor to walk.
QueryPlan : {
    steps : List PlanStep,
    aliases : List Str,
}

## One step in a query plan.
PlanStep : [
    ScanSeeds {
        alias : Str,
        node_ids : List QuineId,
        label : [Labeled Str, Unlabeled],
        inline_props : List { key : Str, value : QuineValue },
    },
    Traverse {
        from_alias : Str,
        edge_type : [Typed Str, Untyped],
        direction : [Outgoing, Incoming, Undirected],
        to_alias : Str,
        to_label : [Labeled Str, Unlabeled],
    },
    Filter {
        predicate : Expr,
    },
    Project {
        items : List ProjectItem,
    },
]

## An item in the Project step.
ProjectItem : [
    WholeNode Str,
    NodeProperty { alias : Str, prop : Str, output_name : Str },
]

## Resolve a node alias: Named uses the name, Anon uses the fallback.
resolve_alias : [Named Str, Anon], Str -> Str
resolve_alias = |alias_tag, fallback|
    when alias_tag is
        Named(name) -> name
        Anon -> fallback

## Build Traverse steps from pattern steps, threading from_alias through.
## Returns the list of PlanSteps and collected aliases (one per hop's to_alias).
build_traversals : Str, List { edge : EdgePattern, node : NodePattern } -> { steps : List PlanStep, aliases : List Str }
build_traversals = |start_alias, pattern_steps|
    init = { steps: [], aliases: [], prev_alias: start_alias, counter: 0u64 }
    result = List.walk(pattern_steps, init, |acc, step|
        anon_name = "_anon_$(Num.to_str(acc.counter))"
        to_alias = resolve_alias(step.node.alias, anon_name)
        traverse_step = Traverse({
            from_alias: acc.prev_alias,
            edge_type: step.edge.edge_type,
            direction: step.edge.direction,
            to_alias: to_alias,
            to_label: step.node.label,
        })
        {
            steps: List.append(acc.steps, traverse_step),
            aliases: List.append(acc.aliases, to_alias),
            prev_alias: to_alias,
            counter: acc.counter + 1,
        })
    { steps: result.steps, aliases: result.aliases }

## Build a Project step from return items, validating all aliases exist.
build_project : List ReturnItem, List Str -> Result PlanStep [PlanError Str]
build_project = |return_items, known_aliases|
    List.walk_try(return_items, [], |items, ri|
        when ri is
            WholeAlias(alias) ->
                if List.contains(known_aliases, alias) then
                    Ok(List.append(items, WholeNode(alias)))
                else
                    Err(PlanError("unknown alias in RETURN: $(alias)"))

            PropAccess({ alias, prop, rename_as }) ->
                if List.contains(known_aliases, alias) then
                    output_name =
                        when rename_as is
                            As(name) -> name
                            NoAs -> "$(alias).$(prop)"
                    Ok(List.append(items, NodeProperty({ alias, prop, output_name })))
                else
                    Err(PlanError("unknown alias in RETURN: $(alias)")))
    |> Result.map_ok(|items| Project({ items }))

## Convert a CypherQuery AST + seed node IDs into a QueryPlan.
plan : CypherQuery, List QuineId -> Result QueryPlan [PlanError Str]
plan = |query, node_ids|
    start = query.pattern.start

    # Determine the start alias
    start_alias = resolve_alias(start.alias, "_start")

    # Check for seeds: need node_ids OR inline props OR a label
    has_seeds = !(List.is_empty(node_ids)) || !(List.is_empty(start.props)) || (start.label != Unlabeled)
    if !has_seeds then
        Err(PlanError("no seed nodes: provide node_ids or inline property constraints"))
    else
        # ScanSeeds step
        scan_step = ScanSeeds({
            alias: start_alias,
            node_ids: node_ids,
            label: start.label,
            inline_props: start.props,
        })

        # Traverse steps
        traversal_result = build_traversals(start_alias, query.pattern.steps)

        # Collect all aliases
        all_aliases = List.concat([start_alias], traversal_result.aliases)

        # Filter step (optional)
        filter_steps =
            when query.where_ is
                Where(expr) -> [Filter({ predicate: expr })]
                NoWhere -> []

        # Project step
        build_project(query.return_items, all_aliases)
        |> Result.map_ok(|project_step|
            steps = List.concat(
                List.concat(
                    List.concat([scan_step], traversal_result.steps),
                    filter_steps,
                ),
                [project_step],
            )
            { steps, aliases: all_aliases })

# ===== Tests =====

# Test 1: Single node query generates ScanSeeds + Project (2 steps)
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            List.len(qp.steps) == 2
        Err(_) -> Bool.false

# Test 2: No seeds + no inline props + no label -> PlanError
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Unlabeled, props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [])
    when result is
        Err(PlanError(msg)) ->
            Str.contains(msg, "no seed nodes")
        _ -> Bool.false

# Test 3: Labeled node populates label field
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ label })) ->
                    label == Labeled("Person")
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 4: Inline props captured in ScanSeeds; inline props act as seeds (no node_ids needed)
expect
    query : CypherQuery
    query = {
        pattern: {
            start: {
                alias: Named("n"),
                label: Unlabeled,
                props: [{ key: "name", value: Str("Alice") }],
            },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ inline_props })) ->
                    List.len(inline_props) == 1
                    && (
                        when List.first(inline_props) is
                            Ok({ key, value }) ->
                                key
                                == "name"
                                && (
                                    when value is
                                        Str(s) -> s == "Alice"
                                        _ -> Bool.false
                                )
                            _ -> Bool.false
                    )
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 5: Single-hop generates ScanSeeds + Traverse + Project (3 steps)
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Typed("KNOWS"), direction: Outgoing },
                    node: { alias: Named("b"), label: Unlabeled, props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            List.len(qp.steps) == 3
        Err(_) -> Bool.false

# Test 6: Multi-hop generates ScanSeeds + 2 Traverse + Project (4 steps)
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Typed("KNOWS"), direction: Outgoing },
                    node: { alias: Named("b"), label: Unlabeled, props: [] },
                },
                {
                    edge: { alias: Anon, edge_type: Typed("FOLLOWS"), direction: Outgoing },
                    node: { alias: Named("c"), label: Unlabeled, props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b"), WholeAlias("c")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            List.len(qp.steps) == 4
        Err(_) -> Bool.false

# Test 7: WHERE clause generates Filter step between traversals and project
expect
    where_expr : Expr
    where_expr = Comparison({
        left: Variable("n"),
        op: Eq,
        right: Literal(Integer(42)),
    })
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: Where(where_expr),
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            # Should be ScanSeeds, Filter, Project (3 steps)
            List.len(qp.steps)
            == 3
            && (
                when List.get(qp.steps, 1) is
                    Ok(Filter(_)) -> Bool.true
                    _ -> Bool.false
            )
        Err(_) -> Bool.false

# Test 8: PropAccess with AS rename -> output_name is the renamed name
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [PropAccess({ alias: "n", prop: "name", rename_as: As("full_name") })],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.last(qp.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ output_name })) ->
                            output_name == "full_name"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 9: PropAccess without AS -> output_name defaults to "alias.prop"
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [PropAccess({ alias: "n", prop: "age", rename_as: NoAs })],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.last(qp.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ output_name })) ->
                            output_name == "n.age"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 10: Unknown alias in RETURN -> PlanError with "unknown alias"
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("x")],
    }
    result = plan(query, [])
    when result is
        Err(PlanError(msg)) ->
            Str.contains(msg, "unknown alias")
        _ -> Bool.false

# Test 11: Aliases list contains all bound aliases in order
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Typed("KNOWS"), direction: Outgoing },
                    node: { alias: Named("b"), label: Unlabeled, props: [] },
                },
                {
                    edge: { alias: Anon, edge_type: Typed("FOLLOWS"), direction: Outgoing },
                    node: { alias: Named("c"), label: Unlabeled, props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b"), WholeAlias("c")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            qp.aliases == ["a", "b", "c"]
        Err(_) -> Bool.false

# Test 12: Anonymous start node gets "_start" alias
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Anon, label: Labeled("Person"), props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("_start")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ alias })) ->
                    alias == "_start"
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 13: Anonymous traverse node gets "_anon_N" alias
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Untyped, direction: Undirected },
                    node: { alias: Anon, label: Unlabeled, props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("_anon_0")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            qp.aliases == ["a", "_anon_0"]
        Err(_) -> Bool.false

# Test 14: Traverse threads from_alias correctly through hops
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Typed("KNOWS"), direction: Outgoing },
                    node: { alias: Named("b"), label: Unlabeled, props: [] },
                },
                {
                    edge: { alias: Anon, edge_type: Typed("FOLLOWS"), direction: Incoming },
                    node: { alias: Named("c"), label: Unlabeled, props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b"), WholeAlias("c")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            # Traverse 1: from a -> b
            first_ok =
                when List.get(qp.steps, 1) is
                    Ok(Traverse({ from_alias, to_alias, direction })) ->
                        from_alias == "a" && to_alias == "b" && direction == Outgoing
                    _ -> Bool.false
            # Traverse 2: from b -> c
            second_ok =
                when List.get(qp.steps, 2) is
                    Ok(Traverse({ from_alias, to_alias, direction })) ->
                        from_alias == "b" && to_alias == "c" && direction == Incoming
                    _ -> Bool.false
            first_ok && second_ok
        Err(_) -> Bool.false

# Test 15: Node IDs passed to ScanSeeds
expect
    id1 = QuineId.from_bytes([0x01])
    id2 = QuineId.from_bytes([0x02])
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Unlabeled, props: [] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    result = plan(query, [id1, id2])
    when result is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ node_ids })) ->
                    List.len(node_ids) == 2
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 16: Traverse edge type and to_label are captured
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("a"), label: Labeled("Person"), props: [] },
            steps: [
                {
                    edge: { alias: Anon, edge_type: Typed("WORKS_AT"), direction: Outgoing },
                    node: { alias: Named("b"), label: Labeled("Company"), props: [] },
                },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b")],
    }
    result = plan(query, [])
    when result is
        Ok(qp) ->
            when List.get(qp.steps, 1) is
                Ok(Traverse({ edge_type, to_label })) ->
                    edge_type == Typed("WORKS_AT") && to_label == Labeled("Company")
                _ -> Bool.false
        Err(_) -> Bool.false
