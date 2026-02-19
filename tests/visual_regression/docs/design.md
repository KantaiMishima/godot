# Visual Regression Test 設計ドキュメント

## 概要

Godot エンジンに **visual regression test** と **interaction test** の仕組みを追加する。
シーンのスクリーンショットをキャプチャし、基準画像と比較することで、意図しない見た目の変化を検出する。

---

## 現状の方針

### アーキテクチャ全体像

```
CLI / スクリプト
  │
  ├─ シーン列挙（.tscn を再帰探索）
  │
  ├─ Godot 起動（実レンダラ付きオフスクリーン）
  │    └─ GODOT_MTL_OFF_SCREEN=1 --rendering-driver metal  (macOS)
  │    └─ xvfb-run --rendering-driver vulkan               (Linux CI)
  │
  ├─ シーンロード → N フレーム待機（レイアウト安定化）
  │
  ├─ SubViewport::get_image() でキャプチャ
  │    └─ ビューポートサイズ固定（例: 1280×720）
  │
  ├─ PNG 保存
  │    └─ tests/visual_regression/screenshots/{platform}/{scene_name}.png
  │
  └─ 外部ツール（regsuite 等）で基準画像と比較
       └─ tests/visual_regression/baselines/{platform}/{scene_name}.png
```

### 実装コンポーネント一覧

| コンポーネント | 状態 | 備考 |
|---|---|---|
| CLI / 実行スクリプト | 未実装 | GDScript の `--script` モードで実装予定 |
| 実レンダリングバックエンドの利用 | **検証済み** | 下記「調査結果」参照 |
| シーン列挙メカニズム | 未実装 | `.tscn` を再帰探索 |
| SubViewport + `get_image()` キャプチャ | **検証済み** | 実ピクセル取得を確認 |
| フレーム安定化（待機） | 未実装 | 適切なフレーム数は要検討 |
| ゴールデンイメージ保管場所 | 未実装 | `baselines/{platform}/` に配置予定 |
| 画像比較ユーティリティ | 未実装 | regsuite 等外部ツールで代替予定 |
| プラットフォーム別基準画像 | 未実装 | macOS / Linux / Windows で分離予定 |
| CI 統合 | 未実装 | Linux: xvfb-run が必要 |

### 着手順序

1. **実レンダラ起動の検証** ← **完了**
2. シーンロード → フレーム待機 → キャプチャ のパイプライン構築
3. CLI / スクリプトの整備（シーン列挙含む）
4. ゴールデンイメージの管理方法の確定（regsuite 連携含む）

---

## 調査結果

### Godot のレンダリング階層

```
DisplayServer（抽象）
  ├─ DisplayServerHeadless  -- --headless フラグで使用。RasterizerDummy を強制する。ピクセル生成不可
  │    └─ DisplayServerMock -- テスト用。入力シミュレーション追加。同様にピクセル生成不可
  └─ DisplayServerMacOS     -- 実ウィンドウ＋実レンダラ。Metal / Vulkan / OpenGL3 をサポート

RendererCompositor（抽象）
  ├─ RasterizerDummy        -- 全描画が no-op。GPU メモリ未使用
  └─ RendererCompositorRD   -- Vulkan / Metal / D3D12 による実レンダリング
```

### `--headless` が使えない理由

`--headless` フラグは内部で以下を強制する：

```cpp
// servers/display/display_server_headless.cpp
DisplayServer *DisplayServerHeadless::create_func(...) {
    RasterizerDummy::make_current();  // 実ピクセル生成不可
    return memnew(DisplayServerHeadless());
}
```

`RasterizerDummy` では `render_target_create()` が空の `RID()` を返すため、
`SubViewport::get_image()` は常に空／null になる。

### macOS での解決策: `GODOT_MTL_OFF_SCREEN=1`

コードベースに未公開の環境変数が存在する：

```cpp
// drivers/metal/rendering_context_driver_metal.cpp:347
if (String v = OS::get_singleton()->get_environment("GODOT_MTL_OFF_SCREEN"); v == U"1") {
    surface = memnew(SurfaceOffscreen(wpd->layer, metal_device));
} else {
    surface = memnew(SurfaceLayer(wpd->layer, metal_device));
}
```

