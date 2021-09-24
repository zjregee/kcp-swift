//
//  main.swift
//  Swift-KCP
//
//  Created by 余润杰 on 2021/9/22.
//

import Foundation

// CMD
let IKCP_CMD_PUSH : uint32 = 81       // cmd: push data
let IKCP_CMD_ACK  : uint32 = 82       // cmd: ack
let IKCP_CMD_WASK : uint32 = 83       // cmd: window probe (ask) 询问对端接受窗口的大小
let IKCP_CMD_WINS : uint32 = 84       // cmd: window size (tell) 通知对端剩余接受窗口的大小

let IKCP_RTO_NDL : uint32 = 30        // no delay min rto
let IKCP_RTO_MIN : uint32 = 100       // normal min rto
let IKCP_RTO_DEF : uint32 = 200
let IKCP_RTO_MAX : uint32 = 60000
let IKCP_ASK_SEND : uint32 = 1        // need to send IKCP_CMD_WASK
let IKCP_ASK_TELL : uint32 = 2        // need to send IKCP_CMD_WINS
let IKCP_WND_SND : uint32 = 32
let IKCP_WND_RCV : uint32 = 128       // must >: uint32 = max fragment size
let IKCP_MTU_DEF : uint32 = 1400
let IKCP_ACK_FAST : uint32 = 3
let IKCP_INTERVAL : uint32 = 100
let IKCP_OVERHEAD : uint32 = 24
let IKCP_DEADLINK : uint32 = 20
let IKCP_THRESH_INIT : uint32 = 2
let IKCP_THRESH_MIN : uint32 = 2
let IKCP_PROBE_INIT : uint32 = 7000        // 7 secs to probe window size
let IKCP_PROBE_LIMIT : uint32 = 120000    // up to 120 secs to probe window

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

fileprivate func TimeDiff(later: uint32, earlier: uint32) -> sint32 {
    return sint32(later) - sint32(earlier)
}

fileprivate func _ibound_(lower:uint32,middle:uint32,upper:uint32) -> uint32 {
    return min(max(lower, middle), upper)
}

