import Foundation
import IOKit

// Journal d'usage : tant que c'est actif, un échantillon toutes les dix secondes
// dans un CSV posé sur le Bureau — alimentation, batterie, processeur, GPU,
// pression thermique. C'est l'outil qui a servi à calibrer les estimations,
// intégré à l'app pour pouvoir enregistrer « un peu tout le temps » sans
// terminal : un fichier par activation, nommé à l'heure de départ, écrit au fil
// de l'eau — l'arrêt brutal ne perd donc que la dernière ligne au pire.
//
// CE QU'ON ÉCRIT, ET POURQUOI CES COLONNES-LÀ. Les colonnes batterie sont celles
// que la calibration a montrées fiables (TrueRemainingCapacity, Amperage signé,
// tension) plus l'état qui permet de les interpréter : branché, en charge, watts
// de l'adaptateur — indispensable depuis qu'on sait que la charge suspendue fait
// mentir `ExternalConnected` et que le drain branché-inhibé ne mesure pas la
// consommation. Le processeur est un pourcentage 0-100 moyenné sur tous les
// cœurs (delta de ticks entre deux échantillons) ; le GPU vient de
// `PerformanceStatistics` de l'accélérateur ; la pression thermique de
// `ProcessInfo`, seule sonde de cette machine (aucune clé de température, ni
// IORegistry ni SMC — vérifié sur les 2 494 clés).
//
// La veille ne s'enregistre pas : le minuteur s'arrête avec la machine et
// reprend au réveil — le trou dans les horodatages EST l'information.
enum UsageLog {

    /// Dix secondes : assez fin pour suivre une charge ou un pic d'activité,
    /// assez espacé pour que le coût soit invisible (quelques lectures
    /// IORegistry et un comptage de ticks par échantillon).
    static let interval: TimeInterval = 10

    /// Destination des fichiers. Le banc d'essai la remplace pour ne pas écrire
    /// sur le vrai Bureau pendant les tests.
    static var destination = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    private static var timer: DispatchSourceTimer?
    private static var handle: FileHandle?

    static var isActive: Bool { timer != nil }

    /// Bascule, comme les autres boutons de la rangée. `false` si le fichier n'a
    /// pas pu être créé — premier lancement sans l'accès au Bureau, par exemple :
    /// macOS le demande à la première écriture, et un refus rend la création
    /// muette. L'appelant affiche alors l'alerte.
    @discardableResult
    static func toggle() -> Bool {
        if isActive { stop(); return true }
        return start()
    }

    @discardableResult
    static func start() -> Bool {
        guard timer == nil else { return true }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // Des points, pas des deux-points : un nom de fichier avec `:` se
        // réécrit en `/` dans le Finder et sème la confusion.
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = destination
            .appendingPathComponent(L("monitor.filename", stamp.string(from: Date())))

        let header = "time,plugged,charging,adapter_w,level_pct,true_mah,mv,ma,"
                   + "instant_ma,battery_mw,cpu_pct,gpu_pct,thermal,low_power\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)),
              let opened = try? FileHandle(forWritingTo: url)
        else { return false }
        opened.seekToEndOfFile()
        handle = opened

        // Pose l'ancre des ticks processeur : le premier échantillon a ainsi un
        // vrai delta au lieu d'une case vide.
        cpuTicks = readCpuTicks()

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { sample() }
        source.resume()
        timer = source
        sample()
        return true
    }

    static func stop() {
        timer?.cancel()
        timer = nil
        try? handle?.close()
        handle = nil
        cpuTicks = nil
    }

    // MARK: - Échantillon

    private static let rowStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let thermalNames: [ProcessInfo.ThermalState: String] =
        [.nominal: "nominal", .fair: "fair", .serious: "serious", .critical: "critical"]

    private static func sample() {
        guard let handle else { return }
        let battery = BatteryTime.batterySnapshot() ?? [:]
        let data = battery["BatteryData"] as? [String: Any]
        let adapter = battery["AdapterDetails"] as? [String: Any]

        // Les compteurs signés de l'IORegistry sont stockés non signés : sans la
        // réinterprétation, une décharge s'écrirait comme un nombre astronomique.
        func number(_ value: Any?) -> String {
            (value as? NSNumber).map { "\($0.intValue)" } ?? ""
        }
        func signed(_ value: Any?) -> String {
            (value as? NSNumber).map { String(Int64(bitPattern: $0.uint64Value)) } ?? ""
        }
        func flag(_ value: Any?) -> String {
            (value as? NSNumber).map { $0.intValue != 0 ? "1" : "0" } ?? ""
        }

        let fields = [
            rowStamp.string(from: Date()),
            flag(battery["ExternalConnected"]),
            flag(battery["IsCharging"]),
            number(adapter?["Watts"]),
            number(battery["CurrentCapacity"]),
            number(data?["TrueRemainingCapacity"]),
            number(battery["Voltage"]),
            signed(battery["Amperage"]),
            signed(battery["InstantAmperage"]),
            signed(data?["BatteryPower"]),
            cpuPercent().map(String.init) ?? "",
            gpuPercent().map(String.init) ?? "",
            thermalNames[ProcessInfo.processInfo.thermalState] ?? "unknown",
            BatteryTime.lowPowerMode().map { $0 ? "1" : "0" } ?? "",
        ]
        handle.write(Data((fields.joined(separator: ",") + "\n").utf8))
    }

    // MARK: - Processeur

    private static var cpuTicks: (busy: UInt64, total: UInt64)?

    /// Pourcentage 0-100 moyenné sur tous les cœurs depuis l'échantillon
    /// précédent. Les ticks par cœur sont des compteurs 32 bits à ~100 Hz : le
    /// débordement prend des mois, on ne s'en protège pas.
    private static func cpuPercent() -> Int? {
        guard let now = readCpuTicks() else { return nil }
        defer { cpuTicks = now }
        // Une cinquantaine de ticks au moins (un dixième de seconde de machine) :
        // en dessous, le rapport est un tirage au sort — le tout premier
        // échantillon, pris dans la microseconde qui suit la pose de l'ancre,
        // rendrait 0 ou 100 selon le tick tombé entre les deux lectures.
        guard let previous = cpuTicks, now.total >= previous.total + 50 else { return nil }
        let percent = Double(now.busy - previous.busy) / Double(now.total - previous.total) * 100
        return min(max(Int(percent.rounded()), 0), 100)
    }

    private static func readCpuTicks() -> (busy: UInt64, total: UInt64)? {
        var cpus = natural_t(0)
        var info: processor_info_array_t?
        var count = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpus, &info, &count) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    // MARK: - GPU

    /// `Device Utilization %` des `PerformanceStatistics` de l'accélérateur.
    /// Un seul GPU sur cette machine ; s'il y en avait plusieurs, le premier qui
    /// publie la statistique gagne.
    private static func gpuPercent() -> Int? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { return nil }
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
                  let value = (statistics["Device Utilization %"] as? NSNumber)?.intValue
            else { continue }
            return min(max(value, 0), 100)
        }
    }
}
