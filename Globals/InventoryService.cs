using Godot;
using Godot.Collections;
using System.Collections.Generic;

public partial class InventoryService : Node
{
    [Signal] public delegate void InventoryChangedEventHandler();
    [Signal] public delegate void ActiveEffectsChangedEventHandler();
    // Fired when the run's unlocked-modifier set changes (shop unlock / gift / load).
    [Signal] public delegate void UnlockedChangedEventHandler();
    // Fired when a utility item with kind == "save_now" is activated.
    // GameLoop listens and writes a journey save in response. Separate signal
    // from ActiveEffectsChanged because save_now never enters _active.
    [Signal] public delegate void SaveRequestedEventHandler();
    // Instant utilities that need GameLoop / JourneySelect to finish the action.
    [Signal] public delegate void SkipRoundRequestedEventHandler();
    [Signal] public delegate void ShaveCooldownRequestedEventHandler(int hours);

    // ---------------------------------------------------------------------------
    // Item registry
    // Loaded from res://data/shop_items.json on startup. Edit that file to tune
    // balance without touching C#. Falls back to hardcoded defaults if the file
    // is missing or malformed.
    // ---------------------------------------------------------------------------

    // Non-static so it is populated once the node is ready (autoload order is safe).
    private Dictionary _registry = new Dictionary();

    // Author-defined, JOURNEY-scoped items — loaded from the journey's Items block each run
    // (LoadJourneyItems) and merged into lookups alongside the built-in _registry. A journey item
    // carries an "effects" bundle (a list of tuned effect dicts) instead of a single kind. Cleared
    // and repopulated per journey load, so stale items from a prior journey never leak.
    private Dictionary _journeyItems = new Dictionary();

    // Path of the JSON data file inside the project.
    private const string RegistryPath = "res://data/shop_items.json";

    public override void _Ready()
    {
        _LoadRegistry();
    }

    private void _LoadRegistry()
    {
        _registry.Clear();

        if (FileAccess.FileExists(RegistryPath))
        {
            using var registryFile = FileAccess.Open(RegistryPath, FileAccess.ModeFlags.Read);
            if (registryFile != null)
            {
                var json = new Json();
                if (json.Parse(registryFile.GetAsText()) == Error.Ok && json.Data.VariantType == Variant.Type.Array)
                {
                    foreach (var item in json.Data.AsGodotArray())
                    {
                        if (item.VariantType != Variant.Type.Dictionary)
                            continue;
                        var d = item.AsGodotDictionary();
                        var id = d.ContainsKey("id") ? d["id"].AsString() : "";
                        if (id != "")
                            _registry[id] = d;
                    }

                    GD.Print($"InventoryService: loaded {_registry.Count} items from {RegistryPath}");
                    return;
                }

                GD.PrintErr($"InventoryService: failed to parse {RegistryPath} — using hardcoded defaults.");
            }
        }
        else
        {
            GD.PrintErr($"InventoryService: {RegistryPath} not found — using hardcoded defaults.");
        }

        _LoadHardcodedDefaults();
    }

