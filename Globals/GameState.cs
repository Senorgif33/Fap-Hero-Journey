using Godot;
using Godot.Collections;
using System.Collections.Generic;
using System.Linq;

// Runtime journey driver. Walks the DAG produced by JourneyScanner.parse_graph
// ({start, nodes} + journey meta): the current node id advances along out-edges,
// and a fork node resolves by picking one of its edges. This replaced the old
// pre-spliced sequence + fork_end sentinel model — migrated journeys play identically.
public partial class GameState : Node
{
	// The combined dict from parse_graph: journey meta + the graph under start/nodes
	// (+ the legacy nested arrays during the Phase-2 transition, which the map/catalogue
	// still read). The runtime only touches start/nodes.
	public Dictionary Journey { get; private set; } = new Dictionary();

	private Dictionary _nodes = new Dictionary();   // id -> { type, data, out:[{to,...}] }
	private string _currentId = "";

	// Round nodes entered so far this run = the 1-based "current round number". A DAG is
	// acyclic, so each node is entered at most once — no double counting.
	private int _roundsEntered = 0;

	// Chronological play log (shape unchanged): fork_choice / round entries. "depth" is the
	// node's tree-nesting depth (stamped by build_graph), reproducing the old fork_depth so
	// the end screen indents nested forks. Author-rewired convergence (Phase 3) could make
	// depth ambiguous, but migrated tree journeys are exact.
	private List<Dictionary> _playLog = new();

	// 1-based number of the current round among round-type nodes entered so far.
	public int RoundNumber => _roundsEntered;

	public void StartJourney(Dictionary data)
	{
		Journey = data;
		_nodes = data.ContainsKey("nodes") ? data["nodes"].AsGodotDictionary() : new Dictionary();
		_currentId = data.ContainsKey("start") ? data["start"].AsString() : "";
		_roundsEntered = 0;
		_playLog.Clear();
		CountIfRound();
	}

	// ---------------------------------------------------------------------------
	// Walking
	// ---------------------------------------------------------------------------

	private Dictionary NodeOf(string id) =>
		(id != "" && _nodes.ContainsKey(id)) ? _nodes[id].AsGodotDictionary() : new Dictionary();

	private Array OutEdges(string id)
	{
		var n = NodeOf(id);
		return n.ContainsKey("out") ? n["out"].AsGodotArray() : new Array();
	}

	private string TypeOf(string id)
	{
		var n = NodeOf(id);
		return n.ContainsKey("type") ? n["type"].AsString() : "";
	}

	// Bumps the round counter when the node we just landed on is a round.
	private void CountIfRound()
	{
		if (TypeOf(_currentId) == "round")
			_roundsEntered++;
	}

	public Dictionary CurrentItem() => NodeOf(_currentId);

	// The current node's type ("round"/"shop"/"storyboard"/"fork"); "" when the journey is
	// done. Drives GameLoop's dispatch and the map keying.
	public string CurrentItemType() => TypeOf(_currentId);

	public Dictionary CurrentRound()      => DataIfType("round");
	public Dictionary CurrentShop()       => DataIfType("shop");
	public Dictionary CurrentStoryboard() => DataIfType("storyboard");

	private Dictionary DataIfType(string type)
	{
		var n = NodeOf(_currentId);
		if (n.ContainsKey("type") && n["type"].AsString() == type)
			return n["data"].AsGodotDictionary();
		return new Dictionary();
	}

