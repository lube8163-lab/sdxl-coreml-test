# FLUX 3 Image Klein / CoreAI INT4 実機検証

提出済みの FLUX.2 アプリと分離した、固定プロンプトの text-to-image 検証です。
実チェックポイントから変換した Qwen3-VL、DiT、VAE を iPhone 上で実行します。
画像参照・画像編集、任意解像度、対話的なプロンプト入力は実装していません。

2026-10-17、物理 iPhone 17 / iOS 27.0.1 の Release 検証アプリで、
**実チェックポイントからの画像生成、六視点の安全性確認、PNG 保存まで成功しました**。
赤いリンゴ・青いマグ・木の机・窓からの光が描かれていることを、保存画像でも確認しました。

| 条件・計測 | 結果 |
| --- | ---: |
| 画像・サンプリング | 512 × 512、16 ステップ、seed 42 |
| Qwen3-VL | 4.35 s |
| DiT の16ステップ | 117.88 s |
| VAE | 5.19 s |
| 上記3段階の合計 | 127.42 s |
| 起動から安全性確認済み PNG 保存 | 約137 s |
| アプリの `phys_footprint` サンプル最大 | 1,117,047,128 bytes（約1.12 GB） |
| メモリ計測の実際の最大間隔 | 約53 ms（要求50 ms） |
| モデル容量 | 5,790,189,767 bytes |

初めて完走した BF16 DiT 経路の計測で、読み込み・特殊化を含みます。
文章側のアセットは先行する切り分け実行でも使用しており、全処理の完全なコールド
ベンチマークではありません。GPU を優先し、CoreAI のフォールバックを許可しています。
一枚・一プロンプトの成功であり、非量子化モデルとの画質差や多様な条件の品質・速度は
この初回の計測には含みません。追加比較は下記に分けて記録しています。
サンプル最大メモリは瞬間ピークや端末全体の消費量とは異なります。

[実機レポートとハッシュ付きアセット一覧](../../measurements/2026-10-17/flux3-coreai-full/summary.json)
に加えて、同じフォルダに元の `report.json`、`memory.csv`、数値検証と生成 PNG を保存しています。

![iPhone 17で生成して安全性確認を通過した画像](../../measurements/2026-10-17/flux3-coreai-full/flux3-512-seed42-approved.png)

## 速度改善の追試

グラフを結合し、統合側の関数を保持する経路を追加しました。物理 iPhone 17 の
同一ビルド比較で、DiT 16ステップは89.28秒→69.77秒（約21.8%短縮）、
Qwen＋DiT＋VAEは94.60秒→75.45秒。サンプル最大メモリは約1.159GB→1.652GBです。
採用設定の先行実行も70.45秒で完走し、全条件でPNGが元画像と一致しました。
上の表は初回完走時の記録です。OS側キャッシュや初回準備の条件が異なるため、
その差をすべて変更の効果とは扱いません。

[全条件と再現手順](PERFORMANCE.md)、[実機ログと来歴](../../measurements/2026-10-17/flux3-coreai-performance/README.md)
を保存しています。配置済みの `Groups8` を通常起動で自動選択する実験用アプリへの変更です。

## 追加の高速化と元の重みとの比較（2026-10-18）

物理 iPhone 14 / iOS27.2 でも画像生成・六視点判定・PNG保存が完走しました。
文章条件を各ステップの時刻で先に計算して大きな関数を解放する経路を追加し、
暖機後に同一ビルドで各2回比較したモデル処理合計は、平均336.44秒→275.55秒
（約18.1%短縮）。事前計算の時間も含めています。サンプル最大メモリの平均は
約1.547GB→1.172GB。全5回のPNGはハッシュまで一致しました。
新経路は `--precompute-text` で明示指定する実験用の選択肢です。
[各回の値・ソース・生ログ](../../measurements/2026-10-18/flux3-coreai-precompute-iphone14/README.md)を保存しました。
その後、iPhone 17 / iOS27.0.1 でも追試しました。同じ熱状態（fair）の従来1回は
98.76秒、新経路2回の平均は68.46秒（67.75〜69.16秒）。事前計算込みで約30.7%短縮、
サンプル最大メモリは約1.606GB→平均1.183GBでした。熱状態seriousを含む追加の従来実行は
比較平均から除き、生ログは保持しています。全6回のPNGは以前のiPhone17の画像とも一致。
起動時のSHA照合によるwatchdog終了も修正しました。
[iPhone17の全条件・熱状態・修正内容](../../measurements/2026-10-18/flux3-coreai-precompute-iphone17/README.md)
を記録しています。少数の固定条件の比較であり、一般的な短縮率とは扱いません。

