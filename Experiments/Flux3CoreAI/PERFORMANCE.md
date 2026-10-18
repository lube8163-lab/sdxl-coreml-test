# FLUX.3 CoreAI の読み込み時間の切り分け

追加実験: [iPhone 14 の文章条件の事前計算](#文章条件を先に計算する追加経路)と
[V100 の量子化比較](QUALITY.md)を別条件として記録する。以下の最初の表は
2026-10-17の iPhone 17 の結果で、iPhone 14 の数値と混ぜない。

2026-10-17〜18（UTC+07）、物理 iPhone 17（iPhone18,3）、iOS 27.0.1、Release の独立検証アプリで計測。
512×512、seed 42、16ステップ、固定キャプション、元の INT4 重みと BF16 計算を維持する。
提出済みの FLUX.2 アプリの計測やアップデートではない。

## 測定方法

`GenerationProbe.swift` の各呼び出しについて、モデル生成、`loadFunction`、
キャッシュ追い出し、`function.run` の await に費やした壁時計時間を JSONL に記録する。
`run` の時間にはスケジューリングや同期が含まれ得る。GPU カーネルだけの時間とは扱わない。
モデルハッシュ検証、Qwen、DiT、VAE、安全性確認を含む全経路は維持する。
`--diagnose` のテンソル走査は性能測定で有効にしない。

元のストリーム方式では、DiT 107.158秒のうち `loadFunction` に55.159秒、
`run` の await に48.511秒を要した。分割された38の重い部品を毎ステップ読み直す
コストが大きい。メモリに保持する個数だけを増やす方法は、端末上の保持コストもある。

最終ビルドで比較すると、元の方式89.28秒から採用設定69.77秒へ約21.8%短縮した。
同条件の採用設定の先行実行も70.45秒。Qwen＋DiT＋VAEは94.60秒から75.45秒、
サンプル最大メモリは約1.159GBから1.652GBになった。全9回の画像はPNGハッシュまで一致し、
六視点の安全性確認を通過した。固定した一画像の結果であり、多条件の品質評価とは異なる。

同一ビルド比較の関数読み込みは34.40秒→15.53秒、推論awaitは51.85秒→53.44秒。
今回の短縮は主に関数を再利用して準備時間を省いた効果と整合する。
元の方式も後の測定で速くなったため、初期の107秒との差をすべて改善効果とは扱わない。

| 条件 | DiT 16ステップ | 関数読み込み | 推論 await | サンプル最大 GB |
| --- | ---: | ---: | ---: | ---: |
| 元の方式・最初の計測 | 107.16 s | 55.16 s | 48.51 s | 1.121 |
| 個別の統合6ブロックを保持 | 113.06 s | 53.29 s | 56.65 s | 2.066 |
| 4ブロック結合・初回 | 98.61 s | 39.51 s | 45.46 s | 0.953 |
| 4ブロック結合・再実行 | 101.59 s | 53.29 s | 45.99 s | 0.948 |
| 8ブロック結合・保持なし | 111.15 s | 57.92 s | 46.81 s | 0.979 |
| 8ブロック結合・統合側を保持 | 70.45 s | 13.83 s | 55.79 s | 1.652 |
| 8ブロック結合・全関数を保持 | 104.80 s | 5.58 s | 97.38 s | 1.759 |
| 採用設定・通常起動で再実行 | 69.77 s | 15.53 s | 53.44 s | 1.652 |
| 同一ビルド・元の方式 | 89.28 s | 34.40 s | 51.85 s | 1.159 |

[全計測ログ・生成画像・来歴](../../measurements/2026-10-17/flux3-coreai-performance/README.md)
に、初期値・不採用条件も保存する。GPU時間の内訳や全保持時に推論待ちが増えた理由は、
この壁時計計測だけでは確定していない。

## グラフの結合と保持

既存の検証済み `.aimodel` のグラフをインライン化し、画像側5ブロック、文章側5ブロック、
統合側は最大8ブロックを一つの関数にする。全38ブロックの順序・定数・計算を維持し、
再量子化は行わない。CoreAI の私有 authoring API を使うため、README のバージョンを固定する。
統合側を8ずつにした場合、重い関数は6個になる（画像1、文章1、統合4）。

```sh
"$PYTHON" Experiments/Flux3CoreAI/compose_all_blocks.py \
  --source-root "$BF16_ASSETS" --output-root "$WORK/coreai-groups8" \
  --shared-group-size 8

"$PYTHON" Experiments/Flux3CoreAI/validate_composition.py image_g00 \
  --source-root "$BF16_ASSETS" --group-root "$WORK/coreai-groups8" \
  --output "$WORK/grouped-image-numeric.json"
"$PYTHON" Experiments/Flux3CoreAI/validate_composition.py text_g00 \
  --source-root "$BF16_ASSETS" --group-root "$WORK/coreai-groups8" \
  --output "$WORK/grouped-text-numeric.json"
"$PYTHON" Experiments/Flux3CoreAI/validate_composition.py shared_g00 \
  --source-root "$BF16_ASSETS" --group-root "$WORK/coreai-groups8" \
  --output "$WORK/grouped-shared-numeric.json"
```

同じ入力で順次呼び出しと結合後の数値を比較する。実画像全体の一致確認は別に行う。
今回、結合部品の最大変換プロセス RSS は約1.52GBで、8GB Mac上で順次作成できた。
重いグループのアセット合計は2,628,771,889 bytes。元の個別 DiT 部品と両方残す場合は、
その分だけ追加の空き容量が必要になる。

README の手順でアプリをビルド・インストールし、元のモデルと fixture を転送した後、
グループを追加する。コンテナを消すオプションは使わない。

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer \
  --domain-identifier com.tasuku.sdxlcoremltest.flux3generationprobe \
  --source "$WORK/coreai-groups8" --destination Documents/Flux3Models/Groups8
```

採用した設定は `--pin-shared-groups=4 --cache-capacity=0`。
統合側の全28ブロックを保持し、画像側・文章側の関数は毎回解放する。
Qwen終了時とDiT終了時にはキャッシュを破棄する。`Groups8/groups.json` が配置済みで
`--groups` と `--individual` を指定しない場合も、この設定を自動選択する。
グループが未配置の場合は、元の個別部品による容量二つのキャッシュで実行する。

```sh
xcrun devicectl device process launch --device YOUR_DEVICE_UDID --terminate-existing \
  com.tasuku.sdxlcoremltest.flux3generationprobe -- \
  --groups=Groups8 --pin-shared-groups=4 --cache-capacity=0 \
  --result-label=grouped8-retained

xcrun devicectl device copy from --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer \
  --domain-identifier com.tasuku.sdxlcoremltest.flux3generationprobe \
  --source Documents/Flux3Results-grouped8-retained \
  --destination "$WORK/results-grouped8-retained"
python3 Experiments/Flux3CoreAI/analyze_performance.py \
  "$WORK/results-grouped8-retained" --output "$WORK/grouped8-retained-summary.json"
```

個別部品の基準条件は `--individual --cache-capacity=2 --pin-count=0`。
結合のみの比較は `--groups=Groups8 --cache-capacity=0 --pin-shared-groups=0`。
4ブロック結合は新しい出力先で `--shared-group-size 4` を指定し、`Groups4` に転送する。
同じ結果ラベルを再利用せず、完走・全16ステップ・PNGハッシュ・六視点のスコアを確認する。

`--cache-capacity=2` と四つの統合グループの固定を組み合わせると、画像・文章を含む
重い全六関数を保持できる。ただし今回の実機ではこの条件の推論待ち時間が伸び、
全体の改善を確認できなかったため採用しない。保持量の最大化を推奨設定とはしない。

50ms間隔を要求した `phys_footprint` サンプル最大を報告し、実際の最大間隔も残す。
端末の温度状態、初回の特殊化、OS側キャッシュなどで時間は揺れる。
単一プロンプト・単一seedの画素一致は、多様な条件の品質評価とは区別する。

Windows GPUでの重み比較の再現手順は [QUALITY.md](QUALITY.md) を参照。
上記の2026-10-17の結合と実機測定には Windows GPU を使用していない。

## 文章条件を先に計算する追加経路

2026-10-18、接続できた物理 iPhone 14（iPhone14,7、約6GB RAM）、iOS 27.2、
Release の独立検証アプリで追加検証。iPhone 17 はこの追加実験では使っていない。

暖機後の同一ビルドで各2回を比較し、モデル処理合計は平均336.44秒→275.55秒
（約18.1%短縮）、サンプル最大メモリの平均は1.547GB→1.172GBだった。
事前計算の約6.65秒も合計に含める。各回には時間のばらつきがあり、
従来経路326.49〜346.39秒、新経路259.81〜291.28秒。
初回コンパイルを含む別の一回は平均から除外した。全5回の保存PNGが完全一致した。
[全実行とソース・生ログ](../../measurements/2026-10-18/flux3-coreai-precompute-iphone14/README.md)に記録する。

文章側の分岐と時刻の条件は、そのステップの画像潜在に依存しない。そこで16ステップ
それぞれの文章条件を先に作り、独立した BF16 配列にコピーする。大きな入力・文章の
関数を解放した後で、画像投影だけの小さいグラフ、画像側、統合側を保持して処理する。
同じ一つの文章条件を全ステップに流用せず、元と同じ16種類の時刻で計算している。
ステップ数・層数・重み・計算精度は変えない。

`slice_image_input.py` は元の BF16 input グラフの画像出力に必要な依存関係だけを
複製する。元の定数と演算を保持し、新アセットは787,537 bytes。
実 CoreAI による同じ入力の比較は完全一致した。CUDA の共通 FP32 参照の一例
（still-life / seed42）でも、事前計算の有無による16ステップの最終潜在は完全一致した。

新経路は `--precompute-text` で明示的に有効にする。通常起動の既存経路と同じ
ビルドで比較できる。画像保存前の六視点チェックは両方で有効。
計測の合計には Qwen・文章条件の事前計算・DiT・VAE を含める。
アセット照合、安全性確認、起動処理はこのモデル合計に含めない。

```sh
"$PYTHON" Experiments/Flux3CoreAI/slice_image_input.py \
  --source-root "$BF16_ASSETS" --output-root "$WORK/split-input"
"$PYTHON" Experiments/Flux3CoreAI/validate_split_input.py \
  --source-root "$BF16_ASSETS" --split-root "$WORK/split-input" \
  --fixture "$WORK/fixture" --output "$WORK/split-input-validation.json"
```

README の手順で現在の検証アプリを Release ビルド・インストールする。元のモデル、
fixture、Groups8 に加え、新しい小さい部品だけを追加入力する。

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer \
  --domain-identifier com.tasuku.sdxlcoremltest.flux3generationprobe \
  --source "$WORK/split-input" --destination Documents/Flux3Models/SplitInput

xcrun devicectl device process launch --device YOUR_DEVICE_UDID --terminate-existing \
  com.tasuku.sdxlcoremltest.flux3generationprobe -- \
  --groups=Groups8 --pin-shared-groups=4 --cache-capacity=0 \
  --precompute-text --result-label=precompute-repeat
```

比較する従来経路は同じフラグから `--precompute-text` だけを省く。結果ラベルは
条件ごとに新しくする。上の回収手順と `analyze_performance.py --baseline` を使い、
`model_pipeline_seconds`（事前計算を含む）と PNG ハッシュを比較する。
`denoising_seconds` だけでは準備を別フェーズに移した分を過大評価する。

上記はiPhone14の実測で、iPhone17の値は換算せず、次の追試で測定した。

## iPhone 17 の追試

同日、物理iPhone17 / iOS27.0.1（24A446）で新経路を検証した。
最初は大容量SHA照合がMainActorを塞ぎ、10秒のscene-create watchdogで終了した。
照合をdetached taskに移し、1MiBずつ読む方式に修正した。全ファイルの期待SHA照合は
維持し、生成の計算は変えていない。以下の全実行は同じ修正版のReleaseビルド。

| 熱状態fairの比較 | モデル処理合計 | DiT | サンプル最大メモリ |
| --- | ---: | ---: | ---: |
| 従来経路・1回 | 98.76 s | 93.36 s | 1.606 GB |
| 新経路・2回平均 | 68.46 s | 60.41 s | 1.183 GB |

事前計算込みで約30.7%短縮、サンプル最大メモリは約26.3%減少。
新経路の合計は67.75秒と69.16秒。DiT中の関数読み込みは従来26.40秒に対し新経路平均3.77秒。
新経路には別途、文章条件の事前計算もあり、その時間は合計に含める。

初回準備用の実行に加え、従来側で熱状態seriousを含む実行が2回あった。
うち128.16秒の実行を含めた単純平均の39.7%短縮は、熱条件が揃わないため見出しに使わない。
休止後の追加実行も98.66秒で完走したが、最後の3ステップがseriousだったため、
事前に決めた基準で比較平均から除いた。従来側の比較標本は1回なので、一般性能の保証にしない。

全6回で16ステップ・六視点の安全性確認・PNG保存に成功し、PNGと各ステップの潜在の
最小・最大は一致した。以前のiPhone17の保存PNGとも同じハッシュだった。
[全データ・温度状態・起動修正の根拠](../../measurements/2026-10-18/flux3-coreai-precompute-iphone17/README.md)
を保存する。通常起動の設定は維持し、新経路は`--precompute-text`で明示指定する。

## 16・8・4ステップの比較（2026-10-18）

事前計算経路を共通にし、物理iPhone17で4題材×2 seed×3条件の24枚を比較した。
送風開始前の熱条件が揃った3組のモデル処理平均は64.67 / 36.74 / 23.06秒。
4ステップは約64.3%短縮し、安全性確認・PNG保存までの平均は26.71秒だった。
送風開始後の別の4組では65.04 / 36.15 / 22.63秒、4の保存までは26.25秒。
題材も異なるため、送風前後を混ぜて冷却効果や改善率を出さない。

全25回（暖機1回込み）のPNG・六視点判定・CSVピークを検算済み。
全体のうちgeometry-seed1234の8 / 4がseriousだったため、その組の三条件を
速度の主比較から除外した。24枚の出力安全性判定は平均約0.137秒。
4でも内容は保たれたが、構図や看板の改行が変わる例がある。
[画像・全条件・集計](../../measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md)と
[STEP_COUNT.md](STEP_COUNT.md)にオプション、参照スケジュールの一致、再現手順を保存した。
