#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p Build/Debug/Tests Build/ModuleCache

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  AppTests/HealthDiagnosticsTests.swift \
  -o Build/Debug/Tests/HealthDiagnosticsTests

Build/Debug/Tests/HealthDiagnosticsTests

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  App/Sources/App/PrerequisiteStatus.swift \
  AppTests/PrerequisiteStatusTests.swift \
  -o Build/Debug/Tests/PrerequisiteStatusTests

Build/Debug/Tests/PrerequisiteStatusTests

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/App/DebouncedMainActorAction.swift \
  AppTests/DebouncedMainActorActionTests.swift \
  -o Build/Debug/Tests/DebouncedMainActorActionTests

Build/Debug/Tests/DebouncedMainActorActionTests

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  App/Sources/App/PrerequisiteStatus.swift \
  App/Sources/App/AppPrerequisiteChecker.swift \
  App/Sources/App/AppStatusModel.swift \
  AppTests/AppStatusModelTests.swift \
  -o Build/Debug/Tests/AppStatusModelTests

Build/Debug/Tests/AppStatusModelTests

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  App/Sources/App/PrerequisiteStatus.swift \
  App/Sources/App/AppPrerequisiteChecker.swift \
  AppTests/AppMicrophoneSelectionStoreTests.swift \
  -o Build/Debug/Tests/AppMicrophoneSelectionStoreTests

Build/Debug/Tests/AppMicrophoneSelectionStoreTests

swiftc \
  -module-cache-path Build/ModuleCache \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  App/Sources/App/PrerequisiteStatus.swift \
  App/Sources/App/SetupPresentation.swift \
  AppTests/SetupPresentationTests.swift \
  -o Build/Debug/Tests/SetupPresentationTests

Build/Debug/Tests/SetupPresentationTests
