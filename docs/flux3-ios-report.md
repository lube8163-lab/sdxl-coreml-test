# FLUX.3 Image Klein on iPhone — 実装と検証の入口

2026-10-18時点の開発版です。Black Forest Labsの蒸留済みFLUX 3 Image KleinをCoreAI向けに変換し、物理iPhone 17で512×512の画像を生成しました。固定入力の実験に加え、「ローカル画像生成」の開発用Previewで、任意入力のトークン化、モデルのダウンロード、4 / 8 / 16ステップ、必須の出力安全性確認まで接続しています。App Storeで配信中のFLUX.2版への更新は含みません。

[日本語の再現手順](flux3-iphone-reproduction.md) · [アプリ統合の仕様](flux3-app-integration.md) · [変換・実験コード](../Experiments/Flux3CoreAI/README.md)

## どの結果を、何の証拠として使うか

| 記録 | 実行環境・入力 | 確認できたこと |
| --- | --- | --- |
| [初回の全モデル実行](../measurements/2026-10-17/flux3-coreai-full/summary.json) | iPhone 17、固定キャプション、16ステップ | 実チェックポイント由来のQwen・DiT・VAEによる生成、六視点判定、PNG保存 |
| [関数の結合・保持](../measurements/2026-10-17/flux3-coreai-performance/README.md) | iPhone 17、同一ビルドの固定入力 | DiT 89.28→69.77秒。全保持は不採用。画像一致 |
| [文章条件の事前計算](../measurements/2026-10-18/flux3-coreai-precompute-iphone17/README.md) | iPhone 17、16ステップ、熱状態fair | 従来1回98.76秒、新経路2回平均68.46秒。事前計算込み、画像一致 |
| [6GB端末での実験](../measurements/2026-10-18/flux3-coreai-precompute-iphone14/README.md) | iPhone 14、固定入力、16ステップ | 暖機後各2回、モデル処理平均336.44→275.55秒。新アプリUIの全操作をiPhone 14で確認した記録ではない |
| [ステップ数比較](../measurements/2026-10-18/flux3-coreai-step-count-iphone17/README.md) | iPhone 17、4題材×2 seed×3条件 | 24枚の画像・実行ログ。送風前の同じ熱条件3組でモデル処理64.67 / 36.74 / 23.06秒 |
| [量子化前後の比較](../measurements/2026-10-18/flux3-quantization-quality/README.md) | Windows V100 32GB、全条件FP32演算 | 元の重み / DiT INT4 / Qwen＋DiT INT4、計24枚。端末速度・端末演算の完全再現ではない |
| [通常アプリへの統合](../measurements/2026-10-18/flux3-app-model-selection/README.md) | iPhone 17、主アプリの実装を呼ぶPreview、灯台の新規キャプション | 公開モデル取得・中断再開・全ファイル照合・4/8/16生成・拒否/取消・モデル切替。暖機済み4ステップの表示23.9秒 |

`InferenceFunction.run`のawait、モデル処理合計、検証開始からPNG保存、アプリの表示時間は計測区間が異なります。単独のGPUカーネル時間やボタン操作から表示までの時間に読み替えないでください。元のレポート、測定順、熱状態、ソースハッシュは各フォルダにあります。

## 実装した範囲

- 蒸留済み5.6Bの画像Transformerと、別のQwen3-VL-4B-Instructの文章経路、VAEを使用。text-to-imageの全層・全幅を保持しています。
- Qwen / DiTの重いLinear重みは対称INT4、group size 32。DiT計算はBF16、正規化等の既存FP32部分を維持。Qwenの埋め込み等とVAEはFP16です。全テンソルが4bitという意味ではありません。
- 個別DiTを画像5層、文章5層、統合最大8層ごとに結合。文章側と時刻依存の条件を先に計算して解放し、画像側の反復中は必要な関数を保持します。
- 主アプリは端末内のトークナイザーとseed由来のノイズを使用。入力はチャット形式込み160トークン以内。独立したプロンプト拡張LLM、画像参照・編集、任意解像度は未統合です。
- 4 / 8 / 16の全条件で、参照する時刻列の始点1から終点0までを実行します。16ステップを途中で打ち切る方法ではありません。
- 入力検査と、全体＋5切り抜きの出力分類を必須とし、確認済み画像だけを表示・保存・共有へ渡します。少数例の判定成功から一般的な検出率は主張しません。

通常アプリの実行コードは[Flux3Runtime.swift](../Vendor/LocalImageGeneration/Sources/LocalImageGeneration/Flux3Runtime.swift)、安全性を含む入口は[LocalFlux3Generator.swift](../Vendor/LocalImageGeneration/Sources/LocalImageGeneration/LocalFlux3Generator.swift)です。初期の固定キャプション検証アプリは[GenerationProbe.swift](../Experiments/Flux3CoreAI/GenerationProbe.swift)で、別の実行経路です。

## 容量と初回実行

公開パッケージはダウンロード4,925,833,766 bytes、展開後5,764,051,319 bytes、144ファイル、44個の`.aimodel`です。最初の空き容量確認は約13GBで、展開・一時領域とコンパイルキャッシュの予算を含みます。

主アプリの灯台の一例は初回コンパイル込み60.0秒、キャッシュ作成後のプロセス再起動を挟んだ4ステップ23.9秒でした。いずれも安全判定込み、初期の全モデル照合・準備は別です。単発の統合検証で、冷却条件を揃えたベンチマークではありません。

FLUX.2と3を両方入れたPreviewでは、重み約9.81GBとは別にCoreAIキャッシュ約9.79GBを観測しました。端末のディスク使用量でありRAMではありません。モデル管理で不要な重みを消しても、システムのコンパイルキャッシュは別管理です。

## 再現性と帰属

変換対象のリビジョンと全チェックポイントSHA-256は[model-spec.json](../Experiments/Flux3CoreAI/model-spec.json)、配布物の全ファイルSHA-256は[パッケージのカタログ](../measurements/2026-10-18/flux3-app-model-selection/flux3-catalog-manifest.json)に固定しています。モデル本体、認証情報、端末識別子を含む生の端末ログはGitに追加しません。

コード・変換は[BFLの参照実装](https://github.com/black-forest-labs/flux-3-image-klein)と[Apple CoreAI](https://github.com/apple/coreai-models)を基にしています。[原モデル](https://huggingface.co/black-forest-labs/flux-3-image-klein)の重みはFLUX Kommunity Licenseです。コードのApache-2.0と同じ利用条件ではありません。[第三者ライセンス](../THIRD_PARTY_NOTICES.md)と原文を確認してください。Black Forest LabsやAppleによる公式iPhone移植・推奨ではありません。

2026-10-18に公式モデルカード、参照リポジトリ、公開検索を確認しましたが、先行例を網羅した調査ではありません。本資料は「世界初」「スマートフォン最速」を主張せず、この実装と端末条件で確認できた記録を公開します。

本資料の構成・執筆と依頼された実装・計測はAI（Codex）が担当し、端末の接続、権限操作、送風等は筆者が担当しました。未実施の試験や別条件の実測を混同しないよう、元の証拠をリンクしています。
