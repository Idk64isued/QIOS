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
@     -1 no IPA argument   -2 CoreFoundation would not load   -3 MobileInstallation would not load
@     -4 a CoreFoundation function is missing   -5 MobileInstallationInstall is missing   -6 a CFString failed
@ and exits 0 only on success.
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
@  28 the path   32 the key   36 the value   40 the options dictionary
@
@ ARMv6, ARM state: runs on every armv6 and armv7 device.

    .text
    .syntax unified
    .arm
    .globl start
start:
    ldr     r4, [sp]                @ argc
    add     r5, sp, #4              @ argv
    bic     sp, sp, #7              @ calls want an 8-byte aligned stack
    mov     r11, #0x2000            @ __DATA
    mvn     r8, #0                  @ -1: no IPA
    cmp     r4, #2
    blt     Lreport
    ldr     r6, [r5, #4]            @ argv[1]

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

    @ MobileInstallationInstall(path, options, NULL, path)
    ldr     r0, [r11, #28]
    ldr     r1, [r11, #40]
    mov     r2, #0
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
Lkey:   .asciz "ApplicationType"
    .align 2
Luser:  .asciz "User"
    .align 2
