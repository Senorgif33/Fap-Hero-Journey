extends GdUnitTestSuite

# FunscriptPlayer.ClearFunscript — empties actions and beats so a cutscene
# (or any no-script node) cannot Resume leftover strokes from a prior round.


func before_test() -> void:
	FunscriptPlayer.ClearFunscript()


func after_test() -> void:
	FunscriptPlayer.ClearFunscript()
	var path := "user://test_clear_funscript.funscript"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write_v_motion_script(path: String) -> void:
	# Positions 100→0→100 create one V-motion beat at the dip.
	var data := {
		"actions": [
			{"at": 0, "pos": 100},
			{"at": 500, "pos": 0},
			{"at": 1000, "pos": 100},
		]
	}
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_object(f).is_not_null()
	f.store_string(JSON.stringify(data))
	f.close()


func test_clear_funscript_empties_actions_and_beats() -> void:
	var path := "user://test_clear_funscript.funscript"
	_write_v_motion_script(path)

	FunscriptPlayer.LoadFunscript(path)
	assert_int(FunscriptPlayer.ActionCount).is_equal(3)
	assert_int(FunscriptPlayer.GetBeats().size()).is_equal(1)

	FunscriptPlayer.ClearFunscript()
	assert_int(FunscriptPlayer.ActionCount).is_equal(0)
	assert_int(FunscriptPlayer.GetBeats().size()).is_equal(0)


func test_clear_funscript_is_idempotent() -> void:
	FunscriptPlayer.ClearFunscript()
	FunscriptPlayer.ClearFunscript()
	assert_int(FunscriptPlayer.ActionCount).is_equal(0)
	assert_array(FunscriptPlayer.GetBeats()).is_empty()
