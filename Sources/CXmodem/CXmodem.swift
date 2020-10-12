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

public class CXmodem {
    
    /// Errors that can occur during a send or receive operation
    public enum OperationError: Int, Error {
            case cancelledByRemote = -1
            case noSync = -2
            case tooManyRetries = -3
            case transmitError = -4
            case unexpectedResponse = -5
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

    private var sendBytesOnWireCallback: SendBytesCallback? = nil
    private var sendChunkSize: Int = 1 {
        didSet {
            precondition(sendChunkSize > 0)
        }
    }
    
    private static var queueMap: NSMapTable<DispatchQueue, Thread> = NSMapTable.weakToWeakObjects()
    
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
    public enum SendResult {
        case success
        case fail(error: OperationError)
    }
    
    /// Send data via xmodem
    /// - Parameters:
    ///   - data: The data to send
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `SendResult.success`, else `SendResult.fail` with the relevant `OperationError`
    /// - Warning: Blocks the current thread
    public class func send(data: Data, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> SendResult {
        let cxmodem = CXmodem.threadLocal
        cxmodem.startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        defer {
            cxmodem.endOperation()
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
    ///   - sendBytesOnWireCallbackQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - completeCallback: The result callback. If success, passed `SendResult.success`, else passed `SendResult.fail` with the relevant `OperationError`
    ///   - callbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    /// - Returns: The operation queue that the send is being performed on
    public class func send(data: Data,
              sendChunkSize: Int = 1,
              sendBytesOnWireCallback: @escaping SendBytesCallback,
              sendBytesOnWireCallbackQueue: DispatchQueue? = nil,
              completeCallback: @escaping (_ result: SendResult) -> Void,
              completeCallbackQueue:DispatchQueue = DispatchQueue.main,
              operationQueue: DispatchQueue = DispatchQueue(label: "XModem Tx", qos: .background)) -> DispatchQueue {
        operationQueue.async {
            CXmodem.queueMap.setObject(Thread.current, forKey: operationQueue)
            let result: SendResult
            if let wireQueue = sendBytesOnWireCallbackQueue {
                result = send(data: data, sendChunkSize: sendChunkSize) { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                }
            } else {
                result = send(data: data, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            CXmodem.queueMap.removeObject(forKey: operationQueue)
            completeCallbackQueue.async {
                completeCallback(result)
            }
        }
        return operationQueue
    }
    
    /// The result of a receive operation
    public enum ReceiveResult {
        case success(data: Data)
        case fail(error: OperationError)
    }

    
    /// Receive data via Xmodem
    /// - Parameters:
    ///   - maxNumPackets: The maximum number of 128 byte packets to receive
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    /// - Returns: If success, `ReceiveResult.success` containing the received data, else `ReceiveResult.fail` with the relevant `OperationError`
    /// - Warning: Blocks the current thread
    public class func receive(maxNumPackets: Int, sendChunkSize: Int = 1, sendBytesOnWireCallback: @escaping SendBytesCallback) -> ReceiveResult {
        let cxmodem = CXmodem.threadLocal
        cxmodem.startOperation(sendBytesOnWireCallback: sendBytesOnWireCallback, sendChunkSize: sendChunkSize)
        defer {
            cxmodem.endOperation()
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
            cxmodem.endOperation()
            return .success(data: data)
        } else {
            cxmodem.endOperation()
            cxmodem.flush()
            cxmodem.inOperation = false
            return .fail(error: OperationError(rawValue: Int(result))!)
        }
    }
    
    /// Receive data via Xmodem on another queue
    /// - Parameters:
    ///   - maxNumPackets: The maximum number of 128 byte packets to receive
    ///   - sendChunkSize: If provided, CXModem will chunk data sends into at most this size
    ///   - sendBytesOnWireCallback: A callback for sending bytes on the wire
    ///   - sendBytesOnWireCallbackQueue: The queue to perform the `sendBytesOnWireCallback` on. Default `nil` is the operation queue
    ///   - completeCallback: The result callback. If success, passed `ReceiveResult.success` containing the received data, else passed `ReceiveResult.fail` with the relevant `OperationError`
    ///   - completeCallbackQueue: The queue to perform the result callback on
    ///   - operationQueue: The queue to perform the operation on
    /// - Returns: The operation queue that the receive is being performed on
    public class func receive(maxNumPackets: Int,
                 sendChunkSize: Int = 1,
                 sendBytesOnWireCallback: @escaping SendBytesCallback,
                 sendBytesOnWireCallbackQueue: DispatchQueue? = nil,
                 completeCallback: @escaping (_ result: ReceiveResult) -> Void,
                 completeCallbackQueue:DispatchQueue = DispatchQueue.main,
                 operationQueue: DispatchQueue = DispatchQueue(label: "XModem Rx", qos: .background)) -> DispatchQueue {
        operationQueue.async {
            CXmodem.queueMap.setObject(Thread.current, forKey: operationQueue)
            let result: ReceiveResult
            if let wireQueue = sendBytesOnWireCallbackQueue {
                result = receive(maxNumPackets: maxNumPackets, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: { (data) in
                    wireQueue.async {
                        sendBytesOnWireCallback(data)
                    }
                })
            } else {
                result = receive(maxNumPackets: maxNumPackets, sendChunkSize: sendChunkSize, sendBytesOnWireCallback: sendBytesOnWireCallback)
            }
            CXmodem.queueMap.removeObject(forKey: operationQueue)
            completeCallbackQueue.async {
                completeCallback(result)
            }
        }
        return operationQueue
    }
}


