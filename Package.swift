// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiteMail",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiteMail", targets: ["LiteMail"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", from: "1.0.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiteMail",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "AppAuth", package: "AppAuth-iOS"),
            ],
            path: "Sources/LiteMail"
        ),
        .testTarget(
            name: "LiteMailTests",
            dependencies: [
                "LiteMail",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/LiteMailTests"
        ),
    ]
)
