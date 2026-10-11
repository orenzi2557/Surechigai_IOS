//
//  Theme.swift
//  Surechigai
//
//  アプリ全体のカラー・グラデーション・余白などのデザイントークン。
//

import SwiftUI

extension Color {
    /// 16進数からColorを生成する（例: Color(hex: 0x6C5CE7)）
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    // MARK: ブランドカラー
    static let brandPrimary   = Color(hex: 0x6C5CE7)   // バイオレット
    static let brandSecondary = Color(hex: 0xFF7AA8)   // ピンク
    static let brandAccent    = Color(hex: 0x21D4B4)   // ミント
    static let brandInk       = Color(hex: 0x1C1B2E)   // 濃紺（テキスト）
    static let appBackground  = Color(hex: 0xF5F5FB)   // 画面背景
    static let cardBackground = Color(hex: 0xFFFFFF)
}

extension LinearGradient {
    /// メインのブランドグラデーション
    static let brand = LinearGradient(
        colors: [Color.brandPrimary, Color.brandSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 背景に敷くやわらかいグラデーション
    static let brandSoft = LinearGradient(
        colors: [Color(hex: 0xEEEBFF), Color(hex: 0xFFEef4)],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum AppMetrics {
    static let corner: CGFloat = 20
    static let cardCorner: CGFloat = 22
    static let spacing: CGFloat = 16
}
