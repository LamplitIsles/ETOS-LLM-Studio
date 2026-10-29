import AssetKit
import Foundation

@main
struct ETOSAssetCompiler {
    static func main() async {
        do {
            try await compile()
        } catch {
            FileHandle.standardError.write(Data("asset compilation failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func compile() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--empty-widget-catalog") else {
            throw Failure.message("usage: ETOSAssetCompiler <catalog> <bundle> [--empty-widget-catalog <build-catalog>]")
        }
        let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let catalog = arguments.count == 5
            ? try emptyWidgetCatalog(source: source, buildPath: arguments[4])
            : source
        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: catalog)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.carData.write(to: output.appendingPathComponent("Assets.car"))
        if let bundle = result.appIconBundle {
            for file in bundle.looseFiles {
                try file.data.write(to: output.appendingPathComponent(file.name))
            }
            let info = output.appendingPathComponent("Info.plist")
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any] else {
                throw Failure.message("invalid bundle Info.plist: \(info.path)")
            }
            for (key, value) in bundle.infoPlistAdditions { plist[key] = value }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        }
    }

    // Xcode's widget template contains three unassigned placeholders. AssetKit
    // cannot decode them; compile an empty catalog only while they remain empty.
    static func emptyWidgetCatalog(source: URL, buildPath: String) throws -> URL {
        let fm = FileManager.default
        let sets: [String: String] = ["AccentColor.colorset": "colors", "WidgetBackground.colorset": "colors", "AppIcon.appiconset": "images"]
        let entries = try Set(fm.contentsOfDirectory(atPath: source.path))
        guard entries == Set(sets.keys).union(["Contents.json"]) else {
            throw Failure.message("widget catalog changed; compile its real assets instead of treating it as empty")
        }
        for (name, valuesKey) in sets {
            let folder = source.appendingPathComponent(name, isDirectory: true)
            guard try fm.contentsOfDirectory(atPath: folder.path) == ["Contents.json"],
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as? [String: Any],
                  Set(json.keys).isSubset(of: ["info", valuesKey]),
                  let values = json[valuesKey] as? [[String: Any]],
                  values.allSatisfy({ Set($0.keys).isSubset(of: ["idiom", "platform", "size", "appearances", "scale"]) }) else {
                throw Failure.message("widget asset \(name) is not an empty placeholder")
            }
        }
        let derived = URL(fileURLWithPath: buildPath, isDirectory: true)
        try fm.createDirectory(at: derived, withIntermediateDirectories: true)
        guard try Set(fm.contentsOfDirectory(atPath: derived.path)).isSubset(of: ["Contents.json"]) else {
            throw Failure.message("derived widget catalog contains unexpected files: \(derived.path)")
        }
        try Data(contentsOf: source.appendingPathComponent("Contents.json")).write(to: derived.appendingPathComponent("Contents.json"))
        return derived
    }

    enum Failure: Error {
        case message(String)
    }
}
