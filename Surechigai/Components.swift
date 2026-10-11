//
//  Components.swift
//  Surechigai
//
//  画面をまたいで使い回す共通UIパーツ。
//

import SwiftUI

// MARK: - カード装飾

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardCorner, style: .continuous))
            .shadow(color: Color.brandInk.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

// MARK: - グラデーションボタン

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                Group {
                    if enabled {
                        LinearGradient.brand
                    } else {
                        Color.gray.opacity(0.4)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - タグチップ

struct TagChip: View {
    let text: String
    var selected: Bool = false
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                selected ? AnyShapeStyle(LinearGradient.brand)
                         : AnyShapeStyle(Color.brandPrimary.opacity(0.10))
            )
            .foregroundStyle(selected ? Color.white : Color.brandPrimary)
            .clipShape(Capsule())
    }
}

// MARK: - アバター

struct Avatar: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let url, let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsView
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
    }

    private var initialsView: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        guard let first = name.first else { return "?" }
        if first.isASCII {
            return String(name.prefix(2)).uppercased()
        }
        return String(first)
    }

    private var palette: [Color] {
        let sets: [[Color]] = [
            [Color(hex: 0x6C5CE7), Color(hex: 0xFF7AA8)],
            [Color(hex: 0x21D4B4), Color(hex: 0x2193B0)],
            [Color(hex: 0xF7971E), Color(hex: 0xFFC371)],
            [Color(hex: 0xFF5F6D), Color(hex: 0xFFC371)],
            [Color(hex: 0x654EA3), Color(hex: 0xEAAFC8)],
        ]
        return sets[abs(name.hashValue) % sets.count]
    }
}

// MARK: - 情報行

struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(Color.brandInk)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}

// MARK: - セクション見出し

struct SectionHeader: View {
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.brandPrimary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.brandInk)
            Spacer()
        }
    }
}

// MARK: - 空状態

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Color.brandPrimary.opacity(0.6))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
