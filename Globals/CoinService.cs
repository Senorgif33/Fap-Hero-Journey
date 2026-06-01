using Godot;

public partial class CoinService : Node
{
	[Signal] public delegate void BalanceChangedEventHandler(int balance);

	public int Balance { get; private set; } = 0;

	public void Reset()
	{
		Balance = 0;
		EmitSignal(SignalName.BalanceChanged, Balance);
	}

	public void AddCoins(int amount)
	{
		if (amount <= 0) 
			return;

		Balance += amount;
		EmitSignal(SignalName.BalanceChanged, Balance);
	}

	public bool SpendCoins(int amount)
	{
		if (amount < 0 || Balance < amount) 
			return false;

		Balance -= amount;
		EmitSignal(SignalName.BalanceChanged, Balance);

		return true;
	}

	public bool CanAfford(int amount) => Balance >= amount;

	// Used by the save/resume flow to restore a previously persisted balance.
	// Distinct from Reset() (which zeroes) and AddCoins() (which deltas).
	public void SetBalance(int amount)
	{
		Balance = amount < 0 ? 0 : amount;
		EmitSignal(SignalName.BalanceChanged, Balance);
	}
}
