// Genera las tablas de idioma de la app a partir de los textos que extrae el compilador.
//
//   swift Scripts/localize.swift <dir .stringsdata> <Localization/en.json> <Contents/Resources>
//
// - Claves: el texto en español tal como está en el código (con %@, %lld… donde hay variables).
// - en.lproj: traducción de Localization/en.json. Es el idioma base (CFBundleDevelopmentRegion = en).
// - es.lproj: el propio texto de la clave.
// Falla si falta alguna traducción o si una traducción no tiene las mismas variables que su clave.
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("uso: localize.swift <stringsdata> <en.json> <Resources>\n".data(using: .utf8)!)
    exit(2)
}
let dataDir = URL(fileURLWithPath: args[1])
let enURL = URL(fileURLWithPath: args[2])
let resources = URL(fileURLWithPath: args[3])

// 1. Claves que usa el código
var keys = Set<String>()
let files = (try? FileManager.default.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
for f in files where f.pathExtension == "stringsdata" {
    guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any],
          let tables = json["tables"] as? [String: [[String: Any]]] else { continue }
    for item in tables["Localizable"] ?? [] { if let k = item["key"] as? String { keys.insert(k) } }
}
guard !keys.isEmpty else { print("localize: no se encontraron textos (¿falta -emit-localized-strings?)"); exit(1) }

// 2. Traducciones
guard let en = (try? JSONSerialization.jsonObject(with: Data(contentsOf: enURL))) as? [String: String] else {
    print("localize: no se pudo leer \(enURL.path)"); exit(1)
}

/// Variables de un formato sin posiciones: "%1$@ y %2$lld" → ["@", "lld"] en orden de posición.
func specifiers(_ s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|ld|d|@|f|lf|llu|lu|u)"#)
    let ns = s as NSString
    var items: [(Int, String)] = []
    var next = 1
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let posRange = m.range(at: 1)
        let pos = posRange.location != NSNotFound ? Int(ns.substring(with: posRange))! : next
        next += 1
        items.append((pos, ns.substring(with: m.range(at: 2))))
    }
    return items.sorted { $0.0 < $1.0 }.map(\.1)
}

let meaningful = keys.filter { $0.rangeOfCharacter(from: .letters) != nil }
let missing = meaningful.filter { en[$0] == nil }.sorted()
let mismatched = meaningful.compactMap { k -> String? in
    guard let v = en[k], specifiers(k) != specifiers(v) else { return nil }
    return "\(k)  →  \(v)"
}.sorted()
let unused = Set(en.keys).subtracting(keys).sorted()

if !unused.isEmpty { print("localize: \(unused.count) traducciones sin usar en en.json (se pueden borrar):\n  " + unused.joined(separator: "\n  ")) }
if !missing.isEmpty || !mismatched.isEmpty {
    if !missing.isEmpty { print("localize: faltan \(missing.count) traducciones en en.json:\n  " + missing.joined(separator: "\n  ")) }
    if !mismatched.isEmpty { print("localize: variables distintas entre clave y traducción:\n  " + mismatched.joined(separator: "\n  ")) }
    exit(1)
}

// 3. Tablas .strings
func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
}
func write(_ lang: String, _ value: (String) -> String) throws {
    let dir = resources.appendingPathComponent("\(lang).lproj")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = keys.sorted().map { "\"\(escape($0))\" = \"\(escape(value($0)))\";" }.joined(separator: "\n") + "\n"
    try body.write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
}
do {
    try write("en") { en[$0] ?? $0 }
    try write("es") { $0 }
} catch {
    print("localize: \(error.localizedDescription)"); exit(1)
}
print("localize: \(keys.count) textos · en, es")
