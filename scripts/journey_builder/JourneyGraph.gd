class_name JourneyGraph
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyGraph — the DAG model that replaces the nested "tree" journey.
#
# A journey is a directed ACYCLIC graph of nodes:
#   { "start": <id>, "nodes": { <id>: Node, ... } }
#
#   Node = {
#     "type": "round" | "shop" | "storyboard" | "fork" | "cooldown" | "cutscene",
#     "data": Dictionary,   # item payload — the round/shop/storyboard/cooldown/cutscene
#                           #   fields, or for a fork: title/description/resolution/…
#     "out":  Array,        # outgoing edges; 0 = an end, 1 = linear, N = fork choices
#   }
#   Edge = { "to": <id>, ...fork-choice config: name/description/image_path/
#                            weight/threshold/required_item/cost }
#
# Non-fork nodes have exactly one out-edge (or zero = an end). Fork nodes have
# one out-edge per choice, each carrying that choice's resolution config. `to == ""`
# (or an empty `out`) terminates the journey.
#
# DAG-only: edges only ever point "forward" (guaranteed here by migration; enforced
# by the builder later). Pure data — no UI, no node state. Mirrors the
# ForkResolver / JourneyData / JourneyScanner split.
#
# `node.data` is shape-compatible with GameState's sequence items ({type,data}), so
# the runtime can read CurrentRound()/CurrentShop()/… straight off a node.
# ---------------------------------------------------------------------------

const FORK_TYPE := "fork"


# Migrates a scanned (nested tree) journey — JourneyScanner.parse_journey output with
# rounds[]/shops[]/storyboards[]/forks[] (forks holding nested paths) — into the graph
# model, PRESERVING current runtime behaviour exactly: each fork path's tail is wired
# to the node that followed the fork (the old implicit rejoin becomes an explicit edge,
# which authors can later rewire to skip/converge). Returns {"start", "nodes"}.
static func build_graph(journey: Dictionary) -> Dictionary:
	var nodes: Dictionary = {}
	var counter: Array = [0]  # boxed int for the id allocator
	var start: String = _flatten_level(
		journey.get("rounds", []),
		journey.get("shops", []),
		journey.get("storyboards", []),
		journey.get("forks", []),
		"",
		nodes,
		counter,
		0
	)
	return {"start": start, "nodes": nodes}


# Builds a chain of nodes for one sequence level (the top-level journey or one fork
# path), interleaving its rounds/shops/storyboards/forks by the runtime sort key. Each
# node's out-edge points to the next item; the last points to `continue_to` (the rejoin
# for a fork path, or "" / end at the top level). Forks become fork nodes whose edges
# flatten each path with `continue_to` = the node after the fork. Returns the id of the
# first node, or `continue_to` when the level is empty (an empty path goes straight on).
static func _flatten_level(
	rounds: Array,
	shops: Array,
	storyboards: Array,
	forks: Array,
	continue_to: String,
	nodes: Dictionary,
	counter: Array,
	depth: int
) -> String:
	var ordered: Array = _interleave(rounds, shops, storyboards, forks)
	if ordered.is_empty():
		return continue_to

	# Pre-allocate an id per item so each node can forward-reference the next.
	# Prefer the item's stable node_id (authored, persisted as "NodeId") so graph ids
	# survive a save — the anchor for redirect edges and Test-From-Here. A legacy item
	# with no node_id (or a stray duplicate from a corrupt save) falls back to a unique
	# positional mint, so a collision can never silently drop a node from `nodes`.
	var ids: Array = []
	var used: Dictionary = {}
	for i in ordered.size():
		var id: String = str((ordered[i]["data"] as Dictionary).get("node_id", ""))
		if id == "" or used.has(id):
			id = _next_id(counter)
			while used.has(id):
				id = _next_id(counter)
		used[id] = true
		ids.append(id)

	for i in ordered.size():
		var item: Dictionary = ordered[i]
		var id: String = ids[i]
		var next_id: String = ids[i + 1] if i + 1 < ordered.size() else continue_to
		if item["type"] == "fork":
			nodes[id] = _build_fork(item["data"], next_id, nodes, counter, depth)
		else:
			nodes[id] = {
				"type": item["type"],
				"data": item["data"],
				"out": [] if next_id == "" else [{"to": next_id}],
				"depth": depth,
			}
	return ids[0]


