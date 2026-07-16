extends GdUnitTestSuite

# Shop economy modes on InventoryService:
#   classic (default, UnlockPayPerUse=false): buy modifier charges, free ActivateItem
#   PPU (UnlockPayPerUse=true): free UnlockItem, pay on ActivateUnlocked
# Driven through InventoryService / CoinService autoloads.


func before_test() -> void:
	InventoryService.Reset()
	CoinService.Reset()


func _enable_ppu() -> void:
	InventoryService.SetUnlockPayPerUse(true)


# ── Classic (default) ─────────────────────────────────────────────────────────


func test_classic_default_after_reset() -> void:
	assert_bool(InventoryService.UnlockPayPerUse).is_false()


func test_classic_add_item_stacks_modifier_charge() -> void:
	InventoryService.AddItem("mirror")
	assert_bool(InventoryService.IsUnlocked("mirror")).is_false()
	assert_int(InventoryService.GetItems().size()).is_equal(1)
	assert_bool(InventoryService.OwnsItem("mirror")).is_true()


func test_classic_activate_item_free() -> void:
	InventoryService.AddItem("mirror")
	CoinService.SetBalance(0)
	assert_bool(InventoryService.ActivateItem(0)).is_true()
	assert_int(CoinService.Balance).is_equal(0)
	assert_int(InventoryService.GetItems().size()).is_equal(0)
	assert_int(InventoryService.GetActiveEffects().size()).is_equal(1)


func test_classic_unlock_and_activate_unlocked_noop() -> void:
	assert_bool(InventoryService.UnlockItem("mirror")).is_false()
	CoinService.AddCoins(999)
	assert_bool(InventoryService.ActivateUnlocked("mirror")).is_false()


func test_classic_load_keeps_modifier_charges() -> void:
	var legacy: Array = [{"id": "mirror"}, {"id": "key"}]
	InventoryService.LoadFromSave(legacy)
	InventoryService.LoadUnlockedFromSave(["mirror"])
	assert_bool(InventoryService.IsUnlocked("mirror")).is_false()
	assert_bool(InventoryService.OwnsItem("mirror")).is_true()
	assert_bool(InventoryService.OwnsItem("key")).is_true()
	assert_int(InventoryService.GetItems().size()).is_equal(2)


# ── Unlock pay-per-use ───────────────────────────────────────────────────────


func test_unlock_modifier_free() -> void:
	_enable_ppu()
	assert_bool(InventoryService.IsModifier("mirror")).is_true()
	assert_bool(InventoryService.IsUnlocked("mirror")).is_false()
	assert_bool(InventoryService.UnlockItem("mirror")).is_true()
	assert_bool(InventoryService.IsUnlocked("mirror")).is_true()
	assert_int(CoinService.Balance).is_equal(0)
	# Second unlock is a no-op.
	assert_bool(InventoryService.UnlockItem("mirror")).is_false()
	assert_int(InventoryService.GetItems().size()).is_equal(0)


func test_add_item_modifier_unlocks_not_stacks() -> void:
	_enable_ppu()
	InventoryService.AddItem("mirror")
	assert_bool(InventoryService.IsUnlocked("mirror")).is_true()
	assert_int(InventoryService.GetItems().size()).is_equal(0)


func test_utility_buy_still_adds_charge() -> void:
	_enable_ppu()
	assert_bool(InventoryService.IsModifier("key")).is_false()
	CoinService.AddCoins(100)
	InventoryService.AddItem("key")
	assert_bool(InventoryService.OwnsItem("key")).is_true()
	assert_bool(InventoryService.IsUnlocked("key")).is_false()
	assert_int(InventoryService.GetItems().size()).is_equal(1)


func test_activate_unlocked_spends_coins() -> void:
	_enable_ppu()
	var price: int = int(InventoryService.GetItemData("mirror").get("price", 0))
	assert_int(price).is_greater(0)
	InventoryService.UnlockItem("mirror")
	CoinService.AddCoins(price)
	assert_bool(InventoryService.ActivateUnlocked("mirror")).is_true()
	assert_int(CoinService.Balance).is_equal(0)
	assert_bool(InventoryService.IsUnlocked("mirror")).is_true()
	assert_int(InventoryService.GetActiveEffects().size()).is_equal(1)


func test_activate_unlocked_insufficient_coins_fails() -> void:
	_enable_ppu()
	InventoryService.UnlockItem("mirror")
	CoinService.SetBalance(0)
	assert_bool(InventoryService.ActivateUnlocked("mirror")).is_false()
	assert_int(InventoryService.GetActiveEffects().size()).is_equal(0)


func test_activate_unlocked_requires_unlock() -> void:
	_enable_ppu()
	CoinService.AddCoins(999)
	assert_bool(InventoryService.ActivateUnlocked("mirror")).is_false()


func test_save_round_trip_unlocked() -> void:
	_enable_ppu()
	InventoryService.UnlockItem("mirror")
	InventoryService.AddItem("key")
	CoinService.AddCoins(10)
	var items: Array = InventoryService.CaptureSaveData()
	var unlocked: Array = InventoryService.CaptureUnlockedSaveData()
	assert_array(unlocked).contains(["mirror"])
	assert_int(items.size()).is_equal(1)

	InventoryService.Reset()
	assert_bool(InventoryService.IsUnlocked("mirror")).is_false()
	assert_bool(InventoryService.UnlockPayPerUse).is_false()

	_enable_ppu()
	InventoryService.LoadFromSave(items)
	InventoryService.LoadUnlockedFromSave(unlocked)
	assert_bool(InventoryService.IsUnlocked("mirror")).is_true()
	assert_bool(InventoryService.OwnsItem("key")).is_true()


func test_old_save_migrates_modifier_charges_to_unlocks() -> void:
	_enable_ppu()
	# Pre-feature saves stored modifiers as inventory charge dicts.
	var legacy: Array = [{"id": "mirror"}, {"id": "key"}]
	InventoryService.LoadFromSave(legacy)
	InventoryService.LoadUnlockedFromSave([])
	assert_bool(InventoryService.IsUnlocked("mirror")).is_true()
	assert_bool(InventoryService.OwnsItem("key")).is_true()
	# Mirror must not remain as a free-to-activate charge.
	for entry in InventoryService.GetItems():
		assert_str(str(entry.get("id", ""))).is_not_equal("mirror")


func test_owns_item_true_when_unlocked() -> void:
	_enable_ppu()
	InventoryService.UnlockItem("cock_lock")
	assert_bool(InventoryService.OwnsItem("cock_lock")).is_true()
