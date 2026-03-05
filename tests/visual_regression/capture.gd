extends SceneTree

## Visual Regression Test - Capture Script
##
## Usage:
##   GODOT_MTL_OFF_SCREEN=1 godot \
##     --path tests/visual_regression \
##     --rendering-driver metal \
##     --script capture.gd
##
## Output: tests/visual_regression/screenshots/{scene_name}.png

const VIEWPORT_SIZE := Vector2i(1280, 720)
const SETTLE_FRAMES := 3
const OUTPUT_DIR := "screenshots"

func _initialize() -> void:
	print("=== Godot Visual Regression Capture ===")

	var vp := SubViewport.new()
	vp.size = VIEWPORT_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	root.add_child(vp)

	# テスト用シーン（ColorRect で動作確認）
	var rect := ColorRect.new()
	rect.color = Color(1, 0, 0)
	rect.size = Vector2(VIEWPORT_SIZE)
	vp.add_child(rect)

	# フレーム安定化
	for i in SETTLE_FRAMES:
		await process_frame

	var img := vp.get_texture().get_image()

	if img == null or img.is_empty():
		printerr("FAIL: image is null or empty")
		quit(1)
		return

	print("Captured: ", img.get_size(), " format=", img.get_format())

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://" + OUTPUT_DIR)
	)

	var save_path := "res://%s/test_colorrect.png" % OUTPUT_DIR
	var err := img.save_png(ProjectSettings.globalize_path(save_path))
	if err == OK:
		print("Saved: ", ProjectSettings.globalize_path(save_path))
	else:
		printerr("Failed to save PNG: ", err)
		quit(1)
		return

	quit(0)
