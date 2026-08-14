import Foundation
import IOKit

// Accès au SMC — le contrôleur d'alimentation.
//
// Partagé entre l'app, qui LIT sans aucun droit, et le helper, qui ÉCRIT sous
// root. Le protocole est le même des deux côtés, et le dupliquer ferait diverger
// deux copies d'un code où une erreur d'offset ne lève aucune erreur : elle
// rend simplement un dialogue muet.
//
// LA STRUCTURE FAIT 80 OCTETS, avec l'alignement C :
//
//     0  key(4)   4  vers(6)  [2 de bourrage]  12 pLimitData(16)
//     28 keyInfo(12)          40 result  41 status  42 data8  [bourrage]
//     44 data32               48 bytes(32)
//
// Ces offsets ont été trouvés à la main : une première version les plaçait à 20,
// 29 et 36, et toutes les lectures revenaient « clé absente » — y compris `#KEY`,
// qui existe forcément. D'où la vérification intégrée plus bas : si `#KEY` ne
// répond pas, c'est le client qui est faux, pas la machine.
//
// LE NOM DE CLÉ VOYAGE COMME UN ENTIER 32 BITS. Sur une machine petit-boutienne
// les quatre lettres se retrouvent donc inversées en mémoire. Les écrire dans
// l'ordre de lecture donne `result = 132`, code SMC pour « clé inconnue ».

public enum SMC {

    private static let size = 80
    private static let oKey = 0, oDataSize = 28, oDataType = 32, oAttributes = 36
    private static let oResult = 40, oData8 = 42, oData32 = 44, oBytes = 48

    /// Sélecteur du pilote. Les sélecteurs 0 et 1 répondent aussi, mais ne
    /// traitent pas les clés — seul le 2 rend un code de résultat exploitable.
    private static let selector: UInt32 = 2

    private static let opRead: UInt8 = 5, opWrite: UInt8 = 6
    private static let opInfo: UInt8 = 9, opKeyFromIndex: UInt8 = 8

    /// Bit d'attribut marquant une clé inscriptible. Ce n'est pas 0x02 —
    /// erreur commise puis corrigée : elle faisait passer les 16 clés
    /// inscriptibles de la machine pour de la lecture seule.
    public static let attributeWritable: UInt8 = 0x40

    public struct Connection {
        fileprivate let port: io_connect_t

        public init?() {
            let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                      IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            var port: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &port) == kIOReturnSuccess
            else { return nil }
            self.port = port
        }

        public func close() { IOServiceClose(port) }
    }

    // MARK: - Encodage

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func put32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset]     = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func get32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }

    private static func call(_ connection: Connection, _ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: size)
        var length = size
        guard IOConnectCallStructMethod(connection.port, selector,
                                        &input, size, &output, &length) == kIOReturnSuccess
        else { return nil }
        return output
    }

    // MARK: - Lecture

    /// Taille, type et attributs d'une clé. Le SMC exige cette fiche avant toute
    /// lecture ou écriture : il refuse une requête dont la taille annoncée ne
    /// correspond pas à la sienne.
    public static func info(_ connection: Connection,
                            _ key: String) -> (size: UInt32, type: UInt32, attributes: UInt8)? {
        var buffer = [UInt8](repeating: 0, count: size)
        put32(&buffer, oKey, fourCC(key))
        buffer[oData8] = opInfo
        guard let out = call(connection, &buffer), out[oResult] == 0 else { return nil }
        return (get32(out, oDataSize), get32(out, oDataType), out[oAttributes])
    }

    /// Octets bruts d'une clé, `nil` si elle n'existe pas. Ne demande aucun droit.
    public static func read(_ connection: Connection, _ key: String) -> [UInt8]? {
        guard let meta = info(connection, key), meta.size > 0, meta.size <= 32
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        put32(&buffer, oKey, fourCC(key))
        buffer[oData8] = opRead
        put32(&buffer, oDataSize, meta.size)
        put32(&buffer, oDataType, meta.type)
        guard let out = call(connection, &buffer), out[oResult] == 0 else { return nil }
        return Array(out[oBytes..<(oBytes + Int(meta.size))])
    }

    /// Contrôle d'intégrité : `#KEY` compte les clés exposées et existe toujours.
    /// Un `nil` ici veut dire que le dialogue est cassé, pas que la machine est
    /// pauvre en clés — c'est la distinction qui a coûté trois essais.
    public static func keyCount(_ connection: Connection) -> UInt32? {
        read(connection, "#KEY").map { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    }

    // MARK: - Écriture

    /// Écrit une clé. **Exige root** : sans lui le pilote répond
    /// `kIOReturnNotPrivileged` (0xe00002c1) sans rien modifier.
    ///
    /// Volontairement non public au-delà du module : c'est le helper qui décide
    /// ce qui a le droit d'être écrit, pas l'appelant.
    public static func write(_ connection: Connection, _ key: String, _ value: [UInt8]) -> Bool {
        guard let meta = info(connection, key), Int(meta.size) == value.count
        else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        put32(&buffer, oKey, fourCC(key))
        buffer[oData8] = opWrite
        put32(&buffer, oDataSize, meta.size)
        put32(&buffer, oDataType, meta.type)
        for (index, byte) in value.enumerated() { buffer[oBytes + index] = byte }
        guard let out = call(connection, &buffer) else { return false }
        return out[oResult] == 0
    }

    // MARK: - Énumération

    /// Nom de la clé d'indice donné. Sert à découvrir ce que la machine expose
    /// au lieu de deviner des noms : sur ce Mac, `CH0B` et `BCLM` — les clés que
    /// tout le monde cite — n'existent tout simplement pas.
    public static func key(_ connection: Connection, at index: UInt32) -> String? {
        var buffer = [UInt8](repeating: 0, count: size)
        buffer[oData8] = opKeyFromIndex
        put32(&buffer, oData32, index)
        guard let out = call(connection, &buffer), out[oResult] == 0 else { return nil }
        let raw = get32(out, oKey)
        let letters = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                       UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(bytes: letters.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii)
    }
}