`SurfaceOffscreen` は `MTL::StorageModePrivate` なオフスクリーン GPU テクスチャにレンダリングし、
画面への表示（`nextDrawable` / `present`）を省略する。ウィンドウは内部に生成されるが画面には表示されない。

### `SubViewport::get_image()` の動作（実レンダラ使用時）

呼び出しチェーン：

```
ViewportTexture::get_image()
  → RenderingServer::texture_2d_get(texture_rid)
    → TextureStorage::texture_2d_get(RID)          // renderer_rd
      → RenderingDevice::texture_get_data(rd_texture, 0)  // GPU readback
```

実レンダラが動いていれば、GPU テクスチャの内容を CPU 側に読み戻して `Image` として返す。

### 概念実証（PoC）の結果

**環境:** macOS / Apple M2 / Godot 4.5.1.stable

**実行コマンド:**
```bash
GODOT_MTL_OFF_SCREEN=1 /Applications/Godot.app/Contents/MacOS/Godot \
  --path /tmp/vr_test_project \
  --rendering-driver metal \
  --script capture_test.gd
```

**結果:**
```
Metal 3.2 - Forward+ - Using Device #0: Apple - Apple M2 (Apple8)
Image size: (320, 240)
Image format: 4
Center pixel: (1.0, 0.0, 0.0, 1.0)
SUCCESS: Center pixel is red as expected!
Saved to: /tmp/vr_test_output.png
```

SubViewport に追加した赤い `ColorRect` のピクセルを正確にキャプチャできることを確認。

### プラットフォーム別の対応方針

| プラットフォーム | 方法 | 備考 |
|---|---|---|
| macOS | `GODOT_MTL_OFF_SCREEN=1` + `--rendering-driver metal` | ウィンドウは非表示で動作 |
| Linux (CI) | `xvfb-run` + `--rendering-driver vulkan` | 仮想フレームバッファが必要 |
| Linux (GPU あり) | `VK_EXT_headless_surface` | 現時点で Godot は未対応 |
| Windows | 未調査 | DirectX12 / Vulkan いずれかで検討 |

### 既存の interaction test 基盤（参考）

`tests/test_macros.h` に以下のマクロが既に整備されている：

```cpp
SEND_GUI_MOUSE_MOTION_EVENT(pos, mask, key);
SEND_GUI_MOUSE_BUTTON_EVENT(pos, button, mask, key);
SEND_GUI_KEY_EVENT(Key::A | KeyModifierMask::CTRL);
SEND_GUI_DOUBLE_CLICK(pos, key);
SEND_GUI_TOUCH_EVENT(pos, pressed, canceled);
SEND_GUI_ACTION("ui_text_newline");
```

これらは `DisplayServerMock::simulate_event()` → `Input::parse_input_event()` を経由して
シグナルやノードの状態変化を検証できる。ただし現時点ではピクセル比較はできない。

### 未解決の課題

- フレーム安定化に必要な待機フレーム数（シーンの複雑さによって変わる可能性）
- フォントのサブピクセルレンダリングによるプラットフォーム差異の扱い
- アニメーションを含むシーンの決定論的なキャプチャ方法
- macOS でウィンドウを完全に非表示にする方法（現状は NSWindow が生成される）

---

## 関連ファイル

| ファイル | 内容 |
|---|---|
| `main/main.cpp:1448` | `--headless` フラグの処理 |
| `servers/display/display_server_headless.cpp` | `RasterizerDummy` を強制する実装 |
| `servers/rendering/dummy/rasterizer_dummy.h` | 全描画 no-op の実装 |
| `drivers/metal/rendering_context_driver_metal.cpp:347` | `GODOT_MTL_OFF_SCREEN` 環境変数 |
| `drivers/metal/rendering_context_driver_metal.cpp:222` | `SurfaceOffscreen` の実装 |
| `platform/macos/display_server_macos.mm:3536` | macOS サポートレンダリングドライバ一覧 |
| `servers/rendering/renderer_viewport.cpp:761` | `draw_viewports()`: SubViewport のレンダリング処理 |
| `servers/rendering/renderer_rd/storage_rd/texture_storage.cpp:1821` | GPU readback の実装 |
| `scene/main/viewport.cpp:181` | `ViewportTexture::get_image()` |
| `tests/test_macros.h` | 既存の GUI 入力シミュレーションマクロ |
| `tests/display_server_mock.h` | テスト用モック DisplayServer |