# Builds a fork node from a scanned fork dict. Each path's content is flattened into
# its own chain (rejoining at `rejoin`), and the path's choice/presentation config
# becomes the edge to that chain's first node (or straight to `rejoin` if empty).
static func _build_fork(
	fork: Dictionary, rejoin: String, nodes: Dictionary, counter: Array, depth: int
) -> Dictionary:
	var edges: Array = []
	for p: Dictionary in fork.get("paths", []):
		var first: String = _flatten_level(
			p.get("rounds", []),
			p.get("shops", []),
			p.get("storyboards", []),
			p.get("forks", []),
			rejoin,
			nodes,
			counter,
			depth + 1
		)
		(
			edges
			. append(
				{
					"to": first,
					"name": p.get("name", ""),
					"description": p.get("description", ""),
					"image_path": p.get("image_path", ""),
					"weight": int(p.get("weight", 1)),
					"threshold": int(p.get("threshold", 0)),
					"required_item": str(p.get("required_item", "")),
					"cost": int(p.get("cost", 0)),
				}
			)
		)
	return {
		"type": FORK_TYPE,
		"data":
		{
			"title": fork.get("title", ""),
			"description": fork.get("description", ""),
			"resolution": str(fork.get("resolution", "choice")),
			"cond_metric": str(fork.get("cond_metric", "score")),
			"default_path": int(fork.get("default_path", 0)),
			# Kept so the runtime journey-map marker can key a fork node by after_order
			# (the map still renders the legacy nested model in Phase 2; the graph map in
			# Phase 3 re-keys by node id and this can go).
			"after_order": int(fork.get("after_order", 0)),
		},
		"out": edges,
		"depth": depth,
	}


# Interleaves a level's items into runtime order. Key scheme matches GameState
# .BuildSequence: round/storyboard = order*3, shop = after_order*3+1, fork = +2.
# Stable: ties break by append index so legacy colliding-key journeys (old saves where
# a shop/fork shared a round's anchor) order deterministically. Returns [{type,data},…].
static func _interleave(rounds: Array, shops: Array, storyboards: Array, forks: Array) -> Array:
	var keyed: Array = []  # [[key, append_idx, {type, data}], ...]
	var ai: int = 0
	for r: Dictionary in rounds:
		keyed.append([int(r.get("order", 0)) * 3, ai, {"type": "round", "data": r}])
		ai += 1
	for sb: Dictionary in storyboards:
		keyed.append([int(sb.get("order", 0)) * 3, ai, {"type": "storyboard", "data": sb}])
		ai += 1
	for sh: Dictionary in shops:
		keyed.append([int(sh.get("after_order", 0)) * 3 + 1, ai, {"type": "shop", "data": sh}])
		ai += 1
	for f: Dictionary in forks:
		keyed.append([int(f.get("after_order", 0)) * 3 + 2, ai, {"type": "fork", "data": f}])
		ai += 1
	keyed.sort_custom(
		func(a: Array, b: Array) -> bool: return a[0] < b[0] if a[0] != b[0] else a[1] < b[1]
	)
	var result: Array = []
	for e in keyed:
		result.append(e[2])
	return result


static func _next_id(counter: Array) -> String:
	var id: String = "n%d" % counter[0]
	counter[0] += 1
	return id


# ── Queries ─────────────────────────────────────────────────────────────────


# The node dict for `id`, or {} for "" / a missing id (treated as an end).
static func node(graph: Dictionary, id: String) -> Dictionary:
	return (graph.get("nodes", {}) as Dictionary).get(id, {})


static func out_edges(graph: Dictionary, id: String) -> Array:
	return (node(graph, id) as Dictionary).get("out", [])


static func is_fork(graph: Dictionary, id: String) -> bool:
	return (node(graph, id) as Dictionary).get("type", "") == FORK_TYPE


# A node ends the journey when it has no outgoing edges (or it's the "" sentinel).
static func is_end(graph: Dictionary, id: String) -> bool:
	return id == "" or out_edges(graph, id).is_empty()


# The set (Dictionary-as-set) of node ids reachable from `from_id` (or journey start) following
# out-edges only. Used by Builder connect to reject true DAG cycles. Does not follow
# release_jump_to — those are intentional play-time loops back into EP islands.
static func out_reachable_ids(graph: Dictionary, from_id: String = "") -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array = [from_id if from_id != "" else str(graph.get("start", ""))]
	while not stack.is_empty():
		var id: String = str(stack.pop_back())
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		for e: Dictionary in out_edges(graph, id):
			stack.append(str(e.get("to", "")))
	return seen


