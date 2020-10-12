# CXmodem

A thread-safe Swift wrapper around a modified version of George Menie's Xmodem.

## Installation using Swift package manager

1. Add the project to your Xcode project by using File >  Swift Packages > Add package dependency and entering `https://github.com/nrbtech/CXmodem.git`, or by modifying your `Package.swift`:

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

2. Import the CXmodem module.

```swift
import CXmodem
```


## Usage

When providing the `completeCallback` parameter, CXmodem's `send` and `receive` functions are automatically performed on a background thread:

```swift
let operationQueue = CXmodem.send(data: dataToSend, sendChunkSize: 20, sendBytesOnWireCallback: { (toSendOnWire) in
    serialPort.send(data: toSendOnWire)
}) { (sendResult) in
    switch sendResult {
    case .success:
        print("Send complete!")
    case .fail(error: let e):
        print("Error: \(e.rawValue)")
    }
}

// call when receiving data on "wire". Can be called on any thread but the operation queue must be passed
CXmodem.receivedBytesOnWire(queue: operationQueue, data: receivedData)
```

You can also optionally provide the queue to use for the `sendBytesOnWireCallback`, the final `completeCallback` and the operation queue.

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

let operationQueue = DispatchQueue(label: "Xmodem send", qos: .background)
operationQueue.async {
    let sendResult = CXmodem.send(data: dataToSend, sendChunkSize: 20) { (toSendOnWire) in
        serialPort.send(data: toSendOnWire)
    }
    DispatchQueue.main.async {
        callback(sendResult)
    }
}

// when receiving data on "wire". Does not have to be called on a specific thread
CXmodem.receivedBytesOnWire(queue: operationQueue, data: receivedData)
```
