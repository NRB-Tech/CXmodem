import xmodem;
import Foundation;
import Dispatch;

private func localXmodem(thread: Thread) -> CXmodem {
    let key = "xmodem"
    let threadDictionary = thread.threadDictionary
    guard let cachedObject = threadDictionary[key] as? CXmodem else {
        let newObject = CXmodem()
        threadDictionary[key] = newObject
        return newObject
    }
    return cachedObject
}

private func inByte(timeout: UInt16) -> Int32 {
    return localXmodem(thread: Thread.current).inByte(timeout: timeout)
}
private func outByte(byte: UInt8) -> Void {
    localXmodem(thread: Thread.current).outByte(byte: byte)
}

private var initCallbacks: () = {
    xmodemInByte = inByte
    xmodemOutByte = outByte
}()

class CXmodem {
    
    /// Errors that can occur during a send or receive operation
    enum OperationError: Int, Error {
            case cancelledByRemote = -1
            case noSync = -2
            case tooManyRetries = -3
            case transmitError = -4
            case unexpectedResponse = -5
    }
    
    
    /// Get an instance of CXmodem local to the current thread
    static var threadLocal: CXmodem {
        return localXmodem(thread: Thread.current)
    }
    
    /// Get the shared instance of CXmodem
    static var shared = CXmodem()
    
    fileprivate init() {
        _=initCallbacks
    }
    
    private(set) public var inOperation = false
    private var receivedDataBuffer: Data = Data()
    private let receiveAccessQueue = DispatchQueue(label: "Receive access queue")
    
    func getReceivedByte() -> UInt8? {
        var byte: UInt8? = nil
        receiveAccessQueue.sync {
            guard receivedDataBuffer.count > 0 else {
                return
            }
            byte = receivedDataBuffer.remove(at: 0)
        }
        return byte
    }

    fileprivate func inByte(timeout: UInt16) -> Int32 {
        let delays = timeout / 10
        var byte: UInt8? = nil
        for _ in 0..<delays {
            flush()
            byte = getReceivedByte()
            if byte != nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let b = byte else {
            return -1
        }
        return Int32(b)
    }
    
    private var outBuffer = Data()
    private func flush() {
        if(outBuffer.count > 0) {
            sendBytesOnWireCallback!(outBuffer)
            outBuffer = Data()
        }
    }
    fileprivate func outByte(byte: UInt8) -> Void {
        outBuffer.append(byte)
        if(outBuffer.count >= sendChunkSize) {
            flush()
        }
    }
    
    typealias SendBytesCallback = (_ data: Data) -> Void

    private var sendBytesOnWireCallback: SendBytesCallback? = nil
    private var sendChunkSize: Int = 1 {
        didSet {
            precondition(sendChunkSize > 0)
        }
    }
    
    private func startOperation(sendBytesOnWireCallback: @escaping SendBytesCallback, sendChunkSize: Int) {
        precondition(!inOperation)
        self.sendBytesOnWireCallback = sendBytesOnWireCallback
        self.sendChunkSize = sendChunkSize
        inOperation = true
    }
    
    private func endOperation() {
        self.flush()
        self.inOperation = false
        self.sendBytesOnWireCallback = nil
    }
    
    
    /// Pass in data received on the wire to CXmodem on a specific thread
    /// - Parameters:
    ///   - thread: The specific thread that CXmodem is running on
    ///   - data: The data received
    class func receivedBytesOnWire(thread: Thread, data: Data) {
        localXmodem(thread: thread).receivedBytesOnWire(data: data)
    }
    
    /// Pass in data received on the wire
    /// - Parameter data: The data received
    func receivedBytesOnWire(data: Data) {
        receiveAccessQueue.async {
            self.receivedDataBuffer.append(data)
        }
    }

    /// The result of a send operation
    enum SendResult {
        case success
        case fail(error: OperationError)
    }
    
    /// Send data via xmodem
    /// - Parameters:
    ///   - data: The data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `SendResult.success`, else `SendResult.fail` with the relevant `OperationError`
    func send(data: Data, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> SendResult {
        startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        defer {
            endOperation()
        }
        let result = data.withUnsafeBytes {
            xmodemTransmit($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
        }
        return result > 0 ? .success : .fail(error: OperationError.init(rawValue: Int(result))!);
    }
    
    
    /// Send data via xmodem on another queue
    /// - Parameters:
    ///   - data: The data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - callback: The result callback. If success, passed `SendResult.success`, else passed `SendResult.fail` with the relevant `OperationError`
    ///   - callbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    func send(data: Data,
              sendChunkSize: Int = 1,
              sendBytesOnWireCallback: @escaping SendBytesCallback,
              sendBytesOnWireQueue: DispatchQueue? = nil,
              callback: @escaping (_ result: SendResult) -> Void,
              callbackQueue:DispatchQueue = DispatchQueue.main,
              operationQueue: DispatchQueue = DispatchQueue(label: "XModem", qos: .background)) -> Void {
        operationQueue.async {
            let result: SendResult
            if let wireQueue = sendBytesOnWireQueue {
                result = self.send(data: data, sendChunkSize: sendChunkSize) { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                }
            } else {
                result = self.send(data: data, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            callbackQueue.async {
                callback(result)
            }
        }
    }
    
    /// The result of a receive operation
    enum ReceiveResult {
        case success(data: Data)
        case fail(error: OperationError)
    }

    
    /// Receive data via Xmodem
    /// - Parameters:
    ///   - maxNumPackets: The maximum number of 128 byte packets to receive
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `ReceiveResult.success` containing the received data, else `ReceiveResult.fail` with the relevant `OperationError`
    func receive(maxNumPackets: Int, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> ReceiveResult {
        startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        defer {
            endOperation()
        }
        let maxLength = 128 * maxNumPackets
        var data = Data(count: maxLength);
        let result = data.withUnsafeMutableBytes {
            xmodem.xmodemReceive($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count));
        }
        if (result > 0) {
            var remove = 0
            for i in 0..<data.count {
                switch data[Int(result) - i - 1] {
                case 0: continue
                case 0x1A:
                    remove = i + 1
                    break
                default:
                    break
                }
                break
            }
            data.removeLast(maxLength - Int(result) + remove);
            self.endOperation()
            return .success(data: data)
        } else {
            self.endOperation()
            self.flush()
            self.inOperation = false
            return .fail(error: OperationError(rawValue: Int(result))!)
        }
    }
    
    /// Receive data via Xmodem on another queue
    /// - Parameters:
    ///   - maxNumPackets: The maximum number of 128 byte packets to receive
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - callback: The result callback. If success, passed `ReceiveResult.success` containing the received data, else passed `ReceiveResult.fail` with the relevant `OperationError`
    ///   - callbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    func receive(maxNumPackets: Int,
                 sendChunkSize: Int = 1,
                 sendBytesOnWireCallback: @escaping SendBytesCallback,
                 sendBytesOnWireQueue: DispatchQueue? = nil,
                 callback: @escaping (_ result: ReceiveResult) -> Void,
                 callbackQueue:DispatchQueue = DispatchQueue.main,
                 operationQueue: DispatchQueue = DispatchQueue(label: "XModem", qos: .background)) -> Void {
        operationQueue.async {
            let result: ReceiveResult
            if let wireQueue = sendBytesOnWireQueue {
                result = self.receive(maxNumPackets: maxNumPackets, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                })
            } else {
                result = self.receive(maxNumPackets: maxNumPackets, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            callbackQueue.async {
                callback(result)
            }
        }
    }
}