# True when wiring (or keeping) out-edge source→target would close a *disallowed* cycle.
# Hub-style loops are allowed when a fork sits on the cycle (either endpoint is a fork, or
# some path target→…→source visits a fork — e.g. freeplay 006→006_5→hub→006). Pure
# round↔round (and other non-fork) cycles stay blocked. release_jump_to is irrelevant —
# only out-edges. Self-links: disallowed for non-forks (Builder also rejects source==target).
static func would_create_disallowed_cycle(
	graph: Dictionary, source: String, target: String
) -> bool:
	var nodes: Dictionary = graph.get("nodes", {})
	if source == "" or target == "" or not nodes.has(source) or not nodes.has(target):
		return false
	# No out-cycle unless target can already reach source (always true for source==target).
	if source != target and not out_reachable_ids(graph, target).has(source):
		return false
	if is_fork(graph, source) or is_fork(graph, target):
		return false
	# Round→round (etc.) inside a hub loop: allow if a return path visits a fork.
	if _path_visits_fork(graph, target, source):
		return false
	return true


# True if some simple out-path from `from_id` to `to_id` visits at least one fork node.
static func _path_visits_fork(graph: Dictionary, from_id: String, to_id: String) -> bool:
	return _path_visits_fork_dfs(graph, from_id, to_id, {}, false)


static func _path_visits_fork_dfs(
	graph: Dictionary, id: String, to_id: String, seen: Dictionary, saw_fork: bool
) -> bool:
	var saw: bool = saw_fork or is_fork(graph, id)
	if id == to_id:
		return saw
	seen[id] = true
	for e: Dictionary in out_edges(graph, id):
		var nxt: String = str(e.get("to", ""))
		if nxt == "" or not (graph.get("nodes", {}) as Dictionary).has(nxt) or seen.has(nxt):
			continue
		if _path_visits_fork_dfs(graph, nxt, to_id, seen, saw):
			seen.erase(id)
			return true
	seen.erase(id)
	return false


# The set (Dictionary-as-set) of node ids reachable from the journey start, following out-edges
# and release_jump_to targets on rounds (fail/EP side-paths are not wired as out-edges — counting
# them here keeps EP islands from looking like orphans). DAG → terminates; `seen` also backstops a
# malformed cycle. Feeds the builder's live "unreachable" warning.
static func reachable_ids(graph: Dictionary, from_id: String = "") -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array = [from_id if from_id != "" else str(graph.get("start", ""))]
	while not stack.is_empty():
		var id: String = str(stack.pop_back())
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		for e: Dictionary in out_edges(graph, id):
			stack.append(str(e.get("to", "")))
		# Release / EP jumps are runtime edges, not graph outs — still reachable in play.
		var data: Dictionary = (node(graph, id) as Dictionary).get("data", {})
		var jump: String = str(data.get("release_jump_to", "")).strip_edges()
		if jump != "":
			stack.append(jump)
	return seen


# Rewires nodes' out-edges per a redirect map {node_id: target_id} — the runtime side of
# the "skip / converge" authoring (a fork path's tail, or any node, pointing somewhere
# other than its default successor). `target_id == ""` makes the node an end. No-op on
# fork nodes (their out-edges ARE the path choices — redirect a path's tail instead).
# Applied by parse_graph after build_graph / from_json; the builder + validation own
# keeping the result a DAG (targets must point forward).
static func apply_redirects(graph: Dictionary, redirects: Dictionary) -> void:
	var nodes: Dictionary = graph.get("nodes", {})
	for from_id: String in redirects:
		if not nodes.has(from_id):
			continue
		var n: Dictionary = nodes[from_id]
		if n.get("type", "") == FORK_TYPE:
			continue
		var to_id: String = str(redirects[from_id])
		n["out"] = [] if to_id == "" else [{"to": to_id}]


# ── Validation (free-form authoring) ─────────────────────────────────────────


