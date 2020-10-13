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

private func _getTxBuffer(size: UnsafeMutablePointer<Int32>?) -> UnsafePointer<UInt8>? {
    return localXmodem(thread: Thread.current).getTxBuffer(size: size)
}
private func _getRxBuffer(size: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>? {
    return localXmodem(thread: Thread.current).getRxBuffer(size: size)
}

private var initCallbacks: () = {
    xmodemInByte = inByte
    xmodemOutByte = outByte
}()

/// Swift typesafe Xmodem wrapper
public class CXmodem {
    
    /// Errors that can occur during a send or receive operation
    public enum OperationError: Int, Error {
        case cancelledByRemote = -1
        case noSync = -2
        case tooManyRetries = -3
        case transmitError = -4
        case unexpectedResponse = -5
        case bufferFull = -6
    }
    
    
    /// Get an instance of CXmodem local to the current thread
    private static var threadLocal: CXmodem {
        return localXmodem(thread: Thread.current)
    }
    
    fileprivate init() {
        _=initCallbacks
    }
    
    private(set) public var inOperation = false
    private var receivedDataBuffer: Data = Data()
    private let receiveAccessQueue = DispatchQueue(label: "Receive access queue")
    
    private func getReceivedByte() -> UInt8? {
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
        var byte: UInt8? = nil
        let startDate = Date()
        let timeoutS = TimeInterval(timeout) / 1000
        let sleepInterval = min(timeoutS, 0.01)
        while true {
            flush()
            byte = getReceivedByte()
            if byte != nil {
                break
            }
            if -startDate.timeIntervalSinceNow > (timeoutS - sleepInterval) {
                break
            }
            Thread.sleep(forTimeInterval: sleepInterval)
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
    
    
    public typealias SendBytesCallback = (_ data: Data) -> Void
    public enum ReceivedDataCallbackResult {
        case `continue`
        case stop
    }
    public typealias ReceivedDataCallback = (_ data: Data) -> ReceivedDataCallbackResult

    private var sendBytesOnWireCallback: SendBytesCallback? = nil
    private var sendChunkSize: Int = 1 {
        didSet {
            precondition(sendChunkSize > 0)
        }
    }
    
    fileprivate func getTxBuffer(size: UnsafeMutablePointer<Int32>?) -> UnsafePointer<UInt8>? {
        let data = txDataCallback!()
        txDataBuffer?.deallocate()
        guard let d = data else {
            txDataBuffer = nil
            return nil
        }
        txDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
        d.copyBytes(to: txDataBuffer!, count: d.count)
        size?.pointee = Int32(d.count)
        return UnsafePointer(txDataBuffer!)
    }
    private static let rxBufferLen = 1024
    private func callbackWithRxBuffer(totalLength: Int? = nil) -> ReceivedDataCallbackResult {
        if let b = rxDataBuffer {
            let data: Data
            if let t = totalLength {
                data = Data(bytes: b, count: t % CXmodem.rxBufferLen)
            } else {
                data = Data(bytes: b, count: CXmodem.rxBufferLen)
            }
            
            b.deallocate()
            rxDataBuffer = nil
            return rxDataCallback!(data)
        }
        return .continue
    }
    fileprivate func getRxBuffer(size: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>? {
        if callbackWithRxBuffer() == .stop {
            return nil
        }
        rxDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CXmodem.rxBufferLen)
        size!.pointee = Int32(CXmodem.rxBufferLen)
        return rxDataBuffer
    }
    
    private static var queueMap: NSMapTable<DispatchQueue, Thread> = NSMapTable.weakToWeakObjects()
    
    private var txDataCallback: (() -> Data?)?
    private var txDataBuffer: UnsafeMutablePointer<UInt8>?
    private var rxDataCallback: ReceivedDataCallback?
    private var rxDataBuffer: UnsafeMutablePointer<UInt8>?
    
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
        self.txDataCallback = nil
        self.txDataBuffer?.deallocate()
        self.txDataBuffer = nil
        self.rxDataBuffer?.deallocate()
        self.rxDataBuffer = nil
        self.rxDataCallback = nil
    }
    
    
    /// Pass in data received on the wire to CXmodem on a specific thread
    /// - Parameters:
    ///   - thread: The specific thread that CXmodem is running on
    ///   - data: The data received
    public class func receivedBytesOnWire(thread: Thread, data: Data) {
        localXmodem(thread: thread).receivedBytesOnWire(data: data)
    }
    
    /// Pass in data received on the wire to CXmodem for a specifc queue
    /// - Parameters:
    ///   - queue: The specific queue that CXmodem is running on
    ///   - data: The data received
    public class func receivedBytesOnWire(queue: DispatchQueue, data: Data) {
        if let thread = queueMap.object(forKey: queue) {
            receivedBytesOnWire(thread: thread, data: data)
        }
    }
    
    /// Pass in data received on the wire
    /// - Parameter data: The data received
    public func receivedBytesOnWire(data: Data) {
        receiveAccessQueue.async {
            guard self.inOperation else {
                return
            }
            self.receivedDataBuffer.append(data)
        }
    }

    /// The result of a send operation
    public enum Result {
        case success
        case fail(error: OperationError)
    }
    
    /// Send data via xmodem
    /// - Parameters:
    ///   - dataCallback: A closure to fetch more data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `SendResult.success`, else `SendResult.fail` with the relevant `OperationError`
    /// - Warning: Blocks the current thread
    public class func send(dataCallback: @escaping () -> Data?, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> Result {
        let cxmodem = CXmodem.threadLocal
        cxmodem.startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        cxmodem.txDataCallback = dataCallback
        defer {
            cxmodem.endOperation()
        }
        let result = xmodemTransmit(_getTxBuffer)
        return result > 0 ?
            .success :
            .fail(error: OperationError.init(rawValue: Int(result))!);
    }
    
    /// Send data via xmodem
    /// - Parameters:
    ///   - data: The data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `SendResult.success`, else `SendResult.fail` with the relevant `OperationError`
    /// - Warning: Blocks the current thread
    public class func send(data: Data, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> Result {
        var sent = false
        return send(dataCallback: {
            guard !sent else { return nil }
            sent = true
            return data
        }, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
    }
    
    
    /// Send data via xmodem on another queue
    /// - Parameters:
    ///   - dataCallback: A closure to fetch more data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireCallbackQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - completeCallback: The result callback. If success, passed `Result.success`, else passed `Result.fail` with the relevant `OperationError`
    ///   - callbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    /// - Returns: The operation queue that the send is being performed on
    public class func send(dataCallback: @escaping () -> Data?,
              sendChunkSize: Int = 1,
              sendBytesOnWireCallback: @escaping SendBytesCallback,
              sendBytesOnWireCallbackQueue: DispatchQueue? = nil,
              completeCallback: @escaping (_ result: Result) -> Void,
              completeCallbackQueue:DispatchQueue = DispatchQueue.main,
              operationQueue: DispatchQueue = DispatchQueue(label: "XModem Tx", qos: .background)) -> DispatchQueue {
        operationQueue.async {
            CXmodem.queueMap.setObject(Thread.current, forKey: operationQueue)
            let result: Result
            if let wireQueue = sendBytesOnWireCallbackQueue {
                result = send(dataCallback: dataCallback, sendChunkSize: sendChunkSize) { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                }
            } else {
                result = send(dataCallback: dataCallback, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            CXmodem.queueMap.removeObject(forKey: operationQueue)
            completeCallbackQueue.async {
                completeCallback(result)
            }
        }
        return operationQueue
    }
    
    /// - Parameters:
    ///   - data: The data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireCallbackQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - completeCallback: The result callback. If success, passed `Result.success`, else passed `Result.fail` with the relevant `OperationError`
    ///   - callbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    /// - Returns: The operation queue that the send is being performed on
    public class func send(data: Data,
              sendChunkSize: Int = 1,
              sendBytesOnWireCallback: @escaping SendBytesCallback,
              sendBytesOnWireCallbackQueue: DispatchQueue? = nil,
              completeCallback: @escaping (_ result: Result) -> Void,
              completeCallbackQueue:DispatchQueue = DispatchQueue.main,
              operationQueue: DispatchQueue = DispatchQueue(label: "XModem Tx", qos: .background)) -> DispatchQueue {
        var sent = false
        return send(dataCallback: {
            guard !sent else { return nil }
            sent = true
            return data
        }, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback, completeCallback: completeCallback, completeCallbackQueue: completeCallbackQueue, operationQueue: operationQueue)
    }

    
    /// Receive data via Xmodem
    /// - Parameters:
    ///   - receivedDataCallback: Called when a packet of data is received, passed the data and should return a boolean – `ReceivedDataCallbackResult.continue` to continue receiving, `ReceivedDataCallbackResult.stop` if rx buffer is full
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `Result.success`, else `Result.fail` with the relevant `OperationError`
    /// - Warning: Blocks the current thread
    public class func receive(receivedDataCallback: @escaping ReceivedDataCallback, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> Result {
        let cxmodem = CXmodem.threadLocal
        cxmodem.startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        defer {
            cxmodem.endOperation()
        }
        cxmodem.rxDataCallback = receivedDataCallback
        let result = xmodemReceive(_getRxBuffer)
        if result > 0 {
            _=cxmodem.callbackWithRxBuffer(totalLength: Int(result))
            return .success
        }
        return .fail(error: OperationError(rawValue: Int(result))!)
    }
    
    /// Receive data via Xmodem on another queue
    /// - Parameters:
    ///   - receivedDataCallback: Called when a packet of data is received, passed the data and should return a boolean – `ReceivedDataCallbackResult.continue` to continue receiving, `ReceivedDataCallbackResult.stop` if rx buffer is full
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireCallbackQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - completeCallback: The result callback. If success, passed `Result.success`, else passed `Result.fail` with the relevant `OperationError`
    ///   - completeCallbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    /// - Returns: The operation queue that the receive is being performed on
    public class func receive(receivedDataCallback: @escaping ReceivedDataCallback,
                 sendChunkSize: Int = 1,
                 sendBytesOnWireCallback: @escaping SendBytesCallback,
                 sendBytesOnWireCallbackQueue: DispatchQueue? = nil,
                 completeCallback: @escaping (_ result: Result) -> Void,
                 completeCallbackQueue:DispatchQueue = DispatchQueue.main,
                 operationQueue: DispatchQueue = DispatchQueue(label: "XModem Rx", qos: .background)) -> DispatchQueue {
        operationQueue.async {
            CXmodem.queueMap.setObject(Thread.current, forKey: operationQueue)
            let result: Result
            if let wireQueue = sendBytesOnWireCallbackQueue {
                result = receive(receivedDataCallback: receivedDataCallback, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                })
            } else {
                result = receive(receivedDataCallback: receivedDataCallback, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            CXmodem.queueMap.removeObject(forKey: operationQueue)
            completeCallbackQueue.async {
                completeCallback(result)
            }
        }
        return operationQueue
    }
}


