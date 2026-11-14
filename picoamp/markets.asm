;==============================================================================
; markets.asm - PICOAMP's market monitor: a page module (see clock.asm), in
; SCREEN 6 (512 x 212, 4 colours: navy, white, green, red) with 80 columns of
; our 6-pixel font, 26 rows. (The 80-column text mode has one colour pair
; besides its own, so it cannot show risers green and fallers red.)
;
; A list of instruments in two columns of 20: name, price, change, percent;
; the risers' change in green, the fallers' in red. The lists of a region (indices; currencies,
; commodities and rates; the shares of an index; My list from PICOAMP.INI),
; the regions Europe, Americas and Asia-Pacific. The day's course of the
; chosen instrument as a chart of columns. Row 0 has what plays and the time.
;
; The engine (0.13) does the work: it fetches the prices (Yahoo Finance,
; delayed), again every minute while the page shows, and gives each row as
; text and the chart as column heights. This page draws them.
;
; Keys: Left/Right the list, Up/Down choose, Enter the chart (there: Up/Down
; the next one, Enter/BS/ESC back), 1 2 3 the region, U update now. C clock,
; W weather, T news, $ or ESC the player; the playback keys keep working.
;==============================================================================

MV_TABLE equ 0
MV_CHART equ 1
MV_DEAD  equ 2                  ; nothing to show: only the keys that leave
MK_ROW0  equ 4                  ; the table's first row on the screen
MK_N     equ 20                 ; rows a column
MK_CW    equ 76                 ; the chart: columns (from screen column 2),
MK_CR    equ 15                 ; rows (from MK_ROW0),
MK_CL    equ MK_CR*8            ; levels
MX_HL    equ 1                  ; our characters: a horizontal line,
MX_NOTE  equ 4                  ; a note,
MX_PTR   equ 5                  ; the pointer,
MX_BAR   equ 7                  ; MX_BAR+n: a column's top, n lines high (1-8)
K_WHITE  equ #55                ; a cell's colour: the SCREEN 6 colour (1, 2, 3) in each
K_GREEN  equ #AA                ; of a byte's four dots
K_RED    equ #FF
G6_TAB   equ vizbuf             ; a glyph row (6 dots) as 12 bits: at 2g shifted 4 left
        assert (G6_TAB & #FF) = 0   ; (a pair's first), at 128+2g as they are (its second)
G6_G0    equ vizbuf+256         ; our 16 characters below 32, 8 rows each
G6_LB    equ vizbuf+384         ; a row being drawn: its 80 characters,
G6_CB    equ G6_LB+82           ; their colours (K_xxx),
G6_ST    equ vizbuf+640         ; their glyphs: 8 lines of 80 bytes
RG0SAV   equ #F3DF
CK_MST   equ 44                 ; the clock block: PVA_MKT_xxx of the open list,
CK_MGEN  equ 45                 ; +1 when its prices changed,
CK_MCH   equ 46                 ; PVA_MKT_xxx of the chart,
CK_MERR  equ 47                 ; the last error
C_MLISTS  equ #46
C_MREGION equ #47
C_MOPEN   equ #48
C_MROWS   equ #49
C_MINFO   equ #4A
C_MCHART  equ #4B
C_MCHGET  equ #4C
C_MMEMB   equ #4D
C_MNEWS   equ #4E
C_MSORT   equ #4F
C_MTAPE   equ #50
CH_W     equ 198                ; the chart's line: columns of 2 dots (from screen column 2),
CH_E     equ vizbuf+1792        ; for each level what an empty byte of its line shows (the scale's dots)
        assert (CH_E & #FF) = 0
CH_YCOL  equ 70                 ; the price scale's column,
CH_XROW  equ 19                 ; the time scale's row
RB_COL   equ 18                 ; the ranges' names in the key line
CH_LO    equ vizbuf+1024        ; for each column the levels it covers: from,
CH_HI    equ vizbuf+1280        ; to,
CH_K     equ vizbuf+1536        ; and its colour
        assert (CH_LO & #FF) = 0
MK_HROW  equ 20                 ; the chart's headlines: rows 20-23

mod_mk:
        jp mk_open              ; the jump table (M_OPEN ...)
        jp mk_tick
        jp mk_ret
        jp mk_keys
        jp mk_info
        jp mk_ret
        jp mk_leave

;------------------------------------------------------------------------------
; the screen: SCREEN 6 with 212 lines, its four colours from PICOAMP's palette
mk_open:
        ld a,(RG0SAV)           ; SCREEN 6: M5 (R#0), no M1 or M2 (R#1)
        and #F1
        or #08
        ld b,0
        call vreg
        ld a,(RG1SAV)
        and #E7
        ld b,1
        call vreg
        ld a,#1F                ; the picture from 0000h
        ld b,2
        call vreg
        xor a                   ; the border: colour 0
        ld b,7
        call vreg
        ld a,(RG8SAV)           ; no sprites
        or #02
        ld b,8
        call vreg
        ld a,(RG9SAV)           ; 212 lines: 26 rows
        or #80
        ld b,9
        call vreg
        xor a                   ; (VRAM above 16 KB: only while a row goes out)
        ld b,14
        call vreg
        xor a                   ; colours 0-3: navy, white, green, red
        ld b,16
        call vreg
        ld hl,mk_palix
        ld b,4
.p:     push bc
        ld a,(hl)
        inc hl
        push hl
        add a,a
        ld hl,palette
        call mk_add
        ld a,(hl)
        out (VDP_P),a
        inc hl
        ld a,(hl)
        out (VDP_P),a
        pop hl
        pop bc
        djnz .p
        call g6_init
        call g6_cls
        ld a,K_WHITE
        ld (mk_k),a
        ld a,#FF
        ld (mk_smin),a
        call mk_info
        ld d,1
        ld e,0
        ld b,80
        ld a,MX_HL
        call mk_fill
        ld a,(eng_minor)
        cp 13
        ld hl,txt_mk_old
        jr c,.dead
        call mk_lists
        ld hl,txt_mk_nowifi
        jr c,.dead
        ld a,(mk_last)          ; the list shown last time
        ld hl,mk_nl
        cp (hl)
        jr c,.l
        xor a
.l:     ld (mk_list),a
        ld e,#FF                ; the order the engine has
        ld a,C_MSORT
        call cmd_u8
        ld a,0
        jr c,.so
        jr nz,.so
        ld a,(reply)
.so:    ld (mk_sort),a
        call mk_openlist
        ld a,(mk_ksub)          ; an index's members were open then: again
        cp #FF
        jr z,.s
        ld e,a
        ld (mk_psel),a
        ld a,C_MMEMB
        call cmd_u8
        jr c,.s
        jr nz,.s
        ld a,(reply)
        ld (mk_n),a
        ld a,1
        ld (mk_sub),a
.s:     ld a,(mk_n)             ; and the row chosen then
        ld b,a
        ld a,(mk_ksel)
        cp b
        jr c,.s1
        xor a
.s1:    ld (mk_sel),a
        call mk_settop
        jp mk_back
.dead:  ld de,#0A02
        ld b,76
        call mk_text
        ld a,MV_DEAD
        ld (mk_view),a
        ld hl,txt_mk_kall
        ld de,#1900
        ld b,80
        jp mk_text

; leaving: the updates stop, SCREEN 4 again (and the settings to the card)
mk_leave:
        ld a,(mk_sel)           ; (where we were: for the next time)
        ld (mk_ksel),a
        ld a,(mk_sub)
        or a
        ld a,#FF
        jr z,.k
        ld a,(mk_psel)
.k:     ld (mk_ksub),a
        ld a,(eng_minor)
        cp 13
        jr c,.s
        ld e,#FF
        ld a,C_MOPEN
        call cmd_u8
.s:     ld a,(RG9SAV)
        ld b,9
        call vreg
        call screen_init
        ld a,(mk_dirty)
        or a
        ret z
        jp ini_save

mk_ret: ret

; g6_init: the tables for the rows' bytes, our characters
g6_init:
        ld ix,G6_TAB+128
        ld c,0                  ; C = a glyph row's 6 dots
.g:     ld a,c
        rlca
        rlca
        ld hl,0
        ld b,6
.b:     add hl,hl               ; each dot twice (2 bits a dot)
        add hl,hl
        rlca
        jr nc,.z
        inc l
        inc l
        inc l
.z:     djnz .b
        ld (ix+0),h             ; the 12 bits as they are: the table's second half
        ld (ix+1),l
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld (ix-128),h           ; and 4 to the left: its first half
        ld (ix-127),l
        inc ix
        inc ix
        inc c
        ld a,c
        cp 64
        jr c,.g
        ld hl,G6_G0             ; our characters: empty, the five of mk_glyphs from 1,
        ld b,128
        xor a
.e:     ld (hl),a
        inc hl
        djnz .e
        ld hl,mk_glyphs
        ld de,G6_G0+8
        ld bc,5*8
        ldir
        ld hl,G6_G0+(MX_BAR+1)*8 ; the columns' tops: n lines from the bottom
        ld c,1
.t:     ld b,8
.tl:    ld a,8
        sub b                   ; the line, 0 at the top
        add a,c
        cp 8
        ld a,0
        jr c,.te
        ld a,#7E
.te:    ld (hl),a
        inc hl
        djnz .tl
        inc c
        ld a,c
        cp 9
        jr c,.t
        ret

; g6_cls: all of the picture empty; mk_clear: rows 2 to 23
g6_cls: ld hl,0
        ld bc,#4000
        xor a
        call vfill
        ld bc,212*128-#4000
        jr g6_high
mk_clear:
        ld hl,mk_first          ; (no rows on the screen)
        ld b,2*MK_N
        xor a
.z:     ld (hl),a
        inc hl
        djnz .z
        ld hl,2*8*128
        ld bc,#4000-2*8*128
        xor a
        call vfill
        ld bc,24*8*128-#4000
g6_high:                        ; BC empty bytes from 4000h on (R#14 = 1 while they go)
        di
        ld a,1
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        xor a
        out (VDP_C),a
        ld a,#40
        out (VDP_C),a
.l:     xor a
        out (VDP_D),a
        dec bc
        ld a,b
        or c
        jr nz,.l
        xor a
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        ei
        ret

; g6_draw: row D, B pairs of cells from the even column E, from G6_LB (characters)
; and G6_CB (colours) to the screen. A pair is 24 dots: 3 bytes. First each
; character's 8 glyph rows go to G6_ST, a line of the picture after the other;
; then every line is put together and sent, at least 25 T-states a byte.
g6_draw:
        ld a,b
        or a
        ret z
        ld (g6_np),a
        ld a,e
        ld (g6_c0),a
        ld a,d
        ld (g6_row),a
        exx
        push bc
        push de
        push hl
        exx
        ld hl,G6_LB
        ld a,e
        call mk_add
        push hl
        pop ix                  ; IX = the characters
        ld a,(g6_np)
        add a,a
        ld b,a
        ld de,G6_ST
.ch:    push bc
        push de
        ld a,(ix+0)
        inc ix
        cp 32
        jr nc,.fo
        and 15                  ; one of ours
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,G6_G0
        jr .gp
.fo:    cp 128
        jr c,.f1
        ld a,'?'
.f1:    sub 32
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,font
.gp:    add hl,bc               ; HL = its glyph
        ld bc,80
        ld a,8
.cp:    ex af,af'
        ld a,(hl)
        ld (de),a
        inc hl
        ex de,hl
        add hl,bc
        ex de,hl
        ex af,af'
        dec a
        jr nz,.cp
        pop de
        inc de
        pop bc
        djnz .ch
        xor a
        ld (g6_s),a
.sl:    ld a,(g6_row)           ; the line's place: (row * 8 + s) * 128 + pairs before * 3
        add a,a
        add a,a
        add a,a
        ld hl,g6_s
        add a,(hl)
        ld hl,g6_yo             ; (and a few lines lower: the price scale's labels)
        add a,(hl)
        ld h,a
        ld l,0
        srl h
        rr l
        ld a,(g6_c0)
        srl a
        ld e,a
        add a,a
        add a,e
        ld e,a
        ld d,0
        add hl,de
        push hl
        ld a,(g6_s)             ; its glyph rows: G6_ST + s * 80
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de
        ld de,G6_ST
        add hl,de
        ex de,hl
        pop hl
        di
        ld a,h                  ; R#14: the address' bits 15-14
        rlca
        rlca
        and 3
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        ld a,l
        out (VDP_C),a
        ld a,h
        and #3F
        or #40
        out (VDP_C),a
        push de
        ld hl,G6_CB
        ld a,(g6_c0)
        call mk_add
        ex de,hl                ; DE = the colours
        pop hl                  ; HL = the glyph rows
        ld a,(g6_np)
        ld b,a
        exx
        ld h,G6_TAB/256
        exx
.pair:  ld a,(de)               ; the first cell: its colour, its 12 bits
        inc de
        ld c,a
        ld a,(hl)
        inc hl
        and #7E
        exx
        ld l,a
        ld d,(hl)
        inc l
        ld e,(hl)
        exx
        ld a,(hl)               ; the second cell's 12 bits
        inc hl
        and #7E
        or #80
        exx
        ld l,a
        ld b,(hl)
        inc l
        ld c,(hl)
        ld a,d
        exx
        and c
        out (VDP_D),a           ; 4 dots of the first
        exx
        ld a,e
        exx
        and c
        ld c,a
        ld a,(de)               ; the second cell's colour
        inc de
        exx
        ld d,a
        and b
        exx
        or c
        out (VDP_D),a           ; 2 dots of the first, 2 of the second
        exx
        ld a,c
        and d
        exx
        out (VDP_D),a           ; 4 dots of the second
        djnz .pair
        xor a
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        ei
        ld hl,g6_s
        inc (hl)
        ld a,(hl)
        cp 8
        jp c,.sl
        exx
        pop hl
        pop de
        pop bc
        exx
        ret

;------------------------------------------------------------------------------
; text: D = row, E = column

; mk_text: HL = text at D, E, B wide (E and B even; spaces after it), in the colour
; mk_k; HL on its 0 (or after B characters)
mk_text:
        push de
        push bc
        push hl
        ld hl,G6_LB
        ld a,e
        call mk_add
        ex de,hl
        pop hl
.c:     ld a,(hl)
        or a
        jr z,.pad
        ld (de),a
        inc hl
        inc de
        djnz .c
        jr .out
.pad:   ld a,' '
.p:     ld (de),a
        inc de
        djnz .p
.out:   pop bc
        pop de
        push hl
        call mk_paint
        srl b
        call g6_draw
        pop hl
        ret

; mk_fill: B cells from D, E with A (E and B even)
mk_fill:
        push de
        push bc
        ld c,a
        ld hl,G6_LB
        ld a,e
        call mk_add
.f:     ld (hl),c
        inc hl
        djnz .f
        pop bc
        pop de
        call mk_paint
        srl b
        jp g6_draw

; mk_paint: the cells E.. (B of them) get the colour mk_k (BC, DE kept)
mk_paint:
        push bc
        ld hl,G6_CB
        ld a,e
        call mk_add
        ld a,(mk_k)
.l:     ld (hl),a
        inc hl
        djnz .l
        pop bc
        ret

mk_add: add a,l                 ; HL += A (DE kept)
        ld l,a
        ret nc
        inc h
        ret

; mk_nth: HL = strings, A = n -> HL = the n-th
mk_nth: or a
        ret z
        ld b,a
.n:     ld a,(hl)
        inc hl
        or a
        jr nz,.n
        djnz .n
        ret

; mk_skip: HL after the string at HL
mk_skip:
        ld a,(hl)
        inc hl
        or a
        jr nz,mk_skip
        ret

;------------------------------------------------------------------------------
; row 0: what plays (its first 60 characters) and the time
mk_info:
        call pg_row0_text       ; HL = pg_t0
        ld hl,G6_LB             ; a note and a space
        ld (hl),MX_NOTE
        inc hl
        ld (hl),' '
        ld de,#0000
        ld b,2
        call mk_paint
        ld b,1
        call g6_draw
        ld hl,pg_t0
        ld de,#0002
        ld b,60
        call mk_text
        ; fall through
mk_clock:                       ; "Fri 30 Oct 09:53" at the right
        ld a,(ckb+CK_FLAGS)
        and CKF_TIME
        ret z
        ld de,mk_lb
        ld a,(ckb+CK_SEC+3)
        cp 7
        jr c,.w
        xor a
.w:     ld hl,mk_wd
        call mk_nth
        call strcpy
        ld a,' '
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+4)
        call put2
        ld a,' '
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+5)
        dec a
        cp 12
        jr c,.m
        xor a
.m:     ld hl,mk_mon
        call mk_nth
        call strcpy
        ld a,' '
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+2)
        call put2
        ld a,':'
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+1)
        call put2
        xor a
        ld (de),a
        ld hl,mk_lb
        ld de,#0040
        ld b,16
        jp mk_text

;------------------------------------------------------------------------------
; each pass: the clock; new prices, another state; the chart coming in
mk_tick:
        ld a,(mk_view)          ; the table: the tape of headlines in row 1, a character on
        or a                    ; every 8 interrupts
        jr nz,.nt
        ld hl,(JIFFY)
        ld de,(mk_tdue)
        or a
        sbc hl,de
        ld de,8
        sbc hl,de
        jr c,.nt
        ld hl,(JIFFY)
        ld (mk_tdue),hl
        ld a,C_MTAPE
        call cmd0
        jr c,.nt
        jr nz,.nt
        ld a,(reply)
        or a
        jr z,.nt
        ld a,K_GREEN
        ld (mk_k),a
        ld hl,reply
        ld de,#0100
        ld b,80
        call mk_text
        ld a,K_WHITE
        ld (mk_k),a
        ld a,1
        ld (mk_tapeon),a
.nt:    ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz
        ld a,(ckb+CK_SEC+1)
        ld hl,mk_smin
        cp (hl)
        jr z,.g
        ld (hl),a
        call mk_clock
.g:     ld a,(mk_view)
        cp MV_DEAD
        ret z
        or a
        jr nz,.ch
        ld a,(ckb+CK_MGEN)      ; the table: its prices changed
        ld hl,mk_gen
        cp (hl)
        jr z,.st
        ld (hl),a
        ld a,(ckb+CK_MST)
        ld (mk_st),a
        jp mk_table
.st:    ld a,(ckb+CK_MST)
        ld hl,mk_st
        cp (hl)
        ret z
        ld (hl),a
        jp mk_status
.ch:    ld a,(mk_wait)          ; the chart: asked for (3: the clock block may be an older one
        or a                    ; for two passes; 1: the engine was seen fetching it)
        jp z,mk_ntick
        ld c,a
        ld a,(ckb+CK_MCH)
        cp 1
        jr nz,.nl
        ld (mk_wait),a
        ret
.nl:    ld b,a
        ld a,c
        cp 1
        jr z,.end
        dec a
        ld (mk_wait),a
        ret
.end:   xor a
        ld (mk_wait),a
        ld a,b
        cp 2
        jp z,mk_chart
        ld hl,txt_mk_nochart
        ; fall through
; (mk_say follows)
        jp mk_say

; the chart's headlines: asked for (as the chart), then shown
mk_ntick:
        ld a,(mk_nwait)
        or a
        ret z
        ld c,a
        ld a,(ckb+CK_NFEED)
        cp #FE                  ; PVA_NEWS_EXT
        ld a,0
        jr nz,.h
        ld a,(ckb+CK_NST)
.h:     cp 1
        jr nz,.nl
        ld (mk_nwait),a
        ret
.nl:    ld b,a
        ld a,c
        cp 1
        jr z,.end
        dec a
        ld (mk_nwait),a
        ret
.end:   xor a
        ld (mk_nwait),a
        ld a,b
        cp 2
        ret nz
        ; fall through
; mk_heads: the four latest headlines the news reader has, under the chart
mk_heads:
        ld a,(ckb+CK_NCOUNT)
        or a
        ret z
        cp 5
        jr c,.c
        ld a,4
.c:     ld (mk_hn),a
        xor a
        ld (args),a
        ld a,4
        ld (args+1),a
        ld a,68
        ld (args+2),a
        ld a,C_NLIST
        ld bc,3
        call cmd
        ret c
        ret nz
        ld a,1
        ld (mk_nhave),a
        ld a,MK_HROW
        ld (mk_hrow),a
        ld hl,reply             ; a story: its time ("14:48" or "13 Nov"), its title
.l:     ld de,mk_lb
        ld a,' '
        ld (de),a
        inc de
        call strcpy
        inc hl
        ld a,' '
        ld (de),a
        inc de
        ld (de),a
        inc de
        call strcpy
        inc hl
        push hl
        ld a,(mk_hrow)
        ld d,a
        inc a
        ld (mk_hrow),a
        ld e,0
        ld b,80
        ld hl,mk_lb
        call mk_text
        pop hl
        ld a,(mk_hn)
        dec a
        ld (mk_hn),a
        jr nz,.l
        ret

; mk_say: HL = a message in the middle
mk_say: ld de,#0A02
        ld b,76
        jp mk_text

;------------------------------------------------------------------------------
; mk_lists: the region and how many lists it has; CF: the engine has no markets
mk_lists:
        ld a,C_MLISTS
        call cmd0
        ret c
        scf
        ret nz
        ld a,(reply)
        ld (mk_region),a
        ld a,(reply+1)
        ld (mk_nr),a
        ld a,(reply+2)
        ld (mk_nl),a
        or a
        ret

; mk_show: the list mk_list: the engine opens it (and fetches its prices)
mk_show:
        call mk_openlist
        jr mk_back
mk_openlist:
        ld a,(mk_list)
        ld (mk_last),a
        ld e,a
        ld a,C_MOPEN
        call cmd_u8
        ld a,0
        jr c,.n
        jr nz,.n
        ld a,(reply)
.n:     ld (mk_n),a
        xor a
        ld (mk_sel),a
        ld (mk_top),a
        ld (mk_sub),a
        ret

; mk_settop: the page (40 rows) the chosen row is on; Z: the one shown
mk_settop:
        ld a,(mk_sel)
        ld c,0
.l:     cp 2*MK_N
        jr c,.d
        sub 2*MK_N
        ld b,a
        ld a,c
        add a,2*MK_N
        ld c,a
        ld a,b
        jr .l
.d:     ld a,c
        ld hl,mk_top
        cp (hl)
        ld (hl),a
        ret

; mk_back: the table again (from the chart)
mk_back:
        xor a
        ld (mk_rkeep),a
        ld (mk_view),a
        ld (mk_wait),a
        call mk_clear
        ld hl,txt_mk_head       ; the columns' names (the right ones for a long list)
        ld de,MK_ROW0*256-256
        ld b,40
        call mk_text
        ld a,(mk_n)
        ld hl,mk_top
        sub (hl)
        cp MK_N+1
        jr c,.k
        ld hl,txt_mk_head
        ld de,MK_ROW0*256-256+40
        ld b,40
        call mk_text
.k:     ld hl,txt_mk_ktab
        call mk_keyline
        ; fall through
; mk_table: the state and the rows as they are now
mk_table:
        call mk_status
        jp mk_rows

; mk_keyline: HL = the view's keys (row 24), the keys of all views under them
mk_keyline:
        ld de,#1800
        ld b,80
        call mk_text
        ld hl,txt_mk_kall
        ld de,#1900
        ld b,80
        jp mk_text

; row 2: "Europe: Indices (1 of 4)" and at the right when the prices came
mk_status:
        ld a,C_MINFO
        call cmd0
        ret c
        ret nz
        ld de,mk_lb
        ld a,' '
        ld (de),a
        inc de
        ld hl,reply+4
        call mk_skip            ; (the list's name, then the region's)
        call strcpy
        ld hl,txt_mk_colon
        call strcpy
        ld hl,reply+4
        call strcpy
        ld a,(mk_sub)           ; a list: "(2 of 4)"
        or a
        jr nz,.nl
        ld hl,txt_mk_open
        call strcpy
        ld a,(mk_list)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_mk_of
        call strcpy
        ld a,(mk_nl)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_mk_close
        call strcpy
.nl:    ld a,(mk_n)             ; more than a page: "41-80 of 98"
        cp 2*MK_N+1
        jr c,.np
        ld a,' '
        ld (de),a
        inc de
        ld (de),a
        inc de
        ld a,(mk_top)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'-'
        ld (de),a
        inc de
        ld a,(mk_n)
        ld b,a
        ld a,(mk_top)
        add a,2*MK_N
        cp b
        jr c,.pe
        ld a,b
.pe:    ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_mk_of
        call strcpy
        ld a,(mk_n)
        ld l,a
        ld h,0
        call fmt_u16
        xor a
        ld (de),a
.np:    ld a,(mk_sort)          ; by percent
        or a
        jr z,.ns
        ld hl,txt_mk_s1
        dec a
        jr z,.s1
        ld hl,txt_mk_s2
.s1:    call strcpy
.ns:    ld hl,mk_lb
        ld de,#0200
        ld b,50
        call mk_text
        ld a,(reply)            ; PVA_MKT_xxx
        cp 1
        ld hl,txt_mk_load
        jr z,.r
        cp 3
        jr z,.fail
        ld hl,reply+4           ; "12:53  Yahoo Finance, delayed"
        call mk_skip
        call mk_skip
        ld de,mk_lb
        call strcpy
        ld hl,txt_mk_src
        call strcpy
        ld hl,mk_lb
        jr .r
.fail:  ld hl,txt_mk_fail       ; "No prices (error 4)": PVA_NERR_xxx
        ld de,mk_lb
        call strcpy
        ld a,(ckb+CK_MERR)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_mk_close
        call strcpy
        ld hl,mk_lb
.r:     ld de,#0232
        ld b,30
        jp mk_text

; the rows: 20 a reply, the first 20 at the left, the others at the right
mk_rows:
        xor a
        ld (mk_half),a
.half:  ld a,(mk_half)
        ld hl,mk_top
        add a,(hl)
        ld (args),a
        ld a,MK_N
        ld (args+1),a
        ld a,C_MROWS
        ld bc,2
        call cmd
        ld c,0                  ; C = rows in this reply
        jr c,.n
        jr nz,.n
        ld a,(reply+1)
        ld c,a
.n:     ld hl,reply+2
        ld b,0                  ; B = the row of this half
.row:   push bc
        ld a,(mk_half)
        add a,b
        ld (mk_idx),a
        ld a,b
        cp c
        ld a,0                  ; no such row: empty
        jr nc,.put
        ld a,(hl)               ; '+', '-', ' ' or '?', then the row's 39 characters
        inc hl
.put:   call mk_rowput
        pop bc
        inc b
        ld a,b
        cp MK_N
        jr c,.row
        ld a,(mk_half)
        add a,MK_N
        ld (mk_half),a
        cp 2*MK_N
        jr c,.half
        ld a,MX_PTR
        jp mk_ptr

; mk_rowput: the list's row mk_idx: A = its direction (0: there is none), HL = its
; text; HL after the text. The pointer's cell and the row's 39: name 14, price 10
; in white, change 8 and percent 7 green for a riser, red for a faller
mk_rowput:
        push hl
        ld c,a
        ld a,(mk_idx)
        ld hl,mk_dir
        call mk_add
        ld (hl),c
        ld a,c                  ; no row, and none on the screen there: nothing to draw
        or a
        jr nz,.d
        ld a,(mk_idx)
        ld hl,mk_first
        call mk_add
        ld a,(hl)
        or a
        jr nz,.d
        pop hl
        ret
.d:     ld a,(mk_idx)
        ld e,0
        cp MK_N
        jr c,.l
        sub MK_N
        ld e,40
.l:     add a,MK_ROW0
        ld d,a
        ld (mk_rc),de
        ld hl,G6_LB
        ld a,e
        call mk_add
        ld (hl),' '
        inc hl
        ex de,hl
        pop hl
        ld b,39
        ld a,c
        or a
        jr z,.pad
.c:     ld a,(hl)
        or a
        jr z,.pad
        ld (de),a
        inc hl
        inc de
        djnz .c
        jr .t
.pad:   ld a,' '
.p:     ld (de),a
        inc de
        djnz .p
.t:     ld a,c
        or a
        jr z,.nt
        inc hl                  ; (after the text's 0)
.nt:    push hl
        ld de,(mk_rc)
        ld hl,G6_LB+1           ; the name's first character: drawn again with the pointer
        ld a,e
        call mk_add
        ld b,(hl)
        ld a,c
        or a
        jr nz,.fc
        ld b,a                  ; (0: the row is empty now)
.fc:    ld a,(mk_idx)
        ld hl,mk_first
        call mk_add
        ld (hl),b
        ld b,25
        call mk_paint
        ld a,c
        cp '-'
        ld b,K_RED
        jr z,.k
        cp '+'
        ld b,K_GREEN
        jr z,.k
        ld b,K_WHITE
.k:     ld a,b
        ld (mk_k),a
        ld a,e
        add a,25
        ld e,a
        ld b,15
        call mk_paint
        ld a,K_WHITE
        ld (mk_k),a
        ld de,(mk_rc)
        ld b,20
        call g6_draw
        pop hl
        ret

; mk_ptr: A = the character before the chosen row (the pointer, or a space)
mk_ptr: ld c,a
        ld a,(mk_n)
        or a
        ret z
        ld a,(mk_sel)           ; its place on this page
        ld hl,mk_top
        sub (hl)
        ret c
        cp 2*MK_N
        ret nc
        ld (mk_idx),a
        ld hl,mk_first
        call mk_add
        ld b,(hl)               ; (the cell after it: a pair is drawn)
        ld a,(mk_idx)
        ld e,0
        cp MK_N
        jr c,.l
        sub MK_N
        ld e,40
.l:     add a,MK_ROW0
        ld d,a
        ld hl,G6_LB
        ld a,e
        call mk_add
        ld (hl),c
        inc hl
        ld (hl),b
        ld b,2
        call mk_paint
        ld b,1
        jp g6_draw

;------------------------------------------------------------------------------
; the chart of the chosen instrument: asked for, then (mk_tick) drawn
mk_chart_ask:
        ld a,(mk_n)
        or a
        ret z
        ld a,(mk_sel)
        ld (args),a
        ld a,(mk_range)
        ld (args+1),a
        ld a,C_MCHART
        ld bc,2
        call cmd
        ret c
        ret nz
        ld a,(mk_tapeon)        ; the tape stops: the line again
        or a
        jr z,.nl
        xor a
        ld (mk_tapeon),a
        ld de,#0100
        ld b,80
        ld a,MX_HL
        call mk_fill
.nl:    ld a,MV_CHART
        ld (mk_view),a
        xor a
        ld (mk_nwait),a
        ld a,(mk_rkeep)         ; (another range of the same one: its headlines stay)
        or a
        jr nz,.kh
        ld (mk_nhave),a
.kh:    ld a,3
        ld (mk_wait),a
        call mk_clear
        ld hl,txt_mk_kchart
        call mk_keyline
        ld a,(mk_range)         ; the range in green
        add a,a
        add a,a
        ld c,a
        ld hl,txt_mk_rng
        call mk_add
        ld de,mk_lb
        ld b,4
.rc:    ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .rc
        xor a
        ld (de),a
        ld a,K_GREEN
        ld (mk_k),a
        ld a,c
        add a,RB_COL
        ld e,a
        ld d,24
        ld b,4
        ld hl,mk_lb
        call mk_text
        ld a,K_WHITE
        ld (mk_k),a
        ld hl,txt_mk_chload
        jp mk_say

mk_chart:
        ld a,CH_W
        ld (args),a
        ld a,MK_CL
        ld (args+1),a
        ld a,C_MCHGET
        ld bc,2
        call cmd
        ld hl,txt_mk_nochart
        jp c,mk_say
        jp nz,mk_say
        call mk_clear
        ld de,mk_lb             ; row 2: " AEX   1141.03   +0.91  +0.08%"
        ld a,' '
        ld (de),a
        inc de
        ld hl,reply+2
        call mk_part
        call mk_part
        call strcpy
        inc hl
        push hl
        ld hl,mk_lb
        ld de,#0200
        ld b,80
        call mk_text
        pop hl
        ld de,mk_lb             ; row 3: " High 1143.18   Low 1136.78   Previous close 1140.12"
        push hl
        ld hl,txt_mk_high
        call strcpy
        pop hl
        call strcpy
        inc hl
        push hl
        ld hl,txt_mk_low
        call strcpy
        pop hl
        call strcpy
        inc hl
        ld a,(hl)
        or a
        jr z,.np
        push hl
        ld a,(mk_range)         ; (the day: the previous close; a longer range: the close before it)
        or a
        ld hl,txt_mk_prev
        jr z,.pp
        ld hl,txt_mk_start
.pp:    call strcpy
        pop hl
        call strcpy
.np:    call mk_skip
        ld (mk_cols),hl         ; the columns: 0 or the level 1..120, +80h under the previous close
        ld hl,mk_lb
        ld de,#0300
        ld b,80
        call mk_text
        ; the line: for each column the levels it covers, from the column before it
        ; to its own (and one under: 2 dots thick), and its colour: green above the
        ; previous close, red under it (white when it is not known)
        ld a,(reply+1)
        ld (mk_plev),a
        ld hl,(mk_cols)
        ld de,CH_LO
        ld b,CH_W
        ld c,0                  ; C = the level before (0: none)
.b:     ld a,(hl)
        inc hl
        push hl
        push bc
        ld b,a
        and #7F
        jr nz,.v
        ld a,#FF                ; nothing in this column
        ld (de),a
        inc d
        xor a
        ld (de),a
        dec d
        pop bc
        ld c,0
        jr .nx
.v:     ld l,a                  ; L = its level
        ld a,(mk_plev)
        or a
        ld h,K_WHITE
        jr z,.kk
        ld h,K_GREEN
        bit 7,b
        jr z,.kk
        ld h,K_RED
.kk:    inc d
        inc d
        ld a,h
        ld (de),a
        dec d
        dec d
        pop bc
        ld a,c
        or a
        jr nz,.pv
        ld a,l
.pv:    cp l
        jr c,.lt
        ld h,a                  ; from its own up to the one before
        ld a,l
        jr .st
.lt:    ld h,l                  ; from the one before up to its own
.st:    cp 2
        jr c,.s1
        dec a
.s1:    ld (de),a
        inc d
        ld a,h
        ld (de),a
        dec d
        ld c,l
.nx:    pop hl
        inc e
        djnz .b
        ld (mk_tk),hl           ; (the scales follow the columns)
        ; what an empty byte shows on each level: dots on the price scale's levels,
        ; dashes on the previous close
        ld hl,CH_E
        ld b,128
        xor a
.ez:    ld (hl),a
        inc hl
        djnz .ez
        ld hl,(mk_tk)
        ld a,(hl)
        inc hl
        or a
        jr z,.ee
        ld b,a
.et:    ld a,(hl)
        and #7F
        inc hl
        push hl
        ld l,a
        ld h,CH_E/256
        ld (hl),#10
        pop hl
        call mk_skip
        djnz .et
.ee:    ld a,(mk_plev)
        or a
        jr z,.ep
        ld l,a
        ld h,CH_E/256
        ld (hl),#54
.ep:
        ; the picture's lines from the top: a byte is two columns
        ld c,MK_CL              ; C = the level
.sl:    ld a,MK_ROW0*8+MK_CL     ; the line: (screen column 2: 12 dots, 3 bytes)
        sub c
        ld e,a                  ; (kept)
        ld h,CH_E/256
        ld l,c
        ld a,(hl)
        ld (mk_epat),a
        ld a,e
        ld h,a
        ld l,0
        srl h
        rr l
        inc hl
        inc hl
        inc hl
        ld a,(mk_epat)
        ld e,a
        di
        call g6_seek
        ld hl,CH_LO
        ld b,CH_W/2
.byte:  ld d,0
        ld a,c
        cp (hl)
        jr c,.e0
        inc h
        ld a,(hl)
        cp c
        jr c,.e1
        inc h
        ld a,(hl)
        and #F0
        ld d,a
        dec h
.e1:    dec h
.e0:    inc l
        ld a,c
        cp (hl)
        jr c,.o0
        inc h
        ld a,(hl)
        cp c
        jr c,.o1
        inc h
        ld a,(hl)
        and #0F
        or d
        ld d,a
        dec h
.o1:    dec h
.o0:    inc l
        ld a,d
        or a
        jr nz,.put
        ld a,e
.put:   out (VDP_D),a
        djnz .byte
        call g6_unseek
        dec c
        jp nz,.sl
        ; the price scale at the right: each price beside its dots
        ld hl,(mk_tk)
        ld a,(hl)
        inc hl
        or a
        jr z,.ny
        ld b,a
.yl:    push bc
        ld a,(hl)
        and #7F
        inc hl
        push hl
        ld c,a
        ld a,MK_ROW0*8+MK_CL-3
        sub c                   ; the label's top line
        cp MK_ROW0*8
        jr nc,.y1
        ld a,MK_ROW0*8
.y1:    cp MK_ROW0*8+MK_CL-8
        jr c,.y2
        ld a,MK_ROW0*8+MK_CL-8
.y2:    ld c,a
        and 7
        ld (g6_yo),a
        ld a,c
        rrca
        rrca
        rrca
        and #1F
        ld d,a
        ld e,CH_YCOL
        ld b,10
        pop hl
        call mk_text
        inc hl
        xor a
        ld (g6_yo),a
        pop bc
        djnz .yl
.ny:    push hl                 ; the time scale under the chart
        ld a,' '
        ld de,CH_XROW*256
        ld b,80
        call mk_fill
        pop hl
        ld a,(hl)
        inc hl
        or a
        jr z,.nx2
        ld b,a
.xl:    push bc
        ld a,(hl)               ; the column: 3 a cell
        inc hl
        ld c,0
.d3:    cp 3
        jr c,.d3e
        sub 3
        inc c
        jr .d3
.d3e:   ld a,c
        add a,2
        and #FE
        ld e,a
        ld d,CH_XROW
        push hl
        ld b,0
.ln:    ld a,(hl)
        or a
        jr z,.le
        inc hl
        inc b
        jr .ln
.le:    pop hl
        inc b
        res 0,b
        call mk_text
        inc hl
        pop bc
        djnz .xl
.nx2:
        ld hl,mk_rkeep
        ld a,(hl)
        ld (hl),0
        or a
        jr z,.fn
        ld a,(mk_nhave)
        or a
        jp nz,mk_heads
.fn:    ld a,(mk_sel)           ; its headlines: the news reader fetches them
        ld e,a
        ld a,C_MNEWS
        call cmd_u8
        ret c
        ret nz
        ld a,3
        ld (mk_nwait),a
        ret

; g6_seek: VRAM from HL on is written (interrupts off until g6_unseek)
g6_seek:
        ld a,h
        rlca
        rlca
        and 3
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        ld a,l
        out (VDP_C),a
        ld a,h
        and #3F
        or #40
        out (VDP_C),a
        ret
g6_unseek:
        xor a
        out (VDP_C),a
        ld a,#8E
        out (VDP_C),a
        ei
        ret

mk_part: call strcpy             ; a part of row 2 and three spaces
        inc hl
        ld a,' '
        ld (de),a
        inc de
        ld (de),a
        inc de
        ld (de),a
        inc de
        ret

;------------------------------------------------------------------------------
mk_keys:
        ld c,a
        ld a,(mk_view)
        cp MV_DEAD
        jp z,mk_kcommon
        cp MV_CHART
        jp z,mk_ckeys
        ld a,c
        cp 28
        jr z,.next
        cp 29
        jr z,.prev
        cp 30
        jp z,mk_up
        cp 31
        jp z,mk_down
        cp 13
        jp z,mk_chart_ask
        cp 8
        jp z,mk_unsub
        cp '1'
        jr c,.l
        cp '4'
        jr c,.region
.l:     and #DF
        cp 'I'
        jp z,mk_members
        cp 'O'
        jp z,mk_order
        cp 'U'
        jp nz,mk_kcommon
        ld e,#FD                ; PVA_MKT_NOW: what is open once more: its prices now
        ld a,C_MOPEN
        call cmd_u8
        ld hl,txt_mk_upd
        ld de,#0232
        ld b,30
        jp mk_text
.next:  ld a,(mk_nl)
        ld b,a
        ld a,(mk_list)
        inc a
        cp b
        jr c,.set
        xor a
        jr .set
.prev:  ld a,(mk_list)
        or a
        jr nz,.p1
        ld a,(mk_nl)
.p1:    dec a
.set:   ld (mk_list),a
        jp mk_show
.region:
        sub '1'
        ld e,a
        ld a,(mk_nr)
        dec a
        cp e
        ret c
        ld a,(mk_region)
        cp e
        ret z
        ld a,C_MREGION
        call cmd_u8
        ret c
        ret nz
        ld a,1
        ld (mk_dirty),a         ; (kept in PICOAMP.INI on leaving)
        call mk_lists
        xor a
        ld (mk_list),a
        jp mk_show

; O: the order: as the list has them, the risers first, the fallers first
mk_order:
        ld a,(mk_sort)
        inc a
        cp 3
        jr c,.o
        xor a
.o:     ld e,a
        ld a,C_MSORT
        call cmd_u8
        ret c
        ret nz
        ld a,(reply)
        ld (mk_sort),a
        jp mk_status            ; (the rows: mk_tick, the engine says they changed)

; I: the members of the index in the chosen row, in the list's place
mk_members:
        ld a,(mk_sub)
        or a
        ret nz
        ld a,(mk_n)
        or a
        ret z
        ld a,(mk_sel)
        ld e,a
        ld a,C_MMEMB
        call cmd_u8
        jr c,.no
        jr nz,.no
        ld a,(reply)
        ld (mk_n),a
        ld a,(mk_sel)
        ld (mk_psel),a
        ld a,1
        ld (mk_sub),a
        xor a
        ld (mk_sel),a
        ld (mk_top),a
        jp mk_back
.no:    ld hl,txt_mk_nomemb
        ld de,#0232
        ld b,30
        jp mk_text

; BS: from an index's members back to the list, on that index
mk_unsub:
        ld a,(mk_sub)
        or a
        ret z
        ld a,(mk_psel)
        push af
        call mk_openlist
        pop af
        ld hl,mk_n
        cp (hl)
        jr c,.s
        xor a
.s:     ld (mk_sel),a
        call mk_settop
        jp mk_back

mk_kcommon:
        ld a,b
        cp 27
        jp z,fs_close
        cp '$'
        jp z,fs_close
        and #DF
        cp 'C'
        ld c,PG_CLOCK
        jp z,pg_enter
        cp 'W'
        ld c,PG_WEATHER
        jp z,pg_enter
        cp 'T'
        ld c,PG_NEWS
        jp z,pg_enter
        cp 'G'
        ret z
        cp 'V'
        ret z
        cp 'Z'
        ret z
        ld a,b
        jp keys_common

mk_up:  call mk_prev
        ld a,MX_PTR
        jp mk_ptr
mk_down:
        call mk_next
        ld a,MX_PTR
        jp mk_ptr

; the chosen row one up / down, round the list (the pointer goes)
mk_prev:
        ld a,' '
        call mk_ptr
        ld a,(mk_sel)
        or a
        jr nz,.p
        ld a,(mk_n)
        or a
        ret z
.p:     dec a
        ld (mk_sel),a
        jr mk_paged
mk_next:
        ld a,' '
        call mk_ptr
        ld a,(mk_n)
        ld b,a
        ld a,(mk_sel)
        inc a
        cp b
        jr c,.n
        xor a
.n:     ld (mk_sel),a
        ; fall through
; the chosen row is on another page: that page (in the table)
mk_paged:
        xor a
        ld (mk_rkeep),a
        call mk_settop
        ret z
        ld a,(mk_view)
        or a
        ret nz
        jp mk_back

; the chart's keys
mk_ckeys:
        ld a,c
        cp 27
        jp z,mk_back
        cp 13
        jp z,mk_back
        cp 8
        jp z,mk_back
        cp 28                   ; right / left: the next / previous range
        jr nz,.lf
        ld a,(mk_range)
        inc a
        cp 8
        jr c,.rs
        xor a
        jr .rs
.lf:    cp 29
        jr nz,.ud
        ld a,(mk_range)
        or a
        jr nz,.l1
        ld a,8
.l1:    dec a
.rs:    ld (mk_range),a
        ld a,1
        ld (mk_rkeep),a
        jp mk_chart_ask
.ud:    cp 30
        jr nz,.d
        call mk_prev
        jp mk_chart_ask
.d:     cp 31
        jr nz,.t
        call mk_next
        jp mk_chart_ask
.t:     and #DF                 ; T: its headlines in the news reader (ESC there: here again)
        cp 'T'
        jp nz,mk_kcommon
        ld a,(mk_nhave)
        or a
        jr nz,.go
        ld hl,txt_mk_nonews
        ld de,MK_HROW*256
        ld b,80
        jp mk_text
.go:    ld a,1
        ld (nw_ext),a
        ld c,PG_NEWS
        jp pg_enter

;------------------------------------------------------------------------------
txt_mk_old:     db "The markets need engine 0.13 or newer",0
txt_mk_nowifi:  db "The markets need the cartridge's WiFi",0
txt_mk_head:    db " Name                Last  Change      %",0
txt_mk_ktab:    db " </> list  Up/Down choose  Enter chart  I members (BS back)  O order  U now",0
txt_mk_kchart:  db " Left/Right range 1D  5D  1M  6M  YTD 1Y  5Y  All  Up/Down next  T news  BS list",0
txt_mk_rng:     db "1D  5D  1M  6M  YTD 1Y  5Y  All "
txt_mk_start:   db "   Close before ",0
txt_mk_s1:      db "  risers first",0
txt_mk_s2:      db "  fallers first",0
txt_mk_nonews:  db " No headlines for this one (yet)",0
txt_mk_nomemb:  db "No member list for this one",0
txt_mk_kall:    db " 1 Europe  2 Americas  3 Asia-Pacific   C clock  W weather  T news  $/ESC player",0
txt_mk_colon:   db ": ",0
txt_mk_open:    db "  (",0
txt_mk_of:      db " of ",0
txt_mk_close:   db ")",0
txt_mk_load:    db "Fetching the prices...",0
txt_mk_upd:     db "Updating...",0
txt_mk_src:     db "  Yahoo Finance, delayed",0
txt_mk_fail:    db "No prices (error ",0
txt_mk_chload:  db "Fetching the day's course...",0
txt_mk_nochart: db "No chart for this one over this range",0
txt_mk_high:    db " High ",0
txt_mk_low:     db "   Low ",0
txt_mk_prev:    db "   Previous close ",0
mk_wd:          db "Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0,"Sun",0
mk_mon:         db "Jan",0,"Feb",0,"Mar",0,"Apr",0,"May",0,"Jun",0,"Jul",0,"Aug",0,"Sep",0,"Oct",0,"Nov",0,"Dec",0
mk_palix:       db NAVY, WHITE, GREEN, RED              ; SCREEN 6's colours 0-3
mk_glyphs:      db 0,0,0,#7E,0,0,0,0                    ; MX_HL (the dots in bits 6-1, as the font)
                db #08,#08,#08,#08,#08,#08,#08,#08      ; (a vertical line)
                db #7E,#7E,#7E,#7E,#7E,#7E,#7E,#7E      ; (a block)
                db #08,#0C,#0A,#0A,#08,#38,#78,#30      ; MX_NOTE
                db #20,#30,#38,#3C,#38,#30,#20,#00      ; MX_PTR

mk_view:        db 0
mk_region:      db 0
mk_nr:          db 0            ; regions
mk_nl:          db 0            ; the region's lists
mk_list:        db 0            ; the one shown
mk_n:           db 0            ; its rows
mk_sel:         db 0            ; the chosen one
mk_half:        db 0
mk_gen:         db 0
mk_st:          db 0
mk_wait:        db 0
mk_dirty:       db 0
mk_smin:        db 0
mk_cols:        dw 0
mk_top:         db 0            ; the first row on the screen (a page is 40)
mk_sub:         db 0            ; 1: an index's members are shown,
mk_psel:        db 0            ; the index's row in the list
mk_plev:        db 0
mk_epat:        db 0
mk_rkeep:       db 0
mk_range:       db 0            ; the chart's range: 0 1D .. 7 all
mk_sort:        db 0            ; the rows' order
mk_tapeon:      db 0
mk_tdue:        dw 0
mk_tk:          dw 0
g6_yo:          db 0
mk_nwait:       db 0
mk_nhave:       db 0
mk_hn:          db 0
mk_hrow:        db 0
mk_k:           db K_WHITE      ; the colour text is drawn in
mk_idx:         db 0
mk_rc:          dw 0
g6_np:          db 0
g6_c0:          db 0
g6_row:         db 0
g6_s:           db 0
mk_first:       ds 2*MK_N       ; each row's first character
mk_dir:         ds 2*MK_N       ; each row's '+', '-', ' ' or '?'
mk_lb:          ds 100          ; a line being put together
mod_mk_end:
