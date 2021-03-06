//
//  kcp.swift
//  kcp-swift
//
//  Created by 余润杰 on 2021/9/22.
//

import Foundation

// CMD
let IKCP_CMD_PUSH : uint32 = 81
let IKCP_CMD_ACK  : uint32 = 82

// CONST
let IKCP_RTO_MIN : uint32 = 100
let IKCP_RTO_DEF : uint32 = 200
let IKCP_RTO_MAX : uint32 = 60000
let IKCP_MTU_DEF : uint32 = 1400
let IKCP_INTERVAL : uint32 = 100
let IKCP_OVERHEAD : uint32 = 24
let IKCP_DEADLINK : uint32 = 20

fileprivate func KCPEncode8u(p: inout Int, buffer: inout [uint8], c: uint8) {
    buffer.append(c)
    p += 1
}

fileprivate func KCPDecode8u(buffer: inout [uint8], c: inout uint8) {
    if buffer.count > 0 {
        c = buffer.first!
        buffer.removeFirst()
    }
}

fileprivate func KCPEncode16u(p: inout Int, buffer: inout [uint8], c: uint16) {
    buffer.append(uint8(c >> 8))
    buffer.append(uint8(c & 0xff))
    p += 2
}

fileprivate func KCPDecode16u(buffer: inout [uint8], c: inout uint16) {
    if buffer.count >= 2 {
        c = uint16(buffer[0]) << 8 + uint16(buffer[1])
        buffer.removeFirst()
        buffer.removeFirst()
    }
}

fileprivate func KCPEncode32u(p: inout Int, buffer: inout [uint8], c: uint32) {
    buffer.append(uint8(c >> 24))
    buffer.append(uint8(c >> 16 & 0xff))
    buffer.append(uint8(c >> 8 & 0xff))
    buffer.append(uint8(c & 0xff))
    p += 4
}

