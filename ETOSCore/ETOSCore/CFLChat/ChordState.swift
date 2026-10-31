import Foundation

// The Lamplit singleton view is a JSON value carried by Chord's state codec.
enum ChordJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([ChordJSON]), object([String: ChordJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ChordJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ChordJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var object: [String: ChordJSON]? { if case .object(let x) = self { return x }; return nil }
    var array: [ChordJSON]? { if case .array(let x) = self { return x }; return nil }
    var string: String? { if case .string(let x) = self { return x }; return nil }
    var integer: Int? {
        guard case .number(let n) = self, n.isFinite, n >= 0, n.rounded() == n, n <= Double(Int.max / 2) else { return nil }
        return Int(n)
    }
}

enum ChordError: Error { case invalid }

struct ChordState {
    private(set) var value: ChordJSON?
    private(set) var sequence: Int?
    private var paths: [Int: [ChordJSON]] = [:]

    mutating func hydrate(_ snapshot: ChordJSON) throws {
        guard let s = snapshot.object, s["serviceId"]?.string == "lamplit.chat.v2",
              s["mode"]?.string == "singleton", let instances = s["instances"]?.array,
              instances.count == 1, let instance = instances[0].object, instance["instance"] == nil,
              let members = instance["members"]?.array,
              let member = members.compactMap(\.object).first(where: { $0["name"]?.string == "view" && $0["kind"]?.string == "state" }),
              let seq = member["sequence"]?.integer, let ops = member["ops"]?.array,
              ops.first?.array?.first?.string == "r" else { throw ChordError.invalid }
        paths.removeAll(); value = nil
        try apply(ops)
        guard value != nil else { throw ChordError.invalid }
        sequence = seq
    }

    mutating func update(_ update: ChordJSON) throws {
        guard let obj = update.object, let type = obj["type"]?.string else { throw ChordError.invalid }
        switch type {
        case "reset":
            guard let snapshot = obj["snapshot"] else { throw ChordError.invalid }
            try hydrate(snapshot)
        case "replaced":
            guard let instance = obj["snapshot"] else { throw ChordError.invalid }
            try hydrate(.object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"), "instances": .array([instance])]))
        case "state":
            guard obj["instance"] == nil, obj["member"]?.string == "view", let seq = obj["sequence"]?.integer,
                  let previous = sequence, seq == previous + 1, let ops = obj["ops"]?.array else { throw ChordError.invalid }
            try apply(ops); sequence = seq
        default: throw ChordError.invalid
        }
    }

    private mutating func apply(_ ops: [ChordJSON]) throws {
        var previous: [ChordJSON]?
        for raw in ops {
            guard let op = raw.array, let code = op.first?.string else { throw ChordError.invalid }
            if code == "#" {
                guard op.count == 3, let id = op[1].integer, let path = op[2].array else { throw ChordError.invalid }
                try validatePath(path); paths[id] = path; continue
            }
            if code == "r" {
                guard op.count == 2 else { throw ChordError.invalid }
                value = op[1]; paths.removeAll(); previous = nil; continue
            }
            let expected: Int
            switch code { case "d": expected = 2; case "s", "a", "t", "m": expected = 3; case "p": expected = 5; default: throw ChordError.invalid }
            let short = op.count == expected - 1
            guard short || op.count == expected else { throw ChordError.invalid }
            let path: [ChordJSON]
            if short { guard let p = previous else { throw ChordError.invalid }; path = p }
            else if let p = op[1].array { path = p; previous = p }
            else if let id = op[1].integer, let p = paths[id] { path = p; previous = p }
            else { throw ChordError.invalid }
            try validatePath(path)
            if path.isEmpty && code != "p" && code != "m" { throw ChordError.invalid }
            let args = Array(op.dropFirst(short ? 1 : 2))
            guard let root = value else { throw ChordError.invalid }
            value = try mutate(root, path: path[...], code: code, args: args)
        }
    }

    private func validatePath(_ path: [ChordJSON]) throws {
        for segment in path {
            if let s = segment.string { if ["__proto__", "prototype", "constructor"].contains(s) { throw ChordError.invalid } }
            else if segment.integer == nil { throw ChordError.invalid }
        }
    }

    private func mutate(_ node: ChordJSON, path: ArraySlice<ChordJSON>, code: String, args: [ChordJSON]) throws -> ChordJSON {
        if path.isEmpty {
            switch (code, node) {
            case ("s", _): guard args.count == 1 else { throw ChordError.invalid }; return args[0]
            case ("a", .string(let text)):
                guard args.count == 1, let suffix = args[0].string else { throw ChordError.invalid }; return .string(text + suffix)
            case ("t", .string(let text)):
                guard args.count == 1, let count = args[0].integer,
                      let index = String.Index(utf16Offset: min(count, text.utf16.count), in: text).samePosition(in: text) else { throw ChordError.invalid }
                return .string(String(text[index...]))
            case ("p", .array(var items)):
                guard args.count == 3, let requestedStart = args[0].integer, let requestedRemove = args[1].integer,
                      let insert = args[2].array else { throw ChordError.invalid }
                let start = min(requestedStart, items.count), remove = min(requestedRemove, items.count - start)
                items.replaceSubrange(start..<(start + remove), with: insert); return .array(items)
            case ("m", .array(let items)):
                guard args.count == 1, let permutation = args[0].array, permutation.count == items.count else { throw ChordError.invalid }
                let indexes = permutation.compactMap(\.integer)
                guard indexes.count == items.count, Set(indexes).count == items.count, indexes.allSatisfy({ $0 < items.count }) else { throw ChordError.invalid }
                return .array(indexes.map { items[$0] })
            default: throw ChordError.invalid
            }
        }
        let key = path.first!, rest = path.dropFirst()
        switch node {
        case .object(var object):
            guard let name = key.string else { throw ChordError.invalid }
            if rest.isEmpty && code == "d" { guard args.isEmpty else { throw ChordError.invalid }; object.removeValue(forKey: name) }
            else if rest.isEmpty && code == "s" { guard args.count == 1 else { throw ChordError.invalid }; object[name] = args[0] }
            else { guard let child = object[name] else { throw ChordError.invalid }; object[name] = try mutate(child, path: rest, code: code, args: args) }
            return .object(object)
        case .array(var array):
            guard let index = key.integer, index <= array.count else { throw ChordError.invalid }
            if index == array.count {
                guard rest.isEmpty, code == "s", args.count == 1 else { throw ChordError.invalid }
                array.append(args[0]); return .array(array)
            }
            if rest.isEmpty && code == "d" { guard args.isEmpty else { throw ChordError.invalid }; array.remove(at: index) }
            else { array[index] = try mutate(array[index], path: rest, code: code, args: args) }
            return .array(array)
        default: throw ChordError.invalid
        }
    }
}
