import SwiftUI
import AppKit

class ProcessTableViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    
    // CRITICAL: Use a cached array, NOT a computed property
    private var cachedData: [SysProcess] = []
    private var rawProcesses: [SysProcess] = []
    private var searchText: String = ""
    private var isUpdatingData = false
    
    // 用户真正点击选中某行时的回调（数据刷新不会触发，避免反馈循环）
    var onSelectionChanged: ((Int?) -> Void)?
    
    // Pre-cached system symbol images (created once, reused forever)
    private lazy var desktopIcon: NSImage? = {
        NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }()
    private lazy var dockerIcon: NSImage? = {
        let svgString = """
        <svg t="1781776387233" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="1236" width="200" height="200"><path d="M0 0m184.32 0l655.36 0q184.32 0 184.32 184.32l0 655.36q0 184.32-184.32 184.32l-655.36 0q-184.32 0-184.32-184.32l0-655.36q0-184.32 184.32-184.32Z" fill="#458EE6" p-id="1237"></path><path d="M433.152 413.696m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1238"></path><path d="M524.288 413.696m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1239"></path><path d="M615.424 413.696m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1240"></path><path d="M342.016 413.696m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1241"></path><path d="M250.88 413.696m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1242"></path><path d="M433.152 327.68m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1243"></path><path d="M524.288 327.68m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1244"></path><path d="M342.016 327.68m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1245"></path><path d="M525.312 241.664m3.072 0l73.216 0q3.072 0 3.072 3.072l0 67.584q0 3.072-3.072 3.072l-73.216 0q-3.072 0-3.072-3.072l0-67.584q0-3.072 3.072-3.072Z" fill="#FFFFFF" p-id="1246"></path><path d="M205.9264 499.82464s-20.5824 3.46112-20.24448 13.1072c-4.57728 26.624-29.40928 253.32736 218.91072 272.64 342.54848 28.96896 417.97632-257.30048 417.97632-257.30048s93.32736 2.32448 115.7632-70.22592c-3.47136-9.216-35.47136-34.73408-100.096-25.01632 0.79872-35.328-44.81024-84.11136-59.2384-84.11136s-57.87648 58.63424-19.95776 139.42784c-1.024 2.9696-21.97504 9.69728-63.77472 11.48928z" fill="#FFFFFF" p-id="1247"></path></svg>
        """
        guard let data = svgString.data(using: .utf8), let img = NSImage(data: data) else { return nil }
        img.size = NSSize(width: 16, height: 16)
        return img
    }()
    private lazy var nodeIcon: NSImage? = {
        NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }()
    private lazy var brewIcon: NSImage? = {
        NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }()
    private lazy var gearIcon: NSImage? = {
        NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }()
    
    // Pre-cached NSColor for tags
    private lazy var tagColors: [ProcessTag: NSColor] = {
        var colors: [ProcessTag: NSColor] = [:]
        for tag in [ProcessTag.system, .desktop, .docker, .node, .brew, .appStore, .brewCask, .git] {
            colors[tag] = NSColor(tag.color)
        }
        return colors
    }()
    
    override func loadView() {
        self.view = NSView()
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 22
        
        addColumn(id: "Name", title: "进程名称", width: 200, key: "name", asc: true)
        addColumn(id: "CPU", title: "% CPU", width: 60, key: "cpu", asc: false)
        addColumn(id: "CPUTime", title: "CPU 时间", width: 80, key: "cputime", asc: false)
        addColumn(id: "Mem", title: "内存", width: 80, key: "mem", asc: false)
        addColumn(id: "Threads", title: "线程", width: 50, key: "threads", asc: false)
        addColumn(id: "Ports", title: "端口", width: 50, key: "ports", asc: false)
        addColumn(id: "Kind", title: "种类", width: 70, key: "kind", asc: true)
        addColumn(id: "PID", title: "PID", width: 60, key: "pid", asc: true)
        addColumn(id: "User", title: "用户", width: 80, key: "user", asc: true)
        
        tableView.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]
        
        scrollView.documentView = tableView
        self.view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func addColumn(id: String, title: String, width: CGFloat, key: String, asc: Bool) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: asc)
        tableView.addTableColumn(col)
    }
    
    // MARK: - Data update (sort once, cache result)
    func update(processes: [SysProcess], searchText: String) {
        self.rawProcesses = processes
        self.searchText = searchText
        rebuildCache()
    }
    
    private func rebuildCache() {
        isUpdatingData = true
        let previousSelectedPID = self.selectedPID
        
        var filtered = rawProcesses
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        let sortDesc = tableView.sortDescriptors.first
        let key = sortDesc?.key ?? "cpu"
        let asc = sortDesc?.ascending ?? false
        
        filtered.sort { a, b in
            switch key {
            case "name":    return asc ? a.name < b.name : a.name > b.name
            case "cpu":     return asc ? a.cpu < b.cpu : a.cpu > b.cpu
            case "mem":     return asc ? a.memKB < b.memKB : a.memKB > b.memKB
            case "pid":     return asc ? a.id < b.id : a.id > b.id
            case "user":    return asc ? a.user < b.user : a.user > b.user
            case "threads": return asc ? a.threads < b.threads : a.threads > b.threads
            case "ports":   return asc ? a.ports < b.ports : a.ports > b.ports
            case "cputime": return asc ? a.cpuTime < b.cpuTime : a.cpuTime > b.cpuTime
            case "kind":    return asc ? a.kindStr < b.kindStr : a.kindStr > b.kindStr
            default:        return false
            }
        }
        
        cachedData = filtered
        tableView.reloadData()
        
        if let prevPID = previousSelectedPID,
           let newRowIndex = cachedData.firstIndex(where: { $0.id == prevPID }) {
            let indexSet = IndexSet(integer: newRowIndex)
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }
        
        isUpdatingData = false
        // 注意：此处不再发出选择变更通知。数据刷新属于程序行为，
        // 若在此通知会回写绑定 → 触发 SwiftUI 重渲染 → 再次 update → 死循环。
    }
    
    // MARK: - NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int {
        cachedData.count
    }
    
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuildCache()
    }
    
    // MARK: - NSTableViewDelegate (cell reuse with per-column identifiers)
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < cachedData.count else { return nil }
        let p = cachedData[row]
        let colId = tableColumn?.identifier.rawValue ?? ""
        
        let cellID = NSUserInterfaceItemIdentifier("Cell_\(colId)")
        
        if colId == "Name" {
            // Name column has icon + text
            var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellID
                
                let imgView = NSImageView()
                imgView.translatesAutoresizingMaskIntoConstraints = false
                imgView.imageScaling = .scaleProportionallyUpOrDown
                cell?.addSubview(imgView)
                cell?.imageView = imgView
                
                let txt = NSTextField(labelWithString: "")
                txt.translatesAutoresizingMaskIntoConstraints = false
                txt.lineBreakMode = .byTruncatingTail
                cell?.addSubview(txt)
                cell?.textField = txt
                
                NSLayoutConstraint.activate([
                    imgView.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    imgView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    imgView.widthAnchor.constraint(equalToConstant: 16),
                    imgView.heightAnchor.constraint(equalToConstant: 16),
                    txt.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    txt.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
                    txt.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4)
                ])
            }
            
            cell?.textField?.stringValue = p.name
            if let img = p.iconImage {
                cell?.imageView?.image = img
                cell?.imageView?.contentTintColor = nil
            } else {
                let icon: NSImage?
                switch p.tag {
                case .desktop: icon = desktopIcon
                case .docker:  icon = dockerIcon
                case .node:    icon = nodeIcon
                case .brew:    icon = brewIcon
                default:       icon = gearIcon
                }
                cell?.imageView?.image = icon
                if p.tag == .docker {
                    cell?.imageView?.contentTintColor = nil
                } else {
                    cell?.imageView?.contentTintColor = tagColors[p.tag]
                }
            }
            return cell
        } else {
            // All other columns: text only
            var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellID
                let txt = NSTextField(labelWithString: "")
                txt.translatesAutoresizingMaskIntoConstraints = false
                txt.lineBreakMode = .byTruncatingTail
                cell?.addSubview(txt)
                cell?.textField = txt
                NSLayoutConstraint.activate([
                    txt.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    txt.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    txt.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4)
                ])
            }
            
            switch colId {
            case "CPU":     cell?.textField?.stringValue = String(format: "%.1f", p.cpu)
            case "CPUTime": cell?.textField?.stringValue = p.cpuTime
            case "Mem":     cell?.textField?.stringValue = p.memStr
            case "Threads": cell?.textField?.stringValue = "\(p.threads)"
            case "Ports":   cell?.textField?.stringValue = "\(p.ports)"
            case "Kind":    cell?.textField?.stringValue = p.kindStr
            case "PID":     cell?.textField?.stringValue = "\(p.id)"
            case "User":    cell?.textField?.stringValue = p.user
            default:        cell?.textField?.stringValue = "-"
            }
            return cell
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        // 仅当是用户交互（而非程序刷新数据）导致的选择变化时才回调
        if !isUpdatingData {
            onSelectionChanged?(selectedPID)
        }
    }
    
    var selectedPID: Int? {
        let row = tableView.selectedRow
        guard row >= 0 && row < cachedData.count else { return nil }
        return cachedData[row].id
    }
}

struct NativeProcessTableView: NSViewControllerRepresentable {
    var processes: [SysProcess]
    var searchText: String
    @Binding var selectedPID: Int?
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSViewController(context: Context) -> ProcessTableViewController {
        let vc = ProcessTableViewController()
        // 用户点击行 → 回写绑定，但仅在值真正变化时写入，彻底打断反馈循环
        vc.onSelectionChanged = { pid in
            if context.coordinator.parent.selectedPID != pid {
                context.coordinator.parent.selectedPID = pid
            }
        }
        return vc
    }
    
    func updateNSViewController(_ nsViewController: ProcessTableViewController, context: Context) {
        context.coordinator.parent = self
        nsViewController.update(processes: processes, searchText: searchText)
    }
    
    class Coordinator {
        var parent: NativeProcessTableView
        init(_ parent: NativeProcessTableView) { self.parent = parent }
    }
}