Windows の V100 32GB では、元の重み・DiT INT4・Qwen＋DiT INT4 の3条件で
4題材×2 seed、計24枚を生成しました。主要な内容や材質は保たれる一方、円すいの先端、
看板の改行、建物の配置などには差が見えました。全条件を FP32 演算に揃えた
重みの比較で、端末の BF16 / FP16 全経路や INT4 の実行速度の再現ではありません。
[比較画像と距離の集計](../../measurements/2026-10-18/flux3-quantization-quality/README.md)、
[抽出方法と再現手順](QUALITY.md)に条件と限界を記録しています。

## 16・8・4ステップの実機比較（2026-10-18）

同じCoreAI INT4モデルで4題材×2 seed×3条件、計24枚をiPhone17で生成した。
暖機を含む全25回で六視点の安全判定とPNG保存まで成功。送風開始前の熱条件を
揃えた3組では、モデル処理の平均は16ステップ64.67秒、8ステップ36.74秒、
4ステップ23.06秒。4の安全確認・保存までの平均は26.71秒だった。
途中からユーザーが送風した4組は別集計し、4ステップのモデル処理平均22.63秒、
保存まで26.25秒。送風単独の効果を測る比較ではない。

主要な物体や指定した色・位置、看板の綴りは保たれた。一方、材質の別seedでは
8 / 4で視点が変化し、看板の一例では4で1行から2行へ変わった。
同一画質・構図の保証ではない。生成後の安全判定は24枚で平均約0.137秒。
実験起動時の `--steps=4/8/16` に対応し、通常の16ステップ既定値は維持する。
[全画像・生データと条件](../../measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md)、
[再現手順](STEP_COUNT.md)を参照。

## 変換対象

- BFL の蒸留済み FLUX 3 Image Klein、512 × 512、16 ステップ、CFG なし。
- 重い DiT / Qwen の Linear 重み: CoreAI INT4、対称量子化、group size 32。
- DiT の活性値と計算: BF16。既存の FP32 正規化・回転位置埋め込み計算は FP32 を保持。
- DiT の未圧縮定数の保存形式、Qwen の埋め込み・正規化、VAE: FP16。
- Qwen3-VL の 4・8・12・16・20・24・28・32 層の出力を連結。
- 画像参照専用の独立した枝だけを除外。text-to-image の全層・全幅を保持。
- 75 個の `.aimodel`、合計 5,790,189,767 bytes（最終マニフェストを正とする）。

入力チェックと既存の六視点出力チェックを通過した画像だけを表示・保存します。
この検証における通過は、モデル全体の安全性評価やストア審査の完了を意味しません。

## 出典と再現条件

