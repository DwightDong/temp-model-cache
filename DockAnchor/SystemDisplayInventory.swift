import Foundation
import CoreGraphics
import IOKit

struct RuntimeDisplayInventory: Equatable {
    let observations: [DisplayRuntimeObservation]
    let framesByRuntimeID: [UInt64: CGRect]
    let mainRuntimeID: UInt64
}

struct DisplayInventoryAcquisition: Equatable {
    let runtime: RuntimeDisplayInventory
    let iokitMetadata: [DisplayMetadataObservation]
    let profilerMetadata: [DisplayMetadataObservation]

    var allMetadata: [DisplayMetadataObservation] {
        iokitMetadata + profilerMetadata
    }
}

struct PreparedDisplayInventory {
    let acquisition: DisplayInventoryAcquisition
    let reconciliation: DisplayReconciliationSnapshot
}

protocol DisplayInventorySourceProviding: AnyObject {
    func acquireRuntimeInventory(
        cancellation: DisplayInventoryCancellationToken
    ) -> RuntimeDisplayInventory?

    /// Nil means a temporary source failure. An empty array is a successful
    /// observation containing no records.
    func acquireIOKitMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]?

    func acquireProfilerMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]?
}

protocol DisplayInventoryPreparing: AnyObject {
    func prepare(
        scope: DisplayInventoryRefreshScope,
        cancellation: DisplayInventoryCancellationToken
    ) -> PreparedDisplayInventory?

    func recordCommittedInventory(
        _ acquisition: DisplayInventoryAcquisition,
        registry: DisplayIdentityRegistry
    )
}

/// Owns the last accepted acquisition and registry. Superseded provider results
/// never enter this state, so an arrangement refresh cannot inherit metadata or
/// aliases from a stale generation.
final class ReconciledDisplayInventoryProvider: DisplayInventoryPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private let source: DisplayInventorySourceProviding
    private var committedAcquisition: DisplayInventoryAcquisition?
    private var committedRegistry: DisplayIdentityRegistry

    init(
        source: DisplayInventorySourceProviding,
        initialRegistry: DisplayIdentityRegistry
    ) {
        self.source = source
        committedRegistry = initialRegistry
    }

    func prepare(
        scope: DisplayInventoryRefreshScope,
        cancellation: DisplayInventoryCancellationToken
    ) -> PreparedDisplayInventory? {
        lock.lock()
        let previous = committedAcquisition
        let priorRegistry = committedRegistry
        lock.unlock()

        guard !cancellation.isCancelled,
              let runtime = source.acquireRuntimeInventory(
                cancellation: cancellation
              ),
              !cancellation.isCancelled else {
            return nil
        }

        let iokitMetadata: [DisplayMetadataObservation]
        let profilerMetadata: [DisplayMetadataObservation]
        switch scope {
        case .arrangement:
            iokitMetadata = previous?.iokitMetadata ?? []
            profilerMetadata = previous?.profilerMetadata ?? []
        case .full:
            guard !cancellation.isCancelled else { return nil }
            iokitMetadata = source.acquireIOKitMetadata(
                cancellation: cancellation
            ) ?? previous?.iokitMetadata ?? []
            guard !cancellation.isCancelled else { return nil }
            profilerMetadata = source.acquireProfilerMetadata(
                cancellation: cancellation
            ) ?? previous?.profilerMetadata ?? []
        }

        guard !cancellation.isCancelled else { return nil }
        let acquisition = DisplayInventoryAcquisition(
            runtime: runtime,
            iokitMetadata: iokitMetadata,
            profilerMetadata: profilerMetadata
        )
        let reconciliation = DisplayReconciler.reconcile(
            runtimes: runtime.observations,
            metadata: acquisition.allMetadata,
            priorRegistry: priorRegistry
        )
        guard !cancellation.isCancelled else { return nil }
        return PreparedDisplayInventory(
            acquisition: acquisition,
            reconciliation: reconciliation
        )
    }

    func recordCommittedInventory(
        _ acquisition: DisplayInventoryAcquisition,
        registry: DisplayIdentityRegistry
    ) {
        lock.lock()
        committedAcquisition = acquisition
        committedRegistry = registry
        lock.unlock()
    }
}

final class SystemDisplayInventorySource: DisplayInventorySourceProviding {
    private let processRunner: BoundedProcessRunning
    private let profilerConfiguration: BoundedProcessConfiguration