fileprivate func KCPDecode32u(buffer: inout [uint8], c: inout uint32) {
    if buffer.count >= 4 {
        c = uint32(buffer[0]) << 24 + uint32(buffer[1]) << 16 + uint32(buffer[2]) << 8 + uint32(buffer[3])
        buffer.removeFirst()
        buffer.removeFirst()
        buffer.removeFirst()
        buffer.removeFirst()
    }
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
    var ts: uint32 = 0       // 发送时的时间戳，用来估计RTT
    var sn: uint32 = 0       // data报文的编号或者ack报文的确认编号
    var una: uint32 = 0      // 当前还未确认的数据包的编号
    var resendts: uint32 = 0 // 下一次重发该报文的时间
    var rto: uint32 = 0      // 重传超时时间
    var fastack: uint32 = 0  // 该报文在收到ACK时被跳过了几次，用于快重传
    var xmit: uint32 = 0     // 记录了该报文被传输了几次
    var data: [uint8]        // 实际传输的数据payload
    
    init(size: Int) {
        self.data = [uint8](repeating: 0, count: size)
    }
    
    init() {
        self.data = [uint8]()
    }
    
    func encode() -> Data {
        var buf = [uint8]()
        var ptr: Int = 0
        KCPEncode32u(p: &ptr, buffer: &buf, c: self.conv)
        KCPEncode8u(p: &ptr, buffer: &buf, c: uint8(self.cmd))
        KCPEncode8u(p: &ptr, buffer: &buf, c: uint8(self.frg))
        KCPEncode32u(p: &ptr, buffer: &buf, c: self.ts)
        KCPEncode32u(p: &ptr, buffer: &buf, c: self.sn)
        KCPEncode32u(p: &ptr, buffer: &buf, c: self.una)
        KCPEncode32u(p: &ptr, buffer: &buf, c: uint32(self.data.count))
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
    
    var rx_rto: uint32 = 0     // 超时重传时间
    var rx_rttval: uint32 = 0  // 计算rx_rto的中间变量
    var rx_srtt: uint32 = 0    // 计算rx_rto的中间变量
    var rx_minrto: uint32 = 0  // 计算rx_rto的中间变量
    
    var current: uint32 = 0    // 当前时间
    var interval: uint32 = 0   // flush的时间粒度
    var ts_flush: uint32 = 0   // 下次需要flush的时间
    var xmit: uint32 = 0       // 该链接超时重传的总次数
    
    var nodelay: uint32 = 0    // 是否启动快速模式，用于控制RTO增长速度
    var updated: uint32 = 0    // 是否调用过update
    
    var dead_link: uint32 = 0  // 当一个报文发送超时次数达到dead_link次时认为连接断开
    var snd_queue: [IKCPSEG]   // 发送队列
    var rcv_queue: [IKCPSEG]   // 接受队列
    var snd_buf: [IKCPSEG]     // 发送缓冲区
    var rcv_buf: [IKCPSEG]     // 接受缓冲区
    var acklist: [uint32]      // 当收到一个数据报文时，将其对应的ACK报文的sn号以及时间戳ts同时加入
    var ackcount: uint32 = 0   // 记录acklist中存放的ACK报文的数量
    var ackblock: uint32 = 0
    var user: uint64 = 0
    var fastresend: Int = 0    // ACK失序fastresend次时触发快速重传
    var stream: Int = 0        // 是否开启流模式，开启后可能会合并包
    
    var output : (([uint8], inout IKCPCB, uint64) -> Int)? // 下层协议输出函数
    
    init(conv: uint32, user: uint64) {
        self.conv = conv
        self.user = user
        self.mtu = IKCP_MTU_DEF
        self.mss = self.mtu - IKCP_OVERHEAD
        self.rx_rto = IKCP_RTO_DEF
        self.rx_minrto = IKCP_RTO_MIN
        self.interval = IKCP_INTERVAL
        self.ts_flush = IKCP_INTERVAL
        self.dead_link = IKCP_DEADLINK
        self.snd_queue = [IKCPSEG]()
        self.rcv_queue = [IKCPSEG]()
        self.snd_buf = [IKCPSEG]()
        self.rcv_buf = [IKCPSEG]()
        self.acklist = [uint32]()
        self.output = DefaultOutput
    }
    
    func send(buffer: Data) -> Int {
        let buf = [uint8](buffer)
        return self.ikcp_send(_buffer: buf)
    }
    
    private func ikcp_send(_buffer: [uint8]) -> Int {
        var buffer = _buffer
        
        if buffer.count == 0 {
            return -1
        }
        
        if self.stream != 0 {
            if !self.snd_queue.isEmpty {
                let old = self.snd_queue.last!
                if old.data.count < self.mss {
                    let capacity = Int(self.mss) - old.data.count
                    let extend = min(buffer.count, Int(capacity))
                    var seg = IKCPSEG(size: old.data.count + extend)
                    
                    for i in 0..<old.data.count {
                        seg.data[i] = old.data[i]
                    }
                    
                    for i in 0..<extend {
                        seg.data[i + old.data.count] = buffer[i]
                    }
                    
                    buffer = Array(buffer[extend..<buffer.endIndex])
                    
                    seg.frg = 0
                    
                    self.snd_queue.removeLast()
                    self.snd_queue.append(seg)
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
            count = (buffer.count + Int(self.mss) - 1) / Int(self.mss)
        }
        
        if count == 0 {
            count = 1
        }
        
        for i in 0..<count {
            let size = min(Int(self.mss), buffer.count)
            var seg = IKCPSEG(size: size)
            if buffer.count > 0 {
                for i in 0..<size {
                    seg.data[i] = buffer[i]
                }
            }
            seg.frg = (self.stream == 0) ? uint32(count - i - 1) : 0
            self.snd_queue.append(seg)
            buffer = Array(buffer[size..<buffer.endIndex])
        }
        
        return 0
    }
    
    func flush() {
        if self.updated == 0 {
            return
        }
        
        let current = self.current
        var buffer = [uint8]()
        var ptr: Int = 0
        
        var seg = IKCPSEG()
        seg.conv = self.conv
        seg.cmd = IKCP_CMD_ACK
        seg.frg = 0
        seg.una = self.rcv_nxt
        seg.sn = 0
        seg.ts = 0
        
        for i in 0..<Int(self.ackcount) {
            let size = uint32(ptr)
            if size + IKCP_OVERHEAD > self.mtu {
                let data = Array(buffer[buffer.startIndex..<Int(size)])
                _ = self.safe_output(data: data)
                ptr = 0
            }
            
            self.ack_get(p: i, sn: &seg.sn, ts: &seg.ts)
            let data: Data = seg.encode()
            let buf = [uint8](data)
            for b in buf {
                buffer.append(b)
                ptr += 1
            }
        }
        self.ackcount = 0
        
        while !self.snd_queue.isEmpty {
            var newseg = self.snd_queue.first!
            
            newseg.conv = self.conv
            newseg.cmd = IKCP_CMD_PUSH
            newseg.ts = current
            newseg.sn = self.snd_nxt; self.snd_nxt+=1;
            newseg.una = self.rcv_nxt
            newseg.resendts = current
            newseg.rto = self.rx_rto
            newseg.fastack = 0
            newseg.xmit = 0
            
            self.snd_queue.remove(at: 0)
            self.snd_buf.append(newseg)
        }
        
        let resent = self.fastresend > 0 ? self.fastresend : 0xffffffff
        let rtomin = self.nodelay == 0 ? self.rx_rto >> 3 : 0
        
        for var segment in self.snd_buf {
            var needsend = false
            if segment.xmit == 0 {
                needsend = true
                segment.xmit += 1
                segment.rto = self.rx_rto
                segment.resendts = current + segment.rto + rtomin
            } else if TimeDiff(later: current, earlier: segment.resendts) >= 0 {
                needsend = true
                segment.xmit += 1
                self.xmit += 1
                if self.nodelay == 0 {
                    segment.rto += max(segment.rto, self.rx_rto)
                } else {
                    let step = self.nodelay < 2 ? segment.rto : self.rx_rto
                    segment.rto += step / 2
                }
                segment.resendts = current + segment.rto
            } else if segment.fastack >= resent {
                needsend = true
                segment.xmit += 1
                segment.fastack = 0
                segment.resendts = current + segment.rto
            }
            
            if needsend {
                segment.ts = current
                segment.una = self.rcv_nxt
                
                let size = uint32(ptr)
                let need = Int(IKCP_OVERHEAD) + segment.data.count
                
                if size + uint32(need) > self.mtu {
                    _ = self.safe_output(data: Array(buffer[buffer.startIndex..<Int(size)]))
                    buffer.removeAll()
                    ptr = 0
                }
                
                let data: Data = segment.encode()
                let buf = [uint8](data)
                for b in buf {
                    buffer.append(b)
                    ptr += 1
                }
                
                if segment.data.count > 0 {
                    for i in 0..<segment.data.count {
                        buffer.append(segment.data[i])
                        ptr += 1
                    }
                }
                
                if segment.xmit >= self.dead_link {
                    self.state = 0xffffffff
                }
            }
        }
        
        let size = ptr
        if size > 0 {
            _ = self.safe_output(data: Array(buffer[buffer.startIndex..<size]))
        }
    }
    
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
    
    func input(data: Data) -> Int {
        let buf = [uint8](data)
        return self.ikcp_input(_data: buf)
    }
    
    private func ikcp_input(_data: [uint8]) -> Int {
        var data = _data
        var maxack: uint32 = 0
        var latest_ts: uint32 = 0
        var flag = false
        
        if data.count < IKCP_OVERHEAD {
            return -1
        }
        
        while (true) {
            var ts: uint32 = 0
            var sn: uint32 = 0
            var len: uint32 = 0
            var una: uint32 = 0
            var conv: uint32 = 0
            var cmd: uint8 = 0
            var frg: uint8 = 0
            if data.count < IKCP_OVERHEAD {
                break
            }
            
            KCPDecode32u(buffer: &data, c: &conv)
            if conv != self.conv {
                return -1
            }
            
            KCPDecode8u(buffer: &data, c: &cmd)
            KCPDecode8u(buffer: &data, c: &frg)
            KCPDecode32u(buffer: &data, c: &ts)
            KCPDecode32u(buffer: &data, c: &sn)
            KCPDecode32u(buffer: &data, c: &una)
            KCPDecode32u(buffer: &data, c: &len)
            
            if data.count < len {
                return -2
            }
            
            if cmd != IKCP_CMD_PUSH && cmd != IKCP_CMD_ACK {
                return -3
            }
            
            self.una_parse(una: una)
            self.buf_shrink()
            
            if cmd == IKCP_CMD_ACK {
                if TimeDiff(later: self.current, earlier: ts) >= 0 {
                    self.ack_update(rtt: TimeDiff(later: self.current, earlier: ts))
                }
                self.ack_parse(sn: sn)
                self.buf_shrink()
                if !flag {
                    flag = true
                    maxack = sn
                    latest_ts = ts
                } else {
                    if TimeDiff(later: sn, earlier: maxack) > 0 {
                        maxack = sn
                        latest_ts = ts
                    }
                }
            } else if cmd == IKCP_CMD_PUSH {
                self.ack_push(sn: sn, ts: ts)
                if TimeDiff(later: sn, earlier: self.rcv_nxt) >= 0 {
                    var seg = IKCPSEG(size: Int(len))
                    seg.conv = conv
                    seg.cmd = uint32(cmd)
                    seg.frg = uint32(frg)
                    seg.ts = ts
                    seg.sn = sn
                    seg.una = una
                    if len > 0 {
                        for i in 0..<seg.data.count {
                            seg.data[i] = data[i]
                        }
                    }
                    
                    self.data_parse(newseg: seg)
                }
            } else {
                return -3
            }
            
            data = Array(data[Int(len)..<data.endIndex])
        }
        
        if flag {
            self.fastack_parse(sn: maxack, ts: latest_ts)
        }
        
        return 0
    }
    
    func recv(dataSize: Int) -> Data? {
        if self.rcv_queue.isEmpty {
            return nil
        }
        
        if dataSize == 0 {
            return nil
        }
        
        let peeksize = self.peek_size()
        if peeksize < 0 {
            return nil
        }
        
        if peeksize > dataSize {
            return nil
        }
        
        var len: Int = 0
        let ispeek = (dataSize < 0)
        var localBuffer = [uint8]()
        let indexSet = NSMutableIndexSet()
        
        for i in 0..<self.rcv_queue.count {
            let seg = self.rcv_queue[i]
            
            var fragment: uint32 = 0
            for i in 0..<seg.data.count {
                localBuffer.append(seg.data[i])
            }
            
            len += seg.data.count
            fragment = seg.frg
            
            if !ispeek {
                indexSet.add(i)
            }
            
            if fragment == 0 {
                break
            }
        }
        
        var i = indexSet.lastIndex
        while i != NSNotFound {
            self.rcv_queue.remove(at: i)
            i = indexSet.indexLessThanIndex(i)
        }
        
        while self.rcv_buf.count != 0 {
            let seg = self.rcv_buf.first!
            if seg.sn == self.rcv_nxt {
                self.rcv_buf.remove(at: 0)
                self.rcv_queue.append(seg)
                self.rcv_nxt += 1
            } else {
                break
            }
        }
        
        var temp = [uint8](repeating: 0, count: len)
        for i in 0..<len {
            temp[i] = localBuffer[i]
        }
        return Data(temp)
    }
    
    private func peek_size() -> Int {
        if self.rcv_queue.isEmpty {
            return -1
        }
        let seg = self.rcv_queue.first!
        if seg.frg == 0 {
            return seg.data.count
        }
        if self.rcv_queue.count < seg.frg + 1 {
            return -1
        }
        var length: Int = 0
        for seg in self.rcv_queue {
            length += seg.data.count
            if seg.frg == 0 {
                break
            }
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
        var weakSelf = self
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
    
    private func fastack_parse(sn: uint32, ts: uint32) {
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
        if TimeDiff(later: sn, earlier: self.rcv_nxt) < 0 {
            return
        }
        
        for seg in self.rcv_buf {
            if seg.sn == sn {
                flag = true
                break
            }
            if TimeDiff(later: sn, earlier: seg.sn) > 0 {
                break
            }
        }
        
        if !flag {
            self.rcv_buf.append(newseg)
        }
        
        while self.rcv_buf.count != 0 {
            let seg = self.rcv_buf.first!
            if seg.sn == self.rcv_nxt {
                self.rcv_buf.remove(at: 0)
                self.rcv_queue.append(seg)
                self.rcv_nxt += 1
            } else {
                break
            }
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
    
    private func buf_shrink() {
        if self.snd_buf.count != 0 {
            let seg = self.snd_buf.first!
            self.snd_una = seg.sn
        } else {
            self.snd_una = self.snd_nxt
        }
    }
    
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
