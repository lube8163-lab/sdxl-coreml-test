# FLUX.3 文章条件の事前計算 / iPhone 17（2026-10-18）

物理 iPhone 17（iPhone18,3、iOS27.0.1 / 24A446）で実施。512×512、16ステップ、seed42、固定キャプション。独立した検証アプリの Release ビルド。

## 同一ビルドの比較（従来1回、新経路2回）

| 条件 | モデル処理合計の平均（範囲） | DiT平均 | サンプル最大メモリの平均 |
| --- | ---: | ---: | ---: |
| 従来の Groups8 / shared4保持 | 98.76 s (98.76–98.76) | 93.36 s | 1.606 GB |
| 文章条件を事前計算 | 68.46 s (67.75–69.16) | 60.41 s | 1.183 GB |

事前計算の時間も含め、上記の平均は約30.7%短縮、サンプル最大メモリの平均は約26.3%減少した。合計は Qwen＋事前計算（有効時）＋DiT＋VAE。起動・アセット照合・出力安全性確認は含めない。

最初の連続測定では control-03 が16ステップ中12ステップで熱状態serious（2）となり、128.16秒まで伸びた。これを混ぜた単純平均は従来113.46秒、新68.46秒（39.7%短縮）だが、熱状態が揃っていないため見出しの改善率に使わない。休止後のcontrol-04を追加し、serious / criticalを含まない実行だけを比較する基準を追加実行の完了前に決めた。全データは下表に残す。

| 実施順 | 条件 | Qwen | 事前計算 | DiT | VAE | 合計 | 最大 GB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [warmup](warmup/report.json) | 4.92 | 0.00 | 95.26 | 1.09 | 101.27 | 1.642 |
| 2 | [precompute-01](precompute-01/report.json) | 4.59 | 2.69 | 61.02 | 0.86 | 69.16 | 1.185 |
| 3 | [control-02](control-02/report.json) | 4.46 | 0.00 | 93.36 | 0.95 | 98.76 | 1.606 |
| 4 | [precompute-02](precompute-02/report.json) | 4.29 | 2.61 | 59.80 | 1.04 | 67.75 | 1.181 |
| 5 | [control-03](control-03/report.json) | 5.27 | 0.00 | 121.89 | 1.00 | 128.16 | 1.598 |
| 6 | [control-04](control-04/report.json) | 4.51 | 0.00 | 93.19 | 0.97 | 98.66 | 1.606 |

最初の修正版 warmup と熱状態seriousを含む実行は比較平均から除いた。全6回で16ステップ・六視点判定・PNG保存を完了し、PNGのSHAが完全一致。以前のiPhone17計測のPNGとも一致した。各ステップの潜在の最小・最大の一致は `summary.json` に記録。

```text
f71fb682f82e7c16d4eba4a3bfd43312637e9b8c12789f130f58eb9c923da674
```

![iPhone17で生成した画像](precompute-02/flux3-512-seed42-approved.png)

## 起動時の終了の修正

最初にiPhone14で使用した旧ビルドを入れると、モデルのSHA照合中にiOSのscene-create watchdog（10秒、FRONTBOARD 0x8BADF00D）で終了した。クラッシュの主スレッドはSHA256圧縮処理だった。メモリ不足を示す終了理由ではない。

`fileSHA256` で全ファイルの照合を detached task に移し、1MiBずつ読む方式へ修正した。照合対象や期待SHAのガードは維持した。生成の重み・ステップ・計算内容は変えていない。上の全6回はこの同じ修正版を使用し、検証モードと所要時間も各レポートに記録。旧ビルドの失敗は性能平均に含めていない。

`startup-watchdog-diagnostic.json`、`startup-verifier-fix.diff`、`build-provenance.json`、`GenerationProbe-tested.swift` に根拠を保存。iPhone14の結果は旧b68ビルドでの別計測のまま保持している。

## 計測範囲と再現

- 全回のPNGハッシュと六視点スコアは回収後に再確認。各回の `analysis.json`、`component-timings.jsonl`、`memory.csv` を保存。CSVから再集計したピークとレポートの一致は `memory-integrity.json`。
- メモリは50ms間隔を要求したアプリの phys_footprint サンプル最大。瞬間ピークや端末全体、Metal割当量とは異なる。実際の最大間隔と熱状態は生データに記録。
- 端末やOSのキャッシュ・負荷で時間は変動する。過去のiPhone17の最速値とは条件が異なるため、効果は今回の同一ビルドで比較する。熱状態を揃えた標本も少数、一つの固定プロンプトなので一般的な速度・画質の保証にはしない。
- `--precompute-text` を明示指定する実験経路。通常起動の設定は維持している。提出済みFLUX.2アプリやAppStoreの変更ではない。

手順は [PERFORMANCE.md](../../../Experiments/Flux3CoreAI/PERFORMANCE.md#文章条件を先に計算する追加経路)。[機械可読集計](summary.json)、[iPhone14の結果](../flux3-coreai-precompute-iphone14/README.md)、[V100の画質比較](../flux3-quantization-quality/README.md)。
