import Foundation
import Darwin
import IOKit

// MARK: - 原生系统指标采集
// 直接调用 macOS 内核接口（Mach host_statistics / IOKit / getifaddrs），
// 与「活动监视器」获取数据的方式一致，几乎零 CPU 开销，
// 取代过去每 5 秒 spawn top / vm_stat / sysctl / netstat 子进程的做法。
final class SystemMetrics {
    
    struct CPUUsage { let user: Double; let system: Double; let idle: Double }
    struct MemoryUsage {
        let appMem: Double      // GB，匿名（App）内存
        let wired: Double       // GB，联动内存
        let compressed: Double  // GB，被压缩
        let fileBacked: Double  // GB，已缓存文件
    }
    
    // 上一次的 CPU tick 快照，用于计算两次采样之间的增量百分比
    private var prevCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    // 物理内存大小固定不变，只读一次
    private lazy var physicalMemoryBytes: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()
    
    var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_073_741_824.0 }
    
    // MARK: CPU —— host_statistics(HOST_CPU_LOAD_INFO)
    func cpuUsage() -> CPUUsage? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks 是长度为 CPU_STATE_MAX(4) 的元组: user/system/idle/nice
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        defer { prevCPUTicks = (user, system, idle, nice) }
        
        guard let prev = prevCPUTicks else { return nil } // 首次无基准
        let du = Double(user &- prev.user)
        let ds = Double(system &- prev.system)
        let di = Double(idle &- prev.idle)
        let dn = Double(nice &- prev.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return nil }
        return CPUUsage(user: (du + dn) / total * 100.0,
                        system: ds / total * 100.0,
                        idle: di / total * 100.0)
    }
    
    // MARK: 内存 —— host_statistics64(HOST_VM_INFO64)
    func memoryUsage() -> MemoryUsage? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let gb = 1_073_741_824.0
        func toGB(_ pages: UInt64) -> Double { Double(pages) * pageSize / gb }
        // 匿名(App)内存 ≈ internal - purgeable，与 vm_stat "Anonymous pages" 一致
        let anonymous = UInt64(info.internal_page_count) >= UInt64(info.purgeable_count)
            ? UInt64(info.internal_page_count) - UInt64(info.purgeable_count) : 0
        return MemoryUsage(
            appMem: toGB(anonymous),
            wired: toGB(UInt64(info.wire_count)),
            compressed: toGB(UInt64(info.compressor_page_count)),
            fileBacked: toGB(UInt64(info.external_page_count))
        )
    }
    
    // MARK: 交换分区 —— sysctl vm.swapusage
    func swapUsedGB() -> Double {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / 1_073_741_824.0
    }
    
    // MARK: 网络累计字节 —— getifaddrs（等价 netstat -ib 的 Link 汇总）
    func networkBytes() -> (inBytes: Double, outBytes: Double) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var ptr = ifaddrPtr
        while let cur = ptr {
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = cur.pointee.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self)
                inBytes += UInt64(data.pointee.ifi_ibytes)
                outBytes += UInt64(data.pointee.ifi_obytes)
            }
            ptr = cur.pointee.ifa_next
        }
        return (Double(inBytes), Double(outBytes))
    }
    
    // MARK: 单进程内存足迹 —— proc_pid_rusage(ri_phys_footprint)
    // 这正是「活动监视器」内存列显示的值（phys_footprint），
    // 它包含被压缩的内存等，比 ps 的 RSS（仅驻留物理页）更准确。
    // 返回字节数；失败（如无权限访问他人进程）返回 0，由调用方回退到 RSS。
    func processMemoryFootprint(pid: Int32) -> Double {
        var info = rusage_info_v2()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V2), reboundPtr)
            }
        }
        guard kr == 0 else { return 0 }
        return Double(info.ri_phys_footprint)
    }
    
    // MARK: 磁盘累计读写字节 —— IOKit IOBlockStorageDriver 统计
    func diskIOBytes() -> (read: Double, write: Double) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var drive = IOIteratorNext(iterator)
        while drive != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { read += r }
                if let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { write += w }
            }
            IOObjectRelease(drive)
            drive = IOIteratorNext(iterator)
        }
        return (Double(read), Double(write))
    }
}
