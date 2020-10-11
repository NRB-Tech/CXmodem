# CXmodem

A thread-safe Swift wrapper around a modified version of George Menie's Xmodem.

## Installation using Swift package manager

1. Add the project to your `Package.swift`:

```swift
import PackageDescription

let package = Package(
    name: "MyAwesomeProject",
    dependencies: [
        .Package(url: "https://github.com/nrbtech/CXmodem.git",
                 majorVersion: 1)
    ]
)
```

Import the CXModem module.

```swift
import CXmodem
```


## Usage

When providing a callback, CXmodem's `send` and `receive` functions are performed on a background thread:

```swift
CXmodem.shared.send(data: dataToSend, sendChunkSize: 20, sendBytesOnWireCallback: { (toSendOnWire) in
    serialPort.send(data: data)
}) { (sendResult) in
    switch sendResult {
    case .success:
        print("Send complete!")
    case .fail(error: let e):
        print("Error: \(e.rawValue)")
    }
}

// when receiving data on "wire". Does not have to be called on a specific thread
CXmodem.shared.receivedBytesOnWire(data: receivedData)
```

If you do not provide a callback the functions are blocking, so must be performed on a background thread. :

```swift
let callback = { (sendResult: CXmodem.SendResult) -> Void in
    switch sendResult {
    case .success:
        print("Send complete!")
    case .fail(error: let e):
        print("Error: \(e.rawValue)")
    }
}

DispatchQueue(label: "Xmodem send", qos: .background).async {
    let sendResult = CXmodem.shared.send(data: dataToSend, sendChunkSize: 20) { (toSendOnWire) in
        serialPort.send(data: toSendOnWire)
    }
    DispatchQueue.main.async {
        callback(sendResult)
    }
}

// when receiving data on "wire". Does not have to be called on a specific thread
CXmodem.shared.receivedBytesOnWire(data: receivedData)
```
