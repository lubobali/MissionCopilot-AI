# ADR 0002: Define the Xcode project with XcodeGen

- Status: accepted
- Date: 2026-10-30

## Context
Xcode stores project settings in a large generated file (project.pbxproj). It is hard to
read, hard to review in a pull request, and conflicts easily when two changes touch it.
This project is built with AI coding agents, so every change must be easy to review in git.

## Options
1. Xcode "New Project": standard, zero setup. The .pbxproj is committed and edited by Xcode.
2. XcodeGen: a short, readable project.yml generates the Xcode project. The generated
   project is not committed.
3. Tuist: more powerful (Swift manifests, caching), but more setup than a small app needs.

## Decision
XcodeGen. ios/project.yml is the single source of truth. MissionCopilot.xcodeproj is
generated and ignored by git.

## Why
- About 40 readable lines instead of a large machine file: easy to review, easy to diff.
- No merge conflicts in the project file.
- Same project every time from the same project.yml (reproducible), locally and in CI.

## Consequences
- Run `xcodegen generate` in ios/ after pulling or after changing project.yml.
- Signing team ID is personal: it lives in ios/Local.xcconfig, which is git-ignored.

## Revisit when
- The app grows into many modules that need build caching (then consider Tuist).
