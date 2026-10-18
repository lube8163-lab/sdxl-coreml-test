import LocalImageGeneration
import Photos
import UIKit

enum PhotoSaveError: LocalizedError, Equatable {
    case permissionDenied, restricted
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "写真への追加が許可されていません。「設定」でこのアプリの写真へのアクセスを許可すると保存できます。"
        case .restricted:
            "この端末では写真への追加が制限されています。生成画像はアプリ内に残っています。"
        }
    }
}

@MainActor
enum PhotoLibrarySaver {
    /// Only an image that passed the mandatory gate can reach the Photos API.
    static func save(_ result: GeneratedImage) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw status == .restricted ? PhotoSaveError.restricted : PhotoSaveError.permissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: result.cgImage))
        }
    }
}
