import Foundation
import SnapCore

// Small throwing-assertion harness so the checks run with Command Line Tools,
// without downloading packages or requiring the XCTest framework/full Xcode.
class CheckSuite {
    var teardowns: [() throws -> Void] = []
    func addTeardownBlock(_ block: @escaping () throws -> Void) { teardowns.append(block) }
    func tearDown() { for block in teardowns.reversed() { try? block() }; teardowns.removeAll() }
}

private var assertionFailures = 0
private func fail(_ message: String, file: StaticString, line: UInt) {
    assertionFailures += 1
    print("  FAIL \(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) {
    do { let left = try a(), right = try b(); if left != right { fail("\(left) != \(right)", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertTrue(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !condition() { fail("Expected true", file: file, line: line) } }
    catch { fail(error.localizedDescription, file: file, line: line) }
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { fail("Expected nil", file: file, line: line) }
}
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a < b) { fail("\(a) is not less than \(b)", file: file, line: line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a > b) { fail("\(a) is not greater than \(b)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail("Expected an error", file: file, line: line) } catch { }
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected nil"]) }
    return value
}

@main
struct CheckRunner {
    static func main() {
        let suite = SnapCoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("persistence, notes and order", suite.testPersistenceNotesAndOrder),
            ("delete undo across restarts", suite.testDeleteUndoSurvivesRestart),
            ("move bounds and unknown IDs", suite.testMoveClampsAndUnknownIDsAreNoOps),
            ("corrupt manifest preservation", suite.testMalformedManifestIsNotOverwritten),
            ("unsafe filename rejection", suite.testRejectsUnsafeFilename),
            ("exact shift, duplicate and reverse", suite.testDetectsExactScrollAndDuplicate),
            ("fast scroll rejection", suite.testRejectsFastScrollWithoutOverlap),
            ("ambiguous repeated rows", suite.testRejectsAmbiguousRepeatedRows),
            ("blank page rejection", suite.testBlankPagesAreNotInventedAsScroll),
            ("pixel-perfect scroll composition", suite.testScrollStitchHasExactPixelsAndNoRepeatedRows),
            ("recover from uncertain frame", suite.testUncertainFrameKeepsAcceptedReferenceForRecovery),
            ("mixed widths, Chinese notes, no upscaling", suite.testMixedWidthsNotesAndNoUpscaling),
            ("pixel and dimension limits", suite.testPixelAndDimensionLimits),
            ("lossless PNG and Retina resolution", suite.testPNGIsLosslessAndPreservesResolution),
            ("Retina text seams and rendered export artifacts", suite.testRetinaTextPageSubpixelCoarseShiftAndExportArtifacts)
        ]
        var failed = 0
        for (name, test) in cases {
            let before = assertionFailures
            do { try test() }
            catch { fail(error.localizedDescription, file: #filePath, line: #line) }
            suite.tearDown()
            if before == assertionFailures { print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        print("\(cases.count - failed)/\(cases.count) checks passed; \(assertionFailures) failed assertions.")
        if failed == 0, CommandLine.arguments.contains("--ui-fixture") {
            do {
                let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/check-artifacts")
                let directory = artifacts.appendingPathComponent("ui-library-" + UUID().uuidString)
                let repository = try LibraryRepository(directory: directory)
                let image = try ImageTools.load(artifacts.appendingPathComponent("scroll-result.png"))
                _ = try repository.add(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 320))!, note: "先整理已知条件，再求解。")
                _ = try repository.add(image.cropping(to: CGRect(x: 0, y: 320, width: image.width, height: 400))!, note: "这组题目需要复习，注意检查结果。")
                print("UI_FIXTURE=\(directory.path)")
            } catch { print("Fixture failed: \(error)"); exit(1) }
        }
        exit(failed == 0 ? 0 : 1)
    }
}
