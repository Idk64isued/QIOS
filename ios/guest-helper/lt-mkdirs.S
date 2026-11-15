@ lt-mkdirs: the one thing a stock iPhone OS image has no tool for.
@
@     lt-mkdirs UID GID PATH...
@
@ For each PATH, in order: mkdir(PATH, 0755), then chown(PATH, UID, GID). A PATH that already exists (a file, or a
@ directory) just gets its owner set, so the same call sets the owner of files that were uploaded into new folders.
@ Errors are ignored and the exit status is always 0: the host checks the result by what it can see afterwards.
@
@ No libSystem, no dyld: a static Mach-O whose entry is reached straight from the kernel with sp at argc, argv[],
@ NULL. BSD system calls on 32-bit ARM Darwin are `svc #0x80` with the number in r12 and the arguments in r0-r3.
@ ARMv6, ARM state (the iPhone and iPod touch of iPhone OS 1 to 3).

    .text
    .syntax unified
    .arm
    .globl start
start:
    ldr     r4, [sp]            @ argc
    add     r5, sp, #4          @ argv
    cmp     r4, #3
    blt     Ldone
    ldr     r0, [r5, #4]        @ argv[1]: uid
    bl      Latoi
    mov     r9, r0
    ldr     r0, [r5, #8]        @ argv[2]: gid
    bl      Latoi
    mov     r10, r0
    mov     r7, #3              @ i = 3
Lnext:
    cmp     r7, r4
    bge     Ldone
    ldr     r8, [r5, r7, lsl #2]
    mov     r0, r8
    mov     r1, #0x1c0
    orr     r1, r1, #0x2d       @ 0755
    mov     r12, #136           @ SYS_mkdir
    svc     #0x80
    mov     r0, r8
    mov     r1, r9
    mov     r2, r10
    mov     r12, #16            @ SYS_chown
    svc     #0x80
    add     r7, r7, #1
    b       Lnext
Ldone:
    mov     r0, #0
    mov     r12, #1             @ SYS_exit
    svc     #0x80
    b       Ldone

@ r0: a decimal string -> r0. Uses r1-r3 only.
Latoi:
    mov     r1, #0
1:  ldrb    r2, [r0], #1
    sub     r2, r2, #48
    cmp     r2, #9
    bhi     2f
    mov     r3, #10
    mul     r1, r3, r1
    add     r1, r1, r2
    b       1b
2:  mov     r0, r1
    bx      lr
