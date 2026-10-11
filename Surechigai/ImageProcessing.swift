//
//  ImageProcessing.swift
//  Surechigai
//
//  プロフィール画像をアップロードする前の下ごしらえ。
//  端末の写真はそのままだと数MB・HEIC などまちまちなので、
//  ここで「長辺を縮めた JPEG」に揃えてから送る。
//

import UIKit

enum ImageProcessing {

    /// アップロード用のJPEGデータを作る。
    /// - Parameters:
    ///   - maxDimension: 長辺の上限（px）。プロフィール表示は最大100pt程度なので1024で十分。
    ///   - quality: JPEG品質。
    static func prepareForUpload(
        _ image: UIImage,
        maxDimension: CGFloat = 1024,
        quality: CGFloat = 0.8
    ) -> Data? {
        resized(image, maxDimension: maxDimension).jpegData(compressionQuality: quality)
    }

    /// 長辺が maxDimension に収まるよう縮小する。
    /// 描画し直すので、カメラ由来のEXIF回転もここで正立に焼き込まれる。
    static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(
            width: max((size.width * scale).rounded(), 1),
            height: max((size.height * scale).rounded(), 1)
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1     // 指定サイズ＝ピクセル数にする（Retina倍率をかけない）
        format.opaque = true // JPEGに透過はないので不透明で描く

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