    private void _LoadHardcodedDefaults()
    {
        _registry["long_game"] = new Dictionary
        {
            ["id"] = "long_game",
            ["name"] = "The Long Game",
            ["description"] = "Expands the funscript stroke length by 20%.",
            ["category"] = "modifier",
            ["price"] = 30,
            ["duration_ms"] = 30000,
            ["kind"] = "scale",
            ["factor"] = 1.2f,
        };
        _registry["cock_lock"] = new Dictionary
        {
            ["id"] = "cock_lock",
            ["name"] = "Cock Lock",
            ["description"] = "Ignores funscript playback for 10 seconds.",
            ["category"] = "modifier",
            ["price"] = 25,
            ["duration_ms"] = 10000,
            ["kind"] = "block",
        };
        _registry["shrink_ray"] = new Dictionary
        {
            ["id"] = "shrink_ray",
            ["name"] = "Shrink Ray",
            ["description"] = "Reduces the funscript stroke length by 20%.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 30000,
            ["kind"] = "scale",
            ["factor"] = 0.8f,
        };
        _registry["final_inch"] = new Dictionary
        {
            ["id"] = "final_inch",
            ["name"] = "The Final Inch",
            ["description"] = "Confines the script to only the top 50% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 50,
            ["max"] = 100,
        };
        _registry["low_tide"] = new Dictionary
        {
            ["id"] = "low_tide",
            ["name"] = "Low Tide",
            ["description"] = "Confines the script to only the bottom 50% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 0,
            ["max"] = 50,
        };
        _registry["mirror"] = new Dictionary
        {
            ["id"] = "mirror",
            ["name"] = "Mirror",
            ["description"] = "Inverts all stroke positions for 30 seconds. Up becomes down.",
            ["category"] = "modifier",
            ["price"] = 30,
            ["duration_ms"] = 30000,
            ["kind"] = "reverse",
        };
        _registry["blackout"] = new Dictionary
        {
            ["id"] = "blackout",
            ["name"] = "Blackout",
            ["description"] = "Hides the video for 30 seconds. The device keeps going in the dark.",
            ["category"] = "modifier",
            ["price"] = 20,
            ["duration_ms"] = 30000,
            ["kind"] = "blackout",
        };
        _registry["score_rush"] = new Dictionary
        {
            ["id"] = "score_rush",
            ["name"] = "Score Rush",
            ["description"] = "Doubles score earned from every stroke for 30 seconds.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 30000,
            ["kind"] = "score_multiplier",
            ["factor"] = 2.0f,
        };
        _registry["jackpot"] = new Dictionary
        {
            ["id"] = "jackpot",
            ["name"] = "Jackpot",
            ["description"] = "Doubles the coin reward at the end of this round.",
            ["category"] = "modifier",
            ["price"] = 50,
            ["duration_ms"] = 300000,
            ["kind"] = "coin_jackpot",
            ["factor"] = 2.0f,
        };
        _registry["pleasure_band"] = new Dictionary
        {
            ["id"] = "pleasure_band",
            ["name"] = "Pleasure Band Clamp",
            ["description"] = "Confines the script to the middle 30-70% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 30,
            ["max"] = 70,
        };
        _registry["wildcard"] = new Dictionary
        {
            ["id"] = "wildcard",
            ["name"] = "Wildcard",
            ["description"] = "Activates a random modifier - could be anything. A cheap gamble.",
            ["category"] = "modifier",
            ["price"] = 20,
            ["duration_ms"] = 30000,
            ["kind"] = "wildcard",
        };
        // Utility item — saves progress at the start of the current round and
        // is consumed. Locked out during boss rounds (because the inventory
        // button itself is disabled during bosses). Doesn't apply a runtime
        // effect; GameLoop catches the SaveRequested signal and writes the
        // save file via JourneySaveService.
        _registry["safe_word"] = new Dictionary
        {
            ["id"] = "safe_word",
            ["name"] = "The Safe Word",
            ["description"] = "Saves your run at the start of the current round. One-time save — used up when you resume.",
            ["category"] = "utility",
            ["price"] = 120,
            ["duration_ms"] = 0,
            ["kind"] = "save_now",
        };
        // Key — held until spent at an item-conditional fork; not manually
        // activatable (see ActivateItem). Mirrors data/shop_items.json.
        _registry["key"] = new Dictionary
        {
            ["id"] = "key",
            ["name"] = "Key",
            ["description"] = "Opens a locked fork path. Consumed when the path is taken.",
            ["category"] = "utility",
            ["price"] = 50,
            ["duration_ms"] = 0,
            ["kind"] = "key",
        };
        // Bail Out — ends the current round for nothing. Manually activated, consumed on use.
        // Mirrors data/shop_items.json.
        _registry["skip_round"] = new Dictionary
        {
            ["id"] = "skip_round",
            ["name"] = "Bail Out",
            ["description"] = "Ends the current round immediately. It counts as played, but pays no coins, score or reward. Consumed when used.",
            ["category"] = "utility",
            ["price"] = 70,
            ["duration_ms"] = 0,
            ["kind"] = "skip_round",
        };
        // Cleanse — held until used on a cursed round; not manually activatable
        // (see ActivateItem). Mirrors data/shop_items.json.
        _registry["cleanse"] = new Dictionary
        {
            ["id"] = "cleanse",
            ["name"] = "Cleanse",
            ["description"] = "Lifts the curse on a cursed round for free. Consumed when used.",
            ["category"] = "utility",
            ["price"] = 60,
            ["duration_ms"] = 0,
            ["kind"] = "cleanse",
        };
        // Erosphere / Inferno modifiers (PPU-only items)
        _registry["erosphere_amulet"] = new Dictionary
        {
            ["id"] = "erosphere_amulet",
            ["name"] = "Amulet of Sustenance",
            ["description"] = "Removes 24 hours from an active journey cooldown. Single-use.",
            ["category"] = "modifier",
            ["price"] = 0,
            ["duration_ms"] = 0,
            ["kind"] = "shave_cooldown",
            ["shave_hours"] = 24,
        };
        _registry["erosphere_psychic_divorce"] = new Dictionary
        {
            ["id"] = "erosphere_psychic_divorce",
            ["name"] = "Psychic Divorce",
            ["description"] = "Removes 48 hours from an active journey cooldown. Pay per use.",
            ["category"] = "modifier",
            ["price"] = 60,
            ["duration_ms"] = 0,
            ["kind"] = "shave_cooldown",
            ["shave_hours"] = 48,
        };
        _registry["erosphere_feign_death"] = new Dictionary
        {
            ["id"] = "erosphere_feign_death",
            ["name"] = "Feign Death",
            ["description"] = "Softens intensity by 70% for the rest of the round. Pay per use.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 0,
            ["kind"] = "volume_attenuate",
            ["factor"] = 0.30f,
            ["round_scoped"] = true,
        };
        _registry["erosphere_blinding_light"] = new Dictionary
        {
            ["id"] = "erosphere_blinding_light",
            ["name"] = "Blinding Light",
            ["description"] = "Blackout for 30 seconds; softens intensity by 40% while the dark lasts. Pay per use.",
            ["category"] = "modifier",
            ["price"] = 60,
            ["duration_ms"] = 30000,
            ["kind"] = "blackout_soft",
            ["factor"] = 0.60f,
        };
        _registry["erosphere_time_control"] = new Dictionary
        {
            ["id"] = "erosphere_time_control",
            ["name"] = "Time Control",
            ["description"] = "Skips to the end of the round. Blocked on item-gated rounds. Pay per use.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 0,
            ["kind"] = "skip_round",
        };
    }

