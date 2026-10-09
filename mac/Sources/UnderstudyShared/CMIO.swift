import CoreMediaIO
import Foundation

/// Just enough of the CoreMediaIO C API to find our device and read the
/// custom properties the extension publishes: 'dmnd' (how many apps are
/// streaming) and 'stat' (the agent's state while there's no live video).
public enum CMIO {
    public static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    public static func devices() -> [CMIOObjectID] {
        objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
    }

    /// Our virtual camera's device, if this process can see it yet.
    public static func virtualCamera() -> CMIOObjectID? {
        devices().first { uid(of: $0) == virtualCameraUID }
    }

    public static func objectIDs(_ object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(UInt32(selector))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else {
            return []
        }
        return ids
    }

    public static func uid(of device: CMIOObjectID) -> String? {
        try? string(device, UInt32(kCMIODevicePropertyDeviceUID))
    }

    /// Reads a CFString property, throwing the OSStatus on failure.
    public static func string(_ object: CMIOObjectID, _ selector: UInt32) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value)
        guard err == noErr, let str = value?.takeRetainedValue() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return str as String
    }

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static let demandSelector = fourCC("dmnd")
    public static let statusSelector = fourCC("stat")
}
