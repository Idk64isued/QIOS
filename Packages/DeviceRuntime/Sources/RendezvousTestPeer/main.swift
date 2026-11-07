import Darwin
import IOSurface
import LTMLinkC

// A stand-in helper for DeviceRuntimeTests: sends one Mach hello (a 1x1 status
// surface) to <service> with <token>, then exits ("exit") or stays until killed ("stay").

let arguments = CommandLine.arguments
guard arguments.count == 4 else { exit(64) }
guard let surface = IOSurface(properties: [.width: 1, .height: 1, .bytesPerElement: 4]) else { exit(1) }
var port = IOSurfaceCreateMachPort(surface)
let kr = ltm_send_hello(arguments[1], arguments[2], 0, 0, &port, 1)
if kr == 0 && arguments[3] == "stay" { pause() }
exit(kr == 0 ? 0 : 1)
