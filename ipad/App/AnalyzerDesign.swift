import SwiftUI

enum AnalyzerDesign {
    static let pageSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 16
    static let sidebarWidth: CGFloat = 260
    static let contentMaxWidth: CGFloat = 1180
}

struct AnalyzerCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder var content: Content

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.tint)
                    }
                    Text(title)
                        .font(.headline)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AnalyzerDesign.cardRadius))
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    let style: Style

    enum Style {
        case neutral, good, warning, active
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch style {
        case .neutral: return .secondary.opacity(0.12)
        case .good: return .green.opacity(0.14)
        case .warning: return .orange.opacity(0.16)
        case .active: return .blue.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch style {
        case .neutral: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .active: return .blue
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.tint.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
