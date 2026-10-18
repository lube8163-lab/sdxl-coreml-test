# FLUX.3 CoreAI 文章条件の事前計算 / iPhone 14（2026-10-18）

接続中の物理 iPhone 14（iPhone14,7、iOS27.2、約6GB RAM）で生成から六視点の安全性確認・PNG保存まで完走した。512×512、16ステップ、seed42、固定の静物キャプション。独立した検証アプリの Release ビルドで測定。

文章条件を各ステップの時刻で先に計算し、大きな入力・文章関数を解放した後、画像投影・画像側・統合側を保持する経路を追加した。ステップ数、層、重み、計算精度は変更していない。

## 暖機後・同一ビルドの結果

通常経路と `--precompute-text` をそれぞれ2回実行した。先行する初回コンパイルを含む `first-use-control` は下の平均から除いた。実施順と各回の値も残している。

| 条件 | モデル処理合計の平均 (範囲) | DiT平均 | サンプル最大メモリの平均 |
| --- | ---: | ---: | ---: |
| 従来の Groups8 / shared4保持 | 336.44 s (326.49–346.39) | 327.56 s | 1.547 GB |
| 文章条件の事前計算 | 275.55 s (259.81–291.28) | 260.37 s | 1.172 GB |

合計時間は平均で約18.1%短縮、サンプル最大メモリは約24.2%減った。合計は Qwen＋文章条件の事前計算（有効時）＋DiT＋VAE。起動・モデルハッシュ照合・出力安全性確認を含む操作全体の時間とは異なる。

| 実施順 | 条件 | Qwen | 事前計算 | DiT | VAE | 合計 | 最大 GB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [first-use-control](first-use-control/report.json) | 28.07 | 0.00 | 393.71 | 5.55 | 427.33 | 1.548 |
| 2 | [precompute-01](precompute-01/report.json) | 6.34 | 6.68 | 244.73 | 2.07 | 259.81 | 1.172 |
| 3 | [warm-control-02](warm-control-02/report.json) | 6.64 | 0.00 | 337.42 | 2.32 | 346.39 | 1.547 |
| 4 | [precompute-02](precompute-02/report.json) | 6.51 | 6.61 | 276.01 | 2.14 | 291.28 | 1.172 |
| 5 | [warm-control-03](warm-control-03/report.json) | 6.58 | 0.00 | 317.70 | 2.22 | 326.49 | 1.546 |

全5回で16ステップを完走し、保存PNGのSHA-256が完全一致した。各ステップの潜在の最小・最大も一致。六視点の安全性判定と保存画像ハッシュを、回収後に解析スクリプトでも再確認した。

```text
0650c75aa2c6b5d84e5d20e43c1a452c762165c76bb1ef0488a5f139f7513ab9
```

![iPhone14で生成した画像](precompute-02/flux3-512-seed42-approved.png)

## 再現性と計測範囲

- `build-provenance.json` に Release バイナリとソースの SHA。暖機後の4回は同じインストール済みバイナリ。初回は旧ソース255のビルド。対応する Swift ソースの写しも保存。
- 各フォルダに `report.json`、50ms間隔を要求した `memory.csv`、部品ごとの `component-timings.jsonl`、`analysis.json`、安全性確認済みPNG。関数の await はスケジューリングや同期を含み得る壁時計時間であり、GPUだけの時間ではない。
- メモリはアプリの `phys_footprint` のサンプル最大。瞬間ピークや端末全体のメモリではない。記録された全ステップの thermal state はnominal、低電力モード無効。それでも時間はばらついた。各2回のため安定した一般性能の保証にはしない。
- `input-image-slice.json` に追加アセットのハッシュ。元グラフの画像出力への依存関係だけを複製し、再量子化していない。`split-input-validation.json` で実 CoreAI の出力が完全一致。
- 同一キャプション・seedの一致確認。任意プロンプトの一致や多様な画像品質を検証したものではない。
- 新経路は `--precompute-text` の明示指定で使う。通常起動の既存設定は維持。iPhone 17 はこの実験時点で未接続のため、新経路の時間とメモリは未測定。

再現手順は [PERFORMANCE.md](../../../Experiments/Flux3CoreAI/PERFORMANCE.md#文章条件を先に計算する追加経路)。[機械可読集計](summary.json)、[Windowsでの重み量子化比較](../flux3-quantization-quality/README.md)も保存している。
