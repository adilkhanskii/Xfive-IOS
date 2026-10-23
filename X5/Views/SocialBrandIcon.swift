import SwiftUI

enum SocialBrand: String {
    case instagram, telegram, whatsapp, tiktok, youtube, linkedin, facebook, other

    init(name: String) {
        switch name.lowercased() {
        case "instagram": self = .instagram
        case "telegram": self = .telegram
        case "whatsapp": self = .whatsapp
        case "tiktok": self = .tiktok
        case "youtube": self = .youtube
        case "linkedin": self = .linkedin
        case "facebook": self = .facebook
        default: self = .other
        }
    }
}

struct SocialBrandIcon: View {
    let brand: SocialBrand
    var size: CGFloat = 22

    init(_ brand: SocialBrand, size: CGFloat = 22) {
        self.brand = brand
        self.size = size
    }

    init(name: String, size: CGFloat = 22) {
        self.brand = SocialBrand(name: name)
        self.size = size
    }

    var body: some View {
        Group {
            switch brand {
            case .instagram:
                InstagramGlyph()
            case .telegram:
                Image(systemName: "paperplane.fill")
                    .font(.system(size: size * 0.74, weight: .bold))
            case .whatsapp:
                Image(systemName: "phone.bubble.left.fill")
                    .font(.system(size: size * 0.74, weight: .bold))
            case .tiktok:
                TikTokGlyph()
            case .youtube:
                YouTubeGlyph()
            case .linkedin:
                Text("in")
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .italic()
            case .facebook:
                Text("f")
                    .font(.system(size: size * 0.82, weight: .heavy))
            case .other:
                Image(systemName: "link")
                    .font(.system(size: size * 0.68, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct InstagramGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let line = max(s * 0.075, 1.2)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.25, style: .continuous)
                    .stroke(.white, lineWidth: line)
                    .frame(width: s * 0.82, height: s * 0.82)
                Circle()
                    .stroke(.white, lineWidth: line)
                    .frame(width: s * 0.34, height: s * 0.34)
                Circle()
                    .fill(.white)
                    .frame(width: s * 0.10, height: s * 0.10)
                    .offset(x: s * 0.24, y: -s * 0.24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct TikTokGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(s * 0.11, 1.5))
                    .frame(width: s * 0.42, height: s * 0.42)
                    .offset(x: -s * 0.14, y: s * 0.22)
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: max(s * 0.12, 2), height: s * 0.68)
                    .offset(x: s * 0.10, y: -s * 0.08)
                Path { path in
                    path.move(to: CGPoint(x: s * 0.54, y: s * 0.18))
                    path.addCurve(
                        to: CGPoint(x: s * 0.80, y: s * 0.34),
                        control1: CGPoint(x: s * 0.60, y: s * 0.25),
                        control2: CGPoint(x: s * 0.70, y: s * 0.32)
                    )
                }
                .stroke(.white, style: StrokeStyle(lineWidth: max(s * 0.12, 2), lineCap: .round, lineJoin: .round))
                .frame(width: s, height: s)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct YouTubeGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.18, style: .continuous)
                    .fill(.white)
                    .frame(width: s * 0.86, height: s * 0.58)
                PlayTriangle()
                    .fill(Color.black.opacity(0.86))
                    .frame(width: s * 0.27, height: s * 0.30)
                    .offset(x: s * 0.02)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
