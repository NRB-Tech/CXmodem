import XCTest
@testable import CXmodem

extension Data {
    var hexString: String {
        String(format: "%3d 0x%@", self.count, self.map({ String(format: "%02X", $0) }).joined())
    }
}

final class CXmodemTests: XCTestCase {
    func testXmodem() {
        let t1,t2: Thread
        let dataToSend = Data([0,1,2])
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.Result?
        var result2: CXmodem.Result?
        var receivedData = Data()
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        t1 = Thread(block: {
            result1 = CXmodem.send(data: dataToSend, sendChunkSize: 20) { (toSend) in
                txQueue.async {
                    print("T1>T2 out \(toSend.hexString)")
                    t1Tot2.append(toSend)
                }
            }
        })
        t1.name = "T1"
        t2 = Thread(block: {
            result2 = CXmodem.receive(receivedDataCallback: { (d) -> CXmodem.ReceivedDataCallbackResult in
                receivedData.append(d)
                return .continue
            }) { (toSend) in
                txQueue.async {
                    print("T2>T1 out \(toSend.hexString)")
                    t2Tot1.append(toSend)
                }
            }
        })
        t2.name = "T2"
        t1.start()
        t2.start()
        let expectation = XCTestExpectation()
        DispatchQueue.global(qos: .background).async {
            while !t1.isFinished || !t2.isFinished {
                txQueue.sync {
                    if t1Tot2.count > 0 {
                        let d = t1Tot2
                        t1Tot2 = Data()
                        print("T1>T2 in  \(d.hexString)")
                        CXmodem.receivedBytesOnWire(thread: t2, data: d)
                    }
                    if t2Tot1.count > 0 {
                        let d = t2Tot1
                        t2Tot1 = Data()
                        print("T2>T1 in  \(d.hexString)")
                        CXmodem.receivedBytesOnWire(thread: t1, data: d)
                    }
                }
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        guard let r1 = result1 else {
            return
        }
        switch r1 {
        case .success:
            break
        case .fail(error: _):
            XCTFail()
        }
        guard let r2 = result2 else {
            return
        }
        switch r2 {
        case .success:
            XCTAssertEqual(receivedData, dataToSend)
        case .fail(error: _):
            XCTFail()
        }
    }
    
    func unlucky(rate: Double) -> Bool {
        let rand = arc4random()
        return rand < UInt32(Double(UInt32.max) * rate)
    }
    
    func randomData(length: Int) -> Data {
        let bytes = [UInt32](repeating: 0, count: length/4).map { _ in arc4random() }
        return Data(bytes: bytes, count: length)
    }
    
    func xmodemQueues(dataToSend: Data, chunkSize: Int, lossRate: Double, corruptionRate: Double, timeout: TimeInterval) -> (sendResult: CXmodem.Result?, receiveResult: CXmodem.Result?, receivedData: Data) {
        let q1,q2: DispatchQueue
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.Result?
        var result2: CXmodem.Result?
        var receivedData = Data()
        var t1OutCount = 0
        var t2OutCount = 0
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        q1 = CXmodem.send(data: dataToSend, sendChunkSize: chunkSize, sendBytesOnWireCallback: { (toSend) in
            t1OutCount += toSend.count
            let lost = self.unlucky(rate: lossRate)
            if lost {
                print("T1>T2 out (\(t1OutCount)) \(toSend.hexString) LOST")
            } else {
                let corrupt = self.unlucky(rate: corruptionRate)
                let s: Data
                if corrupt {
                    s = self.randomData(length: toSend.count)
                } else {
                    s = toSend
                }
                print("T1>T2 out (\(t1OutCount)) \(s.hexString)\(corrupt ? "CORRUPT" : "")")
                t1Tot2.append(s)
            }
        }, sendBytesOnWireCallbackQueue: txQueue, completeCallback: { (result) in
            result1 = result
        })
        q2 = CXmodem.receive(receivedDataCallback: { (d) -> CXmodem.ReceivedDataCallbackResult in
                receivedData.append(d)
                return .continue
            }, sendBytesOnWireCallback: { (toSend) in
                t2OutCount += toSend.count
                let lost = self.unlucky(rate: lossRate)
                if lost {
                    print("T2>T1 out (\(t2OutCount)) \(toSend.hexString) LOST")
                } else {
                    let corrupt = self.unlucky(rate: corruptionRate)
                    let s: Data
                    if corrupt {
                        s = self.randomData(length: toSend.count)
                    } else {
                        s = toSend
                    }
                    print("T2>T1 out (\(t1OutCount)) \(s.hexString)\(corrupt ? " CORRUPT" : "")")
                    t2Tot1.append(s)
                }
        }, sendBytesOnWireCallbackQueue: txQueue, completeCallback: { (result) in
            result2 = result
        })
        let expectation = XCTestExpectation()
        DispatchQueue.global(qos: .background).async {
            while result1 == nil || result2 == nil {
                txQueue.sync {
                    if t1Tot2.count > 0 {
                        let d = t1Tot2
                        t1Tot2 = Data()
                        print("T1>T2 in  \(d.hexString)")
                        CXmodem.receivedBytesOnWire(queue: q2, data: d)
                    }
                    if t2Tot1.count > 0 {
                        let d = t2Tot1
                        t2Tot1 = Data()
                        print("T2>T1 in  \(d.hexString)")
                        CXmodem.receivedBytesOnWire(queue: q1, data: d)
                    }
                }
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: timeout)
        return (sendResult: result1, receiveResult: result2, receivedData: receivedData)
    }
    
    func testXmodemQueues() {
        let dataToSend = Data([0,1,2])
        let result = xmodemQueues(dataToSend: dataToSend, chunkSize: 20, lossRate: 0, corruptionRate: 0, timeout: 20)
        XCTAssertNotNil(result.sendResult)
        XCTAssertNotNil(result.receiveResult)
        guard let sr = result.sendResult else {
            return
        }
        switch sr {
        case .success:
            break
        case .fail(error: let e):
            XCTFail("Tx failed \(e.rawValue)")
        }
        guard let rr = result.receiveResult else {
            return
        }
        switch rr {
        case .success:
            XCTAssertEqual(result.receivedData, dataToSend)
        case .fail(error: let e):
            XCTFail("Rx failed \(e.rawValue)")
        }
    }
    
    func testXmodemQueuesLong() {
        let bytes = [UInt32](repeating: 0, count: 200).map { _ in arc4random() }
        let dataToSend = Data(bytes: bytes, count: bytes.count*4)
        let result = xmodemQueues(dataToSend: dataToSend, chunkSize: 20, lossRate: 0, corruptionRate: 0, timeout: 100)
        XCTAssertNotNil(result.sendResult)
        XCTAssertNotNil(result.receiveResult)
        guard let sr = result.sendResult else {
            return
        }
        switch sr {
        case .success:
            break
        case .fail(error: let e):
            XCTFail("Tx failed \(e.rawValue)")
        }
        guard let rr = result.receiveResult else {
            return
        }
        switch rr {
        case .success:
            XCTAssertEqual(result.receivedData, dataToSend)
        case .fail(error: let e):
            XCTFail("Rx failed \(e.rawValue)")
        }
    }
    
    func testXmodemQueuesLossy() {
        let chunkSize = 20
        let lossRate = Double(chunkSize) / (128.0 * 8.0)
        let bytes = [UInt32](repeating: 0, count: 300).map { _ in arc4random() }
        let dataToSend = Data(bytes: bytes, count: bytes.count*4)
        let result = xmodemQueues(dataToSend: dataToSend, chunkSize: chunkSize, lossRate: lossRate, corruptionRate: 0, timeout: 100)
        XCTAssertNotNil(result.sendResult)
        XCTAssertNotNil(result.receiveResult)
        guard let sr = result.sendResult else {
            return
        }
        switch sr {
        case .success:
            break
        case .fail(error: let e):
            XCTFail("Tx failed \(e.rawValue)")
        }
        guard let rr = result.receiveResult else {
            return
        }
        switch rr {
        case .success:
            XCTAssertEqual(result.receivedData, dataToSend)
        case .fail(error: let e):
            XCTFail("Rx failed \(e.rawValue)")
        }
    }
    
    func testXmodemFailWireDead() {
        let t1: Thread
        let dataToSend = Data([0,1,2])
        var result1: CXmodem.Result?
        let expectation = XCTestExpectation()
        t1 = Thread(block: {
            result1 = CXmodem.send(data: dataToSend, sendChunkSize: 20) { (toSend) in
                
            }
            expectation.fulfill()
        })
        t1.name = "T1"
        t1.start()
        
        wait(for: [expectation], timeout: 35)
        XCTAssertNotNil(result1)
        guard let r = result1 else {
            return
        }
        switch r {
        case .success:
            XCTFail()
            break
        case .fail(error: let e):
            switch e {
            case .noSync:
                break
            default:
                XCTFail()
            }
        }
    }
    
    func testXmodemFailReceiveWireDead() {
        let t1: Thread
        var result1: CXmodem.Result?
        let expectation = XCTestExpectation()
        var receivedData = Data()
        t1 = Thread(block: {
            result1 = CXmodem.receive(receivedDataCallback: { (d) -> CXmodem.ReceivedDataCallbackResult in
                receivedData.append(d)
                return .continue
            }) { (toSend) in
                
            }
            expectation.fulfill()
        })
        t1.name = "T1"
        t1.start()
        
        wait(for: [expectation], timeout: 70)
        XCTAssertNotNil(result1)
        guard let r = result1 else {
            return
        }
        switch r {
        case .success:
            XCTFail()
            break
        case .fail(error: let e):
            switch e {
            case .noSync:
                break
            default:
                XCTFail()
            }
        }
    }
    
    func testXmodemCallbackFailWireDead() {
        let dataToSend = Data([0,1,2])
        var result1: CXmodem.Result?
        let expectation = XCTestExpectation()
        _=CXmodem.send(data: dataToSend) { (toSend) in
            
        } completeCallback: { (result) in
            result1 = result
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 35)
        XCTAssertNotNil(result1)
        guard let r = result1 else {
            return
        }
        switch r {
        case .success:
            XCTFail()
            break
        case .fail(error: let e):
            switch e {
            case .noSync:
                break
            default:
                XCTFail()
            }
        }
    }
    
    func testXmodemCallbackFailReceiveWireDead() {
        var result1: CXmodem.Result?
        let expectation = XCTestExpectation()
        var receivedData = Data()
        _=CXmodem.receive(receivedDataCallback: { (d) -> CXmodem.ReceivedDataCallbackResult in
                receivedData.append(d)
                return .continue
            }) { (toSend) in
            
        } completeCallback: { (result) in
            result1 = result
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 70)
        XCTAssertNotNil(result1)
        guard let r = result1 else {
            return
        }
        switch r {
        case .success:
            XCTFail()
            break
        case .fail(error: let e):
            switch e {
            case .noSync:
                break
            default:
                XCTFail()
            }
        }
    }
}
