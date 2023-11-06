/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// Core implementation of Datadog SDK.
///
/// The core provides a storage and upload mechanism for each registered Feature
/// based on their respective configuration.
///
/// By complying with `DatadogCoreProtocol`, the core can
/// provide context and writing scopes to Features for event recording.
internal final class DatadogCore {
    /// The root location for storing Features data in this instance of the SDK.
    /// For each Feature a set of subdirectories is created inside `CoreDirectory` based on their storage configuration.
    let directory: CoreDirectory

    /// The storage r/w GDC queue.
    let readWriteQueue = DispatchQueue(
        label: "com.datadoghq.ios-sdk-read-write",
        autoreleaseFrequency: .workItem,
        target: .global(qos: .utility)
    )

    /// The system date provider.
    let dateProvider: DateProvider

    /// The user consent publisher.
    let consentPublisher: TrackingConsentPublisher

    /// The core SDK performance presets.
    let performance: PerformancePreset

    /// The HTTP Client for uploads.
    let httpClient: HTTPClient

    /// The on-disk data encryption.
    let encryption: DataEncryption?

    /// The user info publisher that publishes value to the
    /// `contextProvider`
    let userInfoPublisher = UserInfoPublisher()

    /// The application version publisher.
    let applicationVersionPublisher: ApplicationVersionPublisher

    /// The message-bus instance.
    let bus = MessageBus()

    /// Registry for Features.
    @ReadWriteLock
    private(set) var stores: [String: (
        storage: FeatureStorage,
        upload: FeatureUpload
    )] = [:]

    /// Registry for Features.
    @ReadWriteLock
    private var features: [String: DatadogFeature] = [:]

    /// The core context provider.
    internal let contextProvider: DatadogContextProvider

    internal let backgroundTasksEnabled: Bool

    /// Creates a core instance.
    ///
    /// - Parameters:
    ///   - directory: The core directory for this instance of the SDK.
    ///   - dateProvider: The system date provider.
    ///   - initialConsent: The initial user consent.
    ///   - performance: The core SDK performance presets.
    ///   - httpClient: The HTTP Client for uploads.
    ///   - encryption: The on-disk data encryption.
    ///   - contextProvider: The core context provider.
    ///   - applicationVersion: The application version.
    init(
        directory: CoreDirectory,
        dateProvider: DateProvider,
        initialConsent: TrackingConsent,
    	performance: PerformancePreset,
    	httpClient: HTTPClient,
    	encryption: DataEncryption?,
        contextProvider: DatadogContextProvider,
        applicationVersion: String,
        backgroundTasksEnabled: Bool
    ) {
        self.directory = directory
        self.dateProvider = dateProvider
        self.performance = performance
        self.httpClient = httpClient
        self.encryption = encryption
        self.contextProvider = contextProvider
        self.backgroundTasksEnabled = backgroundTasksEnabled
        self.applicationVersionPublisher = ApplicationVersionPublisher(version: applicationVersion)
        self.consentPublisher = TrackingConsentPublisher(consent: initialConsent)

        self.contextProvider.subscribe(\.userInfo, to: userInfoPublisher)
        self.contextProvider.subscribe(\.version, to: applicationVersionPublisher)
        self.contextProvider.subscribe(\.trackingConsent, to: consentPublisher)

        // connect the core to the message bus.
        // the bus will keep a weak ref to the core.
        bus.connect(core: self)

        // forward any context change on the message-bus
        self.contextProvider.publish { [weak self] context in
            self?.send(message: .context(context))
        }
    }

    /// Sets current user information.
    ///
    /// Those will be added to logs, traces and RUM events automatically.
    /// 
    /// - Parameters:
    ///   - id: User ID, if any
    ///   - name: Name representing the user, if any
    ///   - email: User's email, if any
    ///   - extraInfo: User's custom attributes, if any
    func setUserInfo(
        id: String? = nil,
        name: String? = nil,
        email: String? = nil,
        extraInfo: [AttributeKey: AttributeValue] = [:]
    ) {
        let userInfo = UserInfo(
            id: id,
            name: name,
            email: email,
            extraInfo: extraInfo
        )

        userInfoPublisher.current = userInfo
    }

    /// Add or override the extra info of the current user
    ///
    ///  - Parameters:
    ///    - extraInfo: The user's custom attibutes to add or override
    func addUserExtraInfo(_ newExtraInfo: [AttributeKey: AttributeValue?]) {
        var extraInfo = userInfoPublisher.current.extraInfo
        newExtraInfo.forEach { extraInfo[$0.key] = $0.value }
        userInfoPublisher.current.extraInfo = extraInfo
    }

    /// Sets the tracking consent regarding the data collection for the Datadog SDK.
    /// 
    /// - Parameter trackingConsent: new consent value, which will be applied for all data collected from now on
    func set(trackingConsent: TrackingConsent) {
        if trackingConsent != consentPublisher.consent {
            stores.values.forEach { $0.storage.migrateUnauthorizedData(toConsent: trackingConsent) }
            consentPublisher.consent = trackingConsent
        }
    }

