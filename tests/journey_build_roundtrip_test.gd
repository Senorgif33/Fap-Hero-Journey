extends GdUnitTestSuite

# Builder ↔ scanner round-trip (Tier 2, step 2). Runs a builder round item model
# through the REAL serializer (JourneyData.round_to_json) and the REAL scanner
# (JourneyScanner.parse_journey), asserting every authored field comes back equal.
# Unlike journey_scan_test (which hand-authors the JSON), this catches a *builder*-
# side key drop/typo — if round_to_json writes the wrong key, the scanner reads its
# default and the assertion fails. round_to_json is the single shared serializer
# for both the top-level and fork-path round save sites.

const TEST_DIR := "user://test_build_rt"
const JOURNEY := "j"
const EPS := 0.0001


func after() -> void:
	var base := ProjectSettings.globalize_path(TEST_DIR)
	DirAccess.remove_absolute(base + "/" + JOURNEY + "/journey.json")
	DirAccess.remove_absolute(base + "/" + JOURNEY)
	DirAccess.remove_absolute(base)


# A builder round item with every authored field at a non-default value.
func _authored_item() -> Dictionary:
	return {
		"type": "round", "name": "R",
		"round_type": "cursed", "coins": 25, "is_checkpoint": true,
		"curse_reward": 60, "cleanse_cost": 35, "curse_random": false,
		"curses": ["Choked", "Pauper"],
		"boon_random": false, "boons": ["Fervor"], "gift_item": "key",
		"boss_tagline": "rawr",
		"boss_modifiers": [{"kind": "clamp", "min": 10, "max": 40}],
		"sensory": ["Strobe", "Cavern"], "sensory_in_pool": true,
		"sensory_intensity": {"Strobe": 0.6},
		"show_reveal": false,
	}


# Serializes the item to a one-round journey.json (merging the media/slug fields
# the save loop would add) and parses it back through the scanner.
func _roundtrip(item: Dictionary) -> Dictionary:
	var round_json: Dictionary = JourneyData.round_to_json(item)
	round_json["Name"] = "R"
	round_json["FolderName"] = "r001"
	round_json["Order"] = 0
	round_json["FunscriptPath"] = "r001/script.funscript"
	round_json["VideoPath"] = "r001/video.mp4"
	round_json["ActionCount"] = 5
	round_json["LengthMs"] = 1000

	var journey := {"Name": "J", "Rounds": [round_json], "Forks": [], "Shops": [], "Storyboards": []}
	var jdir := TEST_DIR + "/" + JOURNEY
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(jdir))
	var f := FileAccess.open(jdir + "/journey.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(journey))
	f.close()
	return JourneyScanner.parse_journey(jdir, JOURNEY).rounds[0]


# round_to_json emits the expected PascalCase keys and transformed values
# (pure, no scanner) — pinpoints a builder-side key fault directly.
func test_round_to_json_shape() -> void:
	var j := JourneyData.round_to_json(_authored_item())
	assert_str(j["RoundType"]).is_equal("Cursed")          # internal "cursed" → label
	assert_int(j["CoinsAwarded"]).is_equal(25)
	assert_bool(j["ShowReveal"]).is_false()
	assert_array(j["Sensory"]).contains_exactly(["Strobe", "Cavern"])
	assert_dict(j["SensoryIntensity"]).is_equal({"Strobe": 0.6})
	var bm: Array = j["BossModifiers"]                     # {kind,min,max} → {Kind,Min,Max}
	assert_str(bm[0]["Kind"]).is_equal("clamp")
	assert_int(bm[0]["Min"]).is_equal(10)
	assert_int(bm[0]["Max"]).is_equal(40)


# Full authored field set survives builder serialize → scanner parse.
func test_authored_roundtrip() -> void:
	var item := _authored_item()
	var r := _roundtrip(item)
	# VideoPath is merged at the save call site (not in round_to_json) — assert it
	# survives the round-trip resolved to an absolute path.
	assert_str(r.video_path).is_equal(TEST_DIR + "/" + JOURNEY + "/r001/video.mp4")
	assert_str(r.round_type).is_equal("cursed")
	assert_int(int(r.coins)).is_equal(25)
	assert_bool(r.is_checkpoint).is_true()
	assert_int(r.curse_reward).is_equal(60)
	assert_int(r.cleanse_cost).is_equal(35)
	assert_bool(r.curse_random).is_false()
	assert_array(r.curses).contains_exactly(["Choked", "Pauper"])
	assert_bool(r.boon_random).is_false()
	assert_array(r.boons).contains_exactly(["Fervor"])
	assert_str(r.gift_item).is_equal("key")
	assert_str(r.boss_tagline).is_equal("rawr")
	assert_array(r.sensory).contains_exactly(["Strobe", "Cavern"])
	assert_bool(r.sensory_in_pool).is_true()
	assert_float(float(r.sensory_intensity["Strobe"])).is_equal_approx(0.6, EPS)
	assert_bool(r.show_reveal).is_false()
	var bm: Array = r.boss_modifiers
	assert_str(bm[0]["kind"]).is_equal("clamp")
	assert_float(float(bm[0]["min"])).is_equal_approx(10.0, EPS)
	assert_float(float(bm[0]["max"])).is_equal_approx(40.0, EPS)


# An empty item round-trips to the documented defaults (normal, telegraphed,
# cleanse cost 50, randoms on) — guards the default values, not just the keys.
func test_defaults_roundtrip() -> void:
	var r := _roundtrip({"type": "round", "name": "R"})
	assert_str(r.round_type).is_equal("normal")
	assert_bool(r.is_checkpoint).is_false()
	assert_bool(r.show_reveal).is_true()
	assert_int(r.cleanse_cost).is_equal(50)
	assert_bool(r.curse_random).is_true()
	assert_bool(r.boon_random).is_true()
	assert_array(r.curses).is_empty()
	assert_array(r.sensory).is_empty()
	assert_bool(r.sensory_in_pool).is_false()
