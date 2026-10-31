;==============================================================================
; sys.asm - the machine: BIOS calls, the VDP (text, VRAM), keys, numbers,
; strings and the clock.
;==============================================================================

RDSLT   equ #000C
CALSLT  equ #001C
INITXT  equ #006C
CHSNS   equ #009C
CHGET   equ #009F
BEEP    equ #00C0
KILBUF  equ #0156
LINL40  equ #F3AE
CLIKSW  equ #F3DB
FORCLR  equ #F3E9
BAKCLR  equ #F3EA
BDRCLR  equ #F3EB
ARG     equ #F847
HOKVLD  equ #FB20
HIMEM   equ #FC4A
JIFFY   equ #FC9E
EXPTBL  equ #FCC1
H_STKE  equ #FEDA
H_PHYD  equ #FFA7
EXTBIO  equ #FFCA
VDP_D   equ #98
VDP_A   equ #99

        macro BIOS addr
        ld iy,(EXPTBL-1)
        ld ix,addr
        call CALSLT
        endm

TX_HL   equ 1                   ; our characters: a horizontal line,
TX_VL   equ 2                   ; a vertical one,
TX_BLK  equ 3                   ; a block,
TX_DOT  equ 4                   ; a dot

        VAR msx2, 1             ; 0 MSX1 (TEXT 1, 40x24), else TEXT 2 (80x26)
        VAR msxver, 1
        VAR intl, 1             ; the international character set (accents)
        VAR hz, 1
        VAR sw, 1               ; the screen: columns, rows
        VAR sh, 1
        VAR l_nl, 1             ; the layout: headline rows,
        VAR l_h1, 1             ; the line under them,
        VAR l_sum, 1            ; the summary's first row,
        VAR l_h2, 1             ; the line under it,
        VAR l_k1, 1             ; the first key row,
        VAR l_ns, 1             ; story text rows,
        VAR l_st, 1             ; the story's status row,
        VAR l_nf, 1             ; My feeds rows
        VAR old_l40, 1
        VAR old_fc, 3
        VAR old_click, 1
        VAR lbb, 100            ; a row read back (MSX1 bars)
        VAR blb, 10             ; a row's blink bits
        VAR bx_row, 1           ; a row with a second bar (the credits; FFh: none),
        VAR bx_e, 1             ; its first cell,
        VAR bx_b, 1             ; its cells

; A = a byte of the main ROM at HL
rd_main:
        ld a,(EXPTBL)
        call RDSLT
        ei
        ret

; the machine and the screen's layout
sys_init:
        ld hl,#002D
        call rd_main
        ld (msxver),a
        ld (msx2),a
        ld hl,#002B
        call rd_main
        ld b,a
        ld c,60
        bit 7,a
        jr z,.hz
        ld c,50
.hz:    ld a,c
        ld (hz),a
        ld a,b                  ; character set 1: international (MSX2 and up)
        and #0F
        cp 1
        ld a,0
        jr nz,.cs
        ld a,(msx2)
        or a
        jr z,.cs
        ld a,1
.cs:    ld (intl),a
        ld a,(msx2)
        or a
        ld hl,80+26*256
        jr nz,.g
        ld hl,40+24*256
.g:     ld (sw),hl
        ld a,h                  ; headlines: SH-9 rows from row 2
        sub 9
        ld (l_nl),a
        add a,2
        ld (l_h1),a
        inc a
        ld (l_sum),a
        add a,3
        ld (l_h2),a
        ld a,h
        sub 2
        ld (l_k1),a
        dec a
        ld (l_st),a
        ld a,h
        sub 8
        ld (l_ns),a
        ld a,h
        sub 6
        ld (l_nf),a
        ret