# Checks a graph for the invariants the runtime assumes: a real start, every edge resolving to a
# node, no *disallowed* out-edge cycles (hub loops via forks are allowed; round↔round softlocks
# are not), and which nodes are reachable. Returns a list of issues [{kind, id, to?}] — pure
# (no UI strings), so it's unit-tested and the builder formats its own user-facing messages. Kinds:
#   "no_start"    — start is empty or not a node (graph non-empty)
#   "dangling"    — node `id` has an out-edge whose target `to` is not a node
#   "cycle"       — node `id` is involved in a disallowed (non-fork-hub) out-edge cycle
#   "unreachable" — node `id` can't be reached from start (it would never play)
static func validate_graph(graph: Dictionary) -> Array:
	var issues: Array = []
	var nodes: Dictionary = graph.get("nodes", {})
	if nodes.is_empty():
		return issues  # "no rounds" is handled separately; nothing structural to check
	var start: String = str(graph.get("start", ""))
	var start_ok: bool = start != "" and nodes.has(start)
	if not start_ok:
		issues.append({"kind": "no_start", "id": start})
	# Dangling out-edges (a non-empty target that isn't a node).
	for id: String in nodes:
		for e: Dictionary in (nodes[id] as Dictionary).get("out", []):
			var to: String = str(e.get("to", ""))
			if to != "" and not nodes.has(to):
				issues.append({"kind": "dangling", "id": id, "to": to})
	# Disallowed cycles only (fork-hub loops are intentional freeplay / menu back-edges).
	for id: String in _disallowed_cycle_nodes(graph):
		issues.append({"kind": "cycle", "id": id})
	# Unreachable nodes (only meaningful with a valid start).
	if start_ok:
		var reach: Dictionary = reachable_ids(graph, start)
		for id: String in nodes:
			if not reach.has(id):
				issues.append({"kind": "unreachable", "id": id})
	return issues


# Nodes that participate in a disallowed out-edge cycle (see would_create_disallowed_cycle).
static func _disallowed_cycle_nodes(graph: Dictionary) -> Dictionary:
	var found: Dictionary = {}
	var nodes: Dictionary = graph.get("nodes", {})
	for id: String in nodes:
		for e: Dictionary in out_edges(graph, id):
			var to: String = str(e.get("to", ""))
			if to == "" or not nodes.has(to):
				continue
			if would_create_disallowed_cycle(graph, id, to):
				found[id] = true
				found[to] = true
	return found


# Longest count of `round` nodes along any path from `from_id` to an end (inclusive of
# `from_id` if it is a round). DAG-only, so the memoised DFS terminates. Feeds the
# trajectory-relative progress estimate (rounds_done + longest_round_path(current)).
static func longest_round_path(graph: Dictionary, from_id: String) -> int:
	return _longest_round_path(graph, from_id, {}, {})


# `memo` caches results; `seen` guards against a malformed (non-DAG) input so a stray
# back-edge can't spin forever. Both are owned by the public entry point above.
static func _longest_round_path(
	graph: Dictionary, from_id: String, memo: Dictionary, seen: Dictionary
) -> int:
	if from_id == "" or seen.has(from_id):
		return 0
	if memo.has(from_id):
		return memo[from_id]
	seen[from_id] = true
	var here: int = 1 if (node(graph, from_id) as Dictionary).get("type", "") == "round" else 0
	var best_rest: int = 0
	for e: Dictionary in out_edges(graph, from_id):
		best_rest = maxi(best_rest, _longest_round_path(graph, str(e.get("to", "")), memo, seen))
	seen.erase(from_id)
	var total: int = here + best_rest
	memo[from_id] = total
	return total


# ── Serialization (graph ↔ journey.json) ─────────────────────────────────────
#
# The in-memory graph is already pure JSON-shaped data, so serialization is mostly an
# envelope plus a nodes-dict ⇄ array conversion (the array keeps git diffs stable and
# the node id inline). The journey.json shape is:
#   { ...PascalCase meta..., "Format": 2, "Start": <id>, "Nodes": [ {id,type,data,out}, … ] }
#
# Paths in `data` are stored RELATIVE (authoring representation); JourneyScanner.parse_graph
# resolves them to absolute on read via resolve_paths(). to_json assumes a relative-path
# (authoring) graph — never serialize a runtime graph whose paths are already absolute.

const FORMAT_GRAPH := 2  # journey.json "Format" marker for the graph (post-tree) schema.


# Serializes the graph into the journey.json node block ({Format, Start, Nodes}). The
# caller merges journey-level meta (Name/Author/Tags/MapEnabled/…) around it.
static func to_json(graph: Dictionary) -> Dictionary:
	var nodes_arr: Array = []
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		var entry: Dictionary = {
			"id": id,
			"type": n.get("type", ""),
			"data": n.get("data", {}),
			"out": n.get("out", []),
		}
		# Editor canvas position (graph builder), stored as [x, y]. Absent for a graph that
		# was never laid out (e.g. a freshly migrated runtime graph the builder hasn't seeded).
		if n.has("pos"):
			var p: Vector2 = n["pos"]
			entry["pos"] = [p.x, p.y]
		nodes_arr.append(entry)
	return {"Format": FORMAT_GRAPH, "Start": graph.get("start", ""), "Nodes": nodes_arr}


