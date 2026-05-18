using Godot;
using Godot.Collections;

public partial class GameState : Node
{
	public Dictionary Journey    { get; private set; } = new Dictionary();
	public int RoundIndex { get; private set; } = 0;

	public void StartJourney(Dictionary data)
	{
		Journey    = data;
		RoundIndex = 0;
	}

	public Dictionary CurrentRound()
	{
		if (!Journey.ContainsKey("rounds")) return new Dictionary();
		var rounds = Journey["rounds"].AsGodotArray();
		if (rounds.Count == 0 || RoundIndex >= rounds.Count) return new Dictionary();
		return rounds[RoundIndex].AsGodotDictionary();
	}

	public bool IsLastRound()
	{
		if (!Journey.ContainsKey("rounds")) return true;
		return RoundIndex >= Journey["rounds"].AsGodotArray().Count - 1;
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

	public void Advance() => RoundIndex++;

	public int TotalRounds()
	{
		if (!Journey.ContainsKey("rounds")) return 0;
		return Journey["rounds"].AsGodotArray().Count;
	}
}
