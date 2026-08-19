import CoreAudio
import XCTest
@testable import JarvisAudioDriverTool

/// Phase 3 CHECKPOINT 2 — Rpcm CF ownership investigation (§29/§30). Pure logic tests: the
/// FourCC OSStatus formatter and `PCMDiagnosticsStageResult.succeeded`'s stage-combination logic
/// — never touches real CoreAudio (that half, `readPCMDiagnosticsStaged`, is exercised only via
/// real-device usage, matching this project's existing convention for CoreAudio-calling code).
final class PCMDiagnosticsStageTests: XCTestCase {
    // MARK: - formatOSStatus (§30)

    func testFormatOSStatusShowsFourCCForKnownConstant() {
        // 'who?' = kAudioHardwareUnknownPropertyError, a real documented CoreAudio constant.
        XCTAssertEqual(CoreAudioHelpers.formatOSStatus(2_003_332_927), "2003332927 ('who?')")
    }

    /// The real-device value observed for Capture during this investigation — no symbolic name
    /// exists for it in the local SDK, but all four bytes ARE printable ASCII ('iote'), so the
    /// formatter must still show the FourCC reading without inventing a constant name for it.
    func testFormatOSStatusShowsFourCCEvenForUndocumentedValue() {
        XCTAssertEqual(CoreAudioHelpers.formatOSStatus(1_768_911_973), "1768911973 ('iote')")
    }

    func testFormatOSStatusOmitsFourCCForUnprintableBytes() {
        // 0 (noErr) is not four printable ASCII bytes - must fall back to bare decimal, never a
        // fabricated/garbage FourCC reading.
        XCTAssertEqual(CoreAudioHelpers.formatOSStatus(0), "0")
    }

    func testFormatOSStatusHandlesNegativeStatus() {
        // kAudioHardwareBadObjectError = '!obj' - exercises negative-looking bit patterns too
        // (OSStatus is signed; FourCC decoding must still work via the unsigned bit pattern).
        let formatted = CoreAudioHelpers.formatOSStatus(kAudioHardwareBadObjectError)
        XCTAssertTrue(formatted.contains("'!obj'"), "expected FourCC '!obj' in \(formatted)")
    }

    // MARK: - PCMDiagnosticsStageResult.succeeded (§9/§14)

    private func makeDiagnostics() -> CoreAudioHelpers.PCMDeviceDiagnostics {
        CoreAudioHelpers.PCMDeviceDiagnostics(
            version: 1, ioClientCount: 0,
            outputOperationCount: 0, outputFrames: 0, outputNonZeroCallbacks: 0, outputPeakLinear: 0,
            loopbackWriteFrames: 0, loopbackReadFrames: 0, loopbackUnderrunCount: 0, loopbackOverrunFrameCount: 0,
            inputOperationCount: 0, inputFrames: 0, inputNonZeroCallbacks: 0, inputPeakLinear: 0
        )
    }

    func testSucceededTrueWhenEveryStagePasses() {
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: noErr, returnedSize: 8, dataStatus: noErr, hasPropertyAfter: true, diagnostics: makeDiagnostics())
        XCTAssertTrue(result.succeeded)
    }

    func testSucceededFalseWhenHasPropertyBeforeFails() {
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: false, sizeStatus: noErr, returnedSize: 0, dataStatus: noErr, hasPropertyAfter: false, diagnostics: nil)
        XCTAssertFalse(result.succeeded)
    }

    func testSucceededFalseWhenSizeStatusFails() {
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: kAudioHardwareBadPropertySizeError, returnedSize: 0, dataStatus: noErr, hasPropertyAfter: true, diagnostics: nil)
        XCTAssertFalse(result.succeeded)
    }

    /// Exactly the real-device failure pattern under investigation: HasProperty/GetSize both
    /// succeed, but GetPropertyData itself fails ('iote'/'who?').
    func testSucceededFalseWhenDataStatusFails() {
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: noErr, returnedSize: 8, dataStatus: 1_768_911_973, hasPropertyAfter: false, diagnostics: nil)
        XCTAssertFalse(result.succeeded)
    }

    func testSucceededFalseWhenDiagnosticsNilDespiteOKStatuses() {
        // e.g. a version mismatch or undersized payload decoded to nil even though the raw
        // CoreAudio calls themselves reported noErr.
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: noErr, returnedSize: 8, dataStatus: noErr, hasPropertyAfter: true, diagnostics: nil)
        XCTAssertFalse(result.succeeded)
    }

    func testSucceededFalseWhenHasPropertyAfterFails() {
        // The property "disappearing" after a successful read is itself a failure signal, not
        // just the read's own status.
        let result = CoreAudioHelpers.PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: noErr, returnedSize: 8, dataStatus: noErr, hasPropertyAfter: false, diagnostics: makeDiagnostics())
        XCTAssertFalse(result.succeeded)
    }
}
