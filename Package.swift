// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "HLSVideoCache",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "HLSVideoCache",
            targets: ["HLSVideoCache"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/hyperoslo/Cache",
            from: "7.4.0"
        ),
        .package(
            url: "https://github.com/yene/GCDWebServer",
            from: "3.5.7"
        ),   
    ],
    targets: [
        .target(
            name: "HLSVideoCache",
            dependencies: [
                .product(name: "Cache", package: "Cache"),
                .product(name: "GCDWebServer", package: "GCDWebServer")
            ],
            path: "Source"
        )
    ]
)