    // --- Registry access -------------------------------------------------------

    // Returns all registered item IDs in insertion order.
    public Array GetAllItemIds()
    {
        var ids = new Array();

        foreach (var key in _registry.Keys)
            ids.Add(key);
        foreach (var key in _journeyItems.Keys)
            ids.Add(key);

        return ids;
    }

    // Built-in registry ids only (no journey-scoped items). The BUILDER uses this: it merges these
    // with its OWN live journey-item model, so it must not also pull in _journeyItems (play-state left
    // over from a test-play — which would double-count this journey's items and leak another journey's).
    public Array GetBuiltinItemIds()
    {
        var ids = new Array();
        foreach (var key in _registry.Keys)
            ids.Add(key);
        return ids;
    }

    // Replaces the journey-scoped item set from the journey's Items block ([{id, name, description,
    // category, price, duration_ms, effects:[…]}, …]). Called on every journey load (fresh or
    // resumed), so it fully clears the previous journey's items first.
    public void LoadJourneyItems(Array items)
    {
        _journeyItems.Clear();
        foreach (var itemVar in items)
        {
            var item = itemVar.AsGodotDictionary();
            var id = item.ContainsKey("id") ? item["id"].AsString() : "";
            if (id != "")
                _journeyItems[id] = item;
        }
    }