# Rebuilds the in-memory graph from a parsed journey.json dict that carries "Nodes".
# Structural only — paths stay as stored; call resolve_paths() to make them absolute.
static func from_json(data: Dictionary) -> Dictionary:
	var nodes: Dictionary = {}
	for raw: Dictionary in data.get("Nodes", []):
		var node: Dictionary = {
			"type": str(raw.get("type", "")),
			"data": raw.get("data", {}),
			"out": raw.get("out", []),
		}
		# Restore editor canvas position when present (see to_json).
		if raw.has("pos"):
			var p: Array = raw["pos"]
			if p.size() >= 2:
				node["pos"] = Vector2(float(p[0]), float(p[1]))
		nodes[str(raw.get("id", ""))] = node
	return {"start": str(data.get("Start", "")), "nodes": nodes}


# True when a parsed journey.json is already the graph format (vs. the legacy tree).
static func is_graph_json(data: Dictionary) -> bool:
	return data.has("Nodes") or int(data.get("Format", 0)) >= FORMAT_GRAPH


# Resolves every node's stored-relative media paths to absolute (base = the journey
# folder), in place. Mirrors the field set JourneyScanner.parse_journey resolves, so a
# graph read from disk matches a migrated legacy graph (both absolute).
static func resolve_paths(graph: Dictionary, base: String) -> void:
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		match n.get("type", ""):
			"round":
				_resolve_round_paths(n.get("data", {}), base)
			"cutscene":
				var cd: Dictionary = n.get("data", {})
				cd["video_path"] = _abs(str(cd.get("video_path", "")), base)
			"storyboard":
				_resolve_storyboard_paths(n.get("data", {}), base)
			"fork":
				for e: Dictionary in n.get("out", []):
					e["image_path"] = _abs(str(e.get("image_path", "")), base)


static func _resolve_round_paths(d: Dictionary, base: String) -> void:
	d["funscript_path"] = _abs(str(d.get("funscript_path", "")), base)
	d["video_path"] = _abs(str(d.get("video_path", "")), base)
	d["boss_image"] = _abs(str(d.get("boss_image", "")), base)
	_resolve_restim_axis_scripts(d, base)
	_resolve_channels(d.get("vib_scripts", {}), base)
	# Pool round: each encounter entry carries its own media set — resolve them too (incl. a
	# boss entry's intro image).
	for entry: Dictionary in d.get("pool_entries", []):
		entry["funscript_path"] = _abs(str(entry.get("funscript_path", "")), base)
		entry["video_path"] = _abs(str(entry.get("video_path", "")), base)
		entry["boss_image"] = _abs(str(entry.get("boss_image", "")), base)
		_resolve_restim_axis_scripts(entry, base)
		_resolve_channels(entry.get("vib_scripts", {}), base)


static func _resolve_restim_axis_scripts(d: Dictionary, base: String) -> void:
	# Resolve flat axis_scripts first so coerce can merge absolute paths into shared.
	_resolve_channels(d.get("axis_scripts", {}), base)
	var raw_ras: Variant = d.get("restim_axis_scripts", {})
	if raw_ras is Dictionary:
		for slot: String in JourneyData.RESTIM_AXIS_SLOTS:
			var slot_map: Variant = (raw_ras as Dictionary).get(slot, {})
			if slot_map is Dictionary:
				_resolve_channels(slot_map as Dictionary, base)
	var ras: Dictionary = JourneyData.coerce_restim_axis_scripts(d)
	d["restim_axis_scripts"] = ras
	# Keep flat axis_scripts aligned with shared when it was empty / legacy-only.
	if (d.get("axis_scripts", {}) as Dictionary).is_empty():
		d["axis_scripts"] = (ras["shared"] as Dictionary).duplicate(true)


# Resolves every value of a {channel: rel} media map to absolute, in place.
static func _resolve_channels(channels: Dictionary, base: String) -> void:
	for k: String in channels:
		channels[k] = _abs(str(channels[k]), base)


static func _resolve_storyboard_paths(d: Dictionary, base: String) -> void:
	d["image"] = _abs(str(d.get("image", "")), base)
	for line: Dictionary in d.get("lines", []):
		line["image"] = _abs(str(line.get("image", "")), base)


# Prepends the journey base to a non-empty relative path; "" stays "".
static func _abs(rel: String, base: String) -> String:
	return (base + "/" + rel) if rel != "" else ""
