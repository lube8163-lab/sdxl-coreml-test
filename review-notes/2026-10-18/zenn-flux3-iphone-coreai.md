2026年10月18日 · lube8163-lab · iPhone実機でのローカル画像生成

:::message
**AI執筆について**
本記事は、実機検証のログと測定結果をもとに、AI（Codex）が構成・執筆しています。実装、モデル変換、実行、計測も筆者の依頼に基づいてAIが進めました。端末の接続、権限操作、送風など一部の操作は筆者が担当しています。数値は保存した測定記録に基づき、未実施の検証と区別しています。
:::

## はじめに

[前回の記事](https://zenn.dev/lube8163/articles/e24eda10d2a9be)では、4bitのFLUX.2 Klein 4BをCoreAIで動かし、iPhone 17とiPhone 14で画像生成を試しました。今回は、その後に公開された**FLUX 3 Image KleinをiPhone上で動かす**ところまで進めました。

結果を先にまとめます。

- 元のチェックポイントからQwen・画像Transformer・VAEを変換し、iPhone 17で512×512の生成に成功しました。Linear重みをINT4にし、画像Transformerの計算はBF16を使っています。
- 固定条件の比較では、16ステップのモデル処理が平均64.67秒、4ステップが23.06秒でした。4ステップの安全確認・PNG保存までは平均26.71秒です。
- 開発用アプリへモデル選択とダウンロードを組み込み、固定入力ではない文章からも生成できました。こちらの4ステップの一例は、初回コンパイル込み60.0秒、キャッシュ作成後23.9秒でした。
- WindowsのV100 32GBを使い、量子化前後の24枚も比較しました。主要な内容は保たれる一方、形の細部や文字配置には変化があります。

モデルの新しい学習や独自の量子化方式を提案する記事ではありません。既存モデルとCoreAIを組み合わせ、端末で動く構成に変換し、実装と実測を残した記録です。スマートフォンでの初動作や最速を主張するものでもありません。

[コードと測定データ](https://github.com/lube8163-lab/sdxl-coreml-test/tree/codex/flux3-iphone-report) · [実装と検証範囲](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/docs/flux3-ios-report.md) · [日本語の再現手順](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/docs/flux3-iphone-reproduction.md)

## 今回動かしたモデルと、動かしていない部分

原モデルは[Black Forest LabsのFLUX 3 Image Klein](https://huggingface.co/black-forest-labs/flux-3-image-klein)の蒸留版です。画像Transformerが5.6Bで、Qwen3-VL-4B-Instructのテキストエンコーダは別にあります。元のモデルは画像編集にも対応しますが、今回は512pxのtext-to-imageに絞りました。

| 項目 | 今回の構成 |
| --- | --- |
| 画像生成 | 蒸留済みFLUX 3 Image Klein、全層・全幅を保持 |
| 文章の符号化 | Qwen3-VL-4B-Instructの文章経路、32層 |
| 重いLinear重み | CoreAI INT4、対称量子化、group size 32 |
| 画像Transformerの計算 | BF16、既存のFP32正規化等を保持 |
| その他 | Qwenの埋め込み・正規化等とVAEはFP16 |
| 出力・ステップ | 512×512、4 / 8 / 16、CFGなし |
| 端末実行 | Swift＋CoreAI、GPU優先、フォールバック可 |
| 主な実測端末 | iPhone 17、A19、約8GB、iOS 27.0.1 / 24A446 |

「4bit化」は主にLinear重みの圧縮です。埋め込みや活性値、VAEまで、すべての値を4bitにしたわけではありません。文章モデルでは4・8・12・16・20・24・28・32層の出力を取り出して連結し、画像生成の条件へ渡します。

独立したプロンプト拡張LLMは載せていません。公式は短い要求を十分な場面描写へ展開してから渡す構成を推奨しているため、今回の比較にも、被写体・配置・光・材質を記した完成キャプションを使いました。端末上のQwenはその文章を符号化する役割です。

画像参照・編集、任意解像度、独立したプロンプト拡張は未統合です。主アプリでは端末内のトークナイザーで入力を処理し、チャット形式込み160トークンを上限にしています。長すぎる入力は黙って切り詰めず、短縮を案内します。

## まず変換して、FP16で失敗した部分を直した

変換は[BFLの参照コード](https://github.com/black-forest-labs/flux-3-image-klein)を基に、PyTorchの部品をCoreAIへ順番に変換しました。固定した元ファイルのサイズとSHA-256、参照コードのリビジョンはGitHubの[model-spec.json](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/Experiments/Flux3CoreAI/model-spec.json)にあります。

最初は画像側もFP16で実行しましたが、文章の投影結果の一部がFP16の範囲を超えました。そのため、画像Transformerの計算と入出力をBF16へ変更しています。INT4のpacked weightsをもう一度量子化するのではなく、既存定数を維持して計算側を変更しました。定数の属性・型と、変換後グラフの検証も行っています。

2026年10月17日の初回完走では、Qwenが4.35秒、DiTの16ステップが117.88秒、VAEが5.19秒、3段階の合計127.42秒でした。起動から安全確認済みPNGの保存までは約137秒です。

ただし、文章側は先行する切り分け実行でも使っていたため、全処理が完全に未使用の状態ではありません。この初回値と、後の暖機済みの値をそのまま引き算して、最適化だけの効果とは扱っていません。

## 重みを小さくするだけでなく、読み直しを減らした

遅さを分けて測ると、分割した関数を毎ステップ読み直す時間が大きいことがわかりました。ある実行では、DiTの107.16秒のうち、`loadFunction`が55.16秒、`run`のawaitが48.51秒でした。

ここでの`run`は、Swift側で呼び出しを待った壁時計時間です。スケジューリングや同期も含み得るため、GPUカーネルだけを測った値ではありません。

最初に行ったのはグラフの結合です。画像側5層、文章側5層、統合側は最大8層を一つの関数にし、統合側を保持しました。同一ビルドの固定入力では、DiTが89.28秒から69.77秒になりました。一方、全部の関数を保持した条件では104.80秒となり、単に保持量を増やせばよいわけではありませんでした。

次に、文章側の計算順を変えました。

1. Qwenで文章を符号化する。
2. 各ステップの`current_t`と`target_t`に対応する文章側・時刻側の条件を、先に計算する。
3. 大きな文章側の関数を解放する。
4. 画像側・統合側の必要な関数を保持し、ノイズから画像を生成する。
5. VAEで復号し、出力を安全性確認へ渡す。

画像入力の投影も切り出し、反復中に文章側の投影を繰り返さないようにしました。文章条件はステップごとの時刻に依存するため、一度だけ計算して全ステップへ同じ値を渡す変更ではありません。

| 文章条件を先に計算する比較 | 従来経路 | 新経路 |
| --- | ---: | ---: |
| iPhone 17、熱状態fair | 98.76秒、1回 | 68.46秒、2回平均 |
| iPhone 14、暖機後 | 336.44秒、2回平均 | 275.55秒、2回平均 |

いずれもQwen・事前計算・DiT・VAEを含むモデル処理合計です。事前計算の時間を別扱いして短縮率を大きく見せないようにしています。固定入力では変更前後のPNGも一致しました。

iPhone 17ではサンプル最大の`phys_footprint`が約1.606GBから平均1.183GBになりました。ただし、これはプロセスのサンプル値で、瞬間ピークやMetalの総割当量、必要な物理RAMの下限ではありません。iPhone 14の結果は6GB端末での独立プローブの記録で、今回の新UIを全操作検証したという意味ではありません。

[不採用条件も含む速度の切り分け](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/Experiments/Flux3CoreAI/PERFORMANCE.md)に、生ログと条件を残しています。標本は小さく、一般的な短縮率の保証には使えません。

## 16・8・4ステップで、時間と画像はどう変わったか

同じモデルで、静物、位置と形、材質、看板の文字の4題材を比較しました。各2 seed、各16 / 8 / 4ステップで24枚、最初の暖機を含めると25回です。すべて実モデルの生成、安全性確認、PNG保存まで完走しました。

4と8ステップは、16ステップの途中で止めているわけではありません。参照実装の時刻列と一致する点を取り、すべて時刻1から0まで進めます。題材・seedごとに初期ノイズを固定し、ステップ数の実行順を回転させました。

次は、送風開始前に、三条件すべてで熱状態nominal / fairだった同じ題材・seedの3組です。

| ステップ数 | モデル処理の平均 | 検証開始から安全確認・PNG保存まで |
| --- | ---: | ---: |
| 16 | 64.67秒 | 68.35秒 |
| 8 | 36.74秒 | 40.41秒 |
| 4 | 23.06秒 | 26.71秒 |

モデル処理はQwen・文章条件の事前計算・DiT・VAEです。右列は全アセットのSHA照合、入力・出力の確認、画像変換と保存も含み、OSによる起動前や画面表示までの時間は含みません。

途中から端末へ風を当てた後の4組では、モデル処理が65.04 / 36.15 / 22.63秒、4ステップの保存まで26.25秒でした。題材も異なるため、送風前後を混ぜてファンの効果とはしていません。seriousを含んだ1組は速度の主比較から除き、画像と生データは残しています。

![同じseed42での16・8・4ステップ比較](https://raw.githubusercontent.com/lube8163-lab/sdxl-coreml-test/85db0c97f2ae37f82ee69b3fdbeb4de588732361/measurements/2026-10-18/flux3-coreai-step-count-iphone17/comparison-seed42.png)
*左から16・8・4ステップ。図中の秒数はモデル処理時間です。元の512px画像と、別seedの比較もGitHubにあります。*

今回の8組では、4ステップでも主要な物体や色、左右関係は保たれました。看板の「BLUE CAFE」も読めました。一方、看板が1行から2行になった例や、別seedの材質の題材で視点が変わった例があります。同じ構図や細部を保ったまま高速化できるという保証ではありません。

六視点の出力判定は24枚で平均約0.137秒でした。分類器の準備や入力検査は別に記録していますが、この条件では安全性確認が生成時間の主因ではありませんでした。

[全画像、実行順、熱状態、集計方法](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md)を保存しています。人物、手、長い文字列まで含む品質評価や、モデル名を隠した人による評価は未実施です。

## V100で、元の重みとINT4も比較した

量子化による差は、ステップ数とは別に確認しました。同じネットワークのWindows PCにあるTesla V100 32GBを使い、次の3条件を16ステップで比較しています。

| 条件 | 量子化する部分 |
| --- | --- |
| 元の重み | BF16チェックポイント由来の重み |
| DiT INT4 | 画像TransformerのLinear重み |
| Qwen＋DiT INT4 | 文章側と画像側のLinear重み |

CoreAIの実際のpacked INT4とscaleを抽出して使い、別の方式で再量子化していません。ただし、全条件の演算はFP32に揃えました。重みの変化を比べる試験であり、iPhoneのBF16 / FP16や融合演算、端末速度を再現する試験ではありません。

![V100で比較した元の重みとINT4、seed42](https://raw.githubusercontent.com/lube8163-lab/sdxl-coreml-test/85db0c97f2ae37f82ee69b3fdbeb4de588732361/measurements/2026-10-18/flux3-quantization-quality/comparison-seed42.png)
*左から元の重み、DiT INT4、Qwen＋DiT INT4。全列FP32演算。4題材×2 seed×3条件の24枚を生成しました。*

リンゴとマグ、ガラス、布、金属などの主要な内容は保たれました。一方、Qwen＋DiT INT4の一例では、円すいの先端が平らになり、看板の改行と建物の配置にも差が出ました。「大きく崩れなかった」という観察と、「元の画像と同じ」は分ける必要があります。

元の画像に対するSSIMの8画像平均は、DiT INT4が0.8653、Qwen＋DiT INT4が0.8453でした。これは画素の距離で、品質維持率や人間の好みの点数ではありません。文字の配置や構図が変わるだけでも値は変わります。

[全24枚と距離の集計](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/measurements/2026-10-18/flux3-quantization-quality/README.md)、[抽出と再現手順](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/Experiments/Flux3CoreAI/QUALITY.md)に条件を残しました。前回のBonsai比較とはモデルも目的も違うため、ここからBonsaiとの画質順位は出していません。

## 固定入力の実験から、ダウンロードできるアプリへ

最後に「ローカル画像生成」の開発用Previewへ統合しました。FLUX.2を既定に残し、FLUX.3を追加ダウンロードできるモデルとして表示しています。FLUX.3では4 / 8 / 16を選択でき、画像には生成時のモデル・ステップ数・入力・seedが残ります。

次は主アプリの生成処理で、新しく入力した水彩の灯台です。seedは42、4ステップです。

![通常アプリのCoreAI経路で生成した水彩の灯台、4ステップ](https://raw.githubusercontent.com/lube8163-lab/sdxl-coreml-test/85db0c97f2ae37f82ee69b3fdbeb4de588732361/measurements/2026-10-18/flux3-app-model-selection/flux3-4-steps-seed42-approved.png)

> A watercolor painting of a red lighthouse standing on a grassy cliff above a calm blue sea. A small white sailboat is visible on the right. Warm afternoon sunlight comes from the left. Soft textured paper, delicate brush strokes, clear simple composition, no people, no text.

固定入力プローブと異なり、この経路ではユーザーの実際の文章を端末内でトークン化し、seedから初期ノイズを作ります。生成サーバーへ文章や画像を送る構成ではありません。

| 主アプリの統合確認 | 安全判定を含むアプリ表示 |
| --- | ---: |
| ダウンロード後、初回コンパイルを含む4ステップ | 60.0秒 |
| 続けて8ステップ | 40.0秒 |
| 続けて16ステップ | 78.5秒 |
| キャッシュ作成後、プロセス再起動を挟んだ4ステップ | 23.9秒 |

初期のモデル照合・準備はこの時間に含みません。各条件1回で冷却も統制していないため、ステップ数の速度比較には先ほどの固定条件の表を使います。最初と最後の4ステップは画素ハッシュが一致しました。

ダウンロードでは約14.3MBで一時停止してプロセスを終了し、同じバイト数から再開できることを確認しました。既存のFLUX.2も残ります。入力の拒否、生成中の取消、モデル切替でも、以前の確認済み画像とその生成条件を維持しました。

端末のXCTest自動化が初期化に失敗したため、FLUX.3の一連の確認はPreviewだけに入れた起動ドライバから、実際のセットアップと生成メソッドを呼んでいます。全UIタップ試験の成功とは数えていません。検証後はドライバのない通常Previewへ戻し、署名とインストール・起動を確認しました。[アプリ統合の記録](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/measurements/2026-10-18/flux3-app-model-selection/README.md)

## 容量と初回コンパイルは、まだ軽くない

| FLUX.3で保存するもの | 容量・数 |
| --- | ---: |
| 初回ダウンロード | 約4.93GB、25分割 |
| 展開後のパッケージ | 約5.76GB、144ファイル |
| CoreAIモデルアセット | 44個 |
| 初回の空き容量確認 | 約13GB |

空き容量の予算にはアーカイブと展開先だけでなく、コンパイルキャッシュも含めています。FLUX.2と3を両方入れたPreviewでは、重み約9.81GBとは別にCoreAIキャッシュ約9.79GBを観測しました。これはディスク使用量で、RAMではありません。

モデル管理から不要な重みや途中のダウンロードは削除できます。システムのコンパイルキャッシュは別管理です。モデルを小さくすれば、端末で使う保存容量も同じだけになるとは限りません。

配布はCloudflare R2の固定リビジョンを使い、ZIP64全体と展開後の全ファイルをSHA-256で確認します。初回取得後の生成は端末内です。配布先にはIPアドレスなど通常の接続情報が届きます。

## 同じ構成を試すには

アプリを動かすだけなら、チェックポイントからの再変換は不要です。Xcode 27と対応実機、開発用署名を用意し、公開資料の固定コミットを取得します。

```sh
git clone https://github.com/lube8163-lab/sdxl-coreml-test.git
cd sdxl-coreml-test
git checkout 85db0c97f2ae37f82ee69b3fdbeb4de588732361
python3 scripts/prepare_safety_assets.py
python3 scripts/prepare_model_preview.py \
  --destination /tmp/local-image-preview \
  --bundle-id com.example.localimage.preview
open /tmp/local-image-preview/SDXLCoreMLTest.xcodeproj
```

自分のTeamと一意なBundle Identifierを使い、`LocalImageGenerationDevice`スキームを実機でRunします。既存インストールを残すため、別IDのPreviewを使っています。アプリからFLUX.3を選び、ダウンロードして生成できます。Simulatorは画像生成の対象外です。

[日本語の再現手順](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/docs/flux3-iphone-reproduction.md)には、ビルドと署名、入力例、元の重みからの変換、グラフ結合、配布パッケージ、V100での比較までの入口をまとめました。変換はCoreAIの私有MLIR authoring APIに依存する部分があるため、Pythonと変換ツールのバージョンも固定しています。端末のSwift実行はSDKのCoreAI APIを使います。

FLUX.3の重みは[FLUX Kommunity License](https://huggingface.co/black-forest-labs/flux-3-image-klein/blob/main/LICENSE.md)で、FLUX.2 Klein 4Bや参照コードのApache-2.0と同じ条件ではありません。商用利用・配布の条件は原文を確認してください。今回の変換はBFLやAppleによる公式iPhone移植ではありません。

## 今後確認したいこと

4ステップは待ち時間を減らす選択肢になりましたが、20秒台の生成と初回コンパイル、保存容量の負担は残っています。速度を重視するMiMではFLUX.2を継続し、「ローカル画像生成」ではFLUX.3を選べる開発版として扱っています。App Storeで配信中の版は、今回の作業では更新していません。

次は人物や複雑な手、長い文字列を含む入力を増やし、ステップ数と量子化の変化を別々に比べたいと考えています。独立したプロンプト拡張を含めた使い勝手、初回と継続利用の体感時間、端末ごとの発熱も課題です。

実装と測定データは、固定入力のプローブ、V100での重み比較、通常アプリへの統合を分けて公開します。同じ条件を追試した結果を追加できるよう、入力、seed、モデルハッシュ、測定区間を残しました。

## コード・データ・帰属

- [アプリと再現手順](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/docs/flux3-iphone-reproduction.md)
- [変換・速度・量子化比較の実験コード](https://github.com/lube8163-lab/sdxl-coreml-test/tree/codex/flux3-iphone-report/Experiments/Flux3CoreAI)
- [原モデル：Black Forest Labs](https://huggingface.co/black-forest-labs/flux-3-image-klein)
- [BFL参照実装](https://github.com/black-forest-labs/flux-3-image-klein)
- [Apple CoreAI](https://github.com/apple/coreai-models)
- [Qwen3-VL](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct)
- [安全モデル変換：InspiratioNULL](https://huggingface.co/InspiratioNULL/image-safety-classifier-s-CoreML)
- [ライセンスと変更の通知](https://github.com/lube8163-lab/sdxl-coreml-test/blob/codex/flux3-iphone-report/THIRD_PARTY_NOTICES.md)

モデル本体、認証情報、端末識別子を含む生の端末ログ、危険な分類テスト画像はGitに含めていません。公開する測定資料からは端末・接続先の識別情報を取り除き、数値、入力、画像、ソースと重みのハッシュを残しています。
