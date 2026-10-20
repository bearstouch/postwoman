# Contributing to PostWoman

Thank you for your interest in contributing to PostWoman! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Architecture Overview](#architecture-overview)

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 26 / Swift 6.2 toolchain
- Git

### Development Setup

1. **Fork the repository** on GitHub

2. **Clone your fork**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/postwoman.git
   cd postwoman
   ```

3. **Add the upstream remote**:
   ```bash
   git remote add upstream https://github.com/bearstouch/postwoman.git
   ```

4. **Build, test and run**:
   ```bash
   swift build                                  # must be warning-free
   swift test
   swift format lint --strict -r Sources Tests  # must print nothing
   swift run PostWoman                          # or scripts/run-app.sh for a sandboxed .app
   ```
   You can also open `Package.swift` in Xcode. Format with `swift format -i -r Sources Tests`
   (config: `.swift-format`). CI runs the same lint, build, test and app-bundle steps.

## How to Contribute

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title** describing the issue
- **Steps to reproduce** the behavior
- **Expected behavior** vs what actually happened
- **Screenshots** if applicable
- **Environment details**: macOS version, Xcode/Swift version

### Suggesting Features

Feature requests are welcome! Please provide:

- **Clear description** of the feature
- **Use case** explaining why this would be useful
- **Possible implementation** approach (optional)

### Contributing Code

1. **Check existing issues** or create a new one to discuss your idea
2. **Fork and create a branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   # or
   git checkout -b fix/your-bug-fix
   ```
3. **Make your changes** following our coding standards
4. **Test thoroughly** on macOS 14.0+
5. **Commit** with clear, descriptive messages
6. **Push** to your fork and submit a Pull Request

## Pull Request Process

1. **Update documentation** if you're changing functionality
2. **Follow the PR template** (if available)
3. **Link related issues** using keywords like "Fixes #123"
4. **Request review** from maintainers
5. **Address feedback** promptly

### PR Checklist

- [ ] Code compiles without warnings
- [ ] Tested on macOS 14.0+
- [ ] No breaking changes (or documented if necessary)
- [ ] Updated relevant documentation
- [ ] Followed coding standards

## Coding Standards

### Swift Style Guide

- Use Swift's standard naming conventions (camelCase for variables/functions, PascalCase for types)
- Prefer `let` over `var` where possible
- Use meaningful variable and function names
- Keep functions focused and concise

### SwiftUI Best Practices

- Use `@State` for view-local state
- Use `@Bindable` for SwiftData models in views
- Extract reusable components into separate views
- Use `.task` or `.onAppear` for async work

### SwiftData Guidelines

- Define clear relationships with appropriate delete rules
- Use `@Query` for fetching data in views
- Handle optional relationships gracefully

### File Organization

```
Sources/PostWoman/
├── App/                    # App entry point and root views
├── Models/                 # SwiftData @Model classes
├── Views/
│   ├── Sidebar/           # Navigation and list views
│   ├── RequestEditor/     # Request configuration views
│   ├── ResponseViewer/    # Response display views
│   ├── CodeGeneration/    # Code export views
│   └── Shared/            # Reusable components
├── Services/              # Business logic and networking
└── Utilities/             # Helpers and extensions
```

### Commit Messages

Use clear, descriptive commit messages:

```
feat: Add support for PATCH HTTP method
fix: Resolve JSON formatting crash for empty arrays
docs: Update README with new keyboard shortcuts
refactor: Extract URL validation into separate utility
```

Prefixes:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

## Architecture Overview

### Data Flow

```
User Action → View → Service → Network/Storage → View Update
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `HTTPClient` | Main-actor networking with URLSession async/await |
| `AuthenticationHandler` | Applies auth to requests |
| `CodeGenerator/` | Exports requests as code |
| `ContentView` | Root NavigationSplitView layout |

### Adding New Features

#### New HTTP Method
1. Add case to `HTTPMethod` enum
2. Assign a display color

#### New Code Generator
1. Create generator in `Services/CodeGenerator/`
2. Add case to `CodeLanguage` enum
3. Integrate in `generateCode()` function

#### New Auth Type
1. Add case to `AuthenticationType` enum
2. Add UI in `AuthTabView.swift`
3. Handle in `AuthenticationHandler.swift`

## Getting Help

- **Questions?** Open a Discussion on GitHub
- **Found a bug?** Open an Issue
- **Want to contribute?** Check issues labeled `good first issue`

## Recognition

Contributors will be recognized in our README and release notes. Thank you for helping make PostWoman better!
