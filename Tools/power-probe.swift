#!/usr/bin/env swift
// Diagnostic : que renvoie macOS pour le temps restant, et ce compteur tient-il
// compte de la limite de charge (MCL) ?
//
//   swiftc -O Tools/power-probe.swift -o power-probe
//   ./power-probe [intervalle_en_secondes]      (défaut : 20)
//
// Premier échantillon : dump intégral des clés, pour ne rien deviner.
// Ensuite : une ligne par échantillon, horodatée.

import Foundation
import IOKit
import IOKit.ps

// MARK: - Limite de charge (PowerUI), pour corréler avec les compteurs système

@objc protocol SmartChargeProbe {
    func isMCLSupported() -> Bool
    func getMCLLimitWithError(_ error: UnsafeMutablePointer<NSError?>?) -> UInt8
}

let mclClient: SmartChargeProbe? = {
    guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
          let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type
    else { return nil }
    let object = cls.init()
    let designated = Selector(("initWithClientName:"))
    guard object.responds(to: designated) else { return nil }
    _ = object.perform(designated, with: "power-probe")
    guard ["isMCLSupported", "getMCLLimitWithError:"]
        .allSatisfy({ object.responds(to: Selector(($0))) }) else { return nil }
    return unsafeBitCast(object, to: SmartChargeProbe.self)
}()

func currentMCL() -> String {
    guard let mclClient else { return "?" }
    var error: NSError?
    let value = mclClient.getMCLLimitWithError(&error)
    return error == nil && value > 0 ? "\(value)" : "?"
}

// MARK: - Sources d'alimentation (IOKit public)

/// Description de la batterie interne telle que la fournit IOPowerSources.
func powerSourceDescription() -> [String: Any]? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(blob, source)?
            .takeUnretainedValue() as? [String: Any] else { continue }
        if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            return description
        }
    }
    return nil
}

/// Quelques clés d'AppleSmartBattery, pour recouper ce que dit IOPowerSources.
func smartBatteryProperties() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            == KERN_SUCCESS else { return nil }
    return unmanaged?.takeRetainedValue() as? [String: Any]
}

// MARK: - Mise en forme

/// Piège CoreFoundation : `nombre as? Bool` réussit pour n'importe quel NSNumber
/// valant 0 ou 1, si bien qu'un entier 0 s'afficherait « non ». Seul le type
/// CoreFoundation dit si la valeur est vraiment un booléen.
func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
}

func text(_ value: Any?) -> String {
    guard let value else { return "—" }
    if isBoolean(value) { return (value as! NSNumber).boolValue ? "oui" : "non" }
    if let number = value as? NSNumber { return "\(number)" }
    if let string = value as? String { return string }
    return "\(value)"
}

/// Les compteurs macOS valent -1 tant que l'estimation n'est pas stabilisée, et
/// AppleSmartBattery utilise 65535 (0xFFFF) comme « sans objet ».
func minutes(_ value: Any?) -> String {
    guard let value, !isBoolean(value), let number = value as? NSNumber else { return "—" }
    let n = number.intValue
    if n < 0 { return "calcul" }
    if n == 65535 { return "n/a" }
    return "\(n)min"
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

// MARK: - Dump initial

func dumpEverything() {
    print("================ DUMP INITIAL ================")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("MCL courant : \(currentMCL()) %")
    print("MCL supporté : \(mclClient?.isMCLSupported() ?? false)")

    print("\n--- IOPSGetPowerSourceDescription : TOUTES les clés ---")
    if let description = powerSourceDescription() {
        for key in description.keys.sorted() {
            print("  \(pad(key, 34)) = \(text(description[key]))")
        }
    } else {
        print("  (aucune batterie interne trouvée)")
    }

    print("\n--- AppleSmartBattery : clés liées au temps et à la charge ---")
    if let properties = smartBatteryProperties() {
        let interesting = ["AvgTimeToFull", "AvgTimeToEmpty", "TimeRemaining", "IsCharging",
                           "FullyCharged", "ExternalConnected", "ExternalChargeCapable",
                           "CurrentCapacity", "MaxCapacity", "AppleRawCurrentCapacity",
                           "AppleRawMaxCapacity", "NominalChargeCapacity", "DesignCapacity",
                           "Amperage", "InstantAmperage", "Voltage", "PostChargeWaitSeconds"]
        for key in interesting where properties[key] != nil {
            print("  \(pad(key, 34)) = \(text(properties[key]))")
        }
        if let charger = properties["ChargerData"] as? [String: Any] {
            print("  ChargerData :")
            for key in charger.keys.sorted() where !(charger[key] is Data) {
                print("      \(pad(key, 30)) = \(text(charger[key]))")
            }
        }
    } else {
        print("  (AppleSmartBattery illisible)")
    }
    print("==============================================\n")
}

// MARK: - Échantillonnage

func header() {
    print(pad("heure", 9) + pad("MCL", 5) + pad("src", 6) + pad("charge", 8)
          + pad("niveau", 8) + pad("TTEmpty", 9) + pad("TTFull", 9)
          + pad("ASB.AvgTTF", 11) + pad("ASB.TTRem", 10) + pad("mA", 8) + "NotChargingReason")
    print(String(repeating: "-", count: 100))
}

func sample() {
    let description = powerSourceDescription()
    let battery = smartBatteryProperties()
    let charger = battery?["ChargerData"] as? [String: Any]

    let capacity = (description?[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue
    let maximum = (description?[kIOPSMaxCapacityKey] as? NSNumber)?.intValue
    let level = capacity.map { "\($0)/\(maximum ?? 100)" } ?? "—"

    // Amperage est un entier non signé dans ioreg : négatif = décharge.
    var milliamps = "—"
    if let raw = (battery?["InstantAmperage"] as? NSNumber)?.uint64Value {
        milliamps = "\(Int64(bitPattern: raw))"
    }

    var charging = text(description?[kIOPSIsChargingKey])
    if description?[kIOPSIsChargedKey] as? Bool == true { charging += "/plein" }
    if description?["Is Finishing Charge"] as? Bool == true { charging += "/fin" }

    print(pad(clock.string(from: Date()), 9)
        + pad(currentMCL(), 5)
        // Sans espace : « AC Power » casserait le découpage en colonnes.
        + pad(text(description?[kIOPSPowerSourceStateKey]) == kIOPSACPowerValue ? "AC" : "batt", 6)
        + pad(charging, 8)
        + pad(level, 8)
        + pad(minutes(description?[kIOPSTimeToEmptyKey]), 9)
        + pad(minutes(description?[kIOPSTimeToFullChargeKey]), 9)
        + pad(minutes(battery?["AvgTimeToFull"]), 11)
        + pad(minutes(battery?["TimeRemaining"]), 10)
        + pad(milliamps, 8)
        + text(charger?["NotChargingReason"]))
    fflush(stdout)
}

// MARK: -

setvbuf(stdout, nil, _IONBF, 0)
let interval = CommandLine.arguments.dropFirst().compactMap(Double.init).first ?? 20

dumpEverything()
print("Échantillonnage toutes les \(Int(interval)) s. Ctrl-C pour arrêter.\n")
header()
sample()

Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in sample() }
RunLoop.main.run()