    init(
        processRunner: BoundedProcessRunning = BoundedProcessRunner(),
        profilerTimeout: TimeInterval = 8,
        profilerOutputLimit: Int = BoundedProcessConfiguration.absoluteMaximumOutputBytes
    ) {
        self.processRunner = processRunner
        profilerConfiguration = BoundedProcessConfiguration(
            timeout: profilerTimeout,
            maximumOutputBytes: profilerOutputLimit
        )
    }

    func acquireRuntimeInventory(
        cancellation: DisplayInventoryCancellationToken
    ) -> RuntimeDisplayInventory? {
        guard !cancellation.isCancelled else { return nil }
        let maximumDisplayCount: UInt32 = 16
        var identifiers = [CGDirectDisplayID](
            repeating: 0,
            count: Int(maximumDisplayCount)
        )
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(
            maximumDisplayCount,
            &identifiers,
            &count
        ) == .success else {
            return nil
        }

        let validIdentifiers = Array(identifiers.prefix(Int(count))).filter {
            let frame = CGDisplayBounds($0)
            return frame.width > 0 && frame.height > 0
        }
        // A running macOS desktop always has an active runtime display. Treat a
        // zero-length result as an authoritative acquisition failure rather
        // than publishing an empty intermediate UI.
        guard !validIdentifiers.isEmpty, !cancellation.isCancelled else {
            return nil
        }

        var observations: [DisplayRuntimeObservation] = []
        var frames: [UInt64: CGRect] = [:]
        observations.reserveCapacity(validIdentifiers.count)
        frames.reserveCapacity(validIdentifiers.count)
        for displayID in validIdentifiers {
            guard !cancellation.isCancelled else { return nil }
            let serial = CGDisplaySerialNumber(displayID)
            observations.append(DisplayRuntimeObservation(
                runtimeID: UInt64(displayID),
                uuidAlias: Self.displayUUIDAlias(for: displayID),
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: serial == 0 ? nil : serial,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
            ))
            frames[UInt64(displayID)] = CGDisplayBounds(displayID)
        }

        return RuntimeDisplayInventory(
            observations: observations,
            framesByRuntimeID: frames,
            mainRuntimeID: UInt64(CGMainDisplayID())
        )
    }

    func acquireIOKitMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]? {
        guard !cancellation.isCancelled else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var observations: [DisplayMetadataObservation] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard !cancellation.isCancelled else { return nil }
            guard let info = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any] else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            let vendor = DisplayInventoryValueParser.uint32Value(
                info[kDisplayVendorID]
            ) ?? 0
            let product = DisplayInventoryValueParser.uint32Value(
                info[kDisplayProductID]
            ) ?? 0
            let serial = DisplayInventoryValueParser.uint32Value(
                info[kDisplaySerialNumber]
            ).flatMap { $0 == 0 ? nil : $0 }
            let uuidAlias = DisplayInventoryValueParser.stringValue(
                info["DisplayUUID"] ?? info["IODisplayUUID"] ?? info["UUID"]
            )
            let name = DisplayInventoryValueParser.localizedProductName(
                info[kDisplayProductName]
            )

            observations.append(DisplayMetadataObservation(
                source: "iokit",
                sourceID: "iokit-\(registryID)",
                uuidAlias: uuidAlias,
                vendorID: vendor,
                productID: product,
                serialNumber: serial,
                name: name,
                presentationPriority: 50
            ))
        }
        return observations
    }

    func acquireProfilerMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]? {
        let result = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
            arguments: ["-json", "SPDisplaysDataType"],
            configuration: profilerConfiguration,
            cancellation: cancellation
        )
        guard result.succeeded, !cancellation.isCancelled else { return nil }
        return SystemProfilerDisplayParser.parse(result.output)
    }

    private static func displayUUIDAlias(
        for displayID: CGDirectDisplayID
    ) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

