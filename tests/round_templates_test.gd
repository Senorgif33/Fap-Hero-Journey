extends GdUnitTestSuite

# RoundTemplates — the pure logic (upsert / without / strip_for_template / apply_to). No disk.


func _tmpl(name: String, tag: String) -> Dictionary:
	return {"name": name, "data": {"name": tag}}


func test_upsert_appends_new() -> void:
	var out: Array = RoundTemplates.upsert([], "Enc", {"round_type": "pool"})
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("Enc")
	assert_str(str(((out[0] as Dictionary)["data"] as Dictionary)["round_type"])).is_equal("pool")


func test_upsert_replaces_in_place() -> void:
	var start: Array = [_tmpl("A", "a"), _tmpl("B", "b"), _tmpl("C", "c")]
	var out: Array = RoundTemplates.upsert(start, "B", {"name": "b2"})
	assert_int(out.size()).is_equal(3)
	assert_str(str(((out[1] as Dictionary)["data"] as Dictionary)["name"])).is_equal("b2")
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("A")
	assert_str(str((out[2] as Dictionary)["name"])).is_equal("C")


func test_upsert_deep_copies_data() -> void:
	var data: Dictionary = {"name": "orig"}
	var out: Array = RoundTemplates.upsert([], "X", data)
	data["name"] = "mutated"  # mutate source afterward
	assert_str(str(((out[0] as Dictionary)["data"] as Dictionary)["name"])).is_equal("orig")


func test_without_removes_by_name() -> void:
	var out: Array = RoundTemplates.without([_tmpl("A", "a"), _tmpl("B", "b")], "A")
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("B")


# Node-level keys never ride along in a template — the id + edges belong to the graph node.
func test_strip_for_template_drops_node_keys() -> void:
	var out: Dictionary = RoundTemplates.strip_for_template(
		{"type": "round", "node_id": "n_1", "name": "R", "coins": 5, "trim_start_ms": 10}
	)
	assert_bool(out.has("node_id")).is_false()
	assert_bool(out.has("type")).is_false()
	assert_bool(out.has("trim_start_ms")).is_false()
	assert_str(str(out["name"])).is_equal("R")
	assert_int(int(out["coins"])).is_equal(5)


# apply_to overwrites the round's fields but keeps its own node id (so graph edges survive).
func test_apply_to_overwrites_but_keeps_node_id() -> void:
	var data: Dictionary = {"node_id": "n_keep", "name": "Old", "coins": 1}
	RoundTemplates.apply_to(data, {"name": "New", "round_type": "pool", "coins": 9})
	assert_str(str(data["node_id"])).is_equal("n_keep")  # id preserved
	assert_str(str(data["type"])).is_equal("round")  # re-stamped
	assert_str(str(data["name"])).is_equal("New")
	assert_int(int(data["coins"])).is_equal(9)
	assert_bool(data.has("round_type")).is_true()


func test_apply_to_is_deep_copy() -> void:
	var tmpl: Dictionary = {"pool_entries": [{"name": "e1"}]}
	var data: Dictionary = {"node_id": "n1"}
	RoundTemplates.apply_to(data, tmpl)
	(tmpl["pool_entries"] as Array).append({"name": "e2"})  # mutate source after apply
	assert_int((data["pool_entries"] as Array).size()).is_equal(1)
