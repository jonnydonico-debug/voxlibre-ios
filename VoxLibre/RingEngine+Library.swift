import Foundation

/// The recordings library (port of RingLibrary.java): the on-ring file list,
/// downloads, and a persisted index so the list survives offline. Downloaded files
/// live in the app's Documents folder (visible in the Files app).
extension RingEngine {
    struct IdxEntry: Codable {
        var onRing = false
        var ringSize: Int64?
        var dur: Int?
    }

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func recId(_ n: String) -> String? {
        firstMatch(#"amsg_(\d+)_mono"#, in: n, group: 1)
    }

    static func firstMatch(_ pattern: String, in s: String, group: Int = 0) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }

    func localURL(_ name: String) -> URL { Self.docs.appendingPathComponent(name) }
    func wavURL(_ id: String) -> URL { localURL("amsg_\(id)_mono.wav") }

    // MARK: persisted index
    private func loadIdx() -> [String: IdxEntry] {
        guard let d = defaults.data(forKey: "lib"),
              let v = try? JSONDecoder().decode([String: IdxEntry].self, from: d) else { return [:] }
        return v
    }

    private func saveIdx(_ v: [String: IdxEntry]) {
        if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: "lib") }
    }

    func refreshLibrary() {
        var idx = loadIdx()
        if connected {  // reconcile ring state: files = current list
            for k in idx.keys { idx[k]?.onRing = false }
            for (name, size) in files {
                guard let id = Self.recId(name) else { continue }
                var o = idx[id] ?? IdxEntry()
                o.onRing = true
                if name.hasSuffix(".opus") { o.ringSize = Int64(size) }
                if let dur = durById[id] { o.dur = dur }
                idx[id] = o
            }
        }
        // local scan
        var localSz: [String: Int64] = [:]
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: Self.docs.path) {
            for n in names where n.hasSuffix("_mono.opus") {
                if let id = Self.recId(n) {
                    let sz = (try? fm.attributesOfItem(atPath: localURL(n).path)[.size] as? NSNumber)?.int64Value ?? 0
                    localSz[id] = sz
                }
            }
        }
        // union (index + local), newest on top
        let ids = Set(idx.keys).union(localSz.keys).sorted { (Int64($0) ?? 0) > (Int64($1) ?? 0) }
        var out: [Rec] = []
        for id in ids {
            let saved = localSz[id] != nil
            let o = idx[id]
            let onRing = o?.onRing ?? false
            if !saved && !onRing {  // gone from ring and not on phone -> drop
                idx.removeValue(forKey: id)
                continue
            }
            var dur = durById[id]
            if dur == nil, let d = o?.dur {
                dur = d
                durById[id] = d
            }
            if dur == nil { dur = OpusAudio.wavDurationMs(wavURL(id)) }
            let size = saved ? localSz[id]! : (o?.ringSize ?? -1)
            out.append(Rec(id: id, name: "amsg_\(id)_mono.opus", size: size, durationMs: dur,
                           onRing: onRing, savedLocal: saved))
        }
        saveIdx(idx)
        library = out
        DispatchQueue.main.async { [weak self] in self?.autoQueueMissing() }
    }

    func deleteLocal(_ id: String) {
        if playingId == id { stopPlay() }
        try? FileManager.default.removeItem(at: localURL("amsg_\(id)_mono.opus"))
        try? FileManager.default.removeItem(at: wavURL(id))
        log("deleted local \(id)")
        toast("deleted from phone")
        onDeletedLocal(id)
        refreshLibrary()
    }

    // MARK: automatic .json (duration) prefetch
    private func autoQueueMissing() {
        for n in files.keys where n.hasSuffix(".json") {
            if let id = Self.recId(n), durById[id] == nil, !jsonQ.contains(n) { jsonQ.append(n) }
        }
        pumpJson()
    }

    /// New recordings announced by the ring (0x13) are downloaded before anything else.
    private func pumpAuto() -> Bool {
        guard !downloading, connected, !autoQueue.isEmpty else { return false }
        let name = autoQueue.removeFirst()
        if FileManager.default.fileExists(atPath: localURL(name).path) { return pumpAuto() }
        log("auto-download \(name)")
        autoJson = false
        reqFile(name)
        return true
    }

    private func pumpJson() {
        if pumpAuto() { return }
        guard !downloading, !jsonQ.isEmpty, connected else { return }
        autoJson = true
        reqFile(jsonQ.removeFirst())
    }

    /// The file is a stream of comma-separated objects, e.g.
    ///   {"record":[...]},{"duration":["<start>","<end>"]},{"record":[...]}
    /// Wrap in [] and take the end (index 1) of "duration" as ms.
    private func parseDur(_ name: String, _ c: Data) {
        guard let id = Self.recId(name) else { return }
        let wrapped = Data("[".utf8) + c + Data("]".utf8)
        guard let arr = try? JSONSerialization.jsonObject(with: wrapped) as? [[String: Any]] else {
            log("duration parse failed for \(id)")
            return
        }
        for ev in arr {
            if let d = ev["duration"] as? [Any], d.count >= 2 {
                let ms = (d[1] as? String).flatMap(Int.init) ?? (d[1] as? NSNumber)?.intValue
                if let ms {
                    durById[id] = ms
                    log("duration \(id)=\(ms)ms")
                    return
                }
            }
        }
    }

    // MARK: downloads
    func download(_ name: String) {
        guard connected else { toast("connect the ring"); return }
        guard !downloading else { toast("download in progress"); return }
        reqFile(name)
    }

    private func reqFile(_ name: String) {
        curFile = name
        downloading = true
        downloadingName = autoJson ? nil : name
        fileBuf = Data()
        log((autoJson ? "auto-json " : "DOWNLOAD ") + name)
        if !autoJson { toast("downloading…") }
        sendRead(name)
    }

    private func saveFile() {
        guard let cur = curFile else { downloading = false; return }
        if cur.hasSuffix(".json") { parseDur(cur, fileBuf) }
        if !autoJson {
            do {
                try fileBuf.write(to: localURL(cur), options: .atomic)
                log("SAVED \(cur) (\(fileBuf.count)B)")
                toast("saved")
                if cur.hasSuffix(".opus"), let id = Self.recId(cur) {
                    DispatchQueue.main.async { self.onDownloaded(id) }
                }
            } catch {
                log("save error: \(error)")
            }
        }
        downloading = false
        downloadingName = nil
    }

    func requestList() {
        collecting = [:]
        sendList()
    }

    func manualRefresh() {
        guard connected else { toast("connect first"); return }
        guard !downloading else { toast("download in progress"); return }
        log("manual list refresh")
        toast("refreshing…")
        requestList()
    }

    func deleteRing(_ id: String) {
        guard connected else { toast("connect first"); return }
        let names = files.keys.filter { Self.recId($0) == id }
        guard !names.isEmpty else { toast("not in the ring list"); return }
        for n in names {
            log("DELETE on ring: 0x17 [02] \(n)")
            sendDelete(n)
        }
        toast("deleting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.connected, !self.downloading else { return }
            self.requestList()
        }
    }

    /// A download-stream chunk arrived on the DATA characteristic.
    func onFileData(_ chunk: [UInt8]) {
        if downloading { fileBuf.append(contentsOf: chunk) }
    }

    /// Recording-related control opcodes (RX already logged).
    func onLibraryCtrl(_ op: Int, _ d: [UInt8]) {
        let asc = String(bytes: d, encoding: .isoLatin1) ?? ""
        if op == 0x11 {
            if let name = Self.firstMatch(#"[A-Za-z0-9_]+_mono\.(json|opus)"#, in: asc) {
                let size = d.count >= 5 ? (Int(d[3]) << 8 | Int(d[4])) : 0
                if collecting != nil { collecting![name] = size } else { files[name] = size }
                recDebounce?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if let c = self.collecting {
                        self.files = c
                        self.collecting = nil
                    }
                    self.refreshLibrary()
                }
                recDebounce = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        } else if op == 0x13 {
            let f = Self.firstMatch(#"[A-Za-z0-9_]+_mono\.opus"#, in: asc) ?? "?"
            if f != "?" { files[f] = 0 }
            eventText = "BUTTON → new recording: \(f)"
            log("BUTTON/recording: \(f)")
            if f != "?", shouldAutoDownload(), !autoQueue.contains(f) { autoQueue.append(f) }
            refreshLibrary()
            if !downloading { requestList() }
        } else if op == 0x17, d.count >= 2, d[0] == 0x02 {
            let nl = Int(d[1])
            let nm = d.count >= 2 + nl ? (String(bytes: d[2..<2 + nl], encoding: .isoLatin1) ?? "?") : "?"
            log("delete OK on ring: \(nm)")
        } else if op == 0x17, d.count >= 2 {
            let n = Int(d[0]) << 8 | Int(d[1])
            var s = "queue(\(n)):"
            var o = 2
            var i = 0
            while i < n && o + 5 <= d.count {
                let id = Int64(d[o]) << 24 | Int64(d[o + 1]) << 16 | Int64(d[o + 2]) << 8 | Int64(d[o + 3])
                s += " #\(id)(st\(d[o + 4]))"
                i += 1
                o += 6
            }
            log(s)
        } else if op == 0x12, d.first == 0x02, downloading {
            log("transfer complete \(curFile ?? "?") (\(fileBuf.count)B)")
            let wasAuto = autoJson
            saveFile()
            autoJson = false
            if wasAuto {  // auto-json: refresh only when the queue drains
                if jsonQ.isEmpty && autoQueue.isEmpty { refreshLibrary() } else { pumpJson() }
            } else {
                refreshLibrary()
                if connected { requestList() }
            }
        }
    }

    func onLibraryDisconnected() {
        jsonQ.removeAll()
        autoQueue.removeAll()
        autoJson = false
        if downloading {
            log("download aborted by disconnect")
            downloading = false
            downloadingName = nil
        }
    }
}
