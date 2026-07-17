extends GdUnitTestSuite

# RestimAxisKit — hardcoded Restim FOC kit (no restim.ini read at runtime).


func test_e1_through_e4_map_to_tcode() -> void:
	assert_str(RestimAxisKit.tcode_for("e1")).is_equal("E1")
	assert_str(RestimAxisKit.tcode_for("e2")).is_equal("E2")
	assert_str(RestimAxisKit.tcode_for("e3")).is_equal("E3")
	assert_str(RestimAxisKit.tcode_for("e4")).is_equal("E4")
	assert_str(RestimAxisKit.axis_display_label("e1")).is_equal("E1  →  E1")
	assert_bool(RestimAxisKit.should_autofill("e1")).is_true()


func test_core_restim_axes() -> void:
	assert_str(RestimAxisKit.detect_axis("scene.alpha")).is_equal("alpha")
	assert_str(RestimAxisKit.detect_axis("scene.beta")).is_equal("beta")
	assert_str(RestimAxisKit.tcode_for("alpha")).is_equal("L0")
	assert_str(RestimAxisKit.tcode_for("beta")).is_equal("L1")
	assert_str(RestimAxisKit.tcode_for("volume")).is_equal("V0")
	assert_str(RestimAxisKit.tcode_for("frequency")).is_equal("C0")
	assert_str(RestimAxisKit.tcode_for("pulse_frequency")).is_equal("P0")
	assert_str(RestimAxisKit.tcode_for("sensor_suppression")).is_equal("S1")


func test_cybernetic_suffix_strip() -> void:
	assert_str(
		RestimAxisKit.strip_suffix("Cybernetic Succubus #2 Stroking.pulse_frequency")
	).is_equal("Cybernetic Succubus #2 Stroking")
	assert_str(ImportScanner.detect_funscript_axis("/x/Cybernetic.e4.funscript")).is_equal("e4")
	assert_str(ImportScanner.detect_funscript_axis("/x/Cybernetic.funscript")).is_equal("L0")


func test_ssr_axes_still_detect() -> void:
	assert_str(RestimAxisKit.detect_axis("scene.surge")).is_equal("L1")
	assert_str(RestimAxisKit.tcode_for("L1")).is_equal("L1")
	assert_bool(RestimAxisKit.should_autofill("R0")).is_true()


func test_slotted_axis_detection() -> void:
	var a_alpha: Dictionary = RestimAxisKit.detect_slotted_axis("scene.a.alpha")
	assert_str(str(a_alpha.get("slot", ""))).is_equal("a")
	assert_str(str(a_alpha.get("axis", ""))).is_equal("alpha")
	var b_vol: Dictionary = RestimAxisKit.detect_slotted_axis("scene_b_volume")
	assert_str(str(b_vol.get("slot", ""))).is_equal("b")
	assert_str(str(b_vol.get("axis", ""))).is_equal("volume")
	var shared_pulse: Dictionary = RestimAxisKit.detect_slotted_axis("scene.pulse_frequency")
	assert_str(str(shared_pulse.get("slot", ""))).is_equal("shared")
	assert_str(str(shared_pulse.get("axis", ""))).is_equal("pulse_frequency")
	# Plain kit → slot A (not shared).
	var plain_alpha: Dictionary = RestimAxisKit.detect_slotted_axis("scene.alpha")
	assert_str(str(plain_alpha.get("slot", ""))).is_equal("a")
	assert_str(str(plain_alpha.get("axis", ""))).is_equal("alpha")


func test_label_tagged_axis_detection() -> void:
	assert_str(RestimAxisKit.slugify_label("Prostate")).is_equal("prostate")
	assert_str(RestimAxisKit.slugify_label("My Kit")).is_equal("my-kit")
	var tagged: Dictionary = RestimAxisKit.detect_slotted_axis(
		"scene.alpha-prostate", "Restim A", "Prostate"
	)
	assert_str(str(tagged.get("slot", ""))).is_equal("b")
	assert_str(str(tagged.get("axis", ""))).is_equal("alpha")
	var no_match: Dictionary = RestimAxisKit.detect_slotted_axis(
		"scene.alpha-prostate", "Restim A", "Restim B"
	)
	# Tag doesn't match either label slug → not a plain kit either.
	assert_bool(no_match.is_empty()).is_true()
	assert_bool(RestimAxisKit.has_kit_axis_tag("scene.alpha-prostate")).is_true()


func test_slotted_suffix_strip() -> void:
	assert_str(RestimAxisKit.strip_suffix("scene.a.alpha")).is_equal("scene")
	assert_str(RestimAxisKit.strip_suffix("scene_b_e1")).is_equal("scene")
	assert_str(RestimAxisKit.strip_suffix("scene.alpha-prostate", "", "Prostate")).is_equal(
		"scene"
	)
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.a.alpha.funscript")).is_equal("alpha")
