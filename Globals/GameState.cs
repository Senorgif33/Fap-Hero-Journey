using Godot;
using Godot.Collections;
using System.Collections.Generic;
using System.Linq;

public partial class GameState : Node
{
	public Dictionary Journey { get; private set; } = new Dictionary();

	private List<Dictionary> _sequence = new();
	private int _seqIndex = 0;

	// Current position in the sequence (includes fork markers before resolution).
	public int RoundIndex => _seqIndex;

	// 1-based number of the current round among round-type items only.
	public int RoundNumber => _sequence
		.Take(_seqIndex + 1)
		.Count(item => item["type"].AsString() == "round");

	public void StartJourney(Dictionary data)
	{
		Journey   = data;
		_seqIndex = 0;
		_sequence = BuildSequence(data);
	}

	private static List<Dictionary> BuildSequence(Dictionary data)
	{
		var items = new List<(int SortKey, Dictionary Data)>();

		var rounds = data.ContainsKey("rounds") ? data["rounds"].AsGodotArray() : new Array();
		foreach (var r in rounds)
		{
			var rd = r.AsGodotDictionary();
			int order = rd.ContainsKey("order") ? rd["order"].AsInt32() : 0;
			items.Add((order * 2, new Dictionary { ["type"] = "round", ["data"] = rd }));
		}

		var forks = data.ContainsKey("forks") ? data["forks"].AsGodotArray() : new Array();
		foreach (var f in forks)
		{
			var fd = f.AsGodotDictionary();
			int afterOrder = fd.ContainsKey("after_order") ? fd["after_order"].AsInt32() : 0;
			// Sort key: immediately after the round with matching order.
			items.Add((afterOrder * 2 + 1, new Dictionary { ["type"] = "fork", ["data"] = fd }));
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

		var chosen      = paths[pathIndex].AsGodotDictionary();
		var chosenRounds = chosen.ContainsKey("rounds") ? chosen["rounds"].AsGodotArray() : new Array();

		_sequence.RemoveAt(_seqIndex);
		for (int i = chosenRounds.Count - 1; i >= 0; i--)
		{
			_sequence.Insert(_seqIndex, new Dictionary
			{
				["type"] = "round",
				["data"] = chosenRounds[i].AsGodotDictionary(),
			});
		}
		// _seqIndex now points at the first round of the chosen path.
	}

	public void Advance() => _seqIndex++;

	public bool IsSequenceDone() => _seqIndex >= _sequence.Count;

	// Legacy alias — GameLoop checks this before advancing.
	public bool IsLastRound() => _seqIndex >= _sequence.Count - 1;

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

	public bool ShopAfterCurrent()
	{
		var round = CurrentRound();
		if (round.Count == 0 || !Journey.ContainsKey("shops")) return false;
		int order = round.ContainsKey("order") ? round["order"].AsInt32() : -1;
		foreach (var shop in Journey["shops"].AsGodotArray())
			if (shop.AsInt32() == order) return true;
		return false;
	}
}
