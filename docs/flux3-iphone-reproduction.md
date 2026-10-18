# FLUX.3 Image KleinをiPhoneで試す

2026-10-18の開発版の再現手順です。[実装と検証範囲](flux3-ios-report.md)も参照してください。通常アプリを試す方法と、チェックポイントから変換する方法を分けています。

## 1. 開発用Previewで生成する

必要なものはXcode 27 / iOS 27.0.1 SDK、対応する物理iPhone、開発用署名、モデル取得用のネット接続です。今回の主アプリ統合の実機はiPhone 17（8GB、iOS 27.0.1）です。iPhone 14（6GB）の成功記録は固定入力の独立プローブで、新UI全操作の検証とは異なります。Simulatorは生成の対象外です。

モデル取得時は約13GB以上の空き容量を用意します。コンパイルキャッシュは条件で増えるため、余裕を持たせてください。FLUX.3の重みには[FLUX Kommunity License](https://huggingface.co/black-forest-labs/flux-3-image-klein/blob/main/LICENSE.md)が適用されます。

```sh
git clone https://github.com/lube8163-lab/sdxl-coreml-test.git
cd sdxl-coreml-test
# 実装と実機データを固定したコミット。
git checkout 85db0c97f2ae37f82ee69b3fdbeb4de588732361
python3 scripts/prepare_safety_assets.py
python3 scripts/prepare_model_preview.py \
  --destination /tmp/local-image-preview \
  --bundle-id com.example.localimage.preview
open /tmp/local-image-preview/SDXLCoreMLTest.xcodeproj
```

XcodeでTeamを自分のものに変更します。Bundle Identifierは上の例を自分の一意なものへ置き換えてください。`LocalImageGenerationDevice`スキームと実機を選び、Release構成でRunします。既存のインストールとデータを保護するため、`.preview`で終わる別IDを使います。生成用の重みはアプリへ埋め込みません。

CLIでビルドする場合も、自分の署名情報を使います。

```sh
xcodebuild -project /tmp/local-image-preview/SDXLCoreMLTest.xcodeproj \
  -scheme LocalImageGenerationDevice -configuration Release \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath /tmp/local-image-preview-build \
  DEVELOPMENT_TEAM=YOURTEAMID -allowProvisioningUpdates -jobs 2 build
```

アプリで案内を完了し、モデルの「変更」からFLUX.3 Image Kleinを選び、ダウンロードを開始します。25個の分割ファイルを取得し、全体のSHA-256と展開後144ファイルのサイズ・SHA-256を確認してから有効になります。一時停止・アプリ再起動後の再開に対応します。

生成画面では4 / 8 / 16ステップとseedを選べます。最初の生成は関数のコンパイル・特殊化で遅くなります。次の英語キャプションとseed 42は今回の通常アプリ検証で使った入力です。

```text
A watercolor painting of a red lighthouse standing on a grassy cliff above a calm blue sea. A small white sailboat is visible on the right. Warm afternoon sunlight comes from the left. Soft textured paper, delicate brush strokes, clear simple composition, no people, no text.
```

公式の推奨は、短い要求をLLMで十分な場面描写へ拡張してから渡す構成です。このPreviewには独立したプロンプト拡張LLMは含めていません。上のように被写体、配置、光、画材を記した完成キャプションを直接入力してください。Qwenの端末内テキスト符号化は毎回行います。チャット形式込み160トークンを超えると短縮を案内し、黙って切り詰めません。

出力は必須の六視点安全判定を通過後に表示されます。拒否やキャンセルの場合は以前の確認済み画像を維持します。判定を無効化する手順は設けていません。

## 2. 固定条件で時間と画像を比べる

通常アプリの表示時間を、新規インストール後、キャッシュ作成後、別入力、同じ入力・seedの再生成に分けます。端末・OS・熱状態・充電・冷却・実行順と、初期準備を計測区間へ含めたかを記録してください。

固定入力の実験は[STEP_COUNT.md](../Experiments/Flux3CoreAI/STEP_COUNT.md)にあります。4題材×2 seedで初期ノイズを固定し、4 / 8 / 16の全条件を時刻1→0まで進めます。モデル処理合計、アセット照合を含む検証開始からPNG保存、六視点判定を別々に集計します。

通常アプリの検証でXCTestの初期化が失敗したため、記録の一部では起動ドライバから実際のセットアップと生成メソッドを呼びました。[検証範囲](../measurements/2026-10-18/flux3-app-model-selection/README.md)と[専用コピーの作成方法](flux3-app-integration.md)を参照してください。通常Previewへドライバは入りません。公開した画像・測定ログは既存の実測で、資料整理時に別の人の端末で全推論を再実行したという意味ではありません。

## 3. BF16チェックポイントから変換する

主アプリを試すだけならPythonによる変換は不要です。変換を追試する場合は[実験README](../Experiments/Flux3CoreAI/README.md)のバージョンを固定し、次の順で進めます。

1. [model-spec.json](../Experiments/Flux3CoreAI/model-spec.json)のリビジョン・ファイルサイズ・SHA-256で、DiT、Qwen、VAEを取得・検証する。
2. `convert_all.py`で部品ごとに変換し、`validate_real_block.py` / `validate_text_math.py`で数値を確認する。
3. `promote_all_dit.py`でDiTの計算をBF16へ変更する。初期のFP16全経路は投影値のオーバーフローで失敗したため、そのまま使わない。INT4 packed weightsの再量子化は行わない。
4. [PERFORMANCE.md](../Experiments/Flux3CoreAI/PERFORMANCE.md)の`compose_all_blocks.py`でGroups8を作り、数値検証する。`slice_image_input.py`で画像入力側だけの投影を切り出し、検証する。
5. 固定プローブを追試する場合は実験READMEのアプリとfixtureを使う。主アプリ向けの配布物にする場合は、下記のパッケージ手順へ進む。

変換実測はarm64 Python 3.11、PyTorch 2.14.1、coreai-core 1.0.0b3、coreai-torch 0.4.3、coreai-opt 0.3.0、tokenizers 0.22.1です。PyTorchは当該coreai-torchの検証済み上限2.13.0を超えていたため、数値検証と実機結果を併記しています。CoreAIの私有MLIR authoring APIを使う変換処理があり、バージョンを変えた場合の再検証が必要です。Swiftの端末実行はSDKのCoreAI APIを使用します。

元のBF16ソースを同時に残すと約21GB、変換済みモデル約5.8GBに加え、中間ファイルとグループ結合分の領域が必要です。大きな重みはGit管理外の作業フォルダへ保存し、8GB Macでは部品を別プロセスで順次変換します。

## 4. 配布パッケージを再構成する

[package_flux3_model.py](../scripts/package_flux3_model.py)の`--help`を参照し、変換済みのモデル、Groups8、SplitInput、tokenizer、原文ライセンスを用意します。公開済みパッケージと同じ44アセット・構成であることをカタログと照合してください。

```sh
python3 scripts/package_flux3_model.py --help
```

スクリプトは重複する結合前DiTを省き、ZIP64を200MBの分割ファイルへ直接書きます。配布リビジョンは`coreai-flux3-512-int4-dd2ae0a-v1`、アーカイブSHA-256は`15608f44e7e41c0d1e3aafbb972de7a973986aed58d462a340c33b2afdb99638`です。[固定ダウンロード一覧](../measurements/2026-10-18/flux3-app-model-selection/flux3-download-manifest.json)と[全ファイルのカタログ](../measurements/2026-10-18/flux3-app-model-selection/flux3-catalog-manifest.json)も保存しています。

重みの再配布・商用利用には原モデルの条件が適用されます。既存の配布先へのアップロード権限は必要ありません。自分で配布するときは、自分の配布先と新しい不変リビジョンを使い、公開済みバイト列を上書きしないでください。

## 5. 量子化前後をWindows GPUで比較する

[QUALITY.md](../Experiments/Flux3CoreAI/QUALITY.md)に、CoreAIから実際のpacked INT4重みとscaleを抽出し、V100で同じFP32演算へ揃える手順があります。再量子化した別の4bitモデルへの置き換えではありません。

比較は元のBF16由来重み / DiT INT4 / Qwen＋DiT INT4、4題材×2 seed、512×512、16ステップです。V100 32GBでの最大CUDA allocatedは約20.06GBでした。iPhoneのBF16 / FP16演算、融合処理、速度、メモリの再現試験ではありません。SSIM等は画像の距離であり、品質維持率として読み替えないでください。

## 6. ライセンスと報告時の表記

原モデルはFLUX Kommunity License、Qwen3-VLと参照コード等はそれぞれのApache-2.0条項です。[THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)とパッケージ内の原文を参照してください。公式iPhone版、BFL / Appleによる推奨、スマートフォン初・最速という表現は使いません。

公開する追加結果には、固定コミット、モデルのカタログハッシュ、端末・OS、入力全文・seed・ステップ数、初回/準備済みの区別、計測区間と熱条件を添えると比較しやすくなります。端末識別子、認証情報、他アプリの画面を含むログは取り除いてください。
