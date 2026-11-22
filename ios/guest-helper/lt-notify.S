@ lt-notify: posts Darwin notifications, the way installd does when it has installed something.
@
@     lt-notify NAME...
@
@ An app written in by hand lands on disk correctly -- the files, the icons, the installation cache entry -- and
@ SpringBoard still leaves the Home screen empty. It is not objecting to the files: it never learns there is
@ anything new. installd keeps the app list in memory and SpringBoard asks installd, not the file, so a cache this
@ app rewrote behind installd's back is a cache installd has never read. What installd does at the end of a real
@ install is post a Darwin notification; the rest of the system re-reads because of that and for no other reason.
@ That is the step the hand-written path has always been missing, and it is one libSystem call.
@
@ iOS 4 and 5 never needed it: there installd does the install itself, so its own list is already right.
@
@ Prints one line per name, "lt-notify: NAME N", N being notify_post's result (0 is success), and exits 0 only if
@ every one of them succeeded.
@
@ Dynamically linked, like lt-install: dyld binds dlopen and dlsym into __DATA and everything else is looked up.
@
@ __DATA (0x2000), one word each:
@   0 dlopen   4 dlsym   (bound by dyld)
@   8 notify_post
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
    mov     r8, #0                  @ the worst result so far
    cmp     r4, #2
    blt     Lnonames

    @ libSystem, and notify_post out of it.
    adr     r0, Llibsystem
    mov     r1, #2                  @ RTLD_NOW
    ldr     r12, [r11]
    blx     r12
    movs    r7, r0
    beq     Lnolib
    mov     r0, r7
    adr     r1, Lnotifypost
    ldr     r12, [r11, #4]
    blx     r12
    movs    r6, r0
    beq     Lnosym
    str     r6, [r11, #8]

    @ r6 is the index and r7 the name, NOT r9 and r10. iOS treats r9 as a volatile scratch register -- Apple's ARM
    @ ABI departs from AAPCS here -- so notify_post is entitled to destroy it, and did: the loop counter came back
    @ wrong after the first call and only one of the three names was ever posted. r4-r8 and r10-r11 are callee-saved
    @ on every ARM ABI, and Lreport saves the ones it uses.
    mov     r6, #1                  @ argv index
Lnext:
    ldr     r7, [r5, r6, lsl #2]    @ argv[r6]
    cmp     r7, #0
    beq     Ldone
    mov     r0, r7
    ldr     r12, [r11, #8]
    blx     r12                     @ notify_post(name)
    mov     r1, r0                  @ its result
    cmp     r1, #0
    movne   r8, r1                  @ remember that something failed; the exit code is all or nothing
    mov     r0, r7
    bl      Lreport                 @ "lt-notify: NAME <r1>"
    add     r6, r6, #1
    cmp     r6, r4
    blt     Lnext
Ldone:
    cmp     r8, #0
    movne   r0, #1
    moveq   r0, #0
    mov     r12, #1                 @ SYS_exit
    svc     #0x80
    b       .

Lnonames:
    adr     r1, Lusage
    mov     r2, #33                 @ Lusage's length; test.py checks it byte for byte
    b       Lsay
Lnolib:
    adr     r1, Lnolibmsg
    mov     r2, #36                 @ Lnolibmsg's length
    b       Lsay
Lnosym:
    adr     r1, Lnosymmsg
    mov     r2, #39                 @ Lnosymmsg's length
Lsay:
    mov     r0, #2                  @ stderr
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    mov     r0, #1
    mov     r12, #1                 @ SYS_exit
    svc     #0x80
    b       .

@ r0 a NUL-terminated name, r1 a small signed number -> "lt-notify: NAME N\n" on stdout. Clobbers r0-r3, r12.
Lreport:
    push    {r4, r5, r6, r7, lr}
    mov     r6, r0                  @ the name
    mov     r7, r1                  @ the number
    sub     sp, sp, #64
    mov     r4, sp
    add     r5, r4, #63
    mov     r0, #10                 @ '\n'
    strb    r0, [r5]
    @ the number, backwards
    mov     r1, r7
    cmp     r1, #0
    rsblt   r1, r1, #0
    ldr     r2, Ltenth
1:  umull   r3, r12, r1, r2
    lsr     r3, r12, #3             @ r1 / 10
    add     r12, r3, r3, lsl #2
    sub     r0, r1, r12, lsl #1     @ the digit
    add     r0, r0, #48
    sub     r5, r5, #1
    strb    r0, [r5]
    movs    r1, r3
    bne     1b
    cmp     r7, #0
    movlt   r0, #45                 @ '-'
    sublt   r5, r5, #1
    strblt  r0, [r5]
    mov     r0, #32                 @ ' '
    sub     r5, r5, #1
    strb    r0, [r5]
    @ the name, backwards: find its end first
    mov     r1, r6
2:  ldrb    r0, [r1]
    cmp     r0, #0
    addne   r1, r1, #1
    bne     2b
3:  cmp     r1, r6
    beq     4f
    sub     r1, r1, #1
    ldrb    r0, [r1]
    sub     r5, r5, #1
    strb    r0, [r5]
    b       3b
4:  adr     r1, Lhead
    mov     r2, #11
5:  subs    r2, r2, #1
    ldrb    r0, [r1, r2]
    sub     r5, r5, #1
    strb    r0, [r5]
    bne     5b
    mov     r0, #1                  @ stdout
    mov     r1, r5
    add     r2, r4, #64
    sub     r2, r2, r5
    mov     r12, #4                 @ SYS_write
    svc     #0x80
    add     sp, sp, #64
    pop     {r4, r5, r6, r7, lr}
    bx      lr

    .align 2
Ltenth: .word 0xCCCCCCCD
Lhead:  .ascii "lt-notify: "
    .align 2
Lusage: .ascii "lt-notify: no notification names\n"
    .align 2
Lnolibmsg:
    .ascii "lt-notify: libSystem would not load\n"
    .align 2
Lnosymmsg:
    .ascii "lt-notify: this iOS has no notify_post\n"
    .align 2
Llibsystem:
    .asciz "/usr/lib/libSystem.B.dylib"
    .align 2
Lnotifypost:
    .asciz "notify_post"
    .align 2
