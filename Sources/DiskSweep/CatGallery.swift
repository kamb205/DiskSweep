import SwiftUI

/// A freely licensed cat photo from Wikimedia Commons, with the credit its license requires.
struct CatPhoto: Identifiable {
    let id: String
    let imageURL: URL
    let pageURL: URL
    let author: String
    let license: String
}

/// Loads cat photos from Wikimedia Commons' curated "Featured" and "Quality" categories.
/// Every photo there carries its author and license, so each one can be credited properly.
enum CatPhotoLoader {
    private static let categories = ["Featured_pictures_of_cats", "Quality_images_of_cats"]

    static func load() async -> [CatPhoto] {
        var photos: [CatPhoto] = []
        for category in categories {
            photos += await load(category: category)
        }
        return photos.shuffled()
    }

    private static func load(category: String) async -> [CatPhoto] {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "generator", value: "categorymembers"),
            .init(name: "gcmtitle", value: "Category:\(category)"),
            .init(name: "gcmtype", value: "file"),
            .init(name: "gcmlimit", value: "50"),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|extmetadata"),
            .init(name: "iiurlwidth", value: "900"),
            .init(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
            .init(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        // Wikimedia asks API clients to identify themselves.
        request.setValue("DiskSweep/1.0 (macOS disk cleaner; cat gallery)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: [String: Any]] else { return [] }

        return pages.values.compactMap { page in
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)),
                  let pageURL = (info["descriptionurl"] as? String).flatMap(URL.init(string:)) else { return nil }
            let meta = info["extmetadata"] as? [String: [String: Any]]
            let author = plainText(meta?["Artist"]?["value"] as? String) ?? "Unknown author"
            let license = (meta?["LicenseShortName"]?["value"] as? String) ?? "see source"
            return CatPhoto(id: pageURL.absoluteString, imageURL: thumb, pageURL: pageURL, author: author, license: license)
        }
    }

    /// Commons author fields are HTML (often a link); keep just the text.
    private static func plainText(_ html: String?) -> String? {
        guard let html else { return nil }
        let text = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}

struct CatGallery: View {
    @State private var photos: [CatPhoto] = []
    @State private var index = 0
    @State private var failed = false
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            Text("While you wait, here are some cat pictures 🐱")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5))
                if let photo = current {
                    AsyncImage(url: photo.imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.4))) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFit().transition(.opacity)
                        case .failure:
                            Image(systemName: "cat").font(.system(size: 50)).foregroundStyle(.tertiary)
                        default:
                            ProgressView()
                        }
                    }
                    .id(photo.id)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "cat").font(.system(size: 50))
                        Text("Couldn't load cat pictures. Are you offline?").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 520, height: 340)
            .overlay(alignment: .leading) { arrow("chevron.left", step: -1) }
            .overlay(alignment: .trailing) { arrow("chevron.right", step: 1) }

            if let photo = current {
                HStack(spacing: 4) {
                    Text("Photo: \(photo.author) · \(photo.license) ·")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Link("Wikimedia Commons", destination: photo.pageURL)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            }
        }
        .task {
            photos = await CatPhotoLoader.load()
            failed = photos.isEmpty
        }
        .onReceive(timer) { _ in shuffleToNext() }
    }

    private var current: CatPhoto? { photos.isEmpty ? nil : photos[index % photos.count] }

    /// Jumps to a random different photo.
    private func shuffleToNext() {
        guard photos.count > 1 else { return }
        var next = index
        while next == index { next = Int.random(in: 0..<photos.count) }
        withAnimation { index = next }
    }

    private func advance(_ step: Int) {
        guard !photos.isEmpty else { return }
        withAnimation { index = (index + step + photos.count) % photos.count }
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button { advance(step) } label: {
            Image(systemName: symbol)
                .font(.title3.bold())
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .opacity(photos.count > 1 ? 1 : 0)
    }
}
