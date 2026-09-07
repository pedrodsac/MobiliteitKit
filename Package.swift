// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MobilitéitKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MobiliteitKit",
            targets: ["MobiliteitKit"]
        ),
    ],
	dependencies: [
		.package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
		.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0"),
	],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MobiliteitKit",
			dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "CSQLite",
            ],
			path: "Sources/MobilitéitKit",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .testTarget(
            name: "MobiliteitKitTests",
			dependencies: [
                "MobiliteitKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
			path: "Tests/MobilitéitKitTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
