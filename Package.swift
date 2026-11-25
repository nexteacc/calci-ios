// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardDictationDemo",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "KeyboardDictationDemo", targets: ["KeyboardDictationDemo"]),
        .library(name: "KeyboardDictationDemoKeyboard", targets: ["KeyboardDictationDemoKeyboard"]),
    ],
    targets: [
        .target(name: "CalciCredentials"),
        .target(name: "KeyboardDictationDemo", dependencies: ["CalciCredentials"]),
        .target(name: "KeyboardDictationDemoKeyboard", dependencies: ["CalciCredentials"]),
    ],
    swiftLanguageModes: [.v5]
)
