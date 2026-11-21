import Foundation

/// A JSON Schema validator written for exactly the keywords the vendored schemas use (SpaceState's, the timeline's): a
/// test first asserts its schema uses no other (`usedKeywords`), so a schema that grows one fails there rather than
/// passing unchecked. `$ref` resolves only as `#/$defs/<name>`. `validate` answers [] for a valid document, else
/// "path: why" lines.
enum JSONSchemaCheck {
    static let keywords: Set<String> = ["$schema", "$id", "$defs", "$ref", "title", "description", "type", "additionalProperties", "required",
                                        "properties", "const", "enum", "items", "pattern", "minLength", "maxLength", "allOf", "anyOf", "if",
                                        "then", "else", "not",
                                        // 747: the timeline schema's
                                        "format", "maxProperties", "maximum", "minimum", "minItems", "oneOf", "propertyNames"]

    /// Every keyword the schema uses, at every level (property and definition names are not keywords).
    static func usedKeywords(_ s: Any) -> Set<String> {
        guard let o = s as? [String: Any] else { return [] }
        var out = Set(o.keys)
        for (k, v) in o {
            switch k {
            case "properties", "$defs": for sub in (v as? [String: Any] ?? [:]).values { out.formUnion(usedKeywords(sub)) }
            case "allOf", "anyOf", "oneOf": for sub in v as? [Any] ?? [] { out.formUnion(usedKeywords(sub)) }
            case "items", "if", "then", "else", "not", "additionalProperties", "propertyNames": out.formUnion(usedKeywords(v))
            default: break
            }
        }
        return out
    }

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if isBool(a) != isBool(b) { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }

    static func validate(_ v: Any, _ root: [String: Any]) -> [String] {
        var errors: [String] = []
        check(v, root, root, "", &errors)
        return errors
    }

    static func isType(_ v: Any, _ t: String) -> Bool {
        switch t {
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "string": return v is String
        case "boolean": return isBool(v)
        case "integer": return !isBool(v) && (v as? NSNumber).map { $0.doubleValue == $0.doubleValue.rounded() } == true
        case "number": return !isBool(v) && v is NSNumber
        case "null": return v is NSNull
        default: return false
        }
    }

    static func check(_ v: Any, _ s: [String: Any], _ root: [String: Any], _ at: String, _ errors: inout [String]) {
        func fail(_ m: String) { errors.append("\(at.isEmpty ? "/" : at): \(m)") }
        func valid(_ sub: Any, _ x: Any? = nil) -> Bool {
            var e: [String] = []
            check(x ?? v, sub as? [String: Any] ?? [:], root, at, &e)
            return e.isEmpty
        }
        if let ref = s["$ref"] as? String {
            let name = ref.replacingOccurrences(of: "#/$defs/", with: "")
            guard let sub = (root["$defs"] as? [String: Any])?[name] as? [String: Any] else { return fail("no definition \(ref)") }
            check(v, sub, root, at, &errors)
        }
        if let t = s["type"] as? String, !isType(v, t) { fail("not of type \(t)") }
        if let ts = s["type"] as? [String], !ts.contains(where: { isType(v, $0) }) { fail("not of type \(ts)") }
        if let c = s["const"], !same(v, c) { fail("not \(c)") }
        if let e = s["enum"] as? [Any], !e.contains(where: { same(v, $0) }) { fail("not one of \(e)") }
        if let str = v as? String {
            let n = str.utf16.count
            if let m = s["minLength"] as? Int, n < m { fail("shorter than \(m)") }
            if let m = s["maxLength"] as? Int, n > m { fail("longer than \(m)") }
            if let p = s["pattern"] as? String, str.range(of: p, options: .regularExpression) == nil { fail("does not match \(p)") }
            if s["format"] as? String == "regex", (try? NSRegularExpression(pattern: str)) == nil { fail("not a regular expression") }
        }
        if !isBool(v), let n = v as? NSNumber {
            if let m = s["minimum"] as? NSNumber, n.doubleValue < m.doubleValue { fail("below \(m)") }
            if let m = s["maximum"] as? NSNumber, n.doubleValue > m.doubleValue { fail("above \(m)") }
        }
        if let o = v as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for r in s["required"] as? [String] ?? [] where o[r] == nil { fail("\(r) is required") }
            if let m = s["maxProperties"] as? Int, o.count > m { fail("more than \(m) properties") }
            if let pn = s["propertyNames"] {
                for k in o.keys where !valid(pn, k) { fail("the name \(k) is not allowed") }
            }
            for (k, x) in o {
                if let sub = props[k] as? [String: Any] { check(x, sub, root, at + "/" + k, &errors) }
                else if let ap = s["additionalProperties"] {
                    if isBool(ap), (ap as? Bool) == false { fail("\(k) is not allowed") }
                    else if let sub = ap as? [String: Any] { check(x, sub, root, at + "/" + k, &errors) }
                }
            }
        }
        if let a = v as? [Any] {
            if let items = s["items"] as? [String: Any] { for (i, x) in a.enumerated() { check(x, items, root, at + "/\(i)", &errors) } }
            if let m = s["minItems"] as? Int, a.count < m { fail("fewer than \(m) items") }
        }
        for sub in s["allOf"] as? [Any] ?? [] { check(v, sub as? [String: Any] ?? [:], root, at, &errors) }
        if let any = s["anyOf"] as? [Any], !any.contains(where: { valid($0) }) { fail("none of anyOf") }
        if let one = s["oneOf"] as? [Any] {
            let n = one.filter { valid($0) }.count
            if n != 1 { fail(n == 0 ? "none of oneOf" : "more than one of oneOf") }
        }
        if let n = s["not"], valid(n) { fail("matches what not forbids") }
        if let i = s["if"] {
            if valid(i) { if let t = s["then"] as? [String: Any] { check(v, t, root, at, &errors) } }
            else if let e = s["else"] as? [String: Any] { check(v, e, root, at, &errors) }
        }
    }
}
