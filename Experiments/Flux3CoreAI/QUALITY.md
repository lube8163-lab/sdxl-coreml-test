# FLUX.3 の重み量子化比較

2026-10-18 の追加実験。iPhone の実行速度とは分けて、Windows の Tesla V100
32GB で元の BF16 チェックポイントと、実際の CoreAI INT4 重みを比較した。
全24枚が生成と六視点の安全性確認を通過した。
[比較画像・各条件の数値・生レポート](../../measurements/2026-10-18/flux3-quantization-quality/README.md)
を保存している。

元画像に対する8組ずつの平均 SSIM は DiT INT4 が0.8653、Qwen＋DiT INT4 が0.8453。
静物・材質の見た目は保たれたが、看板の改行や建物の配置などには差が見える。
SSIM は画像の一致度の指標で、品質維持率ではない。小標本のため一般的な画質の優劣は断定しない。

## 比較条件

| 条件 | DiT の Linear | Qwen の Linear |
| --- | --- | --- |
| `original` | 元の BF16 重み | 元の BF16 重み |
| `dit-int4` | CoreAI から抽出した INT4 | 元の BF16 重み |
| `all-int4` | CoreAI から抽出した INT4 | CoreAI から抽出した INT4 |

全条件の演算・活性値は FP32。512×512、16ステップ、CFGなし、固定の長文
キャプション4種類（静物、位置関係、材質、看板の文字）、seed 42 / 1234 の計24枚。
同じ seed の初期ノイズとサンプラーを揃える。VAE と非量子化部分は全条件共通。
参照画像専用の独立した枝だけを省いた、既存の全幅 text-to-image 実装を使う。

ここで測るのは**重みを量子化したことによる画像の差**。iPhone の BF16 / FP16
活性値、CoreAI の融合演算、実行機器ごとの丸めをそのまま再現する実験ではない。
INT4 重みは一度 FP32 に展開して使うため、V100 上の時間は INT4 高速化の値ではない。
画素 MAE・PSNR・SSIM・潜在の相対 RMSE は対応する元画像からの距離であり、
「品質を何%維持したか」や人間の好みのスコアには換算しない。

## 実際の INT4 を使う方法

`extract_quantized_weights.py` は検証済み `.aimodel` の
`coreai.blockwise_shift_scale` から packed signed INT4 と FP16 scale を取り出す。
group size 32、入力列方向、下位ニブルからの順序を記録し、zero shift / bias も
ゼロであることを検証する。別の量子化器で元の重みを量子化し直してはいない。

70部品、452行列。DiT は BF16 昇格グラフと同じ scale / product の BF16 丸め、
Qwen は元グラフと同じ FP16 丸めを CPU で反映し、その有効重みを FP32 に展開する。
正規化などの非量子化パラメータは比較中の全条件で元の重みから FP32 に揃える。
したがって、抽出した Linear 重みと端末上の全計算経路の一致は区別する。

形式・マッピングの検証:

- 実 shared_00 一層: 抽出から再構成した FP16 PyTorch 出力は、保存した CoreAI-opt
  PyTorch 出力と完全一致（相対 RMSE / 最大誤差とも0）。
- 実 Qwen 一層: 全7行列を使った再構成と CoreAI 出力の相対 RMSE は約0.000405。

どちらも合成活性値による一層の数値検証で、画像品質の合否には使わない。

## 再現手順

元のアセット生成、固定リビジョン、チェックポイント全体の SHA-256、ライセンスは
[README](README.md) と [model-spec.json](model-spec.json) を参照する。
以下の `WORK` はその変換作業領域、`BF16_ASSETS` は最終 BF16 DiT / FP16 Qwen の
アセット領域、`QUALITY` は新しい比較用領域。CoreAI の私有 MLIR API を使用するため、
README の変換環境のバージョンに依存する。

```sh
mkdir -p "$QUALITY/quantized-weights"
for receipt in "$BF16_ASSETS"/{image,text,shared,te}_*.json; do
  component=$(basename "$receipt" .json)
  "$PYTHON" Experiments/Flux3CoreAI/extract_quantized_weights.py "$component" \
    --source-root "$BF16_ASSETS" --output-root "$QUALITY/quantized-weights"
done
"$PYTHON" Experiments/Flux3CoreAI/validate_extracted_weights.py \
  --work "$WORK" --quant-root "$QUALITY/quantized-weights" \
  --output "$QUALITY/extracted-weights-validation.json"
"$PYTHON" Experiments/Flux3CoreAI/validate_extracted_text.py \
  --source-root "$BF16_ASSETS" --quant-root "$QUALITY/quantized-weights" \
  --output "$QUALITY/extracted-text-validation.json"
```