fileprivate func DefaultOutput(buf: [uint8], kcp: inout IKCPCB, user: uint64) -> Int {
    return 0
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

class IKCPCB {
    var conv: uint32 = 0       // 连接标识
    var mtu: uint32 = 0        // Maximum Transmission Unit 最大传输单元 mss = mtu - 24
    var mss: uint32 = 0        // Maximum Segment Size 最大报文长度
    var state: uint32 = 0      // 连接状态 0 建立连接 -1 连接断开 unsigned int -1 实际上是 0xffffffff
    
    var snd_una: uint32 = 0    // 最小的未ack序列号
    var snd_nxt: uint32 = 0    // 下一个待发送的序列号
    var rcv_nxt: uint32 = 0    // 下一个待接受的序列号，会通过包头中的una字段通知对端
    
    var ts_recent: uint32 = 0  // unused
    var ts_lastack: uint32 = 0 // unused
    var ssthresh: uint32 = 0   // slow start threshhold 慢启动阈值
    
    var rx_rto: uint32 = 0     // 超时重传时间
    var rx_rttval: uint32 = 0  // 计算rx_rto的中间变量
    var rx_srtt: uint32 = 0    // 计算rx_rto的中间变量
    var rx_minrto: uint32 = 0  // 计算rx_rto的中间变量
    
    var snd_wnd: uint32 = 0    // 发送窗口大小
    var rcv_wnd: uint32 = 0    // 接受窗口大小
    var rmt_wnd: uint32 = 0    // 对端剩余接受窗口的大小
    var cwnd: uint32 = 0       // 拥塞窗口，用于拥塞控制
    var probe: uint32 = 0      // 是否要发送控制报文的标志
    
    var current: uint32 = 0    // 当前时间
    var interval: uint32 = 0   // flush的时间粒度
    var ts_flush: uint32 = 0   // 下次需要flush的时间
    var xmit: uint32 = 0       // 该链接超时重传的总次数
    
    var nodelay: uint32 = 0    // 是否启动快速模式，用于控制RTO增长速度
    var updated: uint32 = 0    // 是否调用过update
    
    var ts_probe: uint32 = 0   // 确定何时需要发送窗口询问报文
    var probe_wait: uint32 = 0 // 确定何时需要发送窗口询问报文
    
    var dead_link: uint32 = 0  // 当一个报文发送超时次数达到dead_link次时认为连接断开
    var snd_queue: [IKCPSEG]   // 发送队列
    var rcv_queue: [IKCPSEG]   // 接受队列
    var snd_buf: [IKCPSEG]     // 发送缓冲区
    var rcv_buf: [IKCPSEG]     // 接受缓冲区
    var incr: uint32 = 0       // 用于计算cwnd
    var acklist: [uint32]      // 当收到一个数据报文时，将其对应的ACK报文的sn号以及时间戳ts同时加入
    var ackcount: uint32 = 0   // 记录acklist中存放的ACK报文的数量
    var ackblock: uint32 = 0   // acklist数组的可用长度，当acklist的容量不足时，需要进行扩容
    var buffer: [uint8]        // flush时用到的临时缓冲区
    var user: uint64 = 0
    var fastresend: Int = 0    // ACK失序fastresend次时触发快速重传
    var nocwnd: Int = 0        // 是否不考虑拥塞窗口
    var stream: Int = 0        // 是否开启流模式，开启后可能会合并包
    
    var output : (([uint8], inout IKCPCB, uint64) -> Int)? // 下层协议输出函数
    
    init(conv:uint32,user:uint64) {
        self.conv = conv
        self.user = user
        self.snd_wnd = IKCP_WND_SND
        self.rcv_wnd = IKCP_WND_RCV
        self.rmt_wnd = IKCP_WND_RCV
        self.mtu = IKCP_MTU_DEF
        self.mss = self.mtu - IKCP_OVERHEAD
        self.rx_rto = IKCP_RTO_DEF
        self.rx_minrto = IKCP_RTO_MIN
        self.interval = IKCP_INTERVAL
        self.ts_flush = IKCP_INTERVAL
        self.ssthresh = IKCP_THRESH_INIT
        self.dead_link = IKCP_DEADLINK
        self.snd_queue = [IKCPSEG]()
        self.rcv_queue = [IKCPSEG]()
        self.snd_buf = [IKCPSEG]()
        self.rcv_buf = [IKCPSEG]()
        
        self.buffer = [uint8](repeating: 0, count: Int((self.mtu + IKCP_OVERHEAD)*3))
        self.acklist = [uint32]()
        self.output = DefaultOutput
    }
    
    func send(buffer: Data) -> Int {
        let buf = [uint8](repeating: 0, count: buffer.count)
        _ = buffer.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
        return self.ikcp_send(_buffer: buf)
    }
    
    private func ikcp_send(_buffer: [uint8]) -> Int {
        var buffer = _buffer
        if buffer.count == 0 {
            return -1
        }
        
        // 1.如果当前的KCP开启流模式，取出snd_queue中的最后一个报文将其填充到mss的长度，并设置其frg为0
        if self.stream != 0 {
            if !self.snd_queue.isEmpty {
                var old = self.snd_queue.last!
                if old.data.count < self.mss {
                    let capacity = self.mss - uint32(old.data.count)
                    let extend = min(buffer.count, Int(capacity))
                    var seg = IKCPSEG(size: Int(old.data.count + extend))
                    self.snd_queue.append(seg)
                    
                    for i in 0..<old.data.count {
                        seg.data[i] = old.data[i]
                    }
                    
                    for i in 0..<extend {
                        seg.data[i + old.data.count] = buffer[i]
                    }
                    
                    buffer = Array(UnsafeBufferPointer(start: UnsafeMutablePointer(mutating: buffer) + extend, count: buffer.count - extend))
                    
                    seg.frg = 0 // 流模式下分片编号不用填写
                }
            }
            
            if buffer.count == 0 {
                return 0
            }
        }
        
        var count: Int = 0
        if buffer.count <= self.mss {
            count = 1
        } else {
            count = Int((buffer.count + Int(self.mss) - 1) / Int(self.mss))
        }
        
        if count > IKCP_WND_RCV {
            return -2
        }
        
        if count == 0 {
            count = 1 // ?
        }
        
        for i in 0..<count {
            let size = min(Int(self.mss), buffer.count)
            var seg = IKCPSEG(size: size)
            for i in 0..<size {
                seg.data[i] = buffer[i]
            }
            seg.frg = (self.stream == 0) ? uint32(count - i - 1) : 0 // 流模式下分片编号不用填写
            self.snd_queue.append(seg)
            buffer = Array(UnsafeBufferPointer(start: UnsafeMutablePointer(mutating: buffer) + min(buffer.count, size), count: buffer.count - size))
        }
        
        return 0
    }
    
    // 将数据从snd_queue中移入到snd_buf中，然后调用output发送
    func flush() {
        if self.updated == 0 {
            return
        }
        
        let current = self.current
        let buffer = UnsafeMutablePointer(mutating: self.buffer) // 临时缓冲区
        var ptr = UnsafeMutablePointer(mutating: self.buffer)
        
        var seg = IKCPSEG()
        seg.conv = self.conv
        seg.cmd = IKCP_CMD_ACK
        seg.frg = 0
        seg.wnd = uint32(self.wnd_unused())
        seg.una = self.rcv_nxt
        seg.sn = 0
        seg.ts = 0
        
        //flush acknowledges
        for i in 0..<Int(self.ackcount) {
            let size = uint32(ptr - buffer)
            if size + IKCP_OVERHEAD > self.mtu {
                let data = Array(UnsafeBufferPointer(start: buffer, count: Int(size)))
                _ = self.safe_output(data: data)
                ptr = buffer
            }
            
            self.ack_get(p: i, sn: &seg.sn, ts: &seg.ts)
            let data: Data = seg.encode()
            let buf = [uint8](repeating: 0, count: data.count)
            _ = data.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
            for b in buf {
                ptr.pointee = b
                ptr += 1
            }
        }
        self.ackcount = 0
        
        // probe window size (if remote window size equals zero)
        // 根据ts_probe和probe_wait确定
        if self.rmt_wnd == 0 {
            if self.probe_wait == 0 { // 初始化探测间隔和下一次探测时间
                self.probe_wait = IKCP_PROBE_INIT
                self.ts_probe = self.current + self.probe_wait
            } else {
                if TimeDiff(later: self.current, earlier: self.ts_probe) >= 0 {
                    if self.probe_wait < IKCP_PROBE_INIT {
                        self.probe_wait = IKCP_PROBE_INIT
                    }
                    self.probe_wait += self.probe_wait / 2
                    if self.probe_wait > IKCP_PROBE_LIMIT {
                        self.probe_wait = IKCP_PROBE_LIMIT
                    }
                    self.ts_probe = self.current + self.probe_wait
                    self.probe |= IKCP_ASK_SEND // 标识需要探测远端窗口
                }
            }
        } else {
            self.probe_wait = 0 // ?
            self.ts_probe = 0   // ?
        }
        
        // 检查是否需要发送窗口探测报文
        if (self.probe & IKCP_ASK_SEND) != 0 {
            seg.cmd = IKCP_CMD_WASK
            let size = uint32(ptr - buffer)
            if size + IKCP_OVERHEAD > self.mtu {
                let data = Array(UnsafeBufferPointer(start: buffer,
                                                     count: Int(size)))
                _ = self.safe_output(data: data)
                ptr = buffer
            }
            
            let data : Data = seg.encode()
            let buf = [uint8](repeating: 0, count: data.count)
            _ = data.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
            for b in buf {
                ptr.pointee = b
                ptr += 1
            }
        }
        
        // 检查是否需要发送窗口通知报文
        if (self.probe & IKCP_ASK_TELL) != 0 {
            seg.cmd = IKCP_CMD_WINS
            let size = uint32(ptr - buffer)
            if size + IKCP_OVERHEAD > self.mtu {
                let data = Array(UnsafeBufferPointer(start: buffer,
                                                     count: Int(size)))
                _ = self.safe_output(data: data)
                ptr = buffer
            }
            let data : Data = seg.encode()
            let buf = [uint8](repeating: 0, count: data.count)
            _ = data.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
            for b in buf {
                ptr.pointee = b
                ptr += 1
            }
        }
        
        self.probe = 0
        
        // 计算cwnd
        var cwnd = min(self.snd_wnd, self.rmt_wnd)
        if self.nocwnd == 0 {
            cwnd = min(self.cwnd, cwnd)
        }
        
        // 将报文从snd_queue移动到snd_buf
        // snd_nxt - snd_una 不超过cwnd
        while TimeDiff(later: self.snd_nxt, earlier: self.snd_una + cwnd) < 0 {
            if self.snd_queue.isEmpty {
                break
            }
            
            var newseg = self.snd_queue.first!
            self.snd_queue.remove(at: 0)
            
            newseg.conv = self.conv
            newseg.cmd = IKCP_CMD_PUSH
            newseg.wnd = seg.wnd
            newseg.ts = current
            newseg.sn = self.snd_nxt; self.snd_nxt+=1;
            newseg.una = self.rcv_nxt
            newseg.resendts = current
            newseg.rto = self.rx_rto
            newseg.fastack = 0
            newseg.xmit = 0
            
            self.snd_buf.append(newseg)
        }
        
        // 快速重传，fastresend为0便不执行快速重传
        let resent = self.fastresend > 0 ? self.fastresend : 0xffffffff
        let rtomin = self.nodelay == 0 ? self.rx_rto >> 3 : 0
        var lost = false
        var change: Int = 0
        
        // 将snd_buf中满足条件的报文段都发送出去
        for var segment in self.snd_buf {
            var needsend = false
            if segment.xmit == 0 { // 未发送过
                needsend = true
                segment.xmit += 1
                segment.rto = self.rx_rto
                segment.resendts = current + segment.rto + rtomin
            } else if TimeDiff(later: current, earlier: segment.resendts) >= 0 { // 超时
                needsend = true
                segment.xmit += 1
                self.xmit += 1
                if 0 == self.nodelay {
                    segment.rto += self.rx_rto
                } else {
                    segment.rto += self.rx_rto / 2
                }
                segment.resendts = current + segment.rto
                lost = true
            } else if segment.fastack >= resent { // 快速重传
                needsend = true
                segment.xmit += 1
                segment.fastack = 0
                segment.resendts = current + segment.rto
                change += 1
            }
            
            if needsend {
                segment.ts = current
                segment.wnd = seg.wnd
                segment.una = self.rcv_nxt
                
                let size = Int(ptr - buffer)
                let need = Int(IKCP_OVERHEAD) + segment.data.count
                
                if size + need > self.mtu {
                    _ = self.safe_output(data: Array(UnsafeBufferPointer(start: buffer, count: size)))
                    ptr = buffer
                }
                
                let data : Data = segment.encode()
                let buf = [uint8](repeating: 0, count: data.count)
                _ = data.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
                for b in buf {
                    ptr.pointee = b
                    ptr += 1
                }
                
                if segment.data.count > 0 {
                    for i in 0..<segment.data.count {
                        ptr.pointee = segment.data[Int(i)]
                        ptr += 1
                    }
                }
                
                if segment.xmit >= self.dead_link {
                    self.state = 0xffffffff // 不能写-1
                }
            }
        }
        
        // 发送buffer中剩余的报文段
        let size = Int(ptr - buffer)
        if size > 0 {
            _ = self.safe_output(data: Array(UnsafeBufferPointer(start: buffer, count: size)))
        }
        
        // 根据丢包情况计算ssthresh和cwnd
        if change != 0 {
            let inflight = self.snd_nxt - self.snd_una
            self.ssthresh = inflight / 2
            if self.ssthresh < IKCP_THRESH_MIN {
                self.ssthresh = IKCP_THRESH_MIN
            }
            self.cwnd = self.ssthresh + uint32(resent)
            self.incr = self.cwnd * self.mss
        }
        
        if lost {
            self.ssthresh = cwnd / 2
            if self.ssthresh < IKCP_THRESH_MIN {
                self.ssthresh = IKCP_THRESH_MIN
            }
            self.cwnd = 1
            self.incr = self.mss
        }
        
        if self.cwnd < 1 {
            self.cwnd = 1
            self.incr = self.mss
        }
    }
    
    // 上层应用每隔一段时间(10~100ms)驱动KCP发送数据
    func update(current: uint32) {
        var slap: Int32 = 0
        self.current = current
        if self.updated == 0 {
            self.updated = 1
            self.ts_flush = self.current
        }
        slap = TimeDiff(later: self.current, earlier: self.ts_flush)
        if slap >= 10000 || slap < -10000 {
            self.ts_flush = self.current
            slap = 0
        }
        
        if slap >= 0 {
            self.ts_flush += self.interval
            if TimeDiff(later: self.current, earlier: self.ts_flush) >= 0 {
                self.ts_flush = self.current + self.interval
            }
            self.flush()
        }
    }
    
    // 数据到达会调用ikcp_input
    func input(data: Data) -> Int {
        let buf = [uint8](repeating: 0, count: data.count)
        _ = data.copyBytes(to: UnsafeMutableBufferPointer<uint8>(start: UnsafeMutablePointer(mutating: buf), count: buf.count))
        return self.ikcp_input(_data: buf)
    }
    
    private func ikcp_input(_data: [uint8]) -> Int {
        var data = _data
        let una = self.snd_una
        var maxack: uint32 = 0
        var flag = false
        
        if data.count < IKCP_OVERHEAD {
            return -1
        }
        
        while (true) {
            var ts: uint32 = 0   // 4字节
            var sn: uint32 = 0   // 4字节
            var len: uint32 = 0  // 4字节
            var una: uint32 = 0  // 4字节
            var conv: uint32 = 0 // 4字节
            var wnd: uint16 = 0  // 2字节
            var cmd: uint8 = 0   // 1字节
            var frg: uint8 = 0   // 1字节
            if data.count < IKCP_OVERHEAD {
                break
            }
            
            // 调用ickp_decode*解包，为各个字段赋值
            data = Array(UnsafeBufferPointer(start: KCPDecode32u(p: UnsafeMutablePointer(mutating: data), l: &conv), count: max(0, data.count - 4)))
            if conv != self.conv {
                return -1
            }
            
            data = Array(UnsafeBufferPointer(start: KCPDecode8u(p: UnsafeMutablePointer(mutating:data), c: &cmd), count: max(0, data.count - 1)))
            data = Array(UnsafeBufferPointer(start: KCPDecode8u(p: UnsafeMutablePointer(mutating:data), c: &frg), count: max(0, data.count - 1)))
            data = Array(UnsafeBufferPointer(start: KCPDecode16u(p: UnsafeMutablePointer(mutating:data), w: &wnd), count: max(0, data.count - 2)))
            data = Array(UnsafeBufferPointer(start: KCPDecode32u(p: UnsafeMutablePointer(mutating:data), l: &ts), count: max(0, data.count - 4)))
            data = Array(UnsafeBufferPointer(start: KCPDecode32u(p: UnsafeMutablePointer(mutating:data), l: &sn), count: max(0, data.count - 4)))
            data = Array(UnsafeBufferPointer(start: KCPDecode32u(p: UnsafeMutablePointer(mutating:data), l: &una), count: max(0, data.count - 4)))
            data = Array(UnsafeBufferPointer(start: KCPDecode32u(p: UnsafeMutablePointer(mutating:data), l: &len), count: max(0, data.count - 4)))
            
            if data.count < len {
                return -2
            }
            
            if cmd != IKCP_CMD_PUSH && cmd != IKCP_CMD_ACK && cmd != IKCP_CMD_WASK && cmd != IKCP_CMD_WINS {
                return -3
            }
            
            self.rmt_wnd = uint32(wnd) // 更新rmt_wnd
            self.una_parse(una: una) // 根据una将相应已确认送达的报文从snd_buf中删除
            self.buf_shrink() // 尝试向右移动snd_una
            
            if cmd == IKCP_CMD_ACK { // ACK报文
                if TimeDiff(later: self.current, earlier: ts) >= 0 {
                    // 这里计算RTO
                    self.ack_update(rtt: TimeDiff(later: self.current, earlier: ts))
                }
                self.ack_parse(sn: sn)
                self.buf_shrink()
                if !flag { // 这里计算出这次input得到的最大ACK编号
                    flag = true
                    maxack = sn
                } else {
                    if TimeDiff(later: sn, earlier: maxack) > 0 {
                        maxack = sn
                    }
                }
            } else if cmd == IKCP_CMD_PUSH { // 数据报文
                if TimeDiff(later: sn, earlier: self.rcv_nxt + self.rcv_wnd) < 0 {
                    self.ack_push(sn: sn, ts: ts)
                    if TimeDiff(later: sn, earlier: self.rcv_nxt) >= 0 {
                        var seg = IKCPSEG(size: Int(len))
                        seg.conv = conv
                        seg.cmd = uint32(cmd)
                        seg.frg = uint32(frg)
                        seg.wnd = uint32(wnd)
                        seg.ts = ts
                        seg.sn = sn
                        seg.una = una
                        if len > 0 {
                            for i in 0..<seg.data.count {
                                seg.data[i] = data[i]
                            }
                        }
                        
                        // 插入rcv_buf
                        self.data_parse(newseg: seg)
                    }
                }
            }
        }
        
        return 0
    }
    
    private func wnd_unused() -> Int {
        if self.rcv_queue.count < self.rcv_wnd {
            return Int(self.rcv_wnd) - self.rcv_queue.count
        }
        
        return 0
    }
    
    private func safe_output(data: [uint8]) -> Int {
        if self.output == nil {
            return 0
        }
        if data.count == 0 {
            return 0
        }
        var weakSelf = self // ?
        let ret = self.output?(data, &weakSelf, self.user)
        if ret == nil {
            return 0
        }
        return ret!
    }
    
    private func ack_get(p: Int, sn: UnsafeMutablePointer<uint32>?, ts: UnsafeMutablePointer<uint32>?) {
        sn?.pointee = self.acklist[p * 2]
        ts?.pointee = self.acklist[p * 2 + 1]
    }
    
    //---------------------------------------------------------------------
    // parse ack
    //---------------------------------------------------------------------
    
    // 对于ACK，会调用ikcp_parse_ack将对应已送达的报文从snd_buf中删除
    // 删除之后，ikcp_flush调用中自然不用考虑重传问题了
    private func ack_parse(sn: uint32) {
        if TimeDiff(later: sn, earlier: self.snd_una) < 0 || TimeDiff(later: sn, earlier: self.snd_nxt) >= 0 {
            return
        }
        
        for i in 0..<self.snd_buf.count {
            let seg = self.snd_buf[i]
            if sn == seg.sn {
                self.snd_buf.remove(at: i)
            }
            
            if TimeDiff(later: sn, earlier: seg.sn) < 0 {
                break
            }
        }
    }
    
    private func una_parse(una: uint32) {
        for i in 0..<self.snd_buf.count {
            let seg = self.snd_buf[i]
            if TimeDiff(later: una, earlier: seg.sn) > 0 {
                self.snd_buf.remove(at: i)
            } else {
                break
            }
        }
    }
    
    private func fastack_parse(sn: uint32) {
        if TimeDiff(later: sn, earlier: self.snd_una) < 0 || TimeDiff(later: sn, earlier: self.snd_nxt) >= 0 {
            return
        }
        
        for i in 0..<self.snd_buf.count {
            var seg = self.snd_buf[i]
            if TimeDiff(later: sn, earlier: seg.sn) < 0 {
                break
            } else if (sn != seg.sn) {
                seg.fastack += 1
            }
        }
    }
    
    private func data_parse(newseg: IKCPSEG) {
        let sn = newseg.sn
        var flag = false
        if TimeDiff(later: sn, earlier: self.rcv_nxt + self.rcv_wnd) >= 0 || TimeDiff(later: sn, earlier: self.rcv_nxt) < 0 {
            
        }
    }
    
    private func ack_update(rtt: Int32) {
        var rto: uint32 = 0
        if self.rx_srtt == 0 {
            self.rx_srtt = uint32(rtt)
            self.rx_rttval = uint32(rtt / 2)
        } else {
            var delta = rtt - Int32(self.rx_srtt)
            if delta < 0 {
                delta = -delta
            }
            self.rx_rttval = (3 * self.rx_rttval + uint32(delta)) / 4
            self.rx_srtt = (7 * self.rx_srtt + uint32(rtt)) / 8
            self.rx_srtt = max(1, self.rx_srtt)
        }
        
        rto = self.rx_srtt + max(self.interval, 4 * self.rx_rttval)
        self.rx_rto = _ibound_(lower: self.rx_minrto, middle: rto, upper: IKCP_RTO_MAX)
    }
    
    // ?
    private func buf_shrink() {
        if self.snd_buf.count != 0 {
            let seg = self.snd_buf.first!
            self.snd_una = seg.sn
        } else {
            self.snd_una = self.snd_nxt
        }
    }
    
    // 将相关信息（报文时间和时间戳）插入ACK列表中
    private func ack_push(sn: uint32, ts: uint32) {
        let newsize = self.ackcount + 1
        if newsize > self.ackblock {
            var newblock: uint32 = 8
            while newblock < newsize {
                newblock <<= 1
            }
            var acklist = Array<uint32>(repeating: 0, count: Int(newblock * 2))
            if self.acklist.count != 0 {
                for x in 0..<Int(self.ackcount) {
                    acklist[x * 2] = self.acklist[x * 2]
                    acklist[x * 2 + 1] = self.acklist[x * 2 + 1]
                }
            }
            
            self.acklist = acklist
            self.ackblock = newblock
        }
        
        self.acklist[Int(self.ackcount * 2)] = sn
        self.acklist[Int(self.ackcount * 2 + 1)] = ts
        self.ackcount += 1
    }
    
}