enum DisplayInventoryValueParser {
    static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSString, value.length > 0 {
            return value as String
        }
        return nil
    }

    static func uint32Value(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt64,
           value <= UInt64(UInt32.max) { return UInt32(value) }
        if let value = value as? Int,
           value >= 0,
           value <= Int(UInt32.max) { return UInt32(value) }
        if let value = value as? NSNumber { return value.uint32Value }
        if let value = stringValue(value) { return UInt32(value) }
        return nil
    }

    static func localizedProductName(_ value: Any?) -> String? {
        if let names = value as? [String: String] {
            return names["en_US"]
                ?? names["en"]
                ?? names.keys.sorted().compactMap { names[$0] }.first
        }
        if let names = value as? [String: Any] {
            return names.keys.sorted().compactMap {
                stringValue(names[$0])
            }.first
        }
        return stringValue(value)
    }

    static func profilerUInt32(
        _ value: Any?,
        hexadecimalByDefault: Bool
    ) -> UInt32? {
        if !(value is String) && !(value is NSString) {
            return uint32Value(value)
        }
        guard var text = stringValue(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        text = text.lowercased()
        if text.hasPrefix("0x") {
            return UInt32(text.dropFirst(2), radix: 16)
        }
        if text.allSatisfy({ $0.isNumber }) {
            return UInt32(text, radix: hexadecimalByDefault ? 16 : 10)
        }
        if text.allSatisfy({ $0.isHexDigit }) {
            return UInt32(text, radix: 16)
        }
        return nil
    }
}

enum SystemProfilerDisplayParser {
    static func parse(_ data: Data) -> [DisplayMetadataObservation]? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let adapters = root["SPDisplaysDataType"] as? [[String: Any]] else {
            return nil
        }

        var records: [(
            baseID: String,
            observation: DisplayMetadataObservation
        )] = []
        for adapter in adapters {
            guard let displays = adapter["spdisplays_ndrvs"]
                    as? [[String: Any]] else { continue }
            for display in displays {
                let name = DisplayInventoryValueParser.stringValue(
                    display["_name"]
                )
                let vendor = DisplayInventoryValueParser.profilerUInt32(
                    display["_spdisplays_display-vendor-id"]
                        ?? display["spdisplays_vendor-id"],
                    hexadecimalByDefault: true
                ) ?? 0
                let product = DisplayInventoryValueParser.profilerUInt32(
                    display["_spdisplays_display-product-id"]
                        ?? display["spdisplays_product-id"],
                    hexadecimalByDefault: true
                ) ?? 0
                let serial = DisplayInventoryValueParser.profilerUInt32(
                    display["_spdisplays_display-serial-number"]
                        ?? display["_spdisplays_display-serial-number2"]
                        ?? display["spdisplays_display-serial-number"],
                    hexadecimalByDefault: false
                ).flatMap { $0 == 0 ? nil : $0 }
                let uuidAlias = DisplayInventoryValueParser.stringValue(
                    display["_spdisplays_display-uuid"]
                        ?? display["spdisplays_display-uuid"]
                )
                let type = DisplayInventoryValueParser.stringValue(
                    display["spdisplays_display_type"]
                ) ?? DisplayInventoryValueParser.stringValue(
                    display["_spdisplays_display-type"]
                )
                let isBuiltIn = type.map {
                    $0.localizedCaseInsensitiveContains("built-in") ||
                        $0.localizedCaseInsensitiveContains("internal")
                }
                let resolution = DisplayInventoryValueParser.stringValue(
                    display["_spdisplays_resolution"]
                ) ?? DisplayInventoryValueParser.stringValue(
                    display["spdisplays_resolution"]
                )
                let baseID = [
                    uuidAlias ?? "",
                    String(vendor),
                    String(product),
                    String(serial ?? 0),
                    name ?? "",
                    type ?? "",
                    resolution ?? ""
                ].joined(separator: "|")
                records.append((
                    baseID: baseID,
                    observation: DisplayMetadataObservation(
                        source: "system_profiler",
                        sourceID: baseID,
                        uuidAlias: uuidAlias,
                        vendorID: vendor,
                        productID: product,
                        serialNumber: serial,
                        name: name,
                        isBuiltIn: isBuiltIn,
                        presentationPriority: 100
                    )
                ))
            }
        }

        var occurrences: [String: Int] = [:]
        return records.sorted { $0.baseID < $1.baseID }.map { item in
            let occurrence = occurrences[item.baseID, default: 0]
            occurrences[item.baseID] = occurrence + 1
            let record = item.observation
            return DisplayMetadataObservation(
                source: record.source,
                sourceID: "profiler-\(item.baseID)#\(occurrence)",
                uuidAlias: record.uuidAlias,
                vendorID: record.vendorID,
                productID: record.productID,
                serialNumber: record.serialNumber,
                name: record.name,
                isBuiltIn: record.isBuiltIn,
                presentationPriority: record.presentationPriority
            )
        }
    }
}
