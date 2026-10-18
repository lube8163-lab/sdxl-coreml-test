# FLUX.3 CoreAI / 16・8・4ステップの比較

提出済みFLUX.2アプリと分離した検証。FLUX.3 Image Kleinの蒸留済み重みを
変更せず、同じ512×512 / CoreAI INT4 / BF16経路でステップ数を比較する。
既定値は16を保持し、実験起動時だけ `--steps=8` または `--steps=4` を指定する。

2026-10-18に全24枚＋暖機1回が完了。
送風開始前の同条件3組でモデル処理平均64.67 / 36.74 / 23.06秒。
[全画像・各回の値・冷却条件・検算](../../measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md)
を保存した。通常起動の既定値や提出済みアプリを変更する実験ではない。

## サンプリング

[公式Diffusers資料](https://huggingface.co/docs/diffusers/main/en/api/pipelines/flux3#step-distilled-model)
では蒸留版は4〜16ステップで学習されていると記載されている。
[BFLの参照実装](https://github.com/black-forest-labs/flux-3-image-klein/blob/main/src/flux3/sampling.py)
と同じ、`linspace(1,0,steps+1)` に alpha=6.93 の時間変換を適用する。
今回の4・8・16では、元の17点から等間隔に取り出した値が参照式とビット単位で一致する。
`prepare_step_fixtures.py` でPyTorchによる一致を必須にしている。

全実行は時刻1から0まで生成する。16ステップの途中で停止する比較ではない。
current_t / target_tの双方を各ステップへ渡し、文章条件も選択した時刻の組で事前計算する。
量子化済みのモデル、グループ結合、画像入力の切り出しは前回と共通。

## 比較条件

- 物理iPhone17、Releaseビルド、`--precompute-text`、Groups8 / shared4保持 / cache0。
- 静物、位置・形、材質、看板の文字の4題材。各seed42 / 1234、各16 / 8 / 4ステップで24枚。
- 題材・seedごとに初期ノイズとトークン列を固定。文章のパディングを含め160トークン。
- ステップの実行順を題材・seedごとに回転し、実行間は20秒休止。
- 最初の16ステップ暖機は集計から除外し、過去の同条件PNGと完全一致を要求する。
- 全結果を保持する。熱状態serious / criticalを含まないステップの実行は別集計する。
- 速度差の主比較は、三つのステップ条件がすべてserious / criticalを含まない同じ題材・seedの組で行う。
- 原文・長文キャプションの入力ポリシーと、保存前の六視点安全性チェックを全回に適用する。

## 再現

[README](README.md)と[PERFORMANCE.md](PERFORMANCE.md)でモデル、Groups8、SplitInput、
検証アプリを準備する。このフォルダの最新 `GenerationProbe.swift` を使ってReleaseでビルドする。
`PYTHON` はREADME記載のPyTorch / tokenizers / NumPyを含む環境、`WORK` は新しい作業領域。

```sh
"$PYTHON" Experiments/Flux3CoreAI/prepare_step_fixtures.py \
  --plan "$BF16_ASSETS/model-plan.json" \
  --tokenizer "$CONVERSION_WORK/tokenizer/tokenizer.json" \
  --output "$WORK/fixtures"
xcrun devicectl device copy to --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier com.tasuku.sdxlcoremltest.flux3generationprobe \
  --source "$WORK/fixtures" --destination Documents/Flux3Fixtures
python3 Experiments/Flux3CoreAI/run_step_comparison.py \
  --device "$DEVICE" --fixtures "$WORK/fixtures" --output "$WORK/runs" \
  --label-prefix stepcompare-unique-id \
  --baseline /absolute/path/to/previous-16-step/report.json
python3 Experiments/Flux3CoreAI/analyze_step_comparison.py "$WORK/runs" \
  --output "$WORK/analysis"
```

`--fixture-profile=still-life-seed42` のように、転送したハッシュ付き固定入力を選択する。
任意プロンプトの対話入力や、任意解像度への対応ではない。
中断した比較は同じ条件・出力先で `--resume` を指定できる。完了済みの実行は再利用し、
エラー時は自動でモデルや安全性の設定を弱めず停止する。

## 計測と画質の読み方

モデル処理時間はQwen、文章条件の事前計算、DiT、VAEの壁時計時間の合計。
`run_to_saved_seconds` はアプリ内の検証開始からPNG保存までで、アセット全体のSHA照合と
安全性確認も含む。OSによる起動前の時間や画面表示までを測る値ではない。
今回から入力ポリシー、安全モデルの準備、生成後の六視点判定を個別に記録する。
メモリは50msを要求したプロセスのphys_footprintサンプル最大値。

16ステップ画像とのMAE / PSNR / SSIMは変化の大きさであり、品質維持率や好みの点数ではない。
画像を並べ、個数・形と位置、材質と輪郭、文字の正確さ、余分な物体の有無を目視する。
小規模な固定キャプションの比較から、一般的な品質や速度は保証しない。

今回の生PNG名には旧プローブの `seed42` 表記が残る。実際のseedは各実行フォルダ名、
ハッシュ照合した入力fixture、`report.json` の `seed` を正とする。比較・集計スクリプトは
ファイル名からseedを推定せず、レポートと固定入力の契約を照合する。