    // Returns the data dictionary for the given item ID, or an empty dict if unknown.
    public Dictionary GetItemData(string id)
    {
        if (id != null && _registry.ContainsKey(id))
            return _registry[id].AsGodotDictionary();
        if (id != null && _journeyItems.ContainsKey(id))
            return _journeyItems[id].AsGodotDictionary();
        return new Dictionary();
    }

    // ---------------------------------------------------------------------------
    // Inventory (owned, not-yet-activated items)
    // ---------------------------------------------------------------------------

    private readonly List<Dictionary> _items = new();

    // Pay-per-use unlocked modifiers. When UnlockPayPerUse is true, buying a modifier
    // from the shop adds its id to this set (free unlock) instead of adding a charge
    // to _items. The player then spends coins each time they activate an unlocked
    // modifier via ActivateUnlocked.
    private readonly HashSet<string> _unlocked = new();

    // When true, modifier shop purchases unlock the item for repeated coin-per-use
    // activation instead of adding a one-shot charge. Set per-journey from the
    // journey's unlock_pay_per_use field.
    public bool UnlockPayPerUse { get; private set; }

    // Active effects: one entry per activation, with absolute end time on engine clock (ms).
    private readonly List<Dictionary> _active = new();

    // Boss-round forced effects. These never expire on the timer — they are added
    // when a boss round begins and removed wholesale via ClearBossEffects() when it
    // ends. GetActiveEffects() returns them alongside _active so every consumer
    // (FunscriptPlayer, ScoreService, the HUD chips) sees them transparently.
    private readonly List<Dictionary> _bossEffects = new();

    private double _nowMs = 0.0;

    // When true, the effect clock is frozen — _nowMs stops advancing so active
    // effects neither expire nor visibly count down. Driven by GameLoop while the
    // round is paused (pause button / Options overlay) so timed effects are not
    // drained while no round is playing.
    private bool _paused = false;

    // Freeze or resume the active-effect countdown. Idempotent.
    public void SetPaused(bool paused) => _paused = paused;

