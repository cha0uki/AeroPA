// aeropa-udp-replay: sends ForeFlight-format datagrams (what Aerofly broadcasts)
// to an iPhone/iPad, so the REAL network path of AeroPA can be tested without Aerofly.
//
//   swift run aeropa-udp-replay --host 192.168.1.23 --speed 8
//   swift run aeropa-udp-replay --host 192.168.1.23 --file capture.txt
//
// Without --file it flies DemoFlightScript gate to gate (XGPS 1 Hz, XATT 4 Hz in sim time).
// With --file it replays one datagram per line, at --rate lines per second.
import Foundation
import Network
import AeroPACore

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 49002
    var speed = 1.0
    var file: String?
    var rate = 5.0
    var name = "Aerofly FS 4"
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--host": o.host = args.next() ?? o.host
        case "--port": o.port = UInt16(args.next() ?? "") ?? o.port
        case "--speed": o.speed = Double(args.next() ?? "") ?? o.speed
        case "--file": o.file = args.next()
        case "--rate": o.rate = Double(args.next() ?? "") ?? o.rate
        case "--name": o.name = args.next() ?? o.name
        case "-h", "--help":
            print("usage: aeropa-udp-replay [--host IP] [--port 49002] [--speed 1] [--file capture.txt --rate 5] [--name 'Aerofly FS 4']")
            exit(0)
        default: print("unknown option \(a)"); exit(2)
        }
    }
    return o
}

let opts = parseOptions()
guard let port = NWEndpoint.Port(rawValue: opts.port) else { print("bad port"); exit(2) }
let connection = NWConnection(host: NWEndpoint.Host(opts.host), port: port, using: .udp)
connection.start(queue: .global())

func send(_ line: String) {
    connection.send(content: Data(line.utf8), completion: .contentProcessed { error in
        if let error { FileHandle.standardError.write(Data("send error: \(error)\n".utf8)) }
    })
}

if let path = opts.file {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); exit(1) }
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    print("Replaying \(lines.count) datagrams to \(opts.host):\(opts.port) at \(opts.rate)/s")
    for l in lines {
        send(l)
        Thread.sleep(forTimeInterval: 1 / max(opts.rate, 0.1))
    }
} else {
    var script = DemoFlightScript()
    let dt = 0.25
    var tick = 0
    var lastLeg = script.leg
    print("Flying demo flight to \(opts.host):\(opts.port) at \(opts.speed)× (Ctrl-C to stop)")
    while script.leg != .done {
        script.step(dt)
        tick += 1
        send(String(format: "XATT%@,%.1f,%.1f,%.1f", opts.name, script.heading, script.pitch, script.roll))
        if tick % 4 == 0 {
            send(String(format: "XGPS%@,%.6f,%.6f,%.1f,%.1f,%.2f", opts.name, script.longitude, script.latitude,
                        script.altitudeFeet / Units.feetPerMetre, script.track, script.groundSpeed / Units.knotsPerMetrePerSecond))
        }
        if script.leg != lastLeg {
            print(String(format: "[%6.0fs] %@  alt %.0f ft  gs %.0f kt", script.time, script.leg.title, script.altitudeFeet, script.groundSpeed))
            lastLeg = script.leg
        }
        Thread.sleep(forTimeInterval: dt / max(opts.speed, 0.01))
    }
    print("Flight complete. Holding position for 3 minutes so the parked and flight-ended phases trigger…")
    for _ in 0..<(180 * 4) {
        send(String(format: "XGPS%@,%.6f,%.6f,%.1f,%.1f,0.00", opts.name, script.longitude, script.latitude,
                    script.altitudeFeet / Units.feetPerMetre, script.track))
        Thread.sleep(forTimeInterval: 0.25 / max(opts.speed, 0.01))
    }
}
Thread.sleep(forTimeInterval: 0.5)
connection.cancel()
