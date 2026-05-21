using Godot;
using Godot.Collections;
using System.Collections.Generic;
using System.Linq;

public partial class GameState : Node
{
	public Dictionary Journey { get; private set; } = new Dictionary();

	private List<Dictionary> _sequence = new();
	private int _seqIndex = 0;

	// Chronological play log — entries are either:
	//   { "type": "fork_choice", "fork_title": string, "path_name": string, "path_index": int, "depth": int }
	//   { "type": "round",       "data": Dictionary, "depth": int }
	private List<Dictionary> _playLog = new();

	// Nesting depth of the currently-active fork path. 0 = top-level sequence.
	// Incremented each time a fork is resolved; decremented when the sequence
	// passes a fork_end sentinel (inserted at the tail of each spliced path).
	private int _forkDepth = 0;

	// Current position in the sequence (includes fork markers before resolution).
	public int RoundIndex => _seqIndex;

	// 1-based number of the current round among round-type items only.
	public int RoundNumber => _sequence
		.Take(_seqIndex + 1)
		.Count(item => item["type"].AsString() == "round");

	public void StartJourney(Dictionary data)
	{
		Journey    = data;
		_seqIndex  = 0;
		_forkDepth = 0;
		_sequence  = BuildSequence(data);
		_playLog.Clear();
	}

	private static List<Dictionary> BuildSequence(Dictionary data)
	{
		var items = new List<(int SortKey, Dictionary Data)>();

		var rounds = data.ContainsKey("rounds") ? data["rounds"].AsGodotArray() : new Array();
		foreach (var r in rounds)
		{
			var rd = r.AsGodotDictionary();
			int order = rd.ContainsKey("order") ? rd["order"].AsInt32() : 0;
			items.Add((order * 3, new Dictionary { ["type"] = "round", ["data"] = rd }));
		}

		var shops = data.ContainsKey("shops") ? data["shops"].AsGodotArray() : new Array();
		foreach (var s in shops)
		{
			Dictionary sd;
			int afterOrder;
			if (s.VariantType == Variant.Type.Dictionary)
			{
				sd = s.AsGodotDictionary();
				afterOrder = sd.ContainsKey("after_order") ? sd["after_order"].AsInt32() : 0;
			}
			else
			{
				// Legacy format: "shops": [orderNum, ...]
				afterOrder = s.AsInt32();
				sd = new Dictionary { ["after_order"] = afterOrder };
			}
			items.Add((afterOrder * 3 + 1, new Dictionary { ["type"] = "shop", ["data"] = sd }));
		}

		var storyboards = data.ContainsKey("storyboards") ? data["storyboards"].AsGodotArray() : new Array();
		foreach (var sb in storyboards)
		{
			var sbd = sb.AsGodotDictionary();
			int order = sbd.ContainsKey("order") ? sbd["order"].AsInt32() : 0;
			items.Add((order * 3, new Dictionary { ["type"] = "storyboard", ["data"] = sbd }));
		}

		var forks = data.ContainsKey("forks") ? data["forks"].AsGodotArray() : new Array();
		foreach (var f in forks)
		{
			var fd = f.AsGodotDictionary();
			int afterOrder = fd.ContainsKey("after_order") ? fd["after_order"].AsInt32() : 0;
			items.Add((afterOrder * 3 + 2, new Dictionary { ["type"] = "fork", ["data"] = fd }));
		}

		items.Sort((a, b) => a.SortKey.CompareTo(b.SortKey));
		return items.Select(i => i.Data).ToList();
	}

	public Dictionary CurrentItem()
	{
		if (_seqIndex >= _sequence.Count) return new Dictionary();
		return _sequence[_seqIndex];
	}

	public string CurrentItemType()
	{
		var item = CurrentItem();
		return item.ContainsKey("type") ? item["type"].AsString() : "round";
	}

