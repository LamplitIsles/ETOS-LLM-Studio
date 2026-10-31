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
        guard arguments.count == 3 else {
            throw Failure.message("usage: ETOSAssetCompiler <catalog> <bundle>")
        }
        let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: source)
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

    enum Failure: Error {
        case message(String)
    }
}
