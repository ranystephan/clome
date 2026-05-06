fn main() {
    #[cfg(target_os = "macos")]
    {
        use std::path::PathBuf;

        swift_rs::SwiftLinker::new("14.0")
            .with_package("ClomeGhostty", "native/ClomeGhostty")
            .link();

        let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
        let lib_dir = manifest
            .join("vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64");
        if !lib_dir.join("libghostty.a").is_file() {
            panic!(
                "could not find libghostty.a at {}",
                lib_dir.join("libghostty.a").display()
            );
        }

        println!("cargo:rerun-if-changed=native/ClomeGhostty/Package.swift");
        println!("cargo:rerun-if-changed=native/ClomeGhostty/Sources/ClomeGhostty/ClomeGhostty.swift");
        println!("cargo:rerun-if-changed=native/ClomeGhostty/Sources/CGhostty/module.modulemap");
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        println!("cargo:rustc-link-lib=static=ghostty");
        println!("cargo:rustc-link-lib=z");
        println!("cargo:rustc-link-lib=c++");
        println!("cargo:rustc-link-lib=sqlite3");
        for framework in [
            "Metal",
            "MetalKit",
            "AppKit",
            "QuartzCore",
            "CoreText",
            "CoreGraphics",
            "CoreVideo",
            "IOSurface",
            "IOKit",
            "UniformTypeIdentifiers",
            "UserNotifications",
        ] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }

    tauri_build::build()
}
