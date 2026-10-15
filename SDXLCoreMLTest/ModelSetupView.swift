import SwiftUI
import LocalImageGeneration

struct WelcomeView: View {
    let continueAction: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image("AppLogoMark").resizable().scaledToFit().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("想像を、端末の中で。")
                            .font(.largeTitle.bold()).foregroundStyle(AppStyle.ink)
                        Text("描きたいものを言葉で伝えると、iPhoneが画像を生成します。")
                            .foregroundStyle(AppStyle.slate)
                    }
                    welcomeRow("iphone", "生成はiPhoneの中で", "モデルの準備後はオフラインで使えます。プロンプトや生成画像をサーバーへ送りません。")
                    welcomeRow("square.and.arrow.down", "最初だけモデルを準備", "約3.54GBをダウンロードします。Wi-Fiと約9GBの空き容量をご用意ください。")
                    welcomeRow("checkmark.shield", "安全性を確認してから表示", "入力と生成画像を端末内で確認します。確認できない内容は生成・表示できません。")
                    Button("はじめる", action: continueAction)
                        .buttonStyle(SetupPrimaryButtonStyle()).accessibilityIdentifier("welcome.continue")
                    HStack(spacing: 24) {
                        NavigationLink("利用規約") { LegalDocumentView(document: .terms) }
                        NavigationLink("プライバシー") { LegalDocumentView(document: .privacy) }
                    }.font(.footnote).foregroundStyle(AppStyle.muted)
                    Text("iOS 27.0.1以降・メモリ6GB以上の対応端末が必要です。6GB端末では生成に時間がかかることがあります。")
                        .font(.footnote).foregroundStyle(AppStyle.muted)
                }.padding(28).padding(.vertical, 28)
            }.background(AppStyle.background).preferredColorScheme(.light)
        }
    }
    private func welcomeRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(AppStyle.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(AppStyle.ink)
                Text(detail).font(.subheadline).foregroundStyle(AppStyle.slate).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ModelSetupView: View {
    @ObservedObject var setup: ModelSetupViewModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 44)).foregroundStyle(AppStyle.accent)
                    Text(title).font(.title.bold()).foregroundStyle(AppStyle.ink)
                        .accessibilityIdentifier("model.setup.title")
                    Text(detail).foregroundStyle(AppStyle.slate)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("FLUX.2 Klein 4B").font(.headline)
                        LabeledContent("ダウンロード", value: "約3.54GB")
                        LabeledContent("モデルの保存容量", value: "約4.04GB")
                        Text("実行用キャッシュを含め、約9GBの空き容量をご用意ください。")
                            .font(.footnote).foregroundStyle(AppStyle.muted)
                        Text("一度準備すれば、通信せずに画像を生成できます。")
                            .font(.footnote).foregroundStyle(AppStyle.muted)
                    }.padding(20).background(AppStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    if setup.isBusy {
                        if setup.state == .verifying { ProgressView().tint(AppStyle.slate) }
                        else { ProgressView(value: setup.progress).tint(AppStyle.slate) }
                        if setup.state == .downloading {
                            Text(ByteCountFormatter.string(fromByteCount: setup.downloadedBytes, countStyle: .decimal) + " / 3.54GB")
                                .font(.footnote.monospacedDigit()).foregroundStyle(AppStyle.muted)
                                .accessibilityIdentifier("model.download.progress")
                        }
                        Button("中断する") { setup.pause() }.buttonStyle(.bordered).tint(AppStyle.slate)
                            .accessibilityIdentifier("model.download.pause")
                    } else {
                        Toggle("モバイル通信でもダウンロードする", isOn: $setup.allowsCellular)
                            .font(.subheadline).tint(AppStyle.slate)
                        Text("オフの場合はWi-Fiでダウンロードします。モバイル通信を使うと通信料がかかる場合があります。")
                            .font(.footnote).foregroundStyle(AppStyle.muted)
                        Button(setup.downloadedBytes > 0 ? "ダウンロードを再開" : "モデルをダウンロード") { setup.start() }
                            .buttonStyle(SetupPrimaryButtonStyle()).accessibilityIdentifier("model.download.start")
                    }
                    NavigationLink("プライバシーポリシー") { LegalDocumentView(document: .privacy) }
                        .font(.footnote).foregroundStyle(AppStyle.muted)
                }.padding(28).padding(.vertical, 24)
            }.background(AppStyle.background).preferredColorScheme(.light)
        }
    }
    private var title: String {
        switch setup.state {
        case .downloading: "モデルをダウンロード中"
        case .installing: "モデルを準備しています"
        case .verifying: "モデルを確認しています"
        case .paused: "ダウンロードを再開できます"
        case .failed: "準備を完了できませんでした"
        case .idle, .ready: "最初にモデルを準備します"
        }
    }
    private var detail: String {
        switch setup.state {
        case .failed(let message): message
        case .downloading: "アプリを開いたままお待ちください。中断しても、受信した続きから再開できます。"
        case .installing, .verifying: "安全に使えるよう、モデルの内容を確認しています。"
        case .paused: "通信状況を確認して再開してください。すでに受信したデータは再利用します。"
        case .idle, .ready: "Wi-Fiと約9GBの空き容量をご用意ください。ダウンロード後は、端末の中だけで画像を生成します。"
        }
    }
}

struct UnsupportedDeviceView: View {
    var body: some View {
        ContentUnavailableView {
            Label("この端末では生成できません", systemImage: "iphone.slash")
        } description: {
            Text("FLUX.2 Kleinの画像生成には、iOS 27.0.1以降・メモリ6GB以上の対応端末が必要です。")
        }.background(AppStyle.background).preferredColorScheme(.light)
    }
}

private struct SetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity)
            .padding(.vertical, 18).background(AppStyle.slate.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