    /// Clears all data that has not already yet been uploaded Datadog servers.
    func clearAllData() {
        stores.values.forEach { $0.storage.clearAllData() }
    }

    /// Adds a message receiver to the bus.
    ///
    /// After being added to the bus, the core will send the current context to receiver.
    ///
    /// - Parameters:
    ///   - messageReceiver: The new message receiver.
    ///   - key: The key associated with the receiver.
    private func add(messageReceiver: FeatureMessageReceiver, forKey key: String) {
        bus.connect(messageReceiver, forKey: key)
        contextProvider.read { context in
            self.bus.queue.async { messageReceiver.receive(message: .context(context), from: self) }
        }
    }

    /// Awaits completion of all asynchronous operations, forces uploads (without retrying) and deinitializes
    /// this instance of the SDK. It **blocks the caller thread**.
    ///
    /// Upon return, it is safe to assume that all events were stored and got uploaded. The SDK was deinitialised so this instance of core is missfunctional.
    func flushAndTearDown() {
        // temporary semaphore before implementation
        // of the stop mechanism
        let semaphore = DispatchSemaphore(value: 0)
        harvestAndUpload.notify { semaphore.signal() }
        semaphore.wait()

        // Deallocate all Features and their storage & upload units:
        stores = [:]
        features = [:]
    }
}

extension DatadogCore: DatadogCoreProtocol {
    /// Registers a Feature instance.
    ///
    /// A Feature collects and transfers data to a Datadog Product (e.g. Logs, RUM, ...). A registered Feature can
    /// open a `FeatureScope` to write events, the core will then be responsible for storing and uploading events
    /// in a efficient manner. Performance presets for storage and upload are define when instanciating the core instance.
    ///
    /// A Feature can also communicate to other Features by sending message on the bus that is managed by the core.
    ///
    /// - Parameter feature: The Feature instance.
    func register<T>(feature: T) throws where T: DatadogFeature {
        let featureDirectories = try directory.getFeatureDirectories(forFeatureNamed: T.name)

        let performancePreset: PerformancePreset
        if let override = feature.performanceOverride {
            performancePreset = performance.updated(with: override)
        } else {
            performancePreset = performance
        }

        if let feature = feature as? DatadogRemoteFeature {
            let storage = FeatureStorage(
                featureName: T.name,
                queue: readWriteQueue,
                directories: featureDirectories,
                dateProvider: dateProvider,
                performance: performancePreset,
                encryption: encryption,
                telemetry: telemetry
            )

            let upload = FeatureUpload(
                featureName: T.name,
                contextProvider: contextProvider,
                fileReader: storage.reader,
                requestBuilder: feature.requestBuilder,
                httpClient: httpClient,
                performance: performancePreset,
                backgroundTasksEnabled: backgroundTasksEnabled,
                telemetry: telemetry
            )

            stores[T.name] = (
                storage: storage,
                upload: upload
            )

            // If there is any persisted data recorded with `.pending` consent,
            // it should be deleted on Feature startup:
            storage.clearUnauthorizedData()
        }

        features[T.name] = feature
        add(messageReceiver: feature.messageReceiver, forKey: T.name)
    }

    /// Retrieves a Feature by its name and type.
    ///
    /// A Feature type can be specified as parameter or inferred from the return type:
    ///
    ///     let feature = core.feature(named: "foo", type: Foo.self)
    ///     let feature: Foo? = core.feature(named: "foo")
    ///
    /// - Parameters:
    ///   - name: The Feature's name.
    ///   - type: The Feature instance type.
    /// - Returns: The Feature if any.
    func get<T>(feature type: T.Type = T.self) -> T? where T: DatadogFeature {
        features[T.name] as? T
    }

    func scope(for feature: String) -> FeatureScope? {
        guard let storage = stores[feature]?.storage else {
            return nil
        }

        return DatadogCoreFeatureScope(
            contextProvider: contextProvider,
            storage: storage,
            telemetry: telemetry
        )
    }

    func set(baggage: @escaping () -> FeatureBaggage?, forKey key: String) {
        contextProvider.write { $0.baggages[key] = baggage() }
    }

    func send(message: FeatureMessage, else fallback: @escaping () -> Void) {
        bus.send(message: message, else: fallback)
    }
}

internal struct DatadogCoreFeatureScope: FeatureScope {
    let contextProvider: DatadogContextProvider
    let storage: FeatureStorage
    let telemetry: Telemetry

    func eventWriteContext(bypassConsent: Bool, forceNewBatch: Bool, _ block: @escaping (DatadogContext, Writer) throws -> Void) {
        // On user thread: request SDK context.
        contextProvider.read { context in
            // On context thread: request writer for current tracking consent.
            let writer = storage.writer(
                for: bypassConsent ? .granted : context.trackingConsent,
                forceNewBatch: forceNewBatch
            )

            // Still on context thread: send `Writer` to EWC caller. The writer implements `AsyncWriter`, so
            // the implementation of `writer.write(value:)` will run asynchronously without blocking the context thread.
            do {
                try block(context, writer)
            } catch {
                telemetry.error("Failed to execute feature scope", error: error)
            }
        }
    }
}

