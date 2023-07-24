/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogCore
import DatadogInternal
@testable import DatadogRUM
import TestUtilities

class TelemetryCoreIntegrationTests: XCTestCase {
    private var core: DatadogCoreProxy! // swiftlint:disable:this implicitly_unwrapped_optional
    private var telemetry: TelemetryCore! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUp() {
        core = DatadogCoreProxy()
        telemetry = TelemetryCore(core: core)
    }

    override func tearDown() {
        core.flushAndTearDown()
        core = nil
        telemetry = nil
    }

    func testGivenRUMEnabled_telemetryEventsAreSent() {
        // Given
        var config = RUM.Configuration(applicationID: .mockAny())
        config.telemetrySampleRate = 100
        RUM.enable(with: config, in: core)

        // When
        telemetry.debug("Debug Telemetry", attributes: ["debug.attribute": 42])
        telemetry.error("Error Telemetry")

        // Then
        let debugEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryDebugEvent.self)
        let errorEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryErrorEvent.self)

        XCTAssertEqual(debugEvents.count, 1)
        XCTAssertEqual(errorEvents.count, 1)

        let debug = debugEvents[0]
        XCTAssertEqual(debug.telemetry.message, "Debug Telemetry")
        DDAssertReflectionEqual(debug.telemetry.telemetryInfo, ["debug.attribute": 42])

        let error = errorEvents[0]
        XCTAssertEqual(error.telemetry.message, "Error Telemetry")
    }

    func testGivenRUMEnabled_whenNoViewIsActive_telemetryEventsAreLinkedToSession() throws {
        // Given & When
        var config = RUM.Configuration(applicationID: "rum-app-id")
        config.telemetrySampleRate = 100
        RUM.enable(with: config, in: core)

        // Then
        telemetry.debug("Debug Telemetry", attributes: ["debug.attribute": 42])
        telemetry.error("Error Telemetry")

        let debugEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryDebugEvent.self)
        let errorEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryErrorEvent.self)

        let debug = try XCTUnwrap(debugEvents.first)
        XCTAssertEqual(debug.application?.id, "rum-app-id")
        XCTAssertNotNil(debug.session?.id)
        XCTAssertNil(debug.view?.id)
        XCTAssertNil(debug.action?.id)

        let error = try XCTUnwrap(errorEvents.first)
        XCTAssertEqual(error.application?.id, "rum-app-id")
        XCTAssertNotNil(error.session?.id)
        XCTAssertNil(error.view?.id)
        XCTAssertNil(error.action?.id)
    }

    func testGivenRUMEnabled_whenViewIsActive_telemetryEventsAreLinkedToView() throws {
        // Given
        var config = RUM.Configuration(applicationID: "rum-app-id")
        config.telemetrySampleRate = 100
        RUM.enable(with: config, in: core)

        // When
        RUMMonitor.shared(in: core).startView(key: .mockRandom())

        // Then
        telemetry.debug("Debug Telemetry", attributes: ["debug.attribute": 42])
        telemetry.error("Error Telemetry")

        let debugEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryDebugEvent.self)
        let errorEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryErrorEvent.self)

        let debug = try XCTUnwrap(debugEvents.first)
        XCTAssertEqual(debug.application?.id, "rum-app-id")
        XCTAssertNotNil(debug.session?.id)
        XCTAssertNotNil(debug.view?.id)
        XCTAssertNil(debug.action?.id)

        let error = try XCTUnwrap(errorEvents.first)
        XCTAssertEqual(error.application?.id, "rum-app-id")
        XCTAssertNotNil(error.session?.id)
        XCTAssertNotNil(error.view?.id)
        XCTAssertNil(error.action?.id)
    }

    func testGivenRUMEnabled_whenActionIsActive_telemetryEventsAreLinkedToAction() throws {
        // Given
        var config = RUM.Configuration(applicationID: "rum-app-id")
        config.telemetrySampleRate = 100
        RUM.enable(with: config, in: core)

        // When
        RUMMonitor.shared(in: core).startView(key: .mockRandom())
        RUMMonitor.shared(in: core).addAction(type: .tap, name: "tap")

        // Then
        telemetry.debug("Debug Telemetry", attributes: ["debug.attribute": 42])
        telemetry.error("Error Telemetry")

        let debugEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryDebugEvent.self)
        let errorEvents = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: TelemetryErrorEvent.self)

        let debug = try XCTUnwrap(debugEvents.first)
        XCTAssertEqual(debug.application?.id, "rum-app-id")
        XCTAssertNotNil(debug.session?.id)
        XCTAssertNotNil(debug.view?.id)
        XCTAssertNotNil(debug.action?.id)

        let error = try XCTUnwrap(errorEvents.first)
        XCTAssertEqual(error.application?.id, "rum-app-id")
        XCTAssertNotNil(error.session?.id)
        XCTAssertNotNil(error.view?.id)
        XCTAssertNotNil(error.action?.id)
    }
}