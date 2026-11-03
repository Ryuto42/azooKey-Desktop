// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

#if os(macOS)
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["Zenzai"]
#else
// for testing in Ubuntu environment.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

// Kashiko の機能を入れた変換エンジンのフォーク。リポジトリと並べて clone してあれば、手元の変更をそのまま使う
let localKanaKanjiConverterPath = "../../AzooKeyKanaKanjiConverter"
let kanaKanjiConverterDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: Context.packageDirectory).appendingPathComponent(localKanaKanjiConverterPath).appendingPathComponent("Package.swift").path
)
    ? .package(path: localKanaKanjiConverterPath, traits: kanaKanjiConverterTraits)
    : .package(url: "https://github.com/Ryuto42/AzooKeyKanaKanjiConverter", branch: "feature/smart-input", traits: kanaKanjiConverterTraits)

let products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    )
]

let targets: [Target] = [
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: ["Core"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
]

let package = Package(
    name: "Core",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [
        kanaKanjiConverterDependency,
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
    ],
    targets: targets
)
