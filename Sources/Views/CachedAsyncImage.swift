import SwiftUI
import AppKit
import CryptoKit

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
        // 使用 SHA256 产生跨启动完全稳定的唯一哈希，解决 Swift 默认 HashValue 每次重启都会发生哈希随机化的问题
        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        let hashString = hashed.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hashString + ".img")
    }
    
    // 同步取内存缓存（命中则首帧即显示，无闪烁）
    func cachedImage(for url: URL) -> NSImage? {
        if let img = mem.object(forKey: url as NSURL) { return img }
        return nil
    }
    
    // 异步加载：先查磁盘，再走网络；采用 Stale-While-Revalidate (SWR) 策略平衡速度与自动更新
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let img = mem.object(forKey: url as NSURL) { completion(img); return }
        ioQueue.async {
            let dp = self.diskPath(for: url)
            var cachedImg: NSImage? = nil
            var isExpired = false
            
            // 1. 检查本地磁盘缓存
            if FileManager.default.fileExists(atPath: dp.path) {
                if let data = try? Data(contentsOf: dp), let img = NSImage(data: data) {
                    cachedImg = img
                    // 检查缓存修改日期是否过期（超过 7 天则定义为过期需要后台更新）
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: dp.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        if Date().timeIntervalSince(modDate) > 604800 { // 7天 = 604800秒
                            isExpired = true
                        }
                    }
                }
            }
            
            // 2. 如果命中磁盘缓存，立刻返回主线程渲染，实现秒开无闪烁
            if let img = cachedImg {
                self.mem.setObject(img, forKey: url as NSURL)
                DispatchQueue.main.async { completion(img) }
                
                // 如果未过期，直接结束，不发起网络验证请求
                if !isExpired {
                    return
                }
            }
            
            // 3. 无缓存或缓存已过期，则去异步请求最新网络数据进行后台更新
            self.lock.lock()
            if self.inflight.contains(url) {
                self.lock.unlock()
                return
            }
            self.inflight.insert(url)
            self.lock.unlock()
            
            URLSession.shared.dataTask(with: url) { data, _, _ in
                self.lock.lock()
                self.inflight.remove(url)
                self.lock.unlock()
                
                guard let data = data, let img = NSImage(data: data) else {
                    if cachedImg == nil {
                        DispatchQueue.main.async { completion(nil) }
                    }
                    return
                }
                
                // 更新内存与磁盘缓存（写入会刷新修改时间戳为当前时间）
                self.mem.setObject(img, forKey: url as NSURL)
                self.ioQueue.async(flags: .barrier) {
                    try? data.write(to: dp)
                }
                
                // 返回主线程，渲染最新的图片
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }
    }
}

// 带缓存网络图片视图：内含加载状态机，支持首帧无闪渲染，并提供优雅的失败回显与向后兼容初始化
struct CachedAsyncImage<Placeholder: View, Failure: View>: View {
    let url: URL?
    let placeholder: Placeholder
    let failure: Failure
    
    enum LoadState {
        case loading
        case success(NSImage)
        case failure
    }
    
    @State private var state: LoadState = .loading
    
    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder, @ViewBuilder failure: () -> Failure) {
        self.url = url
        self.placeholder = placeholder()
        self.failure = failure()
        
        if let u = url {
            if let cached = ImageCache.shared.cachedImage(for: u) {
                _state = State(initialValue: .success(cached))
            }
        } else {
            _state = State(initialValue: .failure)
        }
    }
    
    var body: some View {
        Group {
            switch state {
            case .loading:
                placeholder
            case .success(let img):
                Image(nsImage: img).resizable().scaledToFit()
            case .failure:
                failure
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: url) { _ in state = .loading; loadIfNeeded() }
    }
    
    private func loadIfNeeded() {
        guard let u = url else {
            state = .failure
            return
        }
        if case .success = state { return }
        
        ImageCache.shared.load(u) { img in
            if let img = img {
                self.state = .success(img)
            } else {
                self.state = .failure
            }
        }
    }
}

// 拓展提供向后兼容性：若无显式 failure 闭包，则失败时同样展示 placeholder 占位符
extension CachedAsyncImage where Failure == Placeholder {
    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.init(url: url, placeholder: placeholder, failure: placeholder)
    }
}