	// Reconstructs the paths-shaped fork dict that ForkScreen / ForkResolver / GameLoop
	// expect, from the fork node's meta + its out-edges (one edge == one path). Empty when
	// the current node isn't a fork.
	public Dictionary CurrentFork()
	{
		var n = NodeOf(_currentId);
		if (!(n.ContainsKey("type") && n["type"].AsString() == "fork"))
			return new Dictionary();

		var data = n["data"].AsGodotDictionary();
		var paths = new Array();
		foreach (var edgeVariant in OutEdges(_currentId))
		{
			var e = edgeVariant.AsGodotDictionary();
			paths.Add(new Dictionary {
				["name"]          = e.ContainsKey("name")          ? e["name"].AsString()          : "",
				["description"]   = e.ContainsKey("description")   ? e["description"].AsString()   : "",
				["image_path"]    = e.ContainsKey("image_path")    ? e["image_path"].AsString()    : "",
				["weight"]        = e.ContainsKey("weight")        ? e["weight"].AsInt32()         : 1,
				["threshold"]     = e.ContainsKey("threshold")     ? e["threshold"].AsInt32()      : 0,
				["required_item"] = e.ContainsKey("required_item") ? e["required_item"].AsString() : "",
				["cost"]          = e.ContainsKey("cost")          ? e["cost"].AsInt32()           : 0,
			});
		}
		return new Dictionary {
			["title"]        = data.ContainsKey("title")        ? data["title"].AsString()        : "",
			["description"]  = data.ContainsKey("description")  ? data["description"].AsString()  : "",
			["resolution"]   = data.ContainsKey("resolution")  ? data["resolution"].AsString()   : "choice",
			["cond_metric"]  = data.ContainsKey("cond_metric") ? data["cond_metric"].AsString()  : "score",
			["default_path"] = data.ContainsKey("default_path")? data["default_path"].AsInt32()  : 0,
			// Carried through so GameLoop._current_map_key can key the fork's map marker.
			["after_order"]  = data.ContainsKey("after_order") ? data["after_order"].AsInt32()   : 0,
			["paths"]        = paths,
		};
	}

	// Follows the current node's single out-edge (linear/round/shop/storyboard nodes).
	// Lands on "" (done) at an end. Fork nodes are advanced via ResolveFork, not here.
	public void Advance()
	{
		var edges = OutEdges(_currentId);
		_currentId = edges.Count > 0 ? edges[0].AsGodotDictionary()["to"].AsString() : "";
		CountIfRound();
	}

	// Picks the fork's pathIndex-th out-edge and moves to its target. Out-of-range /
	// negative clamps to edge 0 (mirrors the old behaviour). No-op off a fork.
	public void ResolveFork(int pathIndex)
	{
		var n = NodeOf(_currentId);
		if (!(n.ContainsKey("type") && n["type"].AsString() == "fork"))
			return;

		var edges = OutEdges(_currentId);
		if (edges.Count == 0) { _currentId = ""; return; }
		if (pathIndex < 0 || pathIndex >= edges.Count)
			pathIndex = 0;

		var edge = edges[pathIndex].AsGodotDictionary();
		var data = n["data"].AsGodotDictionary();
		_playLog.Add(new Dictionary {
			["type"]       = "fork_choice",
			["fork_title"] = data.ContainsKey("title") ? data["title"].AsString() : "",
			["path_name"]  = edge.ContainsKey("name") ? edge["name"].AsString() : "Path " + (pathIndex + 1),
			["path_index"] = pathIndex,
			["depth"]      = n.ContainsKey("depth") ? n["depth"].AsInt32() : 0,
		});

		_currentId = edge.ContainsKey("to") ? edge["to"].AsString() : "";
		CountIfRound();
	}

	// The journey is done once the current id is the "" sentinel (or points nowhere).
	public bool IsSequenceDone() => _currentId == "" || !_nodes.ContainsKey(_currentId);

	// True when no out-edge leads to another node — i.e. the current node is a terminal
	// item, so the run should route to the end screen instead of advancing. Trailing
	// shops/storyboards still count as "more items" and keep this false (preserves the
	// old "no real items after" semantics, not a rounds-only check).
	public bool IsLastRound() =>
		!OutEdges(_currentId).Any(e => e.AsGodotDictionary()["to"].AsString() != "");

	// Trajectory-relative total: rounds entered before the current node + the longest
	// round path forward from it (DAG longest path). The denominator shifts as the player
	// picks shorter/longer forks — and the bar jumps forward on a skip.
	public int TotalRounds()
	{
		int currentIsRound = TypeOf(_currentId) == "round" ? 1 : 0;
		return (_roundsEntered - currentIsRound) + LongestRoundPath(_currentId);
	}

