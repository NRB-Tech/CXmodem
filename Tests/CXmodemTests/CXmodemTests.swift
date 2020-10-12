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
        var result1: CXmodem.SendResult?
        var result2: CXmodem.ReceiveResult?
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        t1 = Thread(block: {
            result1 = CXmodem.send(data: dataToSend, sendChunkSize: 20) { (toSend) in
                txQueue.async {
                    print("T1>T2 out \(toSend as NSData)")
                    t1Tot2.append(toSend)
                }
            }
        })
        t1.name = "T1"
        t2 = Thread(block: {
            result2 = CXmodem.receive(maxNumPackets: 1) { (toSend) in
                txQueue.async {
                    print("T2>T1 out \(toSend as NSData)")
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
                        print("T1>T2 in  \(d as NSData)")
                        CXmodem.receivedBytesOnWire(thread: t2, data: d)
                    }
                    if t2Tot1.count > 0 {
                        let d = t2Tot1
                        t2Tot1 = Data()
                        print("T2>T1 in  \(d as NSData)")
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
        case .success(data: let d):
            XCTAssertEqual(d, dataToSend)
        case .fail(error: _):
            XCTFail()
        }
    }
    
    func testXmodemQueues() {
        let q1,q2: DispatchQueue
        let dataToSend = Data([0,1,2])
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.SendResult?
        var result2: CXmodem.ReceiveResult?
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        q1 = CXmodem.send(data: dataToSend, sendChunkSize: 20, sendBytesOnWireCallback: { (toSend) in
            print("T1>T2 out \(toSend as NSData)")
            t1Tot2.append(toSend)
        }, sendBytesOnWireCallbackQueue: txQueue, completeCallback: { (result) in
            result1 = result
        })
        q2 = CXmodem.receive(maxNumPackets: 1, sendBytesOnWireCallback: { (toSend) in
            print("T2>T1 out \(toSend as NSData)")
            t2Tot1.append(toSend)
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
                        print("T1>T2 in  \(d as NSData)")
                        CXmodem.receivedBytesOnWire(queue: q2, data: d)
                    }
                    if t2Tot1.count > 0 {
                        let d = t2Tot1
                        t2Tot1 = Data()
                        print("T2>T1 in  \(d as NSData)")
                        CXmodem.receivedBytesOnWire(queue: q1, data: d)
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
        case .success(data: let d):
            XCTAssertEqual(d, dataToSend)
        case .fail(error: _):
            XCTFail()
        }
    }
    
    func testXmodemQueuesLong() {
        let q1,q2: DispatchQueue
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.SendResult?
        var result2: CXmodem.ReceiveResult?
        let bytes = [UInt32](repeating: 0, count: 25000).map { _ in arc4random() }
        let dataToSend = Data(bytes: bytes, count: bytes.count*4)
        var t1OutCount = 0
        var t2OutCount = 0
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        q1 = CXmodem.send(data: dataToSend, sendChunkSize: 20, sendBytesOnWireCallback: { (toSend) in
            t1OutCount += toSend.count
            print("T1>T2 out (\(t1OutCount)) \(toSend as NSData)")
            t1Tot2.append(toSend)
        }, sendBytesOnWireCallbackQueue: txQueue, completeCallback: { (result) in
            result1 = result
        })
        q2 = CXmodem.receive(maxNumPackets: 1000, sendBytesOnWireCallback: { (toSend) in
            t2OutCount += toSend.count
            print("T2>T1 out (\(t2OutCount)) \(toSend as NSData)")
            t2Tot1.append(toSend)
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
                        print("T1>T2 in  \(d as NSData)")
                        CXmodem.receivedBytesOnWire(queue: q2, data: d)
                    }
                    if t2Tot1.count > 0 {
                        let d = t2Tot1
                        t2Tot1 = Data()
                        print("T2>T1 in  \(d as NSData)")
                        CXmodem.receivedBytesOnWire(queue: q1, data: d)
                    }
                }
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 100)
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
        case .success(data: let d):
            XCTAssertEqual(d, dataToSend)
        case .fail(error: _):
            XCTFail()
        }
    }
    
    func testXmodemQueuesLossy() {
        let lossRate = 0.1
        let q1,q2: DispatchQueue
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.SendResult?
        var result2: CXmodem.ReceiveResult?
        let bytes = [UInt32](repeating: 0, count: 300).map { _ in arc4random() }
        let dataToSend = Data(bytes: bytes, count: bytes.count*4)
        var t1OutCount = 0
        var t2OutCount = 0
        let txQueue = DispatchQueue(label: "txQueue", qos:.userInitiated)
        q1 = CXmodem.send(data: dataToSend, sendChunkSize: 20, sendBytesOnWireCallback: { (toSend) in
            t1OutCount += toSend.count
            let rand = arc4random()
            if rand < UInt32(Double(UInt32.max) * lossRate) {
                print("T1>T2 out (\(t1OutCount)) \(toSend.hexString) DROPPED")
            } else {
                print("T1>T2 out (\(t1OutCount)) \(toSend.hexString)")
                t1Tot2.append(toSend)
            }
        }, sendBytesOnWireCallbackQueue: txQueue, completeCallback: { (result) in
            result1 = result
        })
        q2 = CXmodem.receive(maxNumPackets: 1000, sendBytesOnWireCallback: { (toSend) in
            t2OutCount += toSend.count
            let rand = arc4random()
            if rand < UInt32(Double(UInt32.max) * lossRate) {
                print("T2>T1 out (\(t2OutCount)) \(toSend.hexString) DROPPED")
            } else {
                print("T2>T1 out (\(t2OutCount)) \(toSend.hexString)")
                t2Tot1.append(toSend)
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
        wait(for: [expectation], timeout: 100)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        guard let r1 = result1 else {
            return
        }
        switch r1 {
        case .success:
            break
        case .fail(error: let e):
            XCTFail("Tx failed \(e.rawValue)")
        }
        guard let r2 = result2 else {
            return
        }
        switch r2 {
        case .success(data: let d):
            XCTAssertEqual(d, dataToSend)
        case .fail(error: let e):
            XCTFail("Rx failed \(e.rawValue)")
        }
    }
    
    func testXmodemFailWireDead() {
        let t1: Thread
        let dataToSend = Data([0,1,2])
        var result1: CXmodem.SendResult?
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
        var result1: CXmodem.ReceiveResult?
        let expectation = XCTestExpectation()
        t1 = Thread(block: {
            result1 = CXmodem.receive(maxNumPackets: 1) { (toSend) in
                
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
        case .success(data: _):
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
        var result1: CXmodem.SendResult?
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
        var result1: CXmodem.ReceiveResult?
        let expectation = XCTestExpectation()
        _=CXmodem.receive(maxNumPackets: 1) { (toSend) in
            
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
        case .success(data: _):
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
