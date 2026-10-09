/// The virtual camera's CMIO device UID, which AVFoundation also reports as
/// its uniqueID. It must never change: apps remember the camera by it. The
/// extension declares it separately in Extension.swift (it doesn't link this
/// library), so the two have to match.
public let virtualCameraUID = "6C1A4F2E-9B0D-4E57-A3C8-2F7D1B5E8C40"
