import SwiftUI
import AppKit

// 全局图片缓存：内存 + 磁盘，避免重复网络请求导致"图标突然蹦出来"。
final class ImageCache {
    static let shared = ImageCache()
    private let mem = NSCache<NSURL, NSImage>()
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "image.cache.io", attributes: .concurrent)
    private var inflight = Set<URL>()
    private let lock = NSLock()
    
    init() {
        mem.countLimit = 500
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = base.appendingPathComponent("AppRadarImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }
    
    private func diskPath(for url: URL) -> URL {
        // 用 URL 的稳定哈希做文件名
        let name = String(url.absoluteString.hashValue) + ".img"
        return diskDir.appendingPathComponent(name)
    }
    
    // 同步取内存缓存（命中则首帧即显示，无闪烁）
    func cachedImage(for url: URL) -> NSImage? {
        if let img = mem.object(forKey: url as NSURL) { return img }
        return nil
    }
    
    // 异步加载：先查磁盘，再走网络；完成回主线程
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let img = mem.object(forKey: url as NSURL) { completion(img); return }
        ioQueue.async {
            // 磁盘缓存
            let dp = self.diskPath(for: url)
            if let data = try? Data(contentsOf: dp), let img = NSImage(data: data) {
                self.mem.setObject(img, forKey: url as NSURL)
                DispatchQueue.main.async { completion(img) }
                return
            }
            // 去重：同一 URL 只发一次请求
            self.lock.lock()
            if self.inflight.contains(url) { self.lock.unlock(); DispatchQueue.main.async { completion(nil) }; return }
            self.inflight.insert(url); self.lock.unlock()
            
            URLSession.shared.dataTask(with: url) { data, _, _ in
                self.lock.lock(); self.inflight.remove(url); self.lock.unlock()
                guard let data = data, let img = NSImage(data: data) else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                self.mem.setObject(img, forKey: url as NSURL)
                self.ioQueue.async(flags: .barrier) { try? data.write(to: dp) }
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }
    }
}

// 带缓存的网络图片视图：内存命中即首帧显示（不闪），未命中显示 placeholder 后淡入。
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: Placeholder
    @State private var image: NSImage?
    
    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
        // 初始化时同步取内存缓存，命中则首帧无闪
        if let u = url { _image = State(initialValue: ImageCache.shared.cachedImage(for: u)) }
    }
    
    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: url) { _ in image = nil; loadIfNeeded() }
    }
    
    private func loadIfNeeded() {
        guard image == nil, let u = url else { return }
        ImageCache.shared.load(u) { img in if let img = img { self.image = img } }
    }
}