Windows では既存環境を変更せず、新しい作業フォルダと venv を作る。実測環境は
CPython 3.11.17、PyTorch 2.8.0+cu126、NumPy 2.2.6、safetensors 0.6.2、
Pillow 11.3.0、tokenizers 0.22.1。次はその venv での PowerShell 例。

```powershell
python -m venv D:/Codex/flux3-quality/.venv-v100
$python = 'D:/Codex/flux3-quality/.venv-v100/Scripts/python.exe'
& $python -m pip install torch==2.8.0 --index-url https://download.pytorch.org/whl/cu126
& $python -m pip install numpy==2.2.6 safetensors==0.6.2 pillow==11.3.0 tokenizers==0.22.1
```

この作業では公式 uv の管理 Python と `uv pip --python` を使った。上の pip 手順も
同じパッケージを隔離して入れるための例で、Windows 全体の Python やドライバは変更しない。
`nvidia-smi` と CUDA の GPU 番号は一致するとは限らない。ワーカーは V100 の UUID を
使い、実際の CUDA capability が7.0であることを実行前に確認する。

Windows 作業ルートに次を配置する（SSH / SFTP の接続準備は利用者の環境に合わせる）。

- `scripts/`: このフォルダの Python ファイル、`model-spec.json`、`quality-cases.json`。
- `reference/`、`tokenizer/`、`fixture/`、`model-plan.json`: 検証済み変換作業の同名データ。
- `quantized-weights/`: 上記で抽出したファイルと JSON。約4.44GB。
- `weights/`: `fetch_weights_parallel.py` で取得・全体 SHA-256 検証した元の3ファイル。
  DiT 約11.10GB、Qwen 約8.88GB、VAE 約0.34GB。

```powershell
$root = 'D:/Codex/flux3-quality'
& $python "$root/scripts/fetch_weights_parallel.py" dit --output "$root/weights" --workers 8
& $python "$root/scripts/fetch_weights_parallel.py" text --output "$root/weights" --workers 8
& $python "$root/scripts/fetch_weights_parallel.py" vae --output "$root/weights" --workers 8
& $python "$root/scripts/verify_quality_inputs.py" --work $root
```

`validate_extracted_weights.py` の基準データは、README の実ブロック検証で作る
`block-smoke` を使用する。大容量の重みや抽出ファイルを Git に含めない。

## 安全性確認と結果回収

Mac の `SafetyGate` は既存の入力ポリシーと `ImageSafetyChecker` を再利用する。
原文・長文キャプションの両方を確認してから Windows ワーカーを起動する。
Windows は潜在テンソルと数値だけを保存し、画像はメモリ中で PNG 化して SSH へ
ストリームする。Mac は六視点すべてのチェックを通過した PNG だけを保存する。
base64 画像データを進捗ログには出力しない。判定不能・失敗は保存しない。

```sh
swift build -c release --package-path Experiments/Flux3CoreAI/SafetyGate
export GATE="$PWD/Experiments/Flux3CoreAI/SafetyGate/.build/release/flux3-safety-gate"
python3 Experiments/Flux3CoreAI/run_cuda_quality.py \
  --host YOUR_SSH_ALIAS --remote-root D:/Codex/flux3-quality \
  --gate "$GATE" --classifier /absolute/path/to/ImageSafetyClassifier.mlmodelc \
  --cases Experiments/Flux3CoreAI/quality-cases.json --output "$QUALITY/run1"
"$PYTHON" Experiments/Flux3CoreAI/analyze_quality.py "$QUALITY/run1" \
  --cases Experiments/Flux3CoreAI/quality-cases.json
```

Mac の出力先には新しいパスを指定する。リモートは契約 JSON と潜在ファイルのハッシュを
確認して同条件の完了サンプルを再利用できる。条件や重みを変える場合はリモート側も
新しい作業ルートを使う。`summary.json` が存在し、24件の結果と安全性の receipt が
揃ったことを確認する。`analyze_quality.py` は保存画像の SHA と六視点スコアを再確認し、
seed ごとの比較シートと距離の表を作る。SSIM は一様7×7窓・不偏共分散・有効領域平均。

安全性チェックを通過したことと、モデル全体の安全性や画像品質の評価は別である。
少数の固定キャプションなので、人物、複雑な手、長文文字、任意のプロンプトへの一般化は
この比較からは判断しない。

## ネイティブCoreAIでのステップ数比較

別実験として、同じ4題材・2 seedをiPhone17上のCoreAI INT4 / BF16経路で
16 / 8 / 4ステップずつ生成した。全24枚が六視点判定と保存を完了した。
4でも主要な内容と看板の綴りは保たれたが、材質の視点や看板の改行が変化する例がある。
これは元重みとの比較ではなく、同じ量子化済みモデルのステップ数の比較である。
[実機の全比較画像と測定条件](../../measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md)、
[再現手順](STEP_COUNT.md)を参照。
