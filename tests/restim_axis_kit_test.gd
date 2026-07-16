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