    public override void _Process(double delta)
    {
        if (_paused)
            return;

        _nowMs += delta * 1000.0;

        bool removed = false;
        for (int i = _active.Count - 1; i >= 0; i--)
        {
            if (_active[i]["end_time_ms"].AsDouble() <= _nowMs)
            {
                _active.RemoveAt(i);
                removed = true;
            }
        }

        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    public void Reset()
    {
        _items.Clear();
        _active.Clear();
        _bossEffects.Clear();
        _unlocked.Clear();
        UnlockPayPerUse = false;
        // Clear any stale pause state — a player can quit to menu mid-pause,
        // which would otherwise leave the effect clock frozen for the next journey.
        _paused = false;
        EmitSignal(SignalName.InventoryChanged);
        EmitSignal(SignalName.ActiveEffectsChanged);
        EmitSignal(SignalName.UnlockedChanged);
    }

    public void SetUnlockPayPerUse(bool enabled)
    {
        UnlockPayPerUse = enabled;
    }

    // --- Inventory ----------------------------------------------------------

    public Array GetItems()
    {
        var arr = new Array();
        foreach (var item in _items)
            arr.Add(item);

        return arr;
    }

    public void AddItem(string id)
    {
        var data = GetItemData(id);
        if (data.Count == 0)
            return;

        // PPU mode + modifier → unlock instead of adding a charge.
        if (UnlockPayPerUse && IsModifier(id))
        {
            UnlockItem(id);
            return;
        }

        _items.Add(data);
        EmitSignal(SignalName.InventoryChanged);
    }

    // True if the player currently holds at least one item with this id OR has it
    // unlocked (PPU). Used by Sacrifice forks (gating) and item-Conditional forks.
    public bool OwnsItem(string id)
    {
        if (UnlockPayPerUse && _unlocked.Contains(id))
            return true;
        foreach (var item in _items)
            if (item.ContainsKey("id") && item["id"].AsString() == id)
                return true;
        return false;
    }

    // --- Pay-per-use (PPU) unlocks -------------------------------------------

    // True if this item is a modifier (category == "modifier").
    public bool IsModifier(string id)
    {
        var data = GetItemData(id);
        return data.ContainsKey("category") && data["category"].AsString() == "modifier";
    }

    // True if this modifier is unlocked for the current run (PPU only).
    public bool IsUnlocked(string id) => _unlocked.Contains(id);

    // Returns all unlocked modifier IDs (PPU only).
    public Array GetUnlockedIds()
    {
        var arr = new Array();
        foreach (var id in _unlocked)
            arr.Add(id);
        return arr;
    }

    // Unlocks a modifier (PPU only, requires IsModifier). Free unlock; does not spend
    // coins. Returns true if newly unlocked (false if already unlocked / not a modifier).
    public bool UnlockItem(string id)
    {
        if (!UnlockPayPerUse || !IsModifier(id))
            return false;
        if (_unlocked.Contains(id))
            return false;
        _unlocked.Add(id);
        EmitSignal(SignalName.UnlockedChanged);
        EmitSignal(SignalName.InventoryChanged);
        return true;
    }

    // GDScript-friendly overload (optional defaults are not always exposed to GDScript).
    public bool ActivateUnlocked(string id) => ActivateUnlocked(id, -1);

    // Activates an unlocked modifier (PPU only). Spends coins (price), starts the effect.
    // durationOverrideMs >= 0 replaces the item's duration_ms (round-scoped modifiers).
    // Returns false if not unlocked, insufficient coins, or activation gated.
    public bool ActivateUnlocked(string id, int durationOverrideMs)
    {
        if (!_unlocked.Contains(id))
            return false;

        var data = GetItemData(id);
        if (data.Count == 0)
            return false;

        // Instant utilities — signal and done (no coin spend for these edge cases).
        string kind = data.ContainsKey("kind") ? data["kind"].AsString() : "";
        if (kind == "skip_round")
        {
            EmitSignal(SignalName.SkipRoundRequested);
            return true;
        }
        if (kind == "shave_cooldown")
        {
            int hours = data.ContainsKey("shave_hours") ? data["shave_hours"].AsInt32() : 24;
            EmitSignal(SignalName.ShaveCooldownRequested, hours);
            // Amulet is single-use even when unlocked — remove after activation.
            if (id == "erosphere_amulet")
            {
                _unlocked.Remove(id);
                EmitSignal(SignalName.UnlockedChanged);
            }
            return true;
        }

        // Timed effects: spend coins, then start.
        var coinService = GetNode("/root/CoinService");
        int price = data.ContainsKey("price") ? data["price"].AsInt32() : 0;
        if (price > 0)
        {
            bool spent = (bool)coinService.Call("SpendCoins", price);
            if (!spent)
                return false;
        }

        bool started = _StartEffectFromItem(data, durationOverrideMs);
        return started;
    }

    // Removes one held item with this id. Returns true if one was removed. Used
    // when a Sacrifice fork path is chosen.
    public bool ConsumeItem(string id)
    {
        for (int i = 0; i < _items.Count; i++)
        {
            if (_items[i].ContainsKey("id") && _items[i]["id"].AsString() == id)
            {
                _items.RemoveAt(i);
                EmitSignal(SignalName.InventoryChanged);
                return true;
            }
        }
        return false;
    }

    // ─── Save / Resume ────────────────────────────────────────────────────
    //
    // Inventory portion of the journey save record. Only owned (unactivated)
    // items are persisted — active effects are deliberately NOT carried
    // across saves so the player gets a clean modifier slate on resume.

    // Captures the current owned-inventory list for inclusion in the save
    // payload. Same shape GetItems() exposes; we keep a dedicated method so
    // the save callsite is explicit about intent.
    public Array CaptureSaveData() => GetItems();

    // Captures the unlocked-modifier set for PPU journeys (saved as "unlocked" array).
    public Array CaptureUnlockedSaveData() => GetUnlockedIds();

    // Restores an inventory list from a save record. Each entry is looked up
    // fresh in _registry by ID so registry edits made since the save (item
    // removed, price changed, description rewritten) take effect on resume.
    // Saved IDs that no longer exist in the registry are silently dropped.
    // In PPU mode, migrates modifier charges to the unlocked set.
    public void LoadFromSave(Array savedItems)
    {
        _items.Clear();
        foreach (var entry in savedItems)
        {
            if (entry.VariantType != Variant.Type.Dictionary)
                continue;
            var saved = entry.AsGodotDictionary();
            string id = saved.ContainsKey("id") ? saved["id"].AsString() : "";
            if (id == "")
                continue;
            if (!_registry.ContainsKey(id))
                continue;

            // PPU: migrate modifier charges → unlocked.
            if (UnlockPayPerUse && IsModifier(id))
            {
                _unlocked.Add(id);
                continue;
            }

            _items.Add(_registry[id].AsGodotDictionary());
        }
        EmitSignal(SignalName.InventoryChanged);
        EmitSignal(SignalName.UnlockedChanged);
    }

    // Loads the unlocked-modifier set from a save (PPU only). Unions with any modifiers
    // already migrated by LoadFromSave. Call this AFTER LoadFromSave + SetUnlockPayPerUse.
    public void LoadUnlockedFromSave(Array savedUnlocked)
    {
        if (!UnlockPayPerUse)
        {
            EmitSignal(SignalName.UnlockedChanged);
            EmitSignal(SignalName.InventoryChanged);
            return;
        }
        // Do not clear _unlocked first — LoadFromSave may have already migrated
        // modifier charges from the inventory array. Union the explicit list.
        if (savedUnlocked != null)
        {
            foreach (var entry in savedUnlocked)
            {
                string id = entry.AsString();
                if (id != "" && IsModifier(id))
                    _unlocked.Add(id);
            }
        }
        EmitSignal(SignalName.UnlockedChanged);
        EmitSignal(SignalName.InventoryChanged);
    }

    // GDScript-friendly overload (optional defaults are not always exposed to GDScript).
    public bool ActivateItem(int slotIndex) => ActivateItem(slotIndex, -1);

    // Removes the item at slotIndex and starts its effect timer immediately.
    // durationOverrideMs >= 0 replaces the item's duration_ms (round-scoped modifiers).
    public bool ActivateItem(int slotIndex, int durationOverrideMs)
    {
        if (slotIndex < 0 || slotIndex >= _items.Count)
            return false;

        var item = _items[slotIndex];

        // Keys and Cleanses aren't manually usable — a Key is consumed at an
        // item-conditional fork, a Cleanse via the cursed-round cleanse button.
        // Refuse activation so the player can't waste one.
        string itemKind = item.ContainsKey("kind") ? item["kind"].AsString() : "";
        if (itemKind == "key" || itemKind == "cleanse")
            return false;

        _items.RemoveAt(slotIndex);

        // Instant utilities — signal GameLoop / JourneySelect; never enter _active.
        // Boss-round lockout is enforced by the inventory UI.
        if (itemKind == "save_now")
        {
            EmitSignal(SignalName.SaveRequested);
            EmitSignal(SignalName.InventoryChanged);
            return true;
        }
        if (itemKind == "skip_round")
        {
            EmitSignal(SignalName.SkipRoundRequested);
            EmitSignal(SignalName.InventoryChanged);
            return true;
        }
        if (itemKind == "shave_cooldown")
        {
            int hours = item.ContainsKey("shave_hours") ? item["shave_hours"].AsInt32() : 24;
            EmitSignal(SignalName.ShaveCooldownRequested, hours);
            EmitSignal(SignalName.InventoryChanged);
            return true;
        }

        bool started = _StartEffectFromItem(item, durationOverrideMs);
        EmitSignal(SignalName.InventoryChanged);
        return started;
    }

    // Builds and registers a timed effect from a registry / inventory item dict.
    // Shared by ActivateItem (utility / legacy charges) and ActivateUnlocked.
    // durationOverrideMs >= 0 replaces the source duration (round-scoped modifiers).
    private bool _StartEffectFromItem(Dictionary item, int durationOverrideMs = -1)
    {
        var source = item;
        string displayName = item.ContainsKey("name") ? item["name"].AsString() : "";
        if (item.ContainsKey("kind") && item["kind"].AsString() == "wildcard")
        {
            var rolled = _RollWildcard();
            if (rolled.Count > 0)
            {
                source = rolled;
                string rolledName = rolled.ContainsKey("name") ? rolled["name"].AsString() : "";
                if (rolledName != "")
                    displayName = $"Wildcard: {rolledName}";
            }
        }

        string kind = source.ContainsKey("kind") ? source["kind"].AsString() : "";
        int duration = durationOverrideMs >= 0
            ? durationOverrideMs
            : (item.ContainsKey("duration_ms") ? item["duration_ms"].AsInt32() : 0);
        bool roundScoped = item.ContainsKey("round_scoped") && item["round_scoped"].AsBool();

        // blackout_soft: blackout + matching-duration volume_attenuate.
        if (kind == "blackout_soft")
        {
            float softFactor = source.ContainsKey("factor") ? source["factor"].AsSingle() : 0.60f;
            if (duration <= 0)
                duration = 30000;
            string itemId = item.ContainsKey("id") ? item["id"].AsString() : "";
            _AddTimedEffect(itemId, displayName, "blackout", duration, roundScoped, null, null, null);
            _AddTimedEffect(itemId, displayName, "volume_attenuate", duration, roundScoped, softFactor, null, null);
            EmitSignal(SignalName.ActiveEffectsChanged);
            return true;
        }

        string itemIdFinal = item.ContainsKey("id") ? item["id"].AsString() : "";
        // A journey item carries an "effects" bundle (several tuned effects); a built-in item is a
        // single kind. Push one active effect per effect in the bundle (all sharing the item's
        // duration), else the single kind. Consumers match on `kind`, so N entries apply independently.
        var bundle = source.ContainsKey("effects") ? source["effects"].AsGodotArray() : null;
        if (bundle != null && bundle.Count > 0)
        {
            foreach (var effVar in bundle)
                _active.Add(_MakeActiveEffect(itemIdFinal, displayName, effVar.AsGodotDictionary(), duration));
        }
        else
        {
            float? factor = source.ContainsKey("factor") ? source["factor"].AsSingle() : null;
            int? min = source.ContainsKey("min") ? source["min"].AsInt32() : null;
            int? max = source.ContainsKey("max") ? source["max"].AsInt32() : null;
            _AddTimedEffect(itemIdFinal, displayName, kind, duration, roundScoped, factor, min, max);
        }

        EmitSignal(SignalName.ActiveEffectsChanged);
        return true;
    }

    private void _AddTimedEffect(
        string itemId,
        string displayName,
        string kind,
        int duration,
        bool roundScoped,
        float? factor,
        int? min,
        int? max)
    {
        var effect = new Dictionary
        {
            ["id"] = itemId,
            ["name"] = displayName,
            ["kind"] = kind,
            ["duration_ms"] = duration,
            ["end_time_ms"] = _nowMs + duration,
            ["start_time_ms"] = _nowMs,
        };
        if (roundScoped)
            effect["round_scoped"] = true;
        if (factor.HasValue) effect["factor"] = factor.Value;
        if (min.HasValue) effect["min"] = min.Value;
        if (max.HasValue) effect["max"] = max.Value;
        _active.Add(effect);
    }

    // Builds one active-effect entry from an effect source (a built-in item or a bundle effect): the
    // timing fields plus every tuning param (factor/min/max/…) carried through generically, so any
    // kind's params reach the consumers. Meta keys (name/price/category/…) are skipped.
    private Dictionary _MakeActiveEffect(string id, string name, Dictionary src, int duration)
    {
        string kind = src.ContainsKey("kind") ? src["kind"].AsString() : "";
        // coin_jackpot / coin_penalty are settled at the NEXT round end (GameLoop reads and then
        // consumes them there), NOT on a wall clock. They must outlast the item's timer — a short
        // bundle duration (default 30s) would otherwise drop the coin effect before the round paid
        // out, so nothing applied. They persist until consumed; every other kind stays timed.
        bool persistToRoundEnd = kind == "coin_jackpot" || kind == "coin_penalty";
        var effect = new Dictionary
        {
            ["id"] = id,
            ["name"] = name,
            ["kind"] = src.ContainsKey("kind") ? src["kind"] : "",
            ["duration_ms"] = duration,
            ["end_time_ms"] = persistToRoundEnd ? double.MaxValue : _nowMs + duration,
            ["start_time_ms"] = _nowMs,
        };
        foreach (var k in src.Keys)
        {
            var ks = k.AsString();
            if (ks != "kind" && ks != "name" && ks != "desc" && ks != "description"
                && ks != "id" && ks != "duration_ms" && ks != "price"
                && ks != "category" && ks != "image" && ks != "effects")
                effect[ks] = src[k];
        }
        return effect;
    }

    // Picks a random modifier dict from the registry for the Wildcard item.
    // Excludes the wildcard itself, utilities, and compound effects that wouldn't
    // work properly with wildcard's timing.
    private Dictionary _RollWildcard()
    {
        var pool = new List<Dictionary>();
        foreach (var key in _registry.Keys)
        {
            var d = _registry[key].AsGodotDictionary();
            string kind = d.ContainsKey("kind") ? d["kind"].AsString() : "";
            // Stroke / sensory modifiers only — skip utilities and compound items.
            if (kind == "" || kind == "wildcard" || kind == "coin_jackpot")
                continue;
            if (kind == "save_now" || kind == "key" || kind == "cleanse"
                || kind == "shave_cooldown" || kind == "skip_round")
                continue;
            pool.Add(d);
        }
        if (pool.Count == 0)
            return new Dictionary();
        return pool[(int)(GD.Randi() % (uint)pool.Count)];
    }

    // --- Active effects -------------------------------------------------------

    public Array GetActiveEffects()
    {
        var activeEffects = new Array();
        foreach (var fx in _active)
            activeEffects.Add(fx);
        foreach (var fx in _bossEffects)
            activeEffects.Add(fx);

        return activeEffects;
    }

    // Clears player-activated effects only — leaves boss effects and owned
    // inventory items untouched. Used to give a boss round a clean slate.
    public void ClearActiveEffects()
    {
        if (_active.Count == 0)
            return;
        _active.Clear();
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Drops effects tagged round_scoped at round transition so rest-of-round
    // attenuations cannot leak into the next node.
    public void ClearRoundScopedEffects()
    {
        bool removed = false;
        for (int i = _active.Count - 1; i >= 0; i--)
        {
            if (_active[i].ContainsKey("round_scoped") && _active[i]["round_scoped"].AsBool())
            {
                _active.RemoveAt(i);
                removed = true;
            }
        }
        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Installs a set of boss-round forced effects. Each entry must be a complete
    // effect dictionary (kind + params + display name). They apply for the whole
    // boss round and are removed with ClearBossEffects().
    public void AddBossEffects(Array effects)
    {
        foreach (var fx in effects)
        {
            if (fx.VariantType == Variant.Type.Dictionary)
                _bossEffects.Add(fx.AsGodotDictionary());
        }
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Removes all boss-round forced effects. Called when a boss round ends.
    public void ClearBossEffects()
    {
        if (_bossEffects.Count == 0)
            return;
        _bossEffects.Clear();
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Immediately removes every active effect of the given kind. Used by GameLoop
    // to consume coin_jackpot effects right after they pay out, so a single
    // jackpot only ever doubles one round's reward.
    public void ConsumeEffects(string kind)
    {
        bool removed = false;
        for (int i = _active.Count - 1; i >= 0; i--)
        {
            if (_active[i].ContainsKey("kind") && _active[i]["kind"].AsString() == kind)
            {
                _active.RemoveAt(i);
                removed = true;
            }
        }

        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Remaining seconds for the chip countdown text. Returns 0 if expired.
    public double GetRemainingSeconds(Dictionary effect)
    {
        double end = effect.ContainsKey("end_time_ms") ? effect["end_time_ms"].AsDouble() : 0.0;
        return System.Math.Max(0.0, (end - _nowMs) / 1000.0);
    }
}
