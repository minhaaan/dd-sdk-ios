/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-2020 Datadog, Inc.
*/

import Foundation

/// Reads `ObjcInteropType` definitions from `SwiftType` definitions.
internal class ObjcInteropTypeReader {
    /// `SwiftTypes` passed on input.
    private var inputSwiftTypes: [SwiftType] = []
    /// `ObjcInteropTypes` returned on output.
    private var outputObjcInteropTypes: [ObjcInteropType] = []

    func readObjcInteropTypes(from swiftTypes: [SwiftType]) throws -> [ObjcInteropType] {
        self.inputSwiftTypes = swiftTypes
        self.outputObjcInteropTypes = []

        try takeRootSwiftStructs(from: swiftTypes)
            .forEach { rootStruct in
                let rootClass = ObjcInteropRootClass(managedSwiftStruct: rootStruct)
                outputObjcInteropTypes.append(rootClass)
                try generateTransitiveObjcInteropTypes(in: rootClass)
            }

        return outputObjcInteropTypes
    }

    // MARK: - Private

    private func generateTransitiveObjcInteropTypes(in objcClass: ObjcInteropClass) throws {
        // Generate property wrappers
        objcClass.objcPropertyWrappers = try objcClass.managedSwiftStruct.properties
            .map { swiftProperty in
                switch swiftProperty.type {
                case let swiftPrimitive as SwiftPrimitiveType:
                    let propertyWrapper = ObjcInteropPropertyWrapperManagingSwiftStructProperty(
                        owner: objcClass,
                        swiftProperty: swiftProperty
                    )
                    propertyWrapper.objcInteropType = try objcInteropType(for: swiftPrimitive)
                    return propertyWrapper
                case let swiftStruct as SwiftStruct:
                    let propertyWrapper = ObjcInteropPropertyWrapperAccessingNestedStruct(
                        owner: objcClass,
                        swiftProperty: swiftProperty
                    )
                    propertyWrapper.objcNestedClass = ObjcInteropTransitiveClass(
                        owner: propertyWrapper,
                        managedSwiftStruct: swiftStruct
                    )
                    return propertyWrapper
                case let swiftEnum as SwiftEnum:
                    let propertyWrapper = ObjcInteropPropertyWrapperAccessingNestedEnum(
                        owner: objcClass,
                        swiftProperty: swiftProperty
                    )
                    propertyWrapper.objcNestedEnum = ObjcInteropEnum(
                        owner: propertyWrapper,
                        managedSwiftEnum: swiftEnum
                    )
                    return propertyWrapper
                case let swiftArray as SwiftArray where swiftArray.element is SwiftEnum:
                    let propertyWrapper = ObjcInteropPropertyWrapperAccessingNestedEnumsArray(
                        owner: objcClass,
                        swiftProperty: swiftProperty
                    )
                    propertyWrapper.objcNestedEnumsArray = ObjcInteropEnumArray(
                        owner: propertyWrapper,
                        managedSwiftEnum: swiftArray.element as! SwiftEnum // swiftlint:disable:this force_cast
                    )
                    return propertyWrapper
                case let swiftArray as SwiftArray where swiftArray.element is SwiftPrimitiveType:
                    let propertyWrapper = ObjcInteropPropertyWrapperManagingSwiftStructProperty(
                        owner: objcClass,
                        swiftProperty: swiftProperty
                    )
                    propertyWrapper.objcInteropType = try objcInteropType(for: swiftArray)
                    return propertyWrapper
                case let swifTypeReference as SwiftTypeReference:
                    let referencedType = try resolve(swiftTypeReference: swifTypeReference)

                    switch referencedType {
                    case let swiftStruct as SwiftStruct:
                        let propertyWrapper = ObjcInteropPropertyWrapperAccessingNestedStruct(
                            owner: objcClass,
                            swiftProperty: swiftProperty
                        )
                        propertyWrapper.objcNestedClass = ObjcInteropReferencedTransitiveClass(
                            owner: propertyWrapper,
                            managedSwiftStruct: swiftStruct
                        )
                        return propertyWrapper
                    case let swiftEnum as SwiftEnum:
                        let propertyWrapper = ObjcInteropPropertyWrapperAccessingNestedEnum(
                            owner: objcClass,
                            swiftProperty: swiftProperty
                        )
                        propertyWrapper.objcNestedEnum = ObjcInteropReferencedEnum(
                            owner: propertyWrapper,
                            managedSwiftEnum: swiftEnum
                        )
                        return propertyWrapper
                    default:
                        throw Exception.illegal("Illegal reference type: \(swifTypeReference)")
                    }
                default:
                    throw Exception.unimplemented(
                        "Cannot generate @objc property wrapper for: \(type(of: swiftProperty.type))"
                    )
                }
            }

        try objcClass.objcPropertyWrappers
            .compactMap { $0 as? ObjcInteropPropertyWrapperForTransitiveType }
            .forEach { propertyWrapper in
                // Store `ObjcInteropTypes` created for property wrappers
                outputObjcInteropTypes.append(propertyWrapper.objcTransitiveType)
                if let transitiveClass = propertyWrapper.objcTransitiveType as? ObjcInteropClass {
                    // Recursively generate property wrappers for each transitive `ObjcInteropClass`
                    try generateTransitiveObjcInteropTypes(in: transitiveClass)
                }
            }
    }