	// All round nodes' data (every node, not traversal-filtered). Kept for API parity;
	// no current GDScript consumer.
	public Array GetPlayedRounds()
	{
		var result = new Array();
		foreach (var keyVariant in _nodes.Keys)
		{
			var n = _nodes[keyVariant.AsString()].AsGodotDictionary();
			if (n.ContainsKey("type") && n["type"].AsString() == "round")
				result.Add(n["data"]);
		}
		return result;
	}

	// Longest count of round nodes from `fromId` to any end (inclusive of fromId if it is
	// a round). DAG → the memoised DFS terminates; `seen` backstops a malformed cycle.
	private int LongestRoundPath(string fromId) =>
		LongestRoundPathRec(fromId, new System.Collections.Generic.Dictionary<string, int>(), new HashSet<string>());

	private int LongestRoundPathRec(string id, System.Collections.Generic.Dictionary<string, int> memo, HashSet<string> seen)
	{
		if (id == "" || !_nodes.ContainsKey(id) || seen.Contains(id)) return 0;
		if (memo.TryGetValue(id, out int cached)) return cached;
		seen.Add(id);
		int here = TypeOf(id) == "round" ? 1 : 0;
		int best = 0;
		foreach (var e in OutEdges(id))
			best = System.Math.Max(best, LongestRoundPathRec(e.AsGodotDictionary()["to"].AsString(), memo, seen));
		seen.Remove(id);
		int total = here + best;
		memo[id] = total;
		return total;
	}

	// ---------------------------------------------------------------------------
	// Save / Resume
	// ---------------------------------------------------------------------------

	// GameState's slice of the save record: the current node id + rounds-entered count
	// (so the resumed run restores its progress number). CoinService / ScoreService /
	// GameLoop add their own portions.
	public Dictionary CaptureSaveData() => new Dictionary {
		["current_node"]   = _currentId,
		["rounds_entered"] = _roundsEntered,
	};

	// Restores position from a save record. New saves carry current_node; a pre-graph
	// save (sequence_index, no current_node) or a node that no longer exists (journey
	// edited) falls back to the journey start — saves are single-use and short-lived, so
	// losing position across the format change is acceptable.
	public void LoadFromSave(Dictionary journeyData, Dictionary saveData)
	{
		Journey = journeyData;
		_nodes = journeyData.ContainsKey("nodes") ? journeyData["nodes"].AsGodotDictionary() : new Dictionary();
		_playLog.Clear();

		if (saveData.ContainsKey("current_node") && _nodes.ContainsKey(saveData["current_node"].AsString()))
		{
			_currentId = saveData["current_node"].AsString();
			_roundsEntered = saveData.ContainsKey("rounds_entered") ? saveData["rounds_entered"].AsInt32() : 0;
		}
		else
		{
			_currentId = journeyData.ContainsKey("start") ? journeyData["start"].AsString() : "";
			_roundsEntered = 0;
			CountIfRound();
		}
	}

	// Called by GameLoop after each round ends (before ScoreService.EndRound).
	// roundName / lengthMs are passed explicitly from GDScript to avoid C# key-lookup
	// mismatches on the Variant dict.
	public void LogRound(Dictionary roundData, string roundName, int lengthMs)
	{
		var n = NodeOf(_currentId);
		_playLog.Add(new Dictionary {
			["type"]      = "round",
			["name"]      = roundName,
			["length_ms"] = lengthMs,
			["data"]      = roundData,
			["depth"]     = n.ContainsKey("depth") ? n["depth"].AsInt32() : 0,
		});
	}

	// Full chronological log of fork choices and rounds played (for the end screen).
	public Array GetPlayLog()
	{
		var result = new Array();
		foreach (var entry in _playLog)
			result.Add(entry);
		return result;
	}
}
