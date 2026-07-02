extends Control

# Child of GraphView. Holds the auto-laid-out node widgets as children, and
# draws the edges that connect them via _draw(). Pan/zoom transform is applied
# by the parent GraphView to this control's position + scale, so node positions
# and edge coordinates share the same canvas-local space.

# Edges: list of { from: Vector2, to: Vector2, color: Color }
var edges: Array = []


func set_edges(e: Array) -> void:
	edges = e
	queue_redraw()


func _draw() -> void:
	for e in edges:
		var points: PackedVector2Array = e["points"]
		var color: Color = e["color"]
		var dashed: bool = e.get("dashed", false)
		# The route is pre-computed by GraphView (orthogonal, entering the target on whichever face
		# points back toward the source). Draw each segment, then an arrowhead along the entry heading.
		for i in range(points.size() - 1):
			_edge_seg(points[i], points[i + 1], color, dashed)
		if points.size() > 0:
			_draw_arrowhead(points[points.size() - 1], e.get("arrow_dir", Vector2(0, 1)), color)


# A small arrowhead at `tip` pointing along `dir` (the unit heading into the node). The two barbs
# splay back from the tip, so it reads correctly whether the edge enters from the top, bottom, or a side.
func _draw_arrowhead(tip: Vector2, dir: Vector2, color: Color) -> void:
	var a: float = 6.0
	var back: Vector2 = -dir * a
	var perp: Vector2 = Vector2(-dir.y, dir.x) * a
	draw_line(tip, tip + back + perp, color, 2.0, true)
	draw_line(tip, tip + back - perp, color, 2.0, true)


# One edge segment, solid for normal flow or dashed for a redirect (a non-default jump).
func _edge_seg(a: Vector2, b: Vector2, color: Color, dashed: bool) -> void:
	if dashed:
		draw_dashed_line(a, b, color, 2.0, 6.0)
	else:
		draw_line(a, b, color, 2.0, true)