    private func objcInteropType(for swiftType: SwiftType) throws -> ObjcInteropType {
        switch swiftType {
        case _ as SwiftPrimitive<Bool>,
             _ as SwiftPrimitive<Double>,
             _ as SwiftPrimitive<Int>,
             _ as SwiftPrimitive<Int64>:
            return ObjcInteropNSNumber(swiftType: swiftType)
        case let swiftString as SwiftPrimitive<String>:
            return ObjcInteropNSString(swiftString: swiftString)
        case let swiftArray as SwiftArray:
            return ObjcInteropNSArray(element: try objcInteropType(for: swiftArray.element))
        default:
            throw Exception.unimplemented(
                "Cannot create `ObjcInteropType` type for \(type(of: swiftType))."
            )
        }
    }

    // MARK: - Helpers

    /// Filters out given `SwiftTypes` by removing all types referenced using `SwiftReferenceType`.
    ///
    /// For example, given swift schema this Swift code:
    ///
    ///         struct Foo {
    ///            let shared: SharedStruct
    ///         }
    ///
    ///         struct Bar {
    ///            let shared: SharedStruct
    ///         }
    ///
    ///         struct SharedStruct {
    ///            // ...
    ///         }
    ///
    /// if both `Foo` and `Bar` use `SwiftReferenceType(referencedTypeName: "SharedStruct")`,
    /// the returned array will contain only `Foo` and `Bar` schemas.
    private func takeRootSwiftStructs(from swiftTypes: [SwiftType]) -> [SwiftStruct] {
        let referencedTypeNames = swiftTypes
            .compactMap { $0 as? SwiftStruct } // only `SwiftStructs` may contain `SwiftReferenceType`
            .flatMap { $0.recursiveSwiftTypeReferences }
            .map { $0.referencedTypeName }
            .asSet()

        return swiftTypes
            .compactMap { $0 as? SwiftStruct }
            .filter { !referencedTypeNames.contains($0.typeName!) } // swiftlint:disable:this force_unwrapping
    }

    /// Searches `SwiftTypes` passed on input and returns the one described by given `SwiftTypeReference`.
    private func resolve(swiftTypeReference: SwiftTypeReference) throws -> SwiftType {
        return try inputSwiftTypes
            .first { $0.typeName == swiftTypeReference.referencedTypeName }
            .unwrapOrThrow(.inconsistency("Cannot find referenced type \(swiftTypeReference.referencedTypeName)"))
    }
}

// MARK: - Reflection Helpers

private extension SwiftStruct {
    /// Returns `SwiftTypeReferences` used by this or nested structs.
    var recursiveSwiftTypeReferences: [SwiftTypeReference] {
        let referencesInThisStruct = properties
            .compactMap { $0.type as? SwiftTypeReference }
        let referencesInNestedStructs = properties
            .compactMap { $0.type as? SwiftStruct }
            .flatMap { $0.recursiveSwiftTypeReferences }
        return referencesInThisStruct + referencesInNestedStructs
    }
}