[BFL モデル](https://huggingface.co/black-forest-labs/flux-3-image-klein)、
[参照コード](https://github.com/black-forest-labs/flux-3-image-klein)、
[Apple CoreAI](https://github.com/apple/coreai-models) を使用します。
固定リビジョンと BF16 ファイルの完全な SHA-256 は `model-spec.json` にあります。
公開再配布先から取得した BF16 ファイルを丸ごと検証し、事前量子化モデルは使用しません。
重みの FLUX Kommunity License とコードの Apache-2.0 をそれぞれ確認してください。
この手順は実験用で、変換済み重みをこのリポジトリに含めません。

変換環境: arm64 Python 3.11、PyTorch 2.14.1、coreai-core 1.0.0b3、
coreai-torch 0.4.3、coreai-opt 0.3.0、safetensors、tokenizers 0.22.1。
coreai-torch が検証済みとする PyTorch の上限は 2.13.0 なので、
この組み合わせでは後述の数値検証と実機結果も合わせて確認します。
Xcode 27、iOS 27.0.1 SDK、XcodeGen と開発用署名も必要です。

大きなファイルはリポジトリの外に配置します。`PYTHON` は必要なパッケージが
入った Python、`WORK` は新しい作業ディレクトリを指定してください。
以下はリポジトリルートで実行します。

```sh
export PYTHON=/absolute/path/to/venv/bin/python
export WORK=/absolute/path/to/new-flux3-work
mkdir -p "$WORK"
"$PYTHON" Experiments/Flux3CoreAI/prepare_caption.py --work "$WORK"

"$PYTHON" Experiments/Flux3CoreAI/fetch_weights.py dit --output "$WORK/weights"
"$PYTHON" Experiments/Flux3CoreAI/convert_all.py dit --work "$WORK"
"$PYTHON" Experiments/Flux3CoreAI/validate_real_block.py --work "$WORK" --component shared_00

"$PYTHON" Experiments/Flux3CoreAI/fetch_weights.py text --output "$WORK/weights"
"$PYTHON" Experiments/Flux3CoreAI/convert_all.py text --work "$WORK"
"$PYTHON" Experiments/Flux3CoreAI/validate_text_math.py --work "$WORK"

"$PYTHON" Experiments/Flux3CoreAI/fetch_weights.py vae --output "$WORK/weights"
"$PYTHON" Experiments/Flux3CoreAI/convert_all.py vae --work "$WORK"
"$PYTHON" Experiments/Flux3CoreAI/finalize_assets.py --work "$WORK"

export BF16_ASSETS="$WORK/coreai-bf16"
"$PYTHON" Experiments/Flux3CoreAI/promote_all_dit.py --work "$WORK" --output-root "$BF16_ASSETS"
"$PYTHON" Experiments/Flux3CoreAI/finalize_assets.py --work "$WORK" --asset-root "$BF16_ASSETS"
```

同時に全 BF16 ソースを残す場合は約 21 GB、変換済みモデルが約 5.8 GB、
これに作業領域が必要です。変換は部品ごとの別プロセスで順次行います。
完了した部品は再利用するため、計算方法を変更した場合は新しい出力先を使います。

最初の FP16 全経路の実機試験では、文章の投影結果の一部が FP16 上限を超えました。
`promote_all_dit.py` は検証済みの既存 CoreAI グラフを読み、全定数をそのまま保持して
DiT の計算を BF16 に変更します。INT4 データの再量子化は行いません。
保存済み FP16 定数には明示的な BF16 cast を挿入し、非定数の FP16 計算と入出力を
BF16 に変更します。私有の attention / layer norm グラフも処理します。
変更前後の全定数の属性・型が一致することと MLIR の検証を必須にしています。
この処理は上記バージョンの CoreAI MLIR API に依存します。
元の FP16 アセットと BF16 の DiT アセットを両方残す場合は、追加で約 3.1 GB 必要です。
Qwen と VAE の未変更アセットは同一ボリューム内のハードリンクで共有します。

`prepare_caption.py` は固定の無害な長文キャプション、正確な Qwen チャット形式、
117 トークン＋パディング、seed 42 の初期ノイズ、16 ステップの時刻を保存します。
キャプションの展開とトークン化は事前処理です。端末側で LLM による文章の
再生成は行いません。画像用の全モデル推論は端末で実行します。

## 実機アプリ

```sh
"$PYTHON" Experiments/Flux3CoreAI/prepare_device_project.py \
  --output "$WORK/device-project" \
  --classifier /absolute/path/to/ImageSafetyClassifier.mlmodelc \
  --team YOURTEAMID
cd "$WORK/device-project"
xcodegen generate
xcodebuild -project Flux3GenerationProbe.xcodeproj -scheme Flux3GenerationProbe \
  -configuration Release -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath "$WORK/device-build" -allowProvisioningUpdates -jobs 2 build

xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  "$WORK/device-build/Build/Products/Release-iphoneos/Flux3GenerationProbe.app"
xcrun devicectl device copy to --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer \
  --domain-identifier com.tasuku.sdxlcoremltest.flux3generationprobe \
  --source "$BF16_ASSETS" --destination Documents/Flux3Models
xcrun devicectl device process launch --device YOUR_DEVICE_UDID --terminate-existing \
  com.tasuku.sdxlcoremltest.flux3generationprobe
```

モデルはアプリバンドルに埋め込まず Documents に転送します。
データコンテナの既存内容を削除するオプションは使用しないでください。
`Documents/Flux3Results/report.json` と `memory.csv` に進捗・結果が記録されます。
グループ未配置時は二つの未固定ブロックを保持し、DiT の小さい入出力部品を固定します。
追加の `Groups8/groups.json` がある場合は、結合した統合側28ブロックだけを保持する
高速化経路を自動選択します。`--individual` で元の個別部品による経路を比較できます。
変換・起動・計測方法は [速度改善の再現手順](PERFORMANCE.md) を参照してください。
`--resident` は全ブロックの保持を試す別条件で、通常の結果と混在させません。

## 数値検証と画像の区別

`validate_text_math.py` は HF transformers v4.57.1 の計算本体と共通の
ランダム重みで比較します。`validate_real_block.py` と端末の `--block-smoke` は
実重みの一ブロックを同じ INT4 PyTorch 計算と比較します。
どちらも画像品質の評価とは別です。
実画像の成功判定には 16 ステップ、VAE、安全性確認、保存された PNG の照合が必要です。

`validate_promoted_precision.py` では同じ定数を使った BF16 と FP32 の CoreAI 計算も
比較します。実機で取得した文章特徴の投影は相対 RMSE 約 0.17%、実重みの一統合
ブロックと合成活性値では約 0.51% でした。これも画像品質の差を表す値ではありません。
`--diagnose` 起動時は各部品の有限値・最小最大値を記録し、失敗した部品の入力テンソルを
`Documents/Flux3Diagnostics` に保持します。画像の画素データは診断用に保存しません。

メモリは 50 ms 間隔を要求した `phys_footprint` のサンプル最大値です。
実際のサンプル間隔の最大値も記録し、瞬間的なピークを保証しません。
初回のコンパイル・読み込みを含む時間と、暖機後の時間は区別します。
