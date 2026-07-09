extends GdUnitTestSuite

# JourneyData.sanitize_folder_name — turns a journey title into a filesystem-safe folder
# name used by the save flow (and, prefixed with ".~save_", the atomic-swap staging dir).
# The Windows-specific edges matter: a trailing dot/space makes a folder Explorer can't
# delete, and a leading dot makes the scanner skip the journey entirely.

const JD = preload("res://scripts/journey_builder/JourneyData.gd")


func test_spaces_to_underscores() -> void:
	assert_str(JD.sanitize_folder_name("Testing new effect rounds")).is_equal(
		"Testing_new_effect_rounds"
	)


func test_strips_invalid_chars() -> void:
	assert_str(JD.sanitize_folder_name('a/b:c*d?e"f<g>h|i')).is_equal("abcdefghi")


# The bug that stranded a folder on disk: a trailing dot must not survive.
func test_strips_trailing_dot() -> void:
	assert_str(JD.sanitize_folder_name("Testing new effect rounds.")).is_equal(
		"Testing_new_effect_rounds"
	)
	assert_str(JD.sanitize_folder_name("name...")).is_equal("name")


func test_strips_leading_dot() -> void:
	# A leading dot would make JourneyScanner.scan_all skip the folder.
	assert_str(JD.sanitize_folder_name(".hidden")).is_equal("hidden")
	assert_str(JD.sanitize_folder_name("...weird")).is_equal("weird")


func test_trims_surrounding_whitespace() -> void:
	assert_str(JD.sanitize_folder_name("  spaced  ")).is_equal("spaced")


# An interior dot is legitimate (e.g. a version tag) and must be preserved.
func test_keeps_interior_dot() -> void:
	assert_str(JD.sanitize_folder_name("Zaftig v2.0")).is_equal("Zaftig_v2.0")


# Anything that reduces to empty falls back to a usable default.
func test_empty_fallback() -> void:
	assert_str(JD.sanitize_folder_name("")).is_equal("Journey")
	assert_str(JD.sanitize_folder_name("...")).is_equal("Journey")
	assert_str(JD.sanitize_folder_name("/:*?")).is_equal("Journey")
