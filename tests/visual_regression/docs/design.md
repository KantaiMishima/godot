# Visual Regression Test 設計ドキュメント

## 概要

Godot エンジンに **visual regression test** と **interaction test** の仕組みを追加する。
シーンのスクリーンショットをキャプチャし、基準画像と比較することで、意図しない見た目の変化を検出する。

---

## 現状の方針

### 責務の分離方針

**配布形態:** 独立した addon リポジトリとして配布。ユーザーは `addons/` 配下にクローンして使う
**このリポジトリが提供するもの:** シーンのスクリーンショットを撮る仕組み（`capture.gd`）
**利用者側に委ねるもの:** 基準画像との差分比較・管理（Argos CI / reg-suit / pixelmatch 等、任意のツール）

### アーキテクチャ全体像

```text
【このリポジトリの責務】
  capture.gd
    │
    ├─ シーン列挙（.tscn を再帰探索 or 引数指定）
    │
    ├─ Godot 起動（実レンダラ付きオフスクリーン）
    │    └─ GODOT_MTL_OFF_SCREEN=1 --rendering-driver metal  (macOS)
    │    └─ xvfb-run --rendering-driver vulkan               (Linux CI)
    │
    ├─ シーンロード → N フレーム待機（レイアウト安定化）
    │
    ├─ SubViewport::get_image() でキャプチャ
    │    └─ ビューポートサイズ固定（1280×720）
    │
    └─ PNG 保存 → {project}/vr_screenshots/{scene_name}.png

【利用者側の責務】
  任意の VRT ツールで比較
    ├─ Argos CI（OSS 無料枠あり・PR コメント自動投稿）
    ├─ reg-suit（S3/GCS に保管）
    ├─ pixelmatch（自前スクリプト）
    └─ その他
```

### 実装コンポーネント一覧

| コンポーネント | 状態 | 備考 |
| :--- | :--- | :--- |
| CLI / 実行スクリプト | **実装済み** | `tests/visual_regression/capture.gd` |
| 実レンダリングバックエンドの利用 | **検証済み** | 下記「調査結果」参照 |
| シーン列挙メカニズム | **実装済み** | `res://` を再帰探索、引数指定も可 |
| SubViewport + `get_image()` キャプチャ | **検証済み** | 実ピクセル取得・実シーン撮影を確認 |
| フレーム安定化（待機） | **実装済み** | 現在 5 フレーム待機（要調整） |
| ゴールデンイメージ保管場所 | **利用者側に委任** | 比較ツールの流儀に従う |
| 画像比較ユーティリティ | **利用者側に委任** | Argos CI / reg-suit / pixelmatch 等、任意 |
| プラットフォーム別基準画像 | **利用者側に委任** | 比較ツール側で管理 |
| CI 統合 | 未実装 | Linux: xvfb-run が必要 |

### 着手順序

1. **実レンダラ起動の検証** ← **完了**
2. **シーンロード → フレーム待機 → キャプチャのパイプライン構築** ← **完了**
3. **CLI / スクリプトの整備（シーン列挙含む）** ← **完了**（capture.gd として実装）
4. **ゴールデンイメージ管理・差分比較の方針確定** ← **完了**（利用者側に委任）
5. CI 統合（Linux: xvfb-run 対応）

---

## 調査結果

### Godot のレンダリング階層

```bash
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

```gd
ViewportTexture::get_image()
  → RenderingServer::texture_2d_get(texture_rid)
    → TextureStorage::texture_2d_get(RID)          // renderer_rd
      → RenderingDevice::texture_get_data(rd_texture, 0)  // GPU readback
```

実レンダラが動いていれば、GPU テクスチャの内容を CPU 側に読み戻して `Image` として返す。

### 概念実証（PoC）の結果

**環境:** macOS / Apple M2 / Godot 4.5.1.stable

#### PoC1: ColorRect のキャプチャ

```bash
GODOT_MTL_OFF_SCREEN=1 /Applications/Godot.app/Contents/MacOS/Godot \
  --path /tmp/vr_test_project \
  --rendering-driver metal \
  --script capture_test.gd
```

```text
Metal 3.2 - Forward+ - Using Device #0: Apple - Apple M2 (Apple8)
Image size: (320, 240) / Center pixel: (1.0, 0.0, 0.0, 1.0)
SUCCESS: Center pixel is red as expected!
```

SubViewport に追加した赤い `ColorRect` のピクセルを正確にキャプチャできることを確認。

#### PoC2: 実プロジェクトの .tscn キャプチャ

`capture.gd` を使って `mask-tower-defense` プロジェクトの `title.tscn` をキャプチャ。

```bash
GODOT_MTL_OFF_SCREEN=1 /Applications/Godot.app/Contents/MacOS/Godot \
  --path /Users/mishimakanfutoshi/mask-tower-defense \
  --rendering-driver metal \
  --script /path/to/godot/tests/visual_regression/capture.gd \
  -- res://title.tscn
```

```text
=== Godot Visual Regression Capture ===
Project: /Users/mishimakanfutoshi/mask-tower-defense/
Scenes to capture: 1
Capturing: res://title.tscn
  Saved: /Users/mishimakanfutoshi/mask-tower-defense/vr_screenshots/title.png
=== Done ===
```

1280×720 でタイトル画面（背景・テキスト・ボタン）が正確にレンダリングされることを確認。

### プラットフォーム別の対応方針

| プラットフォーム | 方法 | 備考 |
| --- | --- | --- |
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
| --- | --- |
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
