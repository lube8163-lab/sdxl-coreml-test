# FLUX.2をiPhoneで再現するための手順

[実装とBonsai比較をまとめたZenn記事](https://zenn.dev/lube8163/articles/e24eda10d2a9be)

更新日: 2026-10-16。対象は、このリポジトリの4bit / CoreAI / 512×512 / 4ステップ構成です。既存のBlack Forest Labsモデル、dushandz氏の変換資産、Appleのランタイムを利用したアプリ統合と実機検証の記録です。

## 何を再現するか

- **現在のアプリを動かす**: 通常の署名済みアプリをビルドし、アプリ内でモデルをダウンロードします。
- **セットアップの記録を取る**: 別の開発用コピーで本番のダウンロード・インストール・生成処理を呼び、レポートを取得します。
- **過去の速度を調べる**: 保存済みCSV/JSONと、その測定時のソースハッシュを読みます。現在のソースで同じ秒数が再現する保証ではありません。

アプリ1.1（6）のソース基準は [`041bb51ed417ea6b4f4112df4cd547f8e8126f25`](https://github.com/lube8163-lab/sdxl-coreml-test/tree/041bb51ed417ea6b4f4112df4cd547f8e8126f25) です。その後のこの記事向け更新は資料の整理です。10月14日の速度測定は、当時の検証用コピーと以前の安全判定を使っています。10月15日に全6領域それぞれの安全判定を必須にしたため、iPhone 17の約11秒を現行ビルドの再測定値として扱わないでください。

## 必要なもの

- Xcode 27とCoreAIを利用できるSDKを備えたMac。プロジェクトのiOS最小バージョンは27.0.1です。
- 実機iPhoneと開発署名。生成の実測機はiPhone 17 / A19 / 8GB / iOS 27.0.1、iPhone 14 / A15 / 6GB / iOS 27.2です。SimulatorではCoreAI画像生成を実行しません。
- Python 3.8以降、Git。小さな安全モデルの準備スクリプトはPython標準ライブラリを使用します。Swift Package依存はXcodeで解決します。
- 初回ダウンロード約3.54GB、展開済みモデル約4.04GB。実行用キャッシュもあるため、アプリ側は初期の空き容量を約9GB確認します。Macのビルド領域は別途必要です。

6GB端末の対応判定は報告物理メモリ5,500,000,000バイト以上です。4GB端末は対象外です。Extended Virtual Addressingは仮想アドレス空間の設定で、物理RAMを増やす機能ではありません。対応条件の全端末・全OSを試したものではありません。

## 1. ソースと必須の安全モデルを用意する

```sh
git clone https://github.com/lube8163-lab/sdxl-coreml-test.git
cd sdxl-coreml-test
git checkout 041bb51ed417ea6b4f4112df4cd547f8e8126f25
python3 scripts/prepare_safety_assets.py
open SDXLCoreMLTest.xcodeproj
```

安全モデルは固定リビジョンから取得し、ファイルサイズとSHA-256を確認します。欠落・改変した安全モデルのまま本番ビルドを通す手順はありません。

Xcodeで `SDXLCoreMLTest` スキームを選び、Signing & CapabilitiesのTeamとBundle Identifierを自分のものに変更して、接続したiPhoneへRunしてください。署名後のアプリには `com.apple.developer.kernel.extended-virtual-addressing` が必要です。ストアへの提出や配布の承認を意味する手順ではありません。

コマンドでビルドする場合の例です。`YOUR_DEVICE_ID`、`YOUR_TEAM_ID`、`com.example.flux2local` は自分の値へ変更します。

```sh
xcodebuild -project SDXLCoreMLTest.xcodeproj \
  -scheme SDXLCoreMLTest -configuration Release -jobs 2 \
  -destination 'id=YOUR_DEVICE_ID' \
  -derivedDataPath /tmp/flux2-local-build \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.flux2local \
  -allowProvisioningUpdates build
```

通常ビルドは生成モデルをバンドルしません。`LOCAL_FLUX_EMBED_MODELS=YES` は既存の実験用コピー向けであり、通常のアプリ再現には使いません。

## 2. アプリ内でモデルを準備する

1. オンボーディングと初回ダウンロードの説明を読み、Wi-Fiでダウンロードします。携帯回線は明示的に選択した場合だけです。
2. 全体のSHA-256と17ファイルのサイズ・SHA-256を確認した後で、モデルを有効化します。途中で止めた場合は受信済みデータを利用して再開できます。
3. 初回準備・生成はアプリを開いたまま待ちます。初回のCoreAIコンパイルは、以後の生成より長くなることがあります。
4. 静物などの入力例を選び、生成します。入力検査と出力検査を通った画像だけが表示・写真保存・共有へ進みます。

配布元はアプリに固定された公開Cloudflare配信先です。URL、18分割のサイズ・ハッシュは [`flux2-download-manifest.json`](../Vendor/LocalImageGeneration/Sources/LocalImageGeneration/Resources/flux2-download-manifest.json)、展開先17ファイルは [`flux2-catalog-manifest.json`](../Vendor/LocalImageGeneration/Sources/LocalImageGeneration/Resources/flux2-catalog-manifest.json) で確認できます。2026-10-16の確認では、先頭分割ファイルへの1バイトのRange GETは206と期待したContent-Rangeを返しました（全体の再ダウンロードではありません）。HEADは403となったため、HEADだけで配信停止と判断しないでください。将来の配信継続は保証されません。取得できない場合は固定ハッシュに一致する正規の資産が必要で、チェックを無効にして別モデルを流用するものではありません。

再現対象の資産リビジョンは `coreai-512-4bit-a7f65cd-v1`、配布ZIPのSHA-256は `9eee2a1226677c396c165b7204d912a3c1d785fd89aa8b7b22b7aa7ac3af3968` です。元の変換資産は [dushandz / a7f65cd](https://huggingface.co/dushandz/FLUX.2-klein-4B-CoreAI/tree/a7f65cdd6b2c8e2616dab3887efd0ae6ce983e44)。512px用の単一関数へ整理した派生物なので、元リポジトリをそのままコピーするだけではこの17ファイルのハッシュと一致しません。通常の再現はアプリ内配布を使います。

## 3. 取得済みデータを読む

| 資料 | 何が入っているか |
| --- | --- |
| [iPhone 17の測定CSV](../measurements/2026-10-14/iphone17-measurements.csv) / [詳細JSON](../measurements/2026-10-14/iphone17-device-validation.json) | 準備後・再生成・変更プロンプト・アイドル後・全解放後の測定。ソースハッシュと失敗例も保持 |
| [iPhone 14の再検証](../measurements/2026-10-14/iphone14-retest/README.md) | 読み込み失敗3条件と、生成できた条件、メモリCSV、実機画像 |
| [Bonsai / iPhone 14](../measurements/2026-10-14/bonsai-iphone14/README.md) | Binary・Ternaryの結果・設定・実時間動画 |
| [Bonsai / iPhone 17](../measurements/2026-10-14/bonsai-iphone17/README.md) | 14.3秒を含む5結果。入力文の差と記録の限界 |
| [現行ルールの検証](../measurements/2026-10-15/release-readiness/README.md) | 4入力例の生成、安全判定の反例修正、写真保存・権限・実OSバックグラウンド復帰 |
| [共通条件の候補](../Experiments/FluxMemoryRetest/fixtures.json) | プロンプト4種×シード3種の今後の比較用定義。全条件をBonsaiと実行済みという意味ではない |

10月14日のiPhone 17は初期準備3.95 / 5.69秒と、生成13.97 / 14.34秒を分離しています。再生成10.98 / 11.36秒は同じプロンプトを準備済みの条件です。初回ダウンロード、初めてのコンパイル、任意の入力に対するボタンから表示までの時間として使わないでください。

Bonsaiの結果は市販アプリ自身の時間表示です。128pxのVAEタイルを観察しましたが、内部の計測境界・安全判定・メモリを同じ方法で測ったわけではありません。iPhone 17の24.2秒・14.3秒の画像で確認できる入力は `soft light`、こちらの基準入力は `soft window light` です。文章まで一致した対照比較として扱わないでください。

## 4. セットアップを自動記録する開発コピー

通常のアプリとは別の新しいディレクトリへ作成します。既存の作業領域は上書きしません。このドライバは本番処理を呼ぶ開発用コードであり、XCTestで画面をタップした検証ではありません。実行すると約3.54GBのモデルダウンロードと生成を開始します。

```sh
python3 scripts/prepare_setup_probe.py --destination /tmp/flux2-setup-probe
xcodebuild -project /tmp/flux2-setup-probe/SDXLCoreMLTest.xcodeproj \
  -scheme SDXLCoreMLTest -configuration Release -jobs 2 \
  -destination 'id=YOUR_DEVICE_ID' -derivedDataPath /tmp/flux2-setup-build \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.flux2probe \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  /tmp/flux2-setup-build/Build/Products/Release-iphoneos/SDXLCoreMLTest.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID \
  com.example.flux2probe --setup-validation
xcrun devicectl device copy from --device YOUR_DEVICE_ID \
  --domain-type appDataContainer --domain-identifier com.example.flux2probe \
  --source Documents/FirstDownloadValidation \
  --destination /tmp/flux2-setup-evidence
```

末尾の取得は検証が完了してから実行します。`report.json`、安全確認済み画像、メモリCSVを読み、途中失敗も成功へ書き換えず残してください。独立したBundle Identifierなので、元のアプリのモデルを共有せず、ストレージを別途使います。ビルド時にBundle Identifierを上書きした場合は、生成されたprovenanceのデフォルト値と区別して、実際の署名・起動に使った値も記録してください。

**アプリの保存領域で `devicectl device copy to --remove-existing-content true` を使わないでください。** 今回のXcode/iOSでは入れ子の保存先を指定してもアプリ保存領域が初期化された事例がありました。証拠の取得には上の `copy from` を使い、既存のインストールや写真を削除する再現手順はありません。

## 5. 新しく比較する場合の記録項目

端末/OS、アプリのバージョン、モデル、入力文の全文、解像度、ステップ、実際のシード、シード固定、VAEタイル、電源/熱状態、録画の有無を記録します。準備・初回コンパイル・生成・安全判定・保存を分け、利用体験の比較ではボタンから結果表示までの壁時計時間も併記します。

各アプリの新規起動、準備済みの反復、入力変更後を区別します。順番を交互にし、複数回実行して全結果を保存します。安全機能は各アプリの通常設定で有効にし、拒否も結果へ含めます。同じ整数シードでも、異なる乱数実装では同じノイズになりません。

画質はモデル名を伏せ、対象物、個数、色、位置関係、文字、自然さなどを複数入力・複数シードで評価します。今回の静物1種中心の記録から一般的な品質順位は出していません。FP16に対するBonsai公式スコアを、この4bit/CoreAI実装のスコアへ読み替えることもできません。

メモリの `phys_footprint`、RSS、Metal allocationは重複するので足しません。Bonsaiの公式平均値と、このアプリのサンプル最大値を同じ指標として比較しないでください。

## 帰属と公開範囲

原モデルは [Black Forest Labs](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)、変換資産は [dushandz](https://huggingface.co/dushandz/FLUX.2-klein-4B-CoreAI)、ランタイムは [Apple CoreAI](https://github.com/apple/coreai-models)、安全モデル変換は [InspiratioNULL](https://huggingface.co/InspiratioNULL/image-safety-classifier-s-CoreML) に基づきます。詳細は [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) を参照してください。

モデル重み、秘密情報、端末識別子や無関係な画面を含む生ログ、危険な分類テスト画像はGitHubへ含めていません。公開済みの生成例は合成された検証用コンテンツです。別の人のMac・iPhoneでの全推論再実行は、この資料整備では行っていません。
