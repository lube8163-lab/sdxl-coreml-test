import SwiftUI
import LocalImageGeneration

struct ModelLibraryView: View {
    @ObservedObject var setup: ModelSetupViewModel
    let isGenerationBusy: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var deletionError: String?
    @State private var modelToDelete: GenerationModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("使いたいモデルだけをダウンロードできます。モデルを切り替えても、前回の確認済み画像は保持されます。")
                        .font(.subheadline).foregroundStyle(AppStyle.muted)
                    ForEach(GenerationModel.allCases) { model in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.title).font(.headline)
                                    Text(model.subtitle).font(.subheadline).foregroundStyle(AppStyle.muted)
                                }
                                Spacer()
                                if model == setup.model {
                                    Label("選択中", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(AppStyle.slate)
                                } else if setup.installedModels.contains(model) {
                                    Text("保存済み").font(.caption).foregroundStyle(AppStyle.slate)
                                }
                            }
                            HStack(spacing: 18) {
                                Label("512×512", systemImage: "square.dashed")
                                Text(model.availableSteps.map(String.init).joined(separator: "・") + "ステップ")
                            }.font(.caption).foregroundStyle(AppStyle.muted)
                            LabeledContent("ダウンロード", value: ModelByteText.format(model.package.archiveBytes))
                            LabeledContent("モデル本体", value: ModelByteText.format(model.package.installedBytes))
                            if model != setup.model {
                                Button(setup.installedModels.contains(model) ? "このモデルに切り替える" : "ダウンロードの準備へ") {
                                    setup.selectModel(model)
                                    dismiss()
                                }.buttonStyle(.borderedProminent).tint(AppStyle.slate)
                                    .accessibilityIdentifier("model.select." + model.rawValue)
                                    .disabled(isGenerationBusy || setup.isBusy)
                                if setup.installedModels.contains(model) {
                                    Button("モデル本体を削除", role: .destructive) { modelToDelete = model }
                                        .font(.footnote).disabled(isGenerationBusy || setup.isBusy)
                                        .accessibilityIdentifier("model.delete." + model.rawValue)
                                }
                            }
                            if model == .flux3 {
                                Text("英語で、被写体・場所・光・構図を具体的に書くと意図が伝わりやすくなります。")
                                    .font(.footnote).foregroundStyle(AppStyle.muted)
                                NavigationLink("FLUX.3の利用条件") {
                                    ModelLicenseView()
                                }.font(.footnote)
                            }
                        }.padding(20).background(AppStyle.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text("実行用の保存領域も必要です。ダウンロード画面で、準備に必要な空き容量をご案内します。")
                        .font(.footnote).foregroundStyle(AppStyle.muted)
                }.padding(20)
            }.background(AppStyle.background)
                .navigationTitle("モデル管理").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() }.accessibilityIdentifier("model.library.close") } }
                .onAppear { setup.refreshModels() }
                .alert("モデルを削除できませんでした", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                    Button("OK", role: .cancel) { deletionError = nil }
                } message: { Text(deletionError ?? "") }
                .confirmationDialog("モデル本体を削除しますか？", isPresented: Binding(
                    get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }
                ), titleVisibility: .visible) {
                    if let model = modelToDelete {
                        Button(model.title + "を削除", role: .destructive) { deletionError = setup.removeUnusedModel(model); modelToDelete = nil }
                    }
                    Button("キャンセル", role: .cancel) { modelToDelete = nil }
                } message: { Text("必要になったときに、もう一度ダウンロードできます。") }
        }.preferredColorScheme(.light)
    }
}

enum ModelByteText {
    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
    static func required(_ bytes: Int64) -> String { "約\(Int(ceil(Double(bytes) / 1_000_000_000)))GB" }
}

struct ModelLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("FLUX.3の利用条件").font(.title2.bold())
                Text("FLUX.3にはFLUX Kommunity Licenseが適用されます。商用利用には条件があります。以下の原文をご確認ください。")
                    .font(.subheadline)
                Link("配布元のライセンスを開く", destination: GenerationModel.flux3.licenseURL)
                Text(license).font(.footnote).textSelection(.enabled)
            }.padding(20)
        }.background(AppStyle.background).navigationTitle("FLUX.3の利用条件").navigationBarTitleDisplayMode(.inline)
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "Flux3LicenseNotices", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "ライセンス原文は配布元のリンクから確認できます。" }
        return value
    }
}
