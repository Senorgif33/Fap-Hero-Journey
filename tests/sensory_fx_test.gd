extends GdUnitTestSuite

# SensoryFX intensity math — the mapping that turns a normalized 0–1 slider value
# into a real effect value, and the per-round override lookup. Pure logic: _ival
# only reads the roll dict, intensity_for is static, so neither needs setup().
# SensoryFX is reached via its global class_name.

const EPS := 0.0001


# _ival lerps imin→imax across 0–1.
func test_ival_normal_range() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 1.0, "imax": 6.0}  # e.g. blur radius
	assert_float(fx._ival(roll, 0.0)).is_equal_approx(1.0, EPS)
	assert_float(fx._ival(roll, 1.0)).is_equal_approx(6.0, EPS)
	assert_float(fx._ival(roll, 0.5)).is_equal_approx(3.5, EPS)


# Inverted ranges (imin > imax) — "stronger" maps to a lower number, e.g.
# pixelate blocks, strobe interval, low-pass cutoff, tunnel ramp.
func test_ival_inverted_range() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 160.0, "imax": 30.0}  # pixelate: fewer blocks = stronger
	assert_float(fx._ival(roll, 0.0)).is_equal_approx(160.0, EPS)
	assert_float(fx._ival(roll, 1.0)).is_equal_approx(30.0, EPS)
	(
		assert_bool(fx._ival(roll, 1.0) < fx._ival(roll, 0.0))
		. override_failure_message("higher intensity should map to lower value")
		. is_true()
	)


# Intensity is clamped to 0–1 before mapping.
func test_ival_clamps_intensity() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	var roll := {"imin": 0.0, "imax": 1.0}
	assert_float(fx._ival(roll, 2.0)).is_equal_approx(1.0, EPS)
	assert_float(fx._ival(roll, -1.0)).is_equal_approx(0.0, EPS)


# Missing imin/imax fall back to a 0–1 identity (defensive default).
func test_ival_missing_fields() -> void:
	var fx: SensoryFX = auto_free(SensoryFX.new())
	assert_float(fx._ival({}, 0.5)).is_equal_approx(0.5, EPS)


# intensity_for: author override on the round wins; otherwise the catalog default.
func test_intensity_for_override_and_default() -> void:
	var entry := {"name": "Bleary", "idef": 0.3}
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Bleary": 0.8}}, entry))
		. is_equal_approx(0.8, EPS)
	)
	assert_float(SensoryFX.intensity_for({}, entry)).is_equal_approx(0.3, EPS)
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Other": 0.9}}, entry))
		. is_equal_approx(0.3, EPS)
	)


# A stored override outside 0–1 is clamped.
func test_intensity_for_clamps_override() -> void:
	var entry := {"name": "Murk", "idef": 0.5}
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Murk": 5.0}}, entry))
		. is_equal_approx(1.0, EPS)
	)
	(
		assert_float(SensoryFX.intensity_for({"sensory_intensity": {"Murk": -2.0}}, entry))
		. is_equal_approx(0.0, EPS)
	)
