/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Provides the current RUM context tags for produced `Spans`.
internal final class TracingWithRUMIntegration {
    /// The RUM attributes that should be added as Span tags.
    ///
    /// These attributes are synchronized using a read-write lock.
    @ReadWriteLock
    var attribues: [String: Encodable]?
}
