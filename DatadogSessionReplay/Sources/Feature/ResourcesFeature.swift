/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import Foundation
import DatadogInternal

internal class ResourcesFeature: DatadogRemoteFeature {
    static var name = "session-replay-resources"

    var messageReceiver: FeatureMessageReceiver
    var requestBuilder: FeatureRequestBuilder

    init(messageReceiver: FeatureMessageReceiver, requestBuilder: FeatureRequestBuilder) {
        self.messageReceiver = messageReceiver
        self.requestBuilder = requestBuilder
    }
}
#endif