	// Returns the current round's data dict. Empty if current item is a fork or sequence is done.
	public Dictionary CurrentRound()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "round")
			return item["data"].AsGodotDictionary();

		return new Dictionary();
	}

	// Returns the current fork's data dict. Empty if current item is a round.
	public Dictionary CurrentFork()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "fork")
			return item["data"].AsGodotDictionary();

		return new Dictionary();
	}

	// Returns the current shop's data dict. Empty if current item is not a shop.
	public Dictionary CurrentShop()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "shop")
			return item["data"].AsGodotDictionary();

		return new Dictionary();
	}

	// Returns the current storyboard's data dict. Empty if current item is not a storyboard.
	public Dictionary CurrentStoryboard()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "storyboard")
			return item["data"].AsGodotDictionary();

		return new Dictionary();
	}

	// Replaces the current fork marker with the chosen path's rounds, then leaves
	// _seqIndex pointing at the first round of the chosen path.
	public void ResolveFork(int pathIndex)
	{
		var item = CurrentItem();
		if (!item.ContainsKey("type") || item["type"].AsString() != "fork")
			return;

		var forkData = item["data"].AsGodotDictionary();
		if (!forkData.ContainsKey("paths"))
			return;

		var paths = forkData["paths"].AsGodotArray();
		if (pathIndex < 0 || pathIndex >= paths.Count)
			pathIndex = 0;

		var chosen = paths[pathIndex].AsGodotDictionary();

		// Record this choice in the play log so the end screen can show the path taken.
		// Depth is captured BEFORE incrementing so the header aligns with where the fork
		// appeared (e.g. depth 0 = top-level, depth 1 = inside another fork's path).
		_playLog.Add(new Dictionary {
			["type"]       = "fork_choice",
			["fork_title"] = forkData.ContainsKey("title") ? forkData["title"].AsString() : "",
			["path_name"]  = chosen.ContainsKey("name") ? chosen["name"].AsString() : "Path " + (pathIndex + 1),
			["path_index"] = pathIndex,
			["depth"]      = _forkDepth,
		});

		var chosenRounds = chosen.ContainsKey("rounds")  ? chosen["rounds"].AsGodotArray() : new Array();
		var chosenShops = chosen.ContainsKey("shops") ? chosen["shops"].AsGodotArray() : new Array();
		var chosenStoryboards = chosen.ContainsKey("storyboards") ? chosen["storyboards"].AsGodotArray() : new Array();
		var chosenForks = chosen.ContainsKey("forks")  ? chosen["forks"].AsGodotArray() : new Array();

		// Interleave path rounds, shops, storyboards, and nested forks by the same sort-key
		// scheme as BuildSequence so authoring order is preserved on resolution.
		var subItems = new List<(int SortKey, Dictionary Data)>();
		foreach (var chosenRound in chosenRounds)
		{
			var roundData = chosenRound.AsGodotDictionary();
			int order = roundData.ContainsKey("order") ? roundData["order"].AsInt32() : 0;
			subItems.Add((order * 3, new Dictionary { ["type"] = "round", ["data"] = roundData }));
		}
		foreach (var choseStoryboard in chosenStoryboards)
		{
			var storyboardData = choseStoryboard.AsGodotDictionary();
			int order = storyboardData.ContainsKey("order") ? storyboardData["order"].AsInt32() : 0;
			subItems.Add((order * 3, new Dictionary { ["type"] = "storyboard", ["data"] = storyboardData }));
		}
		foreach (var chosenShop in chosenShops)
		{
			var shopData = chosenShop.AsGodotDictionary();
			int afterOrder = shopData.ContainsKey("after_order") ? shopData["after_order"].AsInt32() : 0;
			subItems.Add((afterOrder * 3 + 1, new Dictionary { ["type"] = "shop", ["data"] = shopData }));
		}
		foreach (var chosenFork in chosenForks)
		{
			var chosenForkData = chosenFork.AsGodotDictionary();
			int afterOrder = chosenForkData.ContainsKey("after_order") ? chosenForkData["after_order"].AsInt32() : 0;
			subItems.Add((afterOrder * 3 + 2, new Dictionary { ["type"] = "fork", ["data"] = chosenForkData }));
		}
		subItems.Sort((a, b) => a.SortKey.CompareTo(b.SortKey));

		_sequence.RemoveAt(_seqIndex);
		for (int i = subItems.Count - 1; i >= 0; i--)
		{
			_sequence.Insert(_seqIndex, subItems[i].Data);
		}
		// Insert a fork_end sentinel right after the last item of the spliced path.
		// Advance() skips these sentinels automatically and decrements _forkDepth.
		_sequence.Insert(_seqIndex + subItems.Count, new Dictionary { ["type"] = "fork_end" });
		_forkDepth++;
		// _seqIndex now points at the first item of the chosen path.
	}

	public void Advance()
	{
		_seqIndex++;
		// Consume any fork_end sentinels, decrementing depth for each one.
		// This correctly handles back-to-back sentinel runs when nested forks end together.
		while (_seqIndex < _sequence.Count && _sequence[_seqIndex].ContainsKey("type") &&  _sequence[_seqIndex]["type"].AsString() == "fork_end")
		{
			_forkDepth = _forkDepth > 0 ? _forkDepth - 1 : 0;
			_seqIndex++;
		}
	}

	public bool IsSequenceDone() => _seqIndex >= _sequence.Count;

	// True when there are no more non-sentinel items after the current position.
	// fork_end entries are internal bookkeeping and must not be counted as real items.
	public bool IsLastRound()
	{
		for (int i = _seqIndex + 1; i < _sequence.Count; i++)
		{
			string t = _sequence[i].ContainsKey("type") ? _sequence[i]["type"].AsString() : "";
			if (t != "fork_end")
				return false;
		}
		return true;
	}

	// Count of round-type items currently in the sequence (grows after fork resolution).
	public int TotalRounds() => _sequence.Count(item => item["type"].AsString() == "round");

	public Array GetPlayedRounds()
	{
		var result = new Array();
		foreach (var item in _sequence)
		{
			if (item.ContainsKey("type") && item["type"].AsString() == "round")
				result.Add(item["data"]);
		}
		return result;
	}

	// Called by GameLoop after each round ends (before ScoreService.EndRound).
	// roundName and lengthMs are passed explicitly from GDScript (where Dictionary
	// access is known to work) to avoid C# String/StringName key-lookup mismatches.
	public void LogRound(Dictionary roundData, string roundName, int lengthMs)
	{
		_playLog.Add(new Dictionary {
			["type"]      = "round",
			["name"]      = roundName,
			["length_ms"] = lengthMs,
			["data"]      = roundData,
			["depth"]     = _forkDepth,
		});
	}

	// Returns the full chronological log of fork choices and rounds played.
	public Array GetPlayLog()
	{
		var result = new Array();
		foreach (var entry in _playLog)
			result.Add(entry);

		return result;
	}

}