extension DatadogContextProvider {
    /// Creates a core context provider with the given configuration,
    convenience init(
        site: DatadogSite,
        clientToken: String,
        service: String,
        env: String,
        version: String,
        buildNumber: String,
        variant: String?,
        source: String,
        sdkVersion: String,
        ciAppOrigin: String?,
        applicationName: String,
        applicationBundleIdentifier: String,
        applicationVersion: String,
        sdkInitDate: Date,
        device: DeviceInfo,
        dateProvider: DateProvider,
        serverDateProvider: ServerDateProvider
    ) {
        let context = DatadogContext(
            site: site,
            clientToken: clientToken,
            service: service,
            env: env,
            version: applicationVersion,
            buildNumber: buildNumber,
            variant: variant,
            source: source,
            sdkVersion: sdkVersion,
            ciAppOrigin: ciAppOrigin,
            applicationName: applicationName,
            applicationBundleIdentifier: applicationBundleIdentifier,
            sdkInitDate: dateProvider.now,
            device: device,
            // this is a placeholder waiting for the `ApplicationStatePublisher`
            // to be initialized on the main thread, this value will be overrided
            // as soon as the subscription is made.
            applicationStateHistory: .active(since: dateProvider.now)
        )

        self.init(context: context)

        subscribe(\.serverTimeOffset, to: ServerOffsetPublisher(provider: serverDateProvider))
        subscribe(\.launchTime, to: LaunchTimePublisher())

        if #available(iOS 12, tvOS 12, *) {
            subscribe(\.networkConnectionInfo, to: NWPathMonitorPublisher())
        } else {
            assign(reader: SCNetworkReachabilityReader(), to: \.networkConnectionInfo)
        }

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 12, *) {
            subscribe(\.carrierInfo, to: iOS12CarrierInfoPublisher())
        } else {
            assign(reader: iOS11CarrierInfoReader(), to: \.carrierInfo)
        }
        #endif

        #if os(iOS) && !targetEnvironment(simulator)
        subscribe(\.batteryStatus, to: BatteryStatusPublisher())
        subscribe(\.isLowPowerModeEnabled, to: LowPowerModePublisher())
        #endif

        #if os(iOS) || os(tvOS)
        DispatchQueue.main.async {
            // must be call on the main thread to read `UIApplication.State`
            let applicationStatePublisher = ApplicationStatePublisher(dateProvider: dateProvider)
            self.subscribe(\.applicationStateHistory, to: applicationStatePublisher)
        }
        #endif
    }
}

extension DatadogCore {
    /// Returns a ``DispatchContinuation`` instance that will fire a notification after the core finishes
    /// collecting all events from registered Features. After harvestering is done, all events are written on disk in
    /// dedicated Feature storages.
    ///
    /// The sequence for harvesting events is the following:
    ///     1. Execute operations on the message-bus
    ///     2. Execute Features asynchonous operations in parallel
    ///     3. Execute the requested `eventWriteContext`
    ///     4. Execute r/w operations for storing data
    ///
    /// This property is meant to be used in tests or when stopping the core instance.
    var harvest: DispatchContinuation {
        // First, execute bus queue - because messages can lead to obtaining "event write context" (reading
        // context & performing write) in other Features:
        DispatchContinuationSequence(first: bus)
            // Next, execute flushable Features - finish current data collection to open "event write contexts":
            .then(group: features.values.compactMap { $0 as? DispatchContinuation })
            // Next, execute context queue - because it indicates the entry point to "event write context" and
            // actual writes dispatched from it:
            .then(contextProvider)
            // Last, execute read-write queue - it always comes last, no matter if the write operation is dispatched
            // from "event write context" started on user thread OR if it happens upon receiving an "event" message
            // in other Feature:
            .then(readWriteQueue)
    }

    /// Returns a ``DispatchContinuation`` instance that will fire a notification after the core finishes
    /// collecting and uploading all events from registered Features.
    ///
    /// The property will force the upload by ignoring the minimum age of files stored on disk.
    ///
    /// **This property is meant to be used in tests only.**
    var harvestAndUpload: DispatchContinuation {
        DispatchContinuationSequence(first: harvest)
            // At this point we can assume that all write operations completed and resulted with writing events to
            // storage. We now perform arbitrary uploads on all files (without retrying on failure).
            .then { self.stores.values.forEach { $0.storage.setIgnoreFilesAgeWhenReading(to: true) } }
            .then { self.stores.values.forEach { $0.upload.flushSynchronously() } }
            .then { self.stores.values.forEach { $0.storage.setIgnoreFilesAgeWhenReading(to: false) } }
    }
}
