;==============================================================================
; rss.asm - MSX RSS reader: PicoAmp's news reader on its own, for any MSX with
; a TCP/IP UNAPI network (TLS for https: TCP/IP UNAPI 1.1), and openMSX.
;
;   RSS.COM  MSX-DOS 1 / 2, Nextor:   sjasmplus --raw=RSS.COM rss.asm
;   RSS.ROM  a 32 KB cartridge:       sjasmplus -DROMBUILD --raw=RSS.ROM rss.asm
;            (it starts when the disk is ready, so RSS.INI can be read)
;
; Memory: the program (COM at 0100h, ROM at 4000h-BFFFh), its variables in
; page 2 (COM) or 3 (ROM) - what goes to the network is never in page 1 -
; and the stories and the article in VRAM.
;
; This work is licensed under a "Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
; License". https://creativecommons.org/licenses/by-nc-sa/4.0/
;==============================================================================

        IFDEF ROMBUILD
VARS    equ #C000
        ELSE
VARS    equ #8000
        ENDIF
vp = VARS
        macro VAR _vn, _vs
_vn equ vp
vp = vp + _vs
        endm

        IFDEF ROMBUILD
        org #4000
        db "AB"
        dw rom_init
        dw 0,0,0
        ds 6

; the BIOS: our slot into H.STKE (run when BASIC starts: the disk is ready)
rom_init:
        in a,(#A8)
        rrca
        rrca
        and 3
        ld c,a
        ld b,0
        ld hl,EXPTBL
        add hl,bc
        ld a,(hl)
        and #80
        jr z,.p
        or c
        ld c,a
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)
        and #0C
        or c
        ld c,a
.p:     ld hl,H_STKE
        ld (hl),#F7             ; RST 30h (CALLF) slot, rom_start
        inc hl
        ld (hl),c
        inc hl
        ld (hl),low rom_start
        inc hl
        ld (hl),high rom_start
        inc hl
        ld (hl),#C9
        ret

rom_start:
        ld a,(H_STKE+1)         ; (our slot)
        ld hl,H_STKE
        ld b,5
.c:     ld (hl),#C9
        inc hl
        djnz .c
        ld c,a
        ; BASIC's stack may be where our variables go: 256 bytes of it kept
        ; below HIMEM, our stack under HIMEM; all back at the end
        ld hl,(HIMEM)
        ld de,-768
        add hl,de               ; HL = where it is kept
        push hl
        ld de,VARS_END+32
        or a
        sbc hl,de
        pop de
        jp c,.small             ; (no room: BASIC)
        ld ix,0
        add ix,sp
        push ix
        pop hl
        push bc
        ld bc,256
        ldir                    ; (the stack's top 256 bytes, with this push)
        pop bc
        ld hl,-256              ; (DE = after the copy)
        add hl,de
        ld sp,(HIMEM)
        push ix                 ; the old stack
        push hl                 ; the copy (HIMEM - 768)
        push bc
        call vars_clear
        pop bc
        pop hl
        ld (rom_sa),hl
        pop hl
        ld (rom_sp),hl
        ld a,c
        ld (rom_slot),a
        ; page 2: ours too (it is RAM for BASIC: back at the end)
        in a,(#A8)
        rrca
        rrca
        rrca
        rrca
        and 3
        ld e,a                  ; its primary slot
        ld d,0
        ld hl,EXPTBL
        add hl,de
        ld a,(hl)
        and #80
        jr z,.np
        or e
        ld e,a
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)
        rrca
        rrca
        and #0C
        or e
        ld e,a
.np:    ld a,e
        ld (rom_p2),a
        ld a,(rom_slot)
        ld h,#80
        call #0024              ; ENASLT
        ei
        ld a,(H_PHYD)           ; a disk?
        cp #C9
        ld a,0
        jr z,.nd
        inc a
.nd:    ld (has_disk),a
        call main
        ld a,(rom_p2)
        ld h,#80
        call #0024
        di
        ld hl,(rom_sa)          ; BASIC's stack as it was
        ld de,(rom_sp)
        ld bc,256
        ldir
        ld sp,(rom_sp)
        ei
        ret
.small: ld hl,txt_small
.m:     ld a,(hl)
        or a
        ret z
        push hl
        call #00A2              ; CHPUT
        pop hl
        inc hl
        jr .m
txt_small: db "RSS reader: not enough memory under HIMEM",13,10,0
        VAR rom_slot, 1
        VAR rom_p2, 1
        VAR rom_sp, 2
        VAR rom_sa, 2

        ELSE
        org #100
        ld hl,(6)               ; room for the variables and a stack?
        ld de,VARS_END+400
        or a
        sbc hl,de
        jr c,.small
        call vars_clear
        ld a,1
        ld (has_disk),a
        call main
        ret
.small: ld de,txt_small
        ld c,9
        jp 5
txt_small: db "Not enough memory for the RSS reader",13,10,"$"
        ENDIF

vars_clear:
        ld hl,VARS
        ld de,VARS+1
        ld bc,VARS_END-VARS-1
        ld (hl),0
        ldir
        ret

main:   call sys_init
        call mem_init
        call scr_open
        ld hl,txt_start
        ld de,#0A02
        ld b,40
        call tx_text
        call net_init
        call ini_load
        call ui_start
.loop:  call clk_tick
        call http_poll
        ld (m_data),a
        call news_poll
        call ui_tick
        call getkey
        or a
        call nz,ui_key
        ld a,(quit)
        or a
        jr nz,.end
        ld a,(m_data)
        or a
        jr nz,.loop             ; (data came: no waiting)
        call http_busy
        jr z,.idle
        call net_wait
        jr .loop
.idle:  ei
        halt
        jr .loop
.end:   call http_stop
        jp scr_close
        VAR m_data, 1
txt_start: db "Looking for the network...",0

        include "sys.asm"
        include "net.asm"
        include "parse.asm"
        include "text.asm"
        include "feeds.asm"
        include "ui.asm"
        include "cat.inc"
code_end:
VARS_END equ vp

        IFDEF ROMBUILD
        ASSERT code_end <= #C000
        ds #C000-code_end, #FF
        ELSE
        ASSERT code_end <= VARS
        ENDIF
        ASSERT vp <= VARS+#3000
        display "code ends at ",/H,code_end,", variables end at ",/H,vp
