@ lt-install: hands an .ipa to the device's own installer.
@
@     lt-install IPA
@
@ Calls MobileInstallationInstall(path, {ApplicationType: User}, NULL, path), the call jailbreak-era ipainstaller made
@ and the one installd answers for iTunes and Xcode. installd unpacks the app, makes its container, registers it and
@ tells SpringBoard, which then draws its icon the way it does for any other app. Prepared iPhone 4-class devices
@ carry AppSync in installd (FirmwareKit's appsync recipe option), so an unsigned, decrypted app is accepted.
@
@ Prints one line, "lt-install: N", N being MobileInstallationInstall's result (0 is success) or, when it was never
@ reached, the step that failed as a negative number:
@     -2 CoreFoundation would not load   -3 MobileInstallation would not load
@     -4 a CoreFoundation function is missing   -5 MobileInstallationInstall is missing   -6 a CFString failed
@     -7 no path on the command line and none in the file either
@
@ An optional second argument is a uid to become first (setgid then setuid), so the same program can ask installd
@ as root or as mobile. 0 or absent stays root, which is what iOS 4 and 5 already accept.
@ It exits 0 only on success.
@
@ -1 therefore means one thing only: installd was reached and refused. -7 is deliberately not -1: for five updates
@ lt-install printed -1 both for a refusal and for a missing argument, and the app read every one of them as
@ installd's refusal, so an argument that never arrived would have looked exactly like a device without AppSync.
@
@ It no longer depends on the argument arriving. If argv is empty it prints "argv did not arrive: ..." and reads the
@ path from /var/mobile/Media/PublicStaging/lt-install.path, which the app writes next to the .ipa before each run.
@ So the install works either way, and the note says which way it went.
@
@ Unlike lt-mkdirs and lt-unpack this one is dynamically linked: dyld loads it (LC_LOAD_DYLINKER), binds two pointers
@ in __DATA to libSystem's dlopen and dlsym (LC_DYLD_INFO_ONLY), and enters at `start` with sp at argc, as the kernel
@ does a static program (dyld's traditional LC_UNIXTHREAD hand-off). Everything else is looked up with dlsym.
@ build.py lays the file out and puts __DATA at 0x2000, which this code addresses directly: the image has no PIE
@ flag, so it loads where it says.
@
@ __DATA (0x2000), one word each:
@   0 dlopen   4 dlsym   (bound by dyld)
@   8 CFStringCreateWithCString   12 CFDictionaryCreate   16 kCFTypeDictionaryKeyCallBacks
@  20 kCFTypeDictionaryValueCallBacks   24 MobileInstallationInstall
@  28 the path   32 the key   36 the value   40 the options dictionary   44 CFShow (0 if absent)
@
@ ARMv6, ARM state: runs on every armv6 and armv7 device.

    .text
    .syntax unified
    .arm
    .globl start
start:
    @ stderr onto stdout before anything else, so what the callback below prints (CFShow writes to stderr)
    @ comes back to the app with the rest of the output however the agent collects it.
    mov     r0, #1
    mov     r1, #2
    mov     r12, #90                @ SYS_dup2
    svc     #0x80
    ldr     r4, [sp]                @ argc
    add     r5, sp, #4              @ argv
    bic     sp, sp, #7              @ calls want an 8-byte aligned stack
    mov     r11, #0x2000            @ __DATA
    mov     r6, #0                  @ the path, once there is one
    cmp     r4, #2
    blt     Lnoargv
    ldr     r6, [r5, #4]            @ argv[1]
    cmp     r6, #0
    bne     Lhavepath
Lnoargv:
    @ Nothing came in on the command line. Rather than give up, say so and read the path out of the file the app
    @ writes beside the .ipa for exactly this case: the install then works whether or not argv arrived, and the
    @ note on stdout says which of the two it was. The app reads that note back into its log.
    adr     r1, Lnote
    mov     r2, #57                 @ Lnote's length; test.py checks the line byte for byte
    mov     r0, #1                  @ stdout
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    bl      Lreadpath
    cmp     r6, #0
    mvneq   r8, #6                  @ -7: no path on the command line and none in the file either
    beq     Lreport
Lhavepath:
    @ Optionally become another user before installing.
    @
    @ installd takes the same .ipa on iOS 4 and 5 and refuses it on 6, with everything else identical, and the one
    @ thing this program has never varied is who it is: the agent spawns it as root, while iTunes installs through
    @ installation_proxy as mobile. iOS 6 is the release that tightened installd, so "argv[2] is a uid" lets the
    @ app try root first (which is what 4 and 5 already accept) and then mobile, and say which one worked.
    @
    @ setgid before setuid: the other order drops the privilege needed for the group.
    cmp     r4, #3
    blt     Lready
    ldr     r0, [r5, #8]            @ argv[2]
    cmp     r0, #0
    beq     Lready
    bl      Latoi                   @ r0 = the uid
    cmp     r0, #0
    beq     Lready                  @ 0 is root: nothing to drop
    mov     r9, r0                  @ keep it; r0 is about to be the argument
    mov     r12, #181               @ SYS_setgid
    svc     #0x80
    mov     r0, r9
    mov     r12, #23                @ SYS_setuid
    svc     #0x80
Lready:

    @ CoreFoundation and MobileInstallation
    adr     r0, Lcf
    mov     r1, #2                  @ RTLD_NOW
    ldr     r12, [r11]
    blx     r12
    mvn     r8, #1                  @ -2
    movs    r7, r0
    beq     Lreport
    adr     r0, Lmi
    mov     r1, #2
    ldr     r12, [r11]
    blx     r12
    mvn     r8, #2                  @ -3
    movs    r10, r0
    beq     Lreport

    @ The CoreFoundation pieces, into __DATA 8..20
    mvn     r8, #3                  @ -4
    mov     r0, r7
    adr     r1, Lscs
    bl      Lsym
    str     r0, [r11, #8]
    mov     r0, r7
    adr     r1, Lsdc
    bl      Lsym
    str     r0, [r11, #12]
    mov     r0, r7
    adr     r1, Lskc
    bl      Lsym
    str     r0, [r11, #16]
    mov     r0, r7
    adr     r1, Lsvc
    bl      Lsym
    str     r0, [r11, #20]
    mvn     r8, #4                  @ -5
    mov     r0, r10
    adr     r1, Lsmi
    bl      Lsym
    str     r0, [r11, #24]
    @ CFShow, for the callback. Looked up directly rather than through Lsym: missing it is not a reason to fail.
    mov     r0, r7
    adr     r1, Lsshow
    ldr     r12, [r11, #4]          @ dlsym
    blx     r12
    str     r0, [r11, #44]

    @ The three strings: the path, "ApplicationType", "User"
    mvn     r8, #5                  @ -6
    mov     r0, r6
    bl      Lcfstr
    str     r0, [r11, #28]
    adr     r0, Lkey
    bl      Lcfstr
    str     r0, [r11, #32]
    adr     r0, Luser
    bl      Lcfstr
    str     r0, [r11, #36]

    @ options = CFDictionaryCreate(NULL, &key, &value, 1, &keyCallBacks, &valueCallBacks)
    sub     sp, sp, #8
    ldr     r12, [r11, #16]
    str     r12, [sp]
    ldr     r12, [r11, #20]
    str     r12, [sp, #4]
    mov     r0, #0
    add     r1, r11, #32
    add     r2, r11, #36
    mov     r3, #1
    ldr     r12, [r11, #12]
    blx     r12
    add     sp, sp, #8
    str     r0, [r11, #40]

    @ MobileInstallationInstall(path, options, callback, path)
    @
    @ The third argument used to be NULL. installd reports progress and, on failure, its reason -- the
    @ "ApplicationVerificationFailed" / "PackageExtractionFailed" dictionary iTunes and ideviceinstaller show --
    @ through this callback, and the return value is only a generic -1. Every refusal on iOS 6 came with its
    @ reason attached, and this program threw it away. Now each status dictionary is printed with CFShow.
    ldr     r0, [r11, #28]
    ldr     r1, [r11, #40]
    ldr     r2, [r11, #44]          @ CFShow found?
    cmp     r2, #0
    adrne   r2, Lcallback           @ then the callback, else NULL as before
    mov     r3, r0
    ldr     r12, [r11, #24]
    blx     r12
    mov     r8, r0

@ "lt-install: <r8>\n" on stdout, then exit 0 if r8 is 0, else 1.
Lreport:
    sub     sp, sp, #32
    mov     r4, sp                  @ the line, built backwards from its end
    add     r5, r4, #31
    mov     r0, #10                 @ '\n'
    strb    r0, [r5]
    mov     r6, r8                  @ the number
    cmp     r6, #0
    rsblt   r6, r6, #0              @ its magnitude
    ldr     r7, Ltenth              @ 0xCCCCCCCD: n / 10 is the top of n * this, shifted 3
1:  umull   r2, r3, r6, r7
    lsr     r1, r3, #3              @ r1 = r6 / 10 (unsigned)
    add     r2, r1, r1, lsl #2      @ r1 * 5
    sub     r0, r6, r2, lsl #1      @ r6 - r1 * 10: the digit
    add     r0, r0, #48
    sub     r5, r5, #1
    strb    r0, [r5]
    movs    r6, r1
    bne     1b
    cmp     r8, #0
    movlt   r0, #45                 @ '-'
    sublt   r5, r5, #1
    strblt  r0, [r5]
    adr     r1, Lhead               @ "lt-install: " in front
    mov     r2, #12
4:  subs    r2, r2, #1
    ldrb    r0, [r1, r2]
    sub     r5, r5, #1
    strb    r0, [r5]
    bne     4b
    mov     r0, #1                  @ stdout
    mov     r1, r5
    add     r2, r4, #32
    sub     r2, r2, r5
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    cmp     r8, #0
    movne   r0, #1
    moveq   r0, #0
    mov     r12, #1                 @ SYS_exit
    svc     #0x80
    b       .

@ r0 a NUL-terminated decimal string -> r0 = its value. Stops at the first byte that is not a digit; an empty or
@ non-numeric string gives 0, which this program treats as "stay root".
Latoi:
    mov     r1, #0                  @ the value
1:  ldrb    r2, [r0], #1
    sub     r2, r2, #48
    cmp     r2, #9
    bhi     2f
    add     r1, r1, r1, lsl #2      @ r1 * 5
    add     r1, r2, r1, lsl #1      @ r1 * 10 + digit
    b       1b
2:  mov     r0, r1
    bx      lr

@ Reads the path the app leaves at Lpathfile into __DATA+64 (1 KiB of scratch, well inside the page) and cuts it at
@ the first space or control byte, so a trailing newline is not taken for part of the name. r6 = the path, or 0 if
@ there is nothing usable there. Clobbers r0-r3 and r12.
Lreadpath:
    push    {r4, r5, lr}
    adr     r0, Lpathfile
    mov     r1, #0                  @ O_RDONLY
    mov     r2, #0
    mov     r12, #5                 @ SYS_open
    svc     #0x80
    bcs     2f
    mov     r4, r0                  @ the fd
    add     r5, r11, #64            @ the buffer
    mov     r1, r5
    mov     r2, #1020               @ 1020, not 1024: the buffer is 1 KiB, so the terminator below always fits,
    mov     r12, #3                 @ and 1023 is not an ARMv6 immediate, so there is nothing to clamp afterwards
    svc     #0x80                   @ SYS_read
    mov     r3, r0                  @ how much came back (r0 was the fd going in)
    mov     r0, r4
    mov     r12, #6                 @ SYS_close
    svc     #0x80
    cmp     r3, #1
    blt     2f
    mov     r2, #0
1:  ldrb    r0, [r5, r2]
    cmp     r0, #32                 @ a space, a newline or a NUL ends the path
    ble     3f
    add     r2, r2, #1
    cmp     r2, r3
    blt     1b
3:  mov     r0, #0
    strb    r0, [r5, r2]
    cmp     r2, #0
    beq     2f                      @ the file held nothing but a newline
    mov     r6, r5
    pop     {r4, r5, lr}
    bx      lr
2:  mov     r6, #0
    pop     {r4, r5, lr}
    bx      lr

@ MobileInstallationInstall's callback: void (CFDictionaryRef status, void *context). Prints the status with
@ CFShow and returns. It runs inside MobileInstallationInstall, where r11 belongs to that function, so __DATA is
@ addressed afresh; a tail call leaves the stack and lr exactly as the caller set them.
Lcallback:
    mov     r12, #0x2000
    ldr     r12, [r12, #44]         @ CFShow
    bx      r12                     @ CFShow(status), returning straight to MobileInstallation

@ r0 handle, r1 name -> r0 = dlsym(handle, name); a missing one ends in Lreport with r8's step.
Lsym:
    push    {r4, lr}
    ldr     r12, [r11, #4]
    blx     r12
    pop     {r4, lr}
    cmp     r0, #0
    beq     Lreport
    bx      lr

@ r0 C string -> r0 = CFStringCreateWithCString(NULL, r0, kCFStringEncodingUTF8); a NULL ends in Lreport.
Lcfstr:
    push    {r4, lr}
    mov     r1, r0
    mov     r0, #0
    ldr     r2, Lutf8
    ldr     r12, [r11, #8]
    blx     r12
    pop     {r4, lr}
    cmp     r0, #0
    beq     Lreport
    bx      lr

@ Each string starts on a word: an `adr` reaches anything a multiple of 4 under 1 KiB away.
    .align 2
Lutf8:  .word 0x08000100           @ kCFStringEncodingUTF8
Ltenth: .word 0xCCCCCCCD
Lhead:  .ascii "lt-install: "
    .align 2
Lnote:  .ascii "argv did not arrive: read the path from its file instead\n"
    .align 2
Lpathfile:
    .asciz "/var/mobile/Media/PublicStaging/lt-install.path"
    .align 2
Lcf:    .asciz "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    .align 2
Lmi:    .asciz "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"
    .align 2
Lscs:   .asciz "CFStringCreateWithCString"
    .align 2
Lsdc:   .asciz "CFDictionaryCreate"
    .align 2
Lskc:   .asciz "kCFTypeDictionaryKeyCallBacks"
    .align 2
Lsvc:   .asciz "kCFTypeDictionaryValueCallBacks"
    .align 2
Lsmi:   .asciz "MobileInstallationInstall"
    .align 2
Lsshow: .asciz "CFShow"
    .align 2
Lkey:   .asciz "ApplicationType"
    .align 2
Luser:  .asciz "User"
    .align 2
