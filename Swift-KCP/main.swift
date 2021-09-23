//
//  main.swift
//  Swift-KCP
//
//  Created by 余润杰 on 2021/9/22.
//

import Foundation

fileprivate func KCPEncode8u(p:UnsafeMutablePointer<uint8>,
                             c:uint8) -> UnsafeMutablePointer<uint8> {
    p.pointee = c
    return p+1
}

fileprivate func KCPDecode8u(p:UnsafeMutablePointer<uint8>,
                             c:UnsafeMutablePointer<uint8>) -> UnsafePointer<uint8> {
    c.pointee = p.pointee
    return UnsafePointer(p+1)
}

fileprivate func KCPEncode16u(p:UnsafeMutablePointer<uint8>,
                              w:uint16) -> UnsafeMutablePointer<uint8> {
    var bigEndian = w.littleEndian
    let count = MemoryLayout<uint16>.size
    let bytePtr = withUnsafePointer(to: &bigEndian) {
        $0.withMemoryRebound(to: UInt8.self, capacity: count) {
            UnsafeBufferPointer(start: $0, count: count)
        }
    }
    let byteArray = Array(bytePtr)
    for i in 0..<2 {
        (p+i).pointee = byteArray[i]
    }
    return p+2
}

fileprivate func KCPDecode16u(p:UnsafeMutablePointer<uint8>,
                              w:UnsafeMutablePointer<uint16>) -> UnsafePointer<uint8> {
    let size = 2
    var buf = [uint8](repeating: 0, count: size)
    for i in 0..<size {
        buf[i] = (p+i).pointee
    }
    let data = Data(buf)
    switch CFByteOrderGetCurrent() {
    case CFByteOrder(CFByteOrderLittleEndian.rawValue):
        let value = uint16(littleEndian: data.withUnsafeBytes { $0.pointee} )
        w.pointee = value
        break
    case CFByteOrder(CFByteOrderBigEndian.rawValue):
        let value = uint16(bigEndian: data.withUnsafeBytes { $0.pointee })
        w.pointee = value
        break
    default:
        break;
    }
    
    return UnsafePointer(p+size)
}

fileprivate func KCPEncode32u(p:UnsafeMutablePointer<uint8>,
                              l:uint32) -> UnsafeMutablePointer<uint8> {
    
    var bigEndian = l.littleEndian
    let count = MemoryLayout<UInt32>.size
    let bytePtr = withUnsafePointer(to: &bigEndian) {
        $0.withMemoryRebound(to: UInt8.self, capacity: count) {
            UnsafeBufferPointer(start: $0, count: count)
        }
    }
    let byteArray = Array(bytePtr)
    for i in 0..<4 {
        (p+i).pointee = byteArray[i]
    }
    
    return p+4
}

fileprivate func KCPDecode32u(p:UnsafeMutablePointer<uint8>,
                              l:UnsafeMutablePointer<uint32>) -> UnsafePointer<uint8> {
    let size = 4
    var buf = [uint8](repeating: 0, count: size)
    for i in 0..<size {
        buf[i] = (p+i).pointee
    }
    let data = Data(buf)
    switch CFByteOrderGetCurrent() {
    case CFByteOrder(CFByteOrderLittleEndian.rawValue):
        let value = UInt32(littleEndian: data.withUnsafeBytes { $0.pointee })
        l.pointee = value
        break
    case CFByteOrder(CFByteOrderBigEndian.rawValue):
        let value = UInt32(bigEndian: data.withUnsafeBytes { $0.pointee })
        l.pointee = value
        break
    default:
        break;
    }
    
    return UnsafePointer(p+size)
}

struct IKCPSEG {
    var conv: uint32 = 0     // 会话编号，通信双方保持一致才能使用KCP协议交换数据
    var cmd: uint32 = 0      // 表明当前报文的类型，KCP共有四种类型
    var frg: uint32 = 0      // frq分片的编号，当输出数据大于MSS时，需要将数据进行分片，frq记录了分片时的倒序序号
    var wnd: uint32 = 0      // 填写己方的可用窗口大小
    var ts: uint32 = 0       // 发送时的时间戳，用来估计RTT
    var sn: uint32 = 0       // data报文的编号或者ack报文的确认编号
    var una: uint32 = 0      // 当前还未确认的数据包的编号
    var resendts: uint32 = 0 // 下一次重发该报文的时间
    var rto: uint32 = 0      // 重传超时时间
    var fastack: uint32 = 0  // 该报文在收到ACK时被跳过了几次，用于快重传
    var xmit: uint32 = 0     // 记录了该报文被传输了几次
    var data: [uint8]        // 实际传输的数据payload
    
    init(size: Int) {
        self.data = [uint8](repeating: 9, count: size)
    }
    
    init() {
        self.data = Array<uint8>()
    }
    
    func encode() -> Data {
        let buf = [uint8](repeating: 0, count: 24)
        var ptr = UnsafeMutablePointer(mutating: buf)
        ptr = KCPEncode32u(p: ptr, l: self.conv)
        ptr = KCPEncode8u(p: ptr, c: uint8(self.cmd))
        ptr = KCPEncode8u(p: ptr, c: uint8(self.frg))
        ptr = KCPEncode16u(p: ptr, w: uint16(self.wnd))
        ptr = KCPEncode32u(p: ptr, l: self.ts)
        ptr = KCPEncode32u(p: ptr, l: self.sn)
        ptr = KCPEncode32u(p: ptr, l: self.una)
        ptr = KCPEncode32u(p: ptr, l: uint32(self.data.count))
        return Data(buf)
    }
}