; the screen: TEXT 2 (212 lines: 26 rows, the bars in the blink colours) or TEXT 1
scr_open:
        ld a,(LINL40)
        ld (old_l40),a
        ld hl,FORCLR
        ld de,old_fc
        ld bc,3
        ldir
        ld a,(CLIKSW)
        ld (old_click),a
        xor a
        ld (CLIKSW),a
        ld a,15
        ld (FORCLR),a
        ld a,4
        ld (BAKCLR),a
        ld (BDRCLR),a
        ld a,(sw)
        ld (LINL40),a
        BIOS INITXT
        ei
        ld a,(msx2)
        or a
        jr z,.t1
        ld a,#2F                ; blink bits at 0A00h (after the 27 rows' names)
        ld b,3
        call vreg
        xor a
        ld b,10
        call vreg
        ld a,#F4
        ld b,7
        call vreg
        ld a,#47                ; the bars: dark blue on cyan
        ld b,12
        call vreg
        ld a,#F0                ; the blink colours all the time
        ld b,13
        call vreg
        ld a,(#FFE8)            ; RG9SAV: 212 lines
        or #80
        ld b,9
        call vreg
        ld hl,#1000+TX_HL*8
        call scr_glyphs
        jp tx_cls
.t1:    ld hl,#0800+TX_HL*8
        call scr_glyphs
        ; the characters 128-255: 0-127 inverted (the bars)
        ld hl,#0800
.inv:   push hl
        ld de,lbb
        ld bc,8
        call vr_blk
        ld hl,lbb
        ld b,8
.i2:    ld a,(hl)
        cpl
        ld (hl),a
        inc hl
        djnz .i2
        pop hl
        push hl
        ld bc,#0400
        add hl,bc
        ld de,lbb
        ld bc,8
        call vw_blk
        pop hl
        ld bc,8
        add hl,bc
        ld a,h
        cp #0C
        jr c,.inv
        jp tx_cls

scr_glyphs:
        ld de,glyphs
        ld bc,4*8
        jp vw_blk

glyphs: db 0,0,0,#FC,0,0,0,0                    ; TX_HL
        db #20,#20,#20,#20,#20,#20,#20,#20      ; TX_VL
        db #FC,#FC,#FC,#FC,#FC,#FC,#FC,#FC      ; TX_BLK
        db 0,0,0,#30,#30,0,0,0                  ; TX_DOT

; leaving: the screen as it was
scr_close:
        ld a,(msx2)
        or a
        jr z,.t
        xor a
        ld b,13
        call vreg
.t:     ld hl,old_fc
        ld de,FORCLR
        ld bc,3
        ldir
        ld a,(old_click)
        ld (CLIKSW),a
        ld a,(old_l40)
        ld (LINL40),a
        BIOS INITXT
        ei
        ret

; vreg: A = value, B = register
vreg:   di
        out (VDP_A),a
        ld a,b
        or #80
        out (VDP_A),a
        ei
        ret

; the VRAM address HL (0-FFFFh) to write (vset_w) or read (vset_r); interrupts off; A
vset_w: ld a,#40
        jr vset
vset_r: xor a
vset:   di
        push bc
        ld c,a
        ld a,(msx2)
        or a
        jr z,.lo
        ld a,h                  ; R14: A14-A16
        rlca
        rlca
        and 3
        out (VDP_A),a
        ld a,#8E
        out (VDP_A),a
.lo:    ld a,l
        out (VDP_A),a
        ld a,h
        and #3F
        or c
        out (VDP_A),a
        pop bc
        ret

; vw_blk: BC bytes from DE (RAM) to HL (VRAM)
vw_blk: ld a,b
        or c
        jr z,.e
        call vset_w
.l:     ld a,(de)
        out (VDP_D),a
        inc de
        inc hl
        dec bc
        ld a,b
        or c
        jr z,.e
        ld a,l
        or a
        jr nz,.l
        ld a,h
        and #3F
        jr nz,.l
        call vset_w             ; (a new 16 KB)
        jr .l
.e:     ei
        ret

; vr_blk: BC bytes from HL (VRAM) to DE (RAM)
vr_blk: ld a,b
        or c
        jr z,.e
        call vset_r
.l:     in a,(VDP_D)
        ld (de),a
        inc de
        inc hl
        dec bc
        ld a,b
        or c
        jr z,.e
        ld a,l
        or a
        jr nz,.l
        ld a,h
        and #3F
        jr nz,.l
        call vset_r
        jr .l
.e:     ei
        ret

; vr_get: the byte at HL (read address set before), HL + 1 (interrupts stay off)
vr_get: in a,(VDP_D)
        inc hl
        push af
        ld a,l
        or a
        jr nz,.r
        ld a,h
        and #3F
        call z,vset_r
.r:     pop af
        ret

; vfill: BC bytes of A from HL
vfill:  push af
        call vset_w
        pop af
        ld e,a
.f:     ld a,e
        out (VDP_D),a
        dec bc
        ld a,b
        or c
        jr nz,.f
        ei
        ret

;------------------------------------------------------------------------------
; text: D = row, E = column

tx_at:  ld l,d                  ; HL = row * width + column, to write
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        push hl
        add hl,hl
        add hl,hl
        pop bc
        add hl,bc               ; * 40
        ld a,(sw)
        cp 80
        jr nz,.n
        add hl,hl
.n:     ld c,e
        ld b,0
        add hl,bc
        jp vset_w

; tx_text: HL = text at D, E, B wide (spaces after it); HL after what was shown
tx_text:
        push hl
        push bc
        call tx_at
        pop bc
        pop hl
.c:     ld a,(hl)
        or a
        jr z,.pad
        out (VDP_D),a
        inc hl
        djnz .c
        ei
        ret
.pad:   ld a,' '
.p:     out (VDP_D),a
        djnz .p
        ei
        ret

; tx_fill: B cells from D, E with A
tx_fill:
        push af
        push bc
        call tx_at
        pop bc
        pop af
.f:     out (VDP_D),a
        djnz .f
        ei
        ret

tx_hline:                       ; row D: a line across
        ld e,0
        ld a,(sw)
        ld b,a
        ld a,TX_HL
        jr tx_fill

tx_clrrow:                      ; row D: empty
        ld e,0
        ld a,(sw)
        ld b,a
        ld a,' '
        jr tx_fill

tx_cls: ld a,#FF                ; all of it, and no bars
        ld (bx_row),a
        ld hl,0
        ld bc,80*27
        ld a,(msx2)
        or a
        jr nz,.c
        ld bc,40*24
.c:     ld a,' '
        call vfill
        ld a,(msx2)
        or a
        ret z
        ld hl,#0A00
        ld bc,270
        xor a
        jp vfill

; tx_bar: row D, the cells E.. (B of them) as the bar, the rest of the row not (B = 0: none)
tx_bar: ld a,(msx2)
        or a
        jr z,tx_bar1
        push de
        push bc
        ld hl,blb
        ld b,10
        xor a
.z:     ld (hl),a
        inc hl
        djnz .z
        pop bc
        pop de
        call bar_set
        ld a,(bx_row)           ; the credits' row: their bar too
        cp d
        jr nz,.out
        push de
        ld a,(bx_e)
        ld e,a
        ld a,(bx_b)
        ld b,a
        call bar_set
        pop de
.out:   ld l,d                  ; 0A00h + row * 10
        ld h,0
        add hl,hl
        ld c,l
        ld b,h
        add hl,hl
        add hl,hl
        add hl,bc
        ld bc,#0A00
        add hl,bc
        ld de,blb
        ld bc,10
        jp vw_blk
; bar_set: the cells E.. (B of them) in blb
bar_set:
        ld a,b
        or a
        ret z
.s:     ld a,e
        rrca
        rrca
        rrca
        and #1F
        ld hl,blb
        call add_hla
        ld a,e
        and 7
        push hl
        ld hl,bits
        call add_hla
        ld a,(hl)
        pop hl
        or (hl)
        ld (hl),a
        inc e
        djnz .s
        ret
; MSX1: the row read back, the bar's cells inverted (characters 128-255)
tx_bar1:
        push de
        push bc
        ld e,0
        call tx_at
        ld de,lbb
        ld bc,40
        call vr_blk
        pop bc
        pop de
        ld hl,lbb
        push de
        ld c,40
.z:     res 7,(hl)
        inc hl
        dec c
        jr nz,.z
        pop de
        push de
        call .set
        pop de
        ld a,(bx_row)
        cp d
        jr nz,.w
        push de
        ld a,(bx_e)
        ld e,a
        ld a,(bx_b)
        ld b,a
        call .set
        pop de
.w:     ld e,0
        call tx_at
        ld hl,lbb
        ld bc,40*256+VDP_D
        otir
        ei
        ret
.set:   ld a,b                  ; cells E.. (B of them) inverted
        or a
        ret z
        ld hl,lbb
        ld a,e
        call add_hla
.i:     set 7,(hl)
        inc hl
        djnz .i
        ret

bits:   db #80,#40,#20,#10,#08,#04,#02,#01

;------------------------------------------------------------------------------
; keys: A = the key (0: none)
getkey: BIOS CHSNS
        ei
        ld a,0
        ret z
        BIOS CHGET
        ei
        ret

beep:   BIOS BEEP
        ei
        ret

;------------------------------------------------------------------------------
; numbers and strings

add_hla:                        ; HL += A (DE, BC kept)
        add a,l
        ld l,a
        ret nc
        inc h
        ret

; strcpy: HL to DE with its 0; DE at the 0, HL after it
strcpy: ld a,(hl)
        ld (de),a
        inc hl
        or a
        ret z
        inc de
        jr strcpy

; strncpy: as strcpy, at most B characters (then a 0)
strncpy:
        ld a,(hl)
        or a
        jr z,.e
        ld (de),a
        inc hl
        inc de
        djnz strncpy
.e:     xor a
        ld (de),a
        ret

; strlen: HL -> BC
strlen: push hl
        ld bc,0
.l:     ld a,(hl)
        or a
        jr z,.e
        inc hl
        inc bc
        jr .l
.e:     pop hl
        ret

; skipz: HL after the next 0
skipz:  ld a,(hl)
        inc hl
        or a
        jr nz,skipz
        ret

; nth: HL = strings, A = n -> HL = the n-th
nth:    or a
        ret z
        ld b,a
.n:     call skipz
        djnz .n
        ret

; putc: A to (DE)
putc:   ld (de),a
        inc de
        ret

; fmt_u16: HL in decimal to DE (DE after it, no 0)
        VAR fu_out, 2
fmt_u16:
        push bc
        ld (fu_out),de
        ld b,0
        ld de,10000
        call .d
        ld de,1000
        call .d
        ld de,100
        call .d
        ld de,10
        call .d
        ld a,l
        add a,'0'
        ld de,(fu_out)
        ld (de),a
        inc de
        pop bc
        ret
.d:     ld a,'0'-1
.s:     inc a
        or a
        sbc hl,de
        jr nc,.s
        add hl,de
        cp '0'
        jr nz,.p
        inc b
        dec b
        ret z
.p:     ld b,1
        push de
        ld de,(fu_out)
        ld (de),a
        inc de
        ld (fu_out),de
        pop de
        ret

; put2: A (0-99) as two digits to DE
put2:   ld b,'0'-1
.t:     inc b
        sub 10
        jr nc,.t
        add a,'0'+10
        ld c,a
        ld a,b
        ld (de),a
        inc de
        ld a,c
        ld (de),a
        inc de
        ret

; div16: HL / DE -> HL, the rest in DE
div16:  push bc
        ld a,h
        ld c,l
        ld hl,0
        ld b,16
.l:     sla c
        rla
        adc hl,hl
        sbc hl,de
        jr nc,.n
        add hl,de
        jr .x
.n:     inc c
.x:     djnz .l
        ex de,hl
        ld h,a
        ld l,c
        pop bc
        ret

; mul16: HL * DE -> HL (the low 16 bits)
mul16:  push bc
        ld b,h
        ld c,l
        ld hl,0
        ld a,16
.l:     add hl,hl
        ex de,hl
        add hl,hl
        ex de,hl
        jr nc,.n
        add hl,bc
.n:     dec a
        jr nz,.l
        pop bc
        ret

; num: a decimal number at HL -> DE (HL after it), CF: no digit
num:    ld de,0
        ld a,(hl)
        sub '0'
        cp 10
        ccf
        ret c
.l:     ld a,(hl)
        sub '0'
        cp 10
        jr nc,.e
        inc hl
        push hl
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        ld e,a
        ld d,0
        add hl,de
        ex de,hl
        pop hl
        jr .l
.e:     or a
        ret

skipsp: ld a,(hl)               ; HL past the spaces
        cp ' '
        ret nz
        inc hl
        jr skipsp

neg_hl: ld a,h                  ; HL = -HL
        cpl
        ld h,a
        ld a,l
        cpl
        ld l,a
        inc hl
        ret

lc:     cp 'A'                  ; A in lower case
        ret c
        cp 'Z'+1
        ret nc
        add a,32
        ret

;------------------------------------------------------------------------------
; the clock: UTC from the web's Date headers, counted on by the interrupts;
; the local time from the MSX2's clock chip (its difference to UTC) or tz= in RSS.INI

        VAR clk_ok, 1           ; the time is known
        VAR clk_days, 2         ; days since 1970
        VAR clk_min, 2          ; minutes of the day (UTC)
        VAR clk_sec, 1
        VAR clk_frac, 1
        VAR clk_last, 2
        VAR tz_min, 2           ; local - UTC (minutes)
        VAR tz_set, 1           ; 1 from RSS.INI, 2 from the clock chip
        VAR pd_days, 2          ; parse_date's result
        VAR pd_min, 2
        VAR pd_sec, 1
        VAR dc_y, 2             ; days_civ's
        VAR dc_m, 1
        VAR dc_d, 1
        VAR dc_wd, 1

clk_tick:
        ld hl,(JIFFY)
        ld de,(clk_last)
        ld (clk_last),hl
        or a
        sbc hl,de
        ld a,(clk_ok)
        or a
        ret z
        ld a,h                  ; (a long time: at most 255)
        or a
        ld a,l
        jr z,.a
        ld a,255
.a:     ld hl,clk_frac
        add a,(hl)
        jr nc,.n
        ld a,255
.n:     ld (hl),a
.s:     ld a,(hz)
        ld b,a
        ld a,(clk_frac)
        sub b
        ret c
        ld (clk_frac),a
        ld a,(clk_sec)
        inc a
        ld (clk_sec),a
        cp 60
        jr c,.s
        xor a
        ld (clk_sec),a
        ld hl,(clk_min)
        inc hl
        ld (clk_min),hl
        ld de,1440
        or a
        sbc hl,de
        jr c,.s
        ld (clk_min),hl
        ld hl,(clk_days)
        inc hl
        ld (clk_days),hl
        jr .s

; the time from a Date header (pd_xxx): set; the clock chip's difference to it, once
clk_set:
        ld hl,(pd_days)
        ld (clk_days),hl
        ld hl,(pd_min)
        ld (clk_min),hl
        ld a,(pd_sec)
        ld (clk_sec),a
        xor a
        ld (clk_frac),a
        ld hl,(JIFFY)
        ld (clk_last),hl
        ld a,1
        ld (clk_ok),a
        ld a,(tz_set)
        or a
        ret nz
        ld a,(msx2)
        or a
        ret z
        call rtc_read           ; local days, minutes (CF: not set)
        ret c
        ld a,2
        ld (tz_set),a
        ; (local - UTC) in minutes: (days difference) * 1440 + minutes difference
        push de
        ld de,(clk_days)
        or a
        sbc hl,de               ; days difference (-1, 0, 1 makes sense)
        pop de
        ex de,hl                ; HL = local minutes, DE = days difference
        ld bc,(clk_min)
        or a
        sbc hl,bc
        ld a,e
        or a
        jr z,.r
        ld bc,1440
        cp 1
        jr z,.p
        inc a
        jr nz,.no
        or a
        sbc hl,bc
        jr .r
.p:     add hl,bc
.r:     ; to 15 minutes, and within 14 hours
        bit 7,h
        push af
        jr z,.pos
        call neg_hl
.pos:   ld bc,7
        add hl,bc
        ld de,15
        call div16
        ld de,15
        call mul16
        pop af
        call nz,neg_hl
.pp:    push hl
        bit 7,h
        jr z,.ab
        ld a,h
        cpl
        ld h,a
        ld a,l
        cpl
        ld l,a
.ab:    ld de,14*60+1
        or a
        sbc hl,de
        pop hl
        jr nc,.no
        ld (tz_min),hl
        ret
.no:    ld hl,0
        ld (tz_min),hl
        ret

        VAR rtc_mi, 1
        VAR rtc_h, 1
        VAR rtc_d, 1
        VAR rtc_m, 1
; rtc_read: the MSX2's clock chip -> HL = days since 1970, DE = minutes (CF: not set)
rtc_read:
        ld a,13                 ; block 0
        out (#B4),a
        in a,(#B5)
        and #0C
        out (#B5),a
        ld c,0
        call .r2                ; (seconds)
        call .r2
        ld (rtc_mi),a
        call .r2
        ld (rtc_h),a
        call .r1                ; (weekday)
        call .r2
        ld (rtc_d),a
        call .r2
        ld (rtc_m),a
        call .r2
        add a,80                ; from 1980
        ld l,a
        ld h,0
        ld de,1900
        add hl,de
        ld (dc_y),hl
        ld de,2020
        or a
        sbc hl,de
        ret c                   ; (not set)
        ld a,(rtc_m)
        ld (dc_m),a
        ld a,(rtc_d)
        ld (dc_d),a
        call days_civ_in
        ret c
        push hl
        ld a,(rtc_h)
        ld l,a
        ld h,0
        ld de,60
        call mul16
        ld a,(rtc_mi)
        call add_hla
        ex de,hl
        pop hl
        or a
        ret
.r1:    ld a,c                  ; one register (4 bits)
        out (#B4),a
        in a,(#B5)
        and #0F
        inc c
        ret
.r2:    call .r1                ; two: units, tens
        ld b,a
        call .r1
        ld e,a
        add a,a
        add a,a
        add a,e
        add a,a
        add a,b
        ret

; local now: HL = days, DE = minutes of the day (local); CF: the time is not known
clk_local:
        ld a,(clk_ok)
        or a
        jr nz,.k
        ld a,(msx2)             ; (no web time yet: the clock chip)
        or a
        scf
        ret z
        jp rtc_read
.k:     ld hl,(clk_days)
        ld de,(clk_min)
        ; fall through
; to_local: HL days, DE minutes (UTC) -> local
to_local:
        push hl
        ex de,hl
        ld de,(tz_min)
        add hl,de
        ex de,hl
        pop hl
        bit 7,d
        jr z,.p
        dec hl                  ; before 0:00
        push hl
        ld hl,1440
        add hl,de
        ex de,hl
        pop hl
        or a
        ret
.p:     push hl
        ex de,hl
        ld de,1440
        or a
        sbc hl,de
        ex de,hl
        pop hl
        jr nc,.n
        push hl                 ; (it was below 1440)
        ld hl,1440
        add hl,de
        ex de,hl
        pop hl
        or a
        ret
.n:     inc hl
        or a
        ret

; days_civ_in: dc_y, dc_m, dc_d -> HL = days since 1970 (CF: out of range)
days_civ_in:
        ld hl,(dc_y)
        ld de,1970
        or a
        sbc hl,de
        ret c
        ld a,h
        or a
        scf
        ret nz
        ld a,l
        cp 130                  ; (to 2099)
        ccf
        ret c
        ld a,(dc_m)
        dec a
        cp 12
        ccf
        ret c
        ld a,(dc_d)
        dec a
        cp 31
        ccf
        ret c
        push hl                 ; years * 365 + (years + 1) / 4
        ld de,365
        call mul16
        ex de,hl
        pop hl
        inc hl
        srl h
        rr l
        srl h
        rr l
        add hl,de
        ld a,(dc_m)
        dec a
        add a,a
        ld de,cum_days
        add a,e
        ld e,a
        jr nc,.c
        inc d
.c:     ld a,(de)
        ld c,a
        inc de
        ld a,(de)
        ld b,a
        add hl,bc
        ld a,(dc_m)             ; a leap year after February
        cp 3
        jr c,.d
        ld a,(dc_y)
        and 3
        jr nz,.d
        inc hl
.d:     ld a,(dc_d)
        dec a
        call add_hla
        or a
        ret
cum_days:
        dw 0,31,59,90,120,151,181,212,243,273,304,334

        VAR dc_leap, 1
; days_civ: HL = days since 1970 -> dc_y, dc_m, dc_d, dc_wd (0 Monday)
days_civ:
        push hl
        ld de,7                 ; 1970-01-01 was a Thursday
        inc hl
        inc hl
        inc hl
        call div16
        ld a,e
        ld (dc_wd),a
        pop hl
        ld de,1970
.y:     ld bc,365
        ld a,e
        and 3
        jr nz,.ny
        inc bc
.ny:    push hl
        or a
        sbc hl,bc
        jr c,.yd
        pop af
        inc de
        jr .y
.yd:    pop hl
        ld (dc_y),de
        ld a,e
        and 3
        ld (dc_leap),a
        ld b,0                  ; the month
        ld ix,mdays
.m:     ld a,(ix)
        ld c,a
        ld a,b
        cp 1
        jr nz,.nm
        ld a,(dc_leap)
        or a
        jr nz,.nm
        inc c
.nm:    ld a,h
        or a
        jr nz,.sub
        ld a,l
        cp c
        jr c,.md
.sub:   ld a,l
        sub c
        ld l,a
        jr nc,.s2
        dec h
.s2:    inc b
        inc ix
        jr .m
.md:    inc b
        ld a,b
        ld (dc_m),a
        ld a,l
        inc a
        ld (dc_d),a
        ret
mdays:  db 31,28,31,30,31,30,31,31,30,31,30,31

; date text: HL = days, DE = minutes (local) -> DE text "Fri 30 Oct 2026 09:53" (long, A=1)
; or "30 Oct" (A=0); to (IX)... : the text at fmt_buf
        VAR fmt_buf, 32
fmt_date:
        push de
        push af
        call days_civ
        pop af
        ld de,fmt_buf
        or a
        jr z,.sh
        ld a,(dc_wd)
        ld hl,wdays
        call nth
        call strcpy
        ld a,' '
        call putc
        ld a,(dc_d)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,' '
        call putc
        call .mon
        ld a,' '
        call putc
        ld hl,(dc_y)
        call fmt_u16
        ld a,' '
        call putc
        pop hl
        call fmt_hm
        xor a
        ld (de),a
        ret
.sh:    pop hl
        ld a,(dc_d)
        cp 10
        jr nc,.d2
        ld a,' '
        call putc
.d2:    ld a,(dc_d)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,' '
        call putc
        call .mon
        xor a
        ld (de),a
        ret
.mon:   ld a,(dc_m)
        dec a
        ld hl,months
        call nth
        jp strcpy

; fmt_hm: HL = minutes of the day -> "09:53" to DE
fmt_hm: push de
        ld de,60
        call div16
        ld a,e
        pop de
        push af
        ld a,l
        call put2
        ld a,':'
        call putc
        pop af
        jp put2

wdays:  db "Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0,"Sun",0
months: db "Jan",0,"Feb",0,"Mar",0,"Apr",0,"May",0,"Jun",0,"Jul",0,"Aug",0,"Sep",0,"Oct",0,"Nov",0,"Dec",0
