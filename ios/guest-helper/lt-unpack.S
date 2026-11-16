@ lt-unpack: a whole app bundle in one go, so an install is a few large uploads and one call instead of one agent
@ request per file. The guest agent (it_agent, prebuilt) serves one request and then sleeps a quarter of a second,
@ and each `put` fsyncs; an app of a few hundred files spent minutes on that alone.
@
@     lt-unpack UID GID ARCHIVE
@
@ ARCHIVE (written by the app, GuestInstaller.Pack), little-endian:
@     "LTPK1\0\0\0"
@     records: type, mode, path length, data length (four u32), then the path (NUL-terminated, padded to 4 bytes),
@              then for a file its bytes, padded to 4 bytes
@     type 1: a folder (mkdir, chmod); type 2: a file (created or truncated, written, fchmod); type 0: the end.
@ Every item gets UID:GID. At the end the archive is unlinked and sync(2) flushes everything once.
@ Exit status: 0 done, 1 bad arguments, 2 unreadable or malformed archive, 3 a file could not be written.
@
@ No libSystem, no dyld (see lt-mkdirs.S): a static Mach-O entered from the kernel with sp at argc. System calls are
@ `svc #0x80` with the number in r12; the kernel sets the carry flag on failure. Only r0 and r1 are trusted across a
@ call, so loop state lives in r4-r11. ARMv6, ARM state.
@
@ Stack frame (below the kernel's argc/argv): [sp] record header (16 bytes, also the magic and the padding),
@ [sp+16] path (1024 bytes), [sp+0x410] copy buffer (32 KiB).

    .text
    .syntax unified
    .arm
    .globl start
start:
    ldr     r4, [sp]            @ argc
    add     r5, sp, #4          @ argv (kept for the archive path at the end)
    cmp     r4, #4
    blt     Lbadargs
    ldr     r0, [r5, #4]        @ argv[1]: uid
    bl      Latoi
    mov     r9, r0
    ldr     r0, [r5, #8]        @ argv[2]: gid
    bl      Latoi
    mov     r10, r0
    ldr     r0, [r5, #12]       @ argv[3]: the archive
    mov     r1, #0              @ O_RDONLY
    mov     r2, #0
    mov     r12, #5             @ SYS_open
    svc     #0x80
    bcs     Lfail2
    mov     r11, r0
    sub     sp, sp, #0x8400
    sub     sp, sp, #0x10

    mov     r6, sp              @ the magic
    mov     r7, #8
    bl      Lread
    cmp     r0, #0
    bne     Lfail2
    ldr     r0, [sp]
    mov     r1, #0x4C           @ "LTPK"
    orr     r1, r1, #0x5400
    orr     r1, r1, #0x500000
    orr     r1, r1, #0x4B000000
    cmp     r0, r1
    bne     Lfail2

Lrecord:
    mov     r6, sp              @ type, mode, path length, data length
    mov     r7, #16
    bl      Lread
    cmp     r0, #0
    bne     Lfail2
    ldr     r0, [sp]
    cmp     r0, #0
    beq     Lend
    ldr     r7, [sp, #8]        @ the path
    cmp     r7, #0
    beq     Lfail2
    cmp     r7, #1024
    bhi     Lfail2
    add     r6, sp, #16
    bl      Lread
    cmp     r0, #0
    bne     Lfail2
    ldr     r7, [sp, #8]        @ whatever it says, the path ends at its last byte
    add     r6, sp, #16
    add     r6, r6, r7
    mov     r0, #0
    strb    r0, [r6, #-1]
    ldr     r0, [sp]
    cmp     r0, #1
    beq     Ldir
    cmp     r0, #2
    beq     Lfile
    b       Lfail2

Ldir:
    ldr     r0, [sp, #12]       @ a folder carries no data
    cmp     r0, #0
    bne     Lfail2
    add     r0, sp, #16
    ldr     r1, [sp, #4]
    mov     r12, #136           @ SYS_mkdir (fails harmlessly if it exists)
    svc     #0x80
    add     r0, sp, #16
    ldr     r1, [sp, #4]
    mov     r12, #15            @ SYS_chmod: mkdir's mode went through the umask
    svc     #0x80
    add     r0, sp, #16
    mov     r1, r9
    mov     r2, r10
    mov     r12, #16            @ SYS_chown
    svc     #0x80
    b       Lrecord

Lfile:
    add     r0, sp, #16
    mov     r1, #0x600          @ O_CREAT | O_TRUNC
    orr     r1, r1, #1          @ | O_WRONLY
    ldr     r2, [sp, #4]
    mov     r12, #5             @ SYS_open
    svc     #0x80
    bcs     Lfail3
    mov     r8, r0
    ldr     r4, [sp, #12]       @ bytes left to copy
Lcopy:
    cmp     r4, #0
    beq     Lcopied
    mov     r7, r4
    cmp     r7, #0x8000
    movhi   r7, #0x8000
    add     r6, sp, #0x410
    bl      Lread
    cmp     r0, #0
    bne     Lfail2c             @ the archive ended (or failed) inside the file: malformed
    mov     r7, r4
    cmp     r7, #0x8000
    movhi   r7, #0x8000
    sub     r4, r4, r7
    add     r6, sp, #0x410
    bl      Lwrite
    cmp     r0, #0
    bne     Lfail3c
    b       Lcopy
Lcopied:
    mov     r0, r8
    ldr     r1, [sp, #4]
    mov     r12, #124           @ SYS_fchmod: open's mode went through the umask
    svc     #0x80
    mov     r0, r8
    mov     r1, r9
    mov     r2, r10
    mov     r12, #123           @ SYS_fchown
    svc     #0x80
    mov     r0, r8
    mov     r12, #6             @ SYS_close
    svc     #0x80
    ldr     r7, [sp, #12]       @ the padding after the data: (-length) & 3
    rsb     r7, r7, #0
    and     r7, r7, #3
    mov     r6, sp
    bl      Lread
    cmp     r0, #0
    bne     Lfail2
    b       Lrecord

Lend:
    mov     r0, r11
    mov     r12, #6             @ SYS_close
    svc     #0x80
    ldr     r0, [r5, #12]
    mov     r12, #10            @ SYS_unlink: the archive has done its job
    svc     #0x80
    mov     r12, #36            @ SYS_sync: one flush for the whole bundle
    svc     #0x80
    mov     r0, #0
Lexit:
    mov     r12, #1             @ SYS_exit
    svc     #0x80
    b       Lexit
Lbadargs:
    mov     r0, #1
    b       Lexit
Lfail2:
    mov     r0, #2
    b       Lexit
Lfail2c:
    mov     r0, r8
    mov     r12, #6             @ SYS_close
    svc     #0x80
    b       Lfail2
Lfail3c:
    mov     r0, r8
    mov     r12, #6             @ SYS_close
    svc     #0x80
Lfail3:
    mov     r0, #3
    b       Lexit

@ Read exactly r7 bytes from the archive (r11) into r6. r0 = 0, or 1 on an error or an early end.
Lread:
    cmp     r7, #0
    beq     1f
    mov     r0, r11
    mov     r1, r6
    mov     r2, r7
    mov     r12, #3             @ SYS_read
    svc     #0x80
    bcs     2f
    cmp     r0, #0
    beq     2f
    add     r6, r6, r0
    sub     r7, r7, r0
    b       Lread
1:  mov     r0, #0
    bx      lr
2:  mov     r0, #1
    bx      lr

@ Write exactly r7 bytes from r6 to the file (r8). r0 = 0, or 1 on an error.
Lwrite:
    cmp     r7, #0
    beq     1f
    mov     r0, r8
    mov     r1, r6
    mov     r2, r7
    mov     r12, #4             @ SYS_write
    svc     #0x80
    bcs     2f
    cmp     r0, #0
    ble     2f
    add     r6, r6, r0
    sub     r7, r7, r0
    b       Lwrite
1:  mov     r0, #0
    bx      lr
2:  mov     r0, #1
    bx      lr

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
