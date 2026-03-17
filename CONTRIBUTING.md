# Contributing to Clome

Thanks for your interest in contributing to Clome! The project is in early development, so there are plenty of opportunities to help out.

## Building from Source

Make sure you have the prerequisites installed:

- macOS 14.0+
- Xcode 16+ (with Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`)
- Zig 0.15.2 (`brew install zig`)
- XcodeGen (`brew install xcodegen`)

Then build:

```bash
git clone --recursive https://github.com/user/clome.git
cd clome

# Build libghostty (only needed once, or after updating the ghostty submodule)
cd vendor/ghostty && zig build -Demit-xcframework -Doptimize=ReleaseFast && cd ../..

# Generate the Xcode project and build
xcodegen generate
xcodebuild -project Clome.xcodeproj -scheme Clome -configuration Debug build
```

## Reporting Bugs

Open a [GitHub Issue](https://github.com/user/clome/issues) with:

- A clear description of the problem
- Steps to reproduce
- Your macOS version and any relevant system info
- Console output or crash logs if applicable

## Pull Requests

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused and well-described.
3. Make sure the project builds without errors.
4. Open a pull request against `main` with a summary of what you changed and why.

Keep PRs small and focused when possible. If you are planning a large change, open an issue first to discuss the approach.

## Code Style

- Follow existing patterns in the codebase.
- All UI classes use `@MainActor` isolation for Swift 6 concurrency.
- Use `project.yml` for project configuration (do not commit `Clome.xcodeproj`).
