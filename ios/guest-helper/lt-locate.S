@ lt-locate: tells the device's location service where it is, the way Xcode's "Simulate Location" does.
@
@     lt-locate LATITUDE LONGITUDE     (decimal degrees, e.g. 43.6150 -116.2023)
@     lt-locate stop                   (back to the device's own idea of where it is)
@
@ Only the iPhone 3GS has a GPS receiver this emulator's modem can answer for, so on every other board -- the
@ iPhone 4 included, which is every board that runs iOS 6 -- Location Services found nothing however it was set.
@ Rather than emulate another GPS chip, this takes the route Xcode takes with a real phone: CoreLocation's own
@ simulation interface, CLSimulationManager, which locationd honours from any process signed with the
@ com.apple.locationd.simulation entitlement (build.py signs this one with it). Every app on the device then sees
@ the location given here, as it would see one from GPS.
@
@ The calls, through the Objective-C runtime (each one asked for with respondsToSelector: first, so an iOS that
@ lacks one says so instead of crashing):
@     m = [[CLSimulationManager alloc] init]
@     [m stopLocationSimulation]; [m clearSimulatedLocations]
@     [m appendSimulatedLocation:[[CLLocation alloc] initWithLatitude:lat longitude:lon]]
@     [m flush]; [m startLocationSimulation]
@ then a second and a half for locationd to take it before exiting. "stop" sends stop, clear and flush.
@
@ Prints "lt-locate: ok" (exit 0), or what was missing: "lt-locate: no NAME" per missing piece (exit 2), or one
@ line on stderr when there is nothing to work with at all (exit 1).
@
@ __DATA (0x2000), one word each:
@   0 dlopen   4 dlsym   (bound by dyld)
@   8 objc_getClass   12 sel_registerName   16 objc_msgSend   20 strtod   24 usleep
@   28 the manager   32 the location   36 @selector(respondsToSelector:)
@   40 latitude (two words)   48 longitude (two words)
@
@ ARMv6, ARM state: runs on every armv6 and armv7 device. r9 is never used: iOS treats it as volatile.

    .text
    .syntax unified
    .arm
    .globl start
start:
    ldr     r4, [sp]                @ argc
    add     r5, sp, #4              @ argv
    bic     sp, sp, #7              @ calls want an 8-byte aligned stack
    mov     r11, #0x2000            @ __DATA
    mov     r8, #0                  @ missing pieces so far
    @ r10: the string table. adr can't reach that far with the offsets these strings land at, so the table's
    @ address is worked out once, and every string sits on a 32-byte boundary in it (an offset add can encode).
    ldr     r10, Lstroff
Lpc:
    add     r10, pc, r10
    cmp     r4, #2
    blt     Lusage

    @ The libraries: libSystem (strtod, usleep), libobjc, and CoreLocation (which brings Foundation).
    add     r0, r10, #288
    bl      Lopen
    movs    r6, r0
    beq     Lnolib
    add     r0, r10, #320
    bl      Lopen
    movs    r7, r0
    beq     Lnolib
    add     r0, r10, #352
    bl      Lopen
    cmp     r0, #0
    beq     Lnolib

    @ The functions, into their slots.
    mov     r0, r7
    add     r1, r10, #416
    bl      Lsym
    str     r0, [r11, #8]
    mov     r0, r7
    add     r1, r10, #448
    bl      Lsym
    str     r0, [r11, #12]
    mov     r0, r7
    add     r1, r10, #480
    bl      Lsym
    str     r0, [r11, #16]
    mov     r0, r6
    add     r1, r10, #512
    bl      Lsym
    str     r0, [r11, #20]
    mov     r0, r6
    add     r1, r10, #544
    bl      Lsym
    str     r0, [r11, #24]
    ldr     r0, [r11, #8]
    ldr     r1, [r11, #12]
    ldr     r2, [r11, #16]
    ldr     r3, [r11, #20]
    cmp     r0, #0
    cmpne   r1, #0
    cmpne   r2, #0
    cmpne   r3, #0
    beq     Lnosym

    @ @selector(respondsToSelector:), once.
    add     r0, r10, #640
    ldr     r12, [r11, #12]
    blx     r12
    str     r0, [r11, #36]

    @ The manager.
    add     r0, r10, #576
    ldr     r12, [r11, #8]
    blx     r12                     @ objc_getClass("CLSimulationManager")
    cmp     r0, #0
    beq     Lnomanager
    mov     r6, r0
    add     r0, r10, #672
    ldr     r12, [r11, #12]
    blx     r12
    mov     r1, r0
    mov     r0, r6
    ldr     r12, [r11, #16]
    blx     r12                     @ [CLSimulationManager alloc]
    mov     r6, r0
    add     r0, r10, #704
    ldr     r12, [r11, #12]
    blx     r12
    mov     r1, r0
    mov     r0, r6
    ldr     r12, [r11, #16]
    blx     r12                     @ -init
    cmp     r0, #0
    beq     Lnomanager
    str     r0, [r11, #28]

    @ "stop"?
    ldr     r0, [r5, #4]            @ argv[1]
    add     r1, r10, #928
    bl      Lsame
    cmp     r0, #0
    bne     Lstop

    cmp     r4, #3
    blt     Lusage

    @ The coordinates.
    ldr     r0, [r5, #4]
    mov     r1, #0
    ldr     r12, [r11, #20]
    blx     r12                     @ strtod(argv[1], NULL): a double, in r0:r1
    str     r0, [r11, #40]
    str     r1, [r11, #44]
    ldr     r0, [r5, #8]
    mov     r1, #0
    ldr     r12, [r11, #20]
    blx     r12                     @ strtod(argv[2], NULL)
    str     r0, [r11, #48]
    str     r1, [r11, #52]

    @ [[CLLocation alloc] initWithLatitude:lat longitude:lon]. The latitude rides in r2:r3, the longitude on the
    @ stack: a double after two word arguments, as Apple's ARM ABI passes it.
    add     r0, r10, #608
    ldr     r12, [r11, #8]
    blx     r12
    cmp     r0, #0
    beq     Lnolocation
    mov     r6, r0
    add     r0, r10, #672
    ldr     r12, [r11, #12]
    blx     r12
    mov     r1, r0
    mov     r0, r6
    ldr     r12, [r11, #16]
    blx     r12                     @ [CLLocation alloc]
    mov     r6, r0
    add     r0, r10, #736
    ldr     r12, [r11, #12]
    blx     r12
    mov     r1, r0
    mov     r0, r6
    ldr     r2, [r11, #40]
    ldr     r3, [r11, #44]
    sub     sp, sp, #8
    ldr     r12, [r11, #48]
    str     r12, [sp]
    ldr     r12, [r11, #52]
    str     r12, [sp, #4]
    ldr     r12, [r11, #16]
    blx     r12                     @ -initWithLatitude:longitude:
    add     sp, sp, #8
    cmp     r0, #0
    beq     Lnolocation
    str     r0, [r11, #32]

    add     r0, r10, #768
    mov     r1, #0
    bl      Lsend
    add     r0, r10, #800
    mov     r1, #0
    bl      Lsend
    add     r0, r10, #832
    ldr     r1, [r11, #32]
    bl      Lsend
    add     r0, r10, #864
    mov     r1, #0
    bl      Lsend
    add     r0, r10, #896
    mov     r1, #0
    bl      Lsend
    b       Lsettle

Lstop:
    add     r0, r10, #768
    mov     r1, #0
    bl      Lsend
    add     r0, r10, #800
    mov     r1, #0
    bl      Lsend
    add     r0, r10, #864
    mov     r1, #0
    bl      Lsend

Lsettle:
    @ locationd hears about this over a message the manager sends on its own time; give it that time.
    ldr     r12, [r11, #24]
    cmp     r12, #0
    beq     Lfinish
    ldr     r0, Lsettleus
    blx     r12                     @ usleep(1500000)
Lfinish:
    cmp     r8, #0
    bne     Lpartial
    add     r1, r10, #0
    mov     r2, #14                 @ Mok's length; test.py checks it byte for byte
    mov     r0, #1
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    mov     r0, #0
    mov     r12, #1                 @ SYS_exit
    svc     #0x80
    b       .
Lpartial:
    mov     r0, #2
    mov     r12, #1
    svc     #0x80
    b       .

Lnomanager:
    add     r0, r10, #576
    bl      Lmissing
    b       Lfinish
Lnolocation:
    add     r0, r10, #608
    bl      Lmissing
    b       Lfinish

Lusage:
    add     r1, r10, #96
    mov     r2, #51                 @ Musage's length
    b       Lsay
Lnolib:
    add     r1, r10, #160
    mov     r2, #45                 @ Mnolib's length
    b       Lsay
Lnosym:
    add     r1, r10, #224
    mov     r2, #46                 @ Mnosym's length
Lsay:
    mov     r0, #2                  @ stderr
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    mov     r0, #1
    mov     r12, #1                 @ SYS_exit
    svc     #0x80
    b       .

@ dlopen(r0, RTLD_NOW). Clobbers r0-r3, r12.
Lopen:
    push    {r4, lr}
    mov     r1, #2
    ldr     r12, [r11]
    blx     r12
    pop     {r4, lr}
    bx      lr

@ dlsym(r0, r1). Clobbers r0-r3, r12.
Lsym:
    push    {r4, lr}
    ldr     r12, [r11, #4]
    blx     r12
    pop     {r4, lr}
    bx      lr

@ Sends the selector named by r0 to the manager, with r1 as its one object argument (ignored by those that take
@ none), if the manager responds to it; otherwise reports it missing. Clobbers r0-r3, r12.
Lsend:
    push    {r4, r5, r6, r7, r8, lr}
    mov     r4, r0                  @ the name
    mov     r5, r1                  @ the argument
    ldr     r12, [r11, #12]
    blx     r12                     @ sel_registerName(name)
    mov     r6, r0
    ldr     r0, [r11, #28]
    ldr     r1, [r11, #36]
    mov     r2, r6
    ldr     r12, [r11, #16]
    blx     r12                     @ [manager respondsToSelector:sel]
    ands    r0, r0, #0xff
    beq     1f
    ldr     r0, [r11, #28]
    mov     r1, r6
    mov     r2, r5
    ldr     r12, [r11, #16]
    blx     r12
    pop     {r4, r5, r6, r7, r8, lr}
    bx      lr
1:  mov     r0, r4
    pop     {r4, r5, r6, r7, r8, lr}
    b       Lmissing

@ "lt-locate: no NAME\n" on stdout, for the NUL-terminated name in r0, and one more missing piece. Clobbers r0-r3,
@ r12.
Lmissing:
    push    {r4, r5, r6, lr}
    add     r8, r8, #1
    mov     r6, r0
    mov     r0, #1
    add     r1, r10, #32
    mov     r2, #14                 @ Mno's length
    mov     r12, #4
    svc     #0x80
    mov     r1, r6
    mov     r2, #0
2:  ldrb    r3, [r1, r2]
    cmp     r3, #0
    addne   r2, r2, #1
    bne     2b
    mov     r0, #1
    mov     r12, #4
    svc     #0x80
    mov     r0, #1
    add     r1, r10, #64
    mov     r2, #1
    mov     r12, #4
    svc     #0x80
    pop     {r4, r5, r6, lr}
    bx      lr

@ r0 = 1 if the NUL-terminated strings at r0 and r1 are the same, else 0. Clobbers r0-r3.
Lsame:
3:  ldrb    r2, [r0], #1
    ldrb    r3, [r1], #1
    cmp     r2, r3
    movne   r0, #0
    bxne    lr
    cmp     r2, #0
    bne     3b
    mov     r0, #1
    bx      lr

    .align 2
Lsettleus:  .word 1500000
Lstroff:    .word Lstr - (Lpc + 8)

@ The strings, each on a 32-byte boundary (see r10).
    .balign 32
Lstr:
    .balign 32
Mok: @ +0
    .ascii "lt-locate: ok\n"
    .balign 32
Mno: @ +32
    .ascii "lt-locate: no "
    .balign 32
Mnewline: @ +64
    .ascii "\n"
    .balign 32
Musage: @ +96
    .ascii "lt-locate: give LATITUDE LONGITUDE, or stop to end\n"
    .balign 32
Mnolib: @ +160
    .ascii "lt-locate: a library this needs did not load\n"
    .balign 32
Mnosym: @ +224
    .ascii "lt-locate: this iOS is missing a runtime call\n"
    .balign 32
Llibsystem: @ +288
    .asciz "/usr/lib/libSystem.B.dylib"
    .balign 32
Llibobjc: @ +320
    .asciz "/usr/lib/libobjc.A.dylib"
    .balign 32
Lcorelocation: @ +352
    .asciz "/System/Library/Frameworks/CoreLocation.framework/CoreLocation"
    .balign 32
Ngetclass: @ +416
    .asciz "objc_getClass"
    .balign 32
Nselreg: @ +448
    .asciz "sel_registerName"
    .balign 32
Nmsgsend: @ +480
    .asciz "objc_msgSend"
    .balign 32
Nstrtod: @ +512
    .asciz "strtod"
    .balign 32
Nusleep: @ +544
    .asciz "usleep"
    .balign 32
Cmanager: @ +576
    .asciz "CLSimulationManager"
    .balign 32
Clocation: @ +608
    .asciz "CLLocation"
    .balign 32
Sresponds: @ +640
    .asciz "respondsToSelector:"
    .balign 32
Salloc: @ +672
    .asciz "alloc"
    .balign 32
Sinit: @ +704
    .asciz "init"
    .balign 32
Sinitlatlon: @ +736
    .asciz "initWithLatitude:longitude:"
    .balign 32
Sstop: @ +768
    .asciz "stopLocationSimulation"
    .balign 32
Sclear: @ +800
    .asciz "clearSimulatedLocations"
    .balign 32
Sappend: @ +832
    .asciz "appendSimulatedLocation:"
    .balign 32
Sflush: @ +864
    .asciz "flush"
    .balign 32
Sstart: @ +896
    .asciz "startLocationSimulation"
    .balign 32
Wstop: @ +928
    .asciz "stop"
