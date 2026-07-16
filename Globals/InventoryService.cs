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
    [Signal] public delegate void ClearEffectsRequestedEventHandler();
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
        _registry["soft_touch"] = new Dictionary
        {
            ["id"] = "soft_touch",
            ["name"] = "Soft Touch",
            ["description"] = "Softens intensity for 30 seconds (Restim volume / linear stroke scale).",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 30000,
            ["kind"] = "volume_attenuate",
            ["factor"] = 0.5f,
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
        _registry["erosphere_amulet"] = new Dictionary
        {
            ["id"] = "erosphere_amulet",
            ["name"] = "Amulet of Sustenance",
            ["description"] = "Shaves 24 hours off an active journey cooldown. Single-use.",
            ["category"] = "modifier",
            ["price"] = 0,
            ["duration_ms"] = 0,
            ["kind"] = "shave_cooldown",
            ["shave_hours"] = 24,
        };
        _registry["erosphere_divine_summoning"] = new Dictionary
        {
            ["id"] = "erosphere_divine_summoning",
            ["name"] = "Divine Summoning",
            ["description"] = "Clears active effects on a resolvable effect round. Only usable when effects can be cleared.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 0,
            ["kind"] = "clear_effects",
        };
        _registry["erosphere_psychic_divorce"] = new Dictionary
        {
            ["id"] = "erosphere_psychic_divorce",
            ["name"] = "Psychic Divorce",
            ["description"] = "Shaves 48 hours off an active journey cooldown.",
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
            ["description"] = "Softens intensity to 30% for the rest of the round (Restim volume / linear stroke).",
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
            ["description"] = "Blackout for 30 seconds with intensity softened to 60% while the dark lasts.",
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
            ["description"] = "Ends the current round early and advances as a clean finish. Blocked on bosses and item-gated rounds.",
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

        return ids;
    }

    // Returns the data dictionary for the given item ID, or an empty dict if unknown.
    public Dictionary GetItemData(string id)
    {
        if (id != null && _registry.ContainsKey(id))
            return _registry[id].AsGodotDictionary();
        return new Dictionary();
    }

    // True when the registry entry is a modifier (unlock + pay-per-use), not a
    // utility charge (key / cleanse / save_now).
    public bool IsModifier(string id)
    {
        var data = GetItemData(id);
        if (data.Count == 0)
            return false;
        string category = data.ContainsKey("category") ? data["category"].AsString() : "modifier";
        return category == "modifier";
    }

    // ---------------------------------------------------------------------------
    // Inventory (owned utility charges) + unlocked modifiers
    // ---------------------------------------------------------------------------

    private readonly List<Dictionary> _items = new();

    // Run-scoped set of modifier ids the player has unlocked (free at shop /
    // gift). Activation spends coins via ActivateUnlocked — no inventory slot.
    // Only used when UnlockPayPerUse is true for the current journey.
    private readonly HashSet<string> _unlocked = new();

    // Journey-level shop economy. false (default) = classic buy-charge / free
    // activate; true = unlock modifiers free, pay price on ActivateUnlocked.
    public bool UnlockPayPerUse { get; private set; } = false;

    public void SetUnlockPayPerUse(bool enabled) => UnlockPayPerUse = enabled;

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
        _unlocked.Clear();
        _active.Clear();
        _bossEffects.Clear();
        UnlockPayPerUse = false;
        // Clear any stale pause state — a player can quit to menu mid-pause,
        // which would otherwise leave the effect clock frozen for the next journey.
        _paused = false;
        EmitSignal(SignalName.InventoryChanged);
        EmitSignal(SignalName.UnlockedChanged);
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // --- Inventory ----------------------------------------------------------

    public Array GetItems()
    {
        var arr = new Array();
        foreach (var item in _items)
            arr.Add(item);

        return arr;
    }

    // Adds an inventory charge. In unlock-pay-per-use mode, modifiers unlock
    // instead of stacking charges (see UnlockItem / ActivateUnlocked).
    public void AddItem(string id)
    {
        var data = GetItemData(id);
        if (data.Count == 0)
            return;

        if (UnlockPayPerUse && IsModifier(id))
        {
            UnlockItem(id);
            return;
        }

        _items.Add(data);
        EmitSignal(SignalName.InventoryChanged);
    }

    // --- Unlocks (modifiers) ------------------------------------------------

    public bool IsUnlocked(string id) => id != null && _unlocked.Contains(id);

    public Array GetUnlockedIds()
    {
        var arr = new Array();
        foreach (var id in _unlocked)
            arr.Add(id);
        return arr;
    }

    // Marks a modifier as unlocked for this run. No-op if PPU is off, unknown,
    // already unlocked, or not a modifier. Free — shop / gifts never charge.
    public bool UnlockItem(string id)
    {
        if (!UnlockPayPerUse)
            return false;
        if (id == null || id == "" || !IsModifier(id) || _unlocked.Contains(id))
            return false;

        _unlocked.Add(id);
        EmitSignal(SignalName.UnlockedChanged);
        EmitSignal(SignalName.InventoryChanged);
        return true;
    }

    // Pays registry price and starts the modifier effect. Does not consume an
    // inventory slot. Returns false if PPU is off, not unlocked, not a modifier, or broke.
    // durationOverrideMs >= 0 replaces item duration (round-scoped volume attenuate).
    // Instant kinds (clear_effects / skip_round / shave_cooldown) fire the same
    // signals as ActivateItem after the coin spend.
    public bool ActivateUnlocked(string id, int durationOverrideMs = -1)
    {
        if (!UnlockPayPerUse || !IsUnlocked(id) || !IsModifier(id))
            return false;

        var item = GetItemData(id);
        if (item.Count == 0)
            return false;

        int price = item.ContainsKey("price") ? item["price"].AsInt32() : 0;
        var coins = GetNodeOrNull<CoinService>("/root/CoinService");
        if (coins == null)
            return false;
        if (price > 0 && !coins.SpendCoins(price))
            return false;

        string itemKind = item.ContainsKey("kind") ? item["kind"].AsString() : "";
        if (itemKind == "clear_effects")
        {
            EmitSignal(SignalName.ClearEffectsRequested);
            return true;
        }
        if (itemKind == "skip_round")
        {
            EmitSignal(SignalName.SkipRoundRequested);
            return true;
        }
        if (itemKind == "shave_cooldown")
        {
            int hours = item.ContainsKey("shave_hours") ? item["shave_hours"].AsInt32() : 24;
            // Amulet is single-use once unlocked — drop the unlock after shaving.
            if (id == "erosphere_amulet")
            {
                _unlocked.Remove(id);
                EmitSignal(SignalName.UnlockedChanged);
                EmitSignal(SignalName.InventoryChanged);
            }
            EmitSignal(SignalName.ShaveCooldownRequested, hours);
            return true;
        }

        return _StartEffectFromItem(item, durationOverrideMs);
    }

    // True if the player currently holds at least one charge with this id, or
    // has unlocked it as a modifier. Used by Sacrifice forks (gating) and
    // item-Conditional forks (the ownership check).
    public bool OwnsItem(string id)
    {
        if (IsUnlocked(id))
            return true;
        foreach (var item in _items)
            if (item.ContainsKey("id") && item["id"].AsString() == id)
                return true;
        return false;
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
    // Inventory portion of the journey save record. Only owned utility charges
    // and unlocked modifier ids are persisted — active effects are deliberately
    // NOT carried across saves so the player gets a clean modifier slate on resume.

    // Captures owned utility charges for the save payload.
    public Array CaptureSaveData() => GetItems();

    // Captures unlocked modifier ids for the save payload (sibling key "unlocked").
    public Array CaptureUnlockedSaveData() => GetUnlockedIds();

    // Restores inventory from a save record. Each entry is looked up fresh in
    // _registry by ID. In PPU mode, modifier entries in old saves are migrated
    // into _unlocked; in classic mode they stay as charges. Unknown ids dropped.
    public void LoadFromSave(Array savedItems)
    {
        _items.Clear();
        _unlocked.Clear();
        foreach (var entry in savedItems)
        {
            if (entry.VariantType != Variant.Type.Dictionary)
                continue;
            var saved = entry.AsGodotDictionary();
            string id = saved.ContainsKey("id") ? saved["id"].AsString() : "";
            if (id == "" || !_registry.ContainsKey(id))
                continue;
            // PPU only: promote legacy modifier charges into the unlock set.
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

    // Restores the unlock set from a save. Only meaningful in PPU mode.
    // Missing / empty array = no unlocks (backward compatible). Unknown ids dropped.
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

    // Peek at a held charge without consuming it. Empty dict if out of range.
    public Dictionary PeekItem(int slotIndex)
    {
        if (slotIndex < 0 || slotIndex >= _items.Count)
            return new Dictionary();
        return _items[slotIndex];
    }

    // Removes the utility charge at slotIndex and starts its effect (or fires
    // SaveRequested for save_now). Modifiers should use ActivateUnlocked instead;
    // this path stays coin-free for charge-based utilities / legacy charges.
    // durationOverrideMs >= 0 replaces the item's duration_ms (round-scoped modifiers).
    public bool ActivateItem(int slotIndex, int durationOverrideMs = -1)
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
        if (itemKind == "clear_effects")
        {
            EmitSignal(SignalName.ClearEffectsRequested);
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
            _AddTimedEffect(item, displayName, "blackout", duration, roundScoped, null, null, null);
            _AddTimedEffect(item, displayName, "volume_attenuate", duration, roundScoped, softFactor, null, null);
            EmitSignal(SignalName.ActiveEffectsChanged);
            return true;
        }

        float? factor = source.ContainsKey("factor") ? source["factor"].AsSingle() : null;
        int? min = source.ContainsKey("min") ? source["min"].AsInt32() : null;
        int? max = source.ContainsKey("max") ? source["max"].AsInt32() : null;
        _AddTimedEffect(item, displayName, kind, duration, roundScoped, factor, min, max);
        EmitSignal(SignalName.ActiveEffectsChanged);
        return true;
    }

    private void _AddTimedEffect(
        Dictionary item,
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
            ["id"] = item.ContainsKey("id") ? item["id"] : "",
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

    // Picks a random modifier dict from the registry for the Wildcard item.
    // Excludes the wildcard itself and coin_jackpot — the latter's payout relies
    // on a long lifetime that the wildcard's shorter duration would cut short.
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
                || kind == "shave_cooldown" || kind == "clear_effects" || kind == "skip_round")
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
