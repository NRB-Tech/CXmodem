import XCTest
@testable import CXmodem

final class CXmodemTests: XCTestCase {
    func testXmodem() {
        let t1,t2: Thread
        let dataToSend = Data([0,1,2])
        var t1Tot2 = Data()
        var t2Tot1 = Data()
        var result1: CXmodem.SendResult?
        var result2: CXmodem.ReceiveResult?
        t1 = Thread(block: {
            result1 = CXmodem.threadLocal.send(data: dataToSend, sendChunkSize: 20) { (toSend) in
                print("T1>T2 out \(toSend as NSData)")
                t1Tot2.append(toSend)
            }
        })
        t1.name = "T1"
        t2 = Thread(block: {
            result2 = CXmodem.threadLocal.receive(maxNumPackets: 1) { (toSend) in
                print("T2>T1 out \(toSend as NSData)")
                t2Tot1.append(toSend)
            }
        })
        t2.name = "T2"
        t1.start()
        t2.start()
        let expectation = XCTestExpectation()
        DispatchQueue.global(qos: .background).async {
            while !t1.isFinished || !t2.isFinished {
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
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        switch result1! {
        case .success:
            break
        case .fail(error: _):
            XCTFail()
        }
        switch result2! {
        case .success(data: let d):
            XCTAssertEqual(d, dataToSend)
        case .fail(error: _):
            XCTFail()
        }
    }
}
