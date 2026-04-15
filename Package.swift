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
        .package(url: "https://github.com/kukushechkin/swift-jmap-client.git", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiteMail",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "AppAuth", package: "AppAuth-iOS"),
                .product(name: "JMAPClient", package: "swift-jmap-client"),
            ],
            path: "Sources/LiteMail",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LiteMailTests",
            dependencies: [
                "LiteMail",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/LiteMailTests"
        ),
        .testTarget(
            name: "LiteMailIntegrationTests",
            dependencies: [
                "LiteMail",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/LiteMailIntegrationTests"
        ),
        .testTarget(
            name: "LiteMailProtocolTests",
            dependencies: [
                "LiteMail",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftMail", package: "SwiftMail"),
            ],
            path: "Tests/LiteMailProtocolTests"
        ),
        .testTarget(
            name: "LiteMailGUITests",
            dependencies: [
                "LiteMail",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/LiteMailGUITests"
        ),
    ]
)
