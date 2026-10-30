;==============================================================================
; news.asm - PICOAMP's news reader: a page module (see clock.asm), in the
; MSX2's 80-column text mode (TEXT 2, 26 rows), as an RSS reader.
;
; The headlines of a feed, one a line, the chosen one's summary under them;
; a story with its title and its text, scrolled (the full article comes in
; from the web while one reads); My feeds (the favourites) beside the
; engine's catalogue of feeds by topic, to add and remove them. Row 0 has
; what plays (moving when it is long) and the time. The engine (0.12) reads
; the feeds, keeps the stories and wraps the text into lines.
;
; Keys: headlines: Up/Down, Left/Right a page, Enter the story, 1-9 a feed of
; My feeds, F My feeds. A story: Up/Down a line, Left/Right a page, Enter the
; full article / the summary, N/P the next/previous story, ESC the headlines.
; My feeds: Left/Right the side, Enter read (left) / add (right), D or DEL
; remove, U/J move. C clock, W weather, T or ESC (headlines) the player; the
; other playback keys keep working.
;==============================================================================

V_LIST   equ 0
V_STORY  equ 1
V_FEEDS  equ 2
NL_ROWS  equ 17                 ; headlines (rows 2-18)
NS_ROWS  equ 18                 ; story lines (rows 5-22)
NF_ROWS  equ 20                 ; My feeds / the catalogue (rows 3-22)
NW_NAMES equ vizbuf             ; My feeds' names, 32 bytes each (20)
TX_HL    equ 1                  ; our characters: a horizontal line,
TX_VL    equ 2                  ; a vertical one,
TX_BLK   equ 3                  ; a block,
TX_NOTE  equ 4                  ; a note
TX_BAR_C equ NAVY*16+CYAN       ; the chosen line / the bars (blink colours)
TX_COL   equ WHITE*16+NAVY

mod_news:
        jp nw_open              ; the jump table (M_OPEN ...)
        jp nw_tick
        jp nw_ret
        jp nw_keys
        jp nw_info
        jp nw_ret
        jp nw_leave

;------------------------------------------------------------------------------
; the screen: TEXT 2 with 212 lines, our font, the bars in the blink colours
nw_open:
        ld a,#70                ; shown, interrupts, M1 (with M4 of SCREEN 4: TEXT 2)
        ld b,1
        call vreg
        ld a,#03                ; names 0000h
        ld b,2
        call vreg
        ld a,#2F                ; blink bits 0A00h (after the 27 rows' names)
        ld b,3
        call vreg
        xor a
        ld b,10
        call vreg
        ld a,#02                ; patterns 1000h
        ld b,4
        call vreg
        ld a,TX_COL
        ld b,7
        call vreg
        ld a,(RG9SAV)           ; 212 lines: 26 rows
        or #80
        ld b,9
        call vreg
        ld a,TX_BAR_C
        ld b,12
        call vreg
        ld a,#F0                ; the blink colours all the time
        ld b,13
        call vreg
        call nw_font
        call tx_cls
        xor a
        ld (nw_t0),a
        ld (nw_dirty),a
        ld (nw_msgon),a
        ld a,#FF
        ld (nw_smin),a
        call nw_info
        ld a,(eng_minor)
        cp 12
        jr nc,.ok
        ld hl,txt_nw_old
        ld de,#0A02
        ld b,60
        jp tx_text
.ok:    call nw_favs
        ld a,(ckb+CK_NST)       ; a feed that is there already: its headlines
        cp 2
        jr nz,.f
        ld a,(ckb+CK_NFEED)
        ld hl,nw_nf
        cp (hl)
        jr nc,.f
        ld (nw_feed),a
        ld a,(ckb+CK_NCOUNT)
        ld (nw_n),a
        xor a
        ld (nw_sel),a
        ld (nw_first),a
        ld (nw_wait),a
        jp nw_list
.f:     ld a,(nw_nf)            ; else the first feed, or My feeds
        or a
        jp z,nw_feeds
        xor a
        jp nw_fetch

; leaving: SCREEN 4 again (and the settings to the card)
nw_leave:
        ld a,(RG9SAV)
        ld b,9
        call vreg
        call screen_init
        ld a,(nw_dirty)
        or a
        ret z
        jp ini_save

nw_ret: ret

; the font: the machine's (PICOAMP keeps it one pixel to the right), ours below 32
nw_font:
        ld hl,#1000
        call vwrite
        ld b,0                  ; characters 0-31: empty
        xor a
.z:     out (VDP_D),a
        djnz .z
        ld hl,font
        ld bc,96*8
.f:     ld a,(hl)
        add a,a
        out (VDP_D),a
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.f
        ei
        ld hl,#1000+TX_HL*8
        call vwrite
        ld hl,nw_glyphs
        ld bc,4*8*256+VDP_D
        otir
        ei
        ret

;------------------------------------------------------------------------------
; text: D = row, E = column

; tx_at: the VRAM address of the cell (interrupts off until the bytes are out)
tx_at:  ld l,d
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        push hl
        add hl,hl
        add hl,hl
        pop bc
        add hl,bc               ; * 80
        ld c,e
        ld b,0
        add hl,bc
        jp vwrite

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
        ld b,80
        ld a,TX_HL
        jr tx_fill

tx_clrrow:                      ; row D: empty
        ld e,0
        ld b,80
        ld a,' '
        jr tx_fill

tx_cls: ld hl,0                 ; all of it, and no bars
        ld bc,80*27
        ld a,' '
        call vfill
        ld hl,#0A00
        ld bc,270
        xor a
        jp vfill

; tx_bar: row D, the cells E.. (B of them) in the bar's colours, the rest not (B = 0: none)
tx_bar: push de
        push bc
        ld hl,nw_bl
        ld b,10
        xor a
.z:     ld (hl),a
        inc hl
        djnz .z
        pop bc
        pop de
        ld a,b
        or a
        jr z,.out
.s:     ld a,e
        rrca
        rrca
        rrca
        and #1F
        ld hl,nw_bl
        call nw_add
        ld a,e
        and 7
        push hl
        ld hl,nw_bits
        call nw_add
        ld a,(hl)
        pop hl
        or (hl)
        ld (hl),a
        inc e
        djnz .s
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
        call vwrite
        ld hl,nw_bl
        ld bc,10*256+VDP_D
        otir
        ei
        ret

; nw_lines: D = the first row, B = rows, C = the lines in the reply, HL = the first (from column 1)
nw_lines:
        ld a,c
        or a
        jr z,.e
        push bc
        push de
        ld e,1
        ld b,79
        call tx_text
.sk:    ld a,(hl)               ; (after its 0)
        inc hl
        or a
        jr nz,.sk
        pop de
        pop bc
        dec c
        jr .n
.e:     push bc
        push de
        push hl
        call tx_clrrow
        pop hl
        pop de
        pop bc
.n:     inc d
        djnz nw_lines
        ret

nw_add: add a,l                 ; HL += A (DE kept)
        ld l,a
        ret nc
        inc h
        ret

; nw_nth: HL = strings, A = n -> HL = the n-th
nw_nth: or a
        ret z
        ld b,a
.n:     ld a,(hl)
        inc hl
        or a
        jr nz,.n
        djnz .n
        ret

;------------------------------------------------------------------------------
; row 0: what plays (moving round when it is long) and the time
nw_info:
        call pg_row0_text       ; HL = pg_t0
        ld de,nw_t0
        ld b,0
.c:     ld a,(de)               ; the same as shown?
        cp (hl)
        jr nz,.new
        or a
        ret z
        inc hl
        inc de
        inc b
        jr .c
.new:   ld hl,pg_t0
        ld de,nw_t0
        ld bc,64
        ldir
        ld hl,nw_t0
        ld b,0
.l:     ld a,(hl)
        or a
        jr z,.le
        inc hl
        inc b
        jr .l
.le:    ld a,b
        ld (nw_tlen),a
        xor a
        ld (nw_toff),a
        ld hl,(JIFFY)
        ld de,60                ; a second still
        add hl,de
        ld (nw_tdue),hl
        ; fall through
nw_row0:                        ; the text from nw_toff, round and round (3 spaces between)
        ld de,#0000
        call tx_at
        ld a,TX_NOTE
        out (VDP_D),a
        ld a,' '
        out (VDP_D),a
        ld a,(nw_tlen)
        cp 61
        jr nc,.mv
        ld hl,nw_t0             ; short: as it is
        ld b,61
.s:     ld a,(hl)
        or a
        jr z,.sp
        out (VDP_D),a
        inc hl
        djnz .s
        ei
        ret
.sp:    ld a,' '
.sl:    out (VDP_D),a
        djnz .sl
        ei
        ret
.mv:    add a,3
        ld c,a                  ; C = the round
        ld a,(nw_toff)
        ld e,a
        ld b,61
.m:     ld a,e
        cp c
        jr c,.m1
        sub c
        ld e,a
.m1:    ld a,(nw_tlen)
        dec a
        cp e
        ld a,' '
        jr c,.m2
        ld hl,nw_t0
        ld a,e
        call nw_add
        ld a,(hl)
.m2:    out (VDP_D),a
        inc e
        djnz .m
        ei
        ret

nw_clock:                       ; "Fri 30 Oct 09:53" at the right
        ld a,(ckb+CK_FLAGS)
        and CKF_TIME
        ret z
        ld de,linebuf
        ld a,(ckb+CK_SEC+3)
        cp 7
        jr c,.w
        xor a
.w:     ld hl,nw_wd
        call nw_nth
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
.m:     ld hl,nw_mon
        call nw_nth
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
        ld hl,linebuf
        ld de,#0040
        ld b,16
        jp tx_text

;------------------------------------------------------------------------------
; each pass: the clock, the ticker, a feed or an article coming in, a message going
nw_tick:
        ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz
        ld a,(ckb+CK_SEC+1)
        ld hl,nw_smin
        cp (hl)
        jr z,.tk
        ld (hl),a
        call nw_clock
.tk:    ld a,(nw_tlen)          ; the ticker: a character every 8 interrupts
        cp 61
        jr c,.ms
        ld hl,(JIFFY)
        ld de,(nw_tdue)
        or a
        sbc hl,de
        bit 7,h
        jr nz,.ms
        ld hl,(JIFFY)
        ld de,8
        add hl,de
        ld (nw_tdue),hl
        ld a,(nw_tlen)
        add a,3
        ld b,a
        ld a,(nw_toff)
        inc a
        cp b
        jr c,.to
        xor a
.to:    ld (nw_toff),a
        call nw_row0
.ms:    ld a,(nw_msgon)         ; a message: the keys again after 3 s
        or a
        jr z,.w
        ld hl,(JIFFY)
        ld de,(nw_msgt)
        or a
        sbc hl,de
        ld de,180
        sbc hl,de
        jr c,.w
        xor a
        ld (nw_msgon),a
        call nw_keyline
.w:     ld a,(nw_wait)          ; a feed being fetched
        or a
        jr z,.art
        ld a,(ckb+CK_NST)
        cp 1
        ret z
        xor a
        ld (nw_wait),a
        ld a,(ckb+CK_NST)
        cp 2
        jr nz,.fail
        ld a,(ckb+CK_NCOUNT)
        ld (nw_n),a
        xor a
        ld (nw_sel),a
        ld (nw_first),a
        jp nw_list
.fail:  ld hl,txt_nw_fail
        jp nw_say
.art:   ld a,(nw_view)          ; the article coming in: more of it shown
        cp V_STORY
        ret nz
        ld a,(nw_which)
        or a
        ret z
        ld a,(nw_aflags)
        and PVA_TXF_LOADING
        ret z
        ld hl,(JIFFY)           ; (twice a second at most)
        ld de,(nw_adue)
        or a
        sbc hl,de
        bit 7,h
        ret nz
        ld hl,(JIFFY)
        ld de,30
        add hl,de
        ld (nw_adue),hl
        ld hl,(ckb+CK_ALEN)
        ld de,(nw_alen)
        or a
        sbc hl,de
        jr nz,.more
        ld a,(ckb+CK_ASTATE)    ; in (or failed): the last time
        cp 1
        jp z,nw_status          ; (the KB read)
.more:  ld hl,(ckb+CK_ALEN)
        ld (nw_alen),hl
        jp nw_stext

PVA_TXF_LOADING equ 1
PVA_TXF_ARTICLE equ 2
PVA_TXF_FAILED  equ 4

; nw_say: HL = a message in the middle of the list
nw_say: ld de,#0A02
        ld b,76
        jp tx_text

; nw_msg: HL = a message on the key line for a while
nw_msg: ld de,#1800
        ld b,80
        call tx_text
        ld hl,(JIFFY)
        ld (nw_msgt),hl
        ld a,1
        ld (nw_msgon),a
        ret

nw_keyline:                     ; rows 24 and 25: the view's keys
        ld a,(nw_view)
        ld hl,txt_nw_klist
        or a
        jr z,.k
        ld hl,txt_nw_kstory
        dec a
        jr z,.k
        ld hl,txt_nw_kfeeds
.k:     ld de,#1800
        ld b,80
        call tx_text
        ld hl,txt_nw_kall
        ld de,#1900
        ld b,80
        jp tx_text

;------------------------------------------------------------------------------
; My feeds' names from the engine (NW_NAMES)
nw_favs:
        ld a,C_NFEEDS
        call cmd0
        ld a,0
        jr c,.n
        jr nz,.n
        ld hl,reply
        ld a,(hl)
        inc hl
        cp NF_ROWS+1
        jr c,.n
        ld a,NF_ROWS
.n:     ld (nw_nf),a
        or a
        ret z
        ld b,a
        ld de,NW_NAMES
.c:     push bc
        push de
        ld bc,31
        call strncpy0
        pop de
        ex de,hl
        ld bc,32
        add hl,bc
        ex de,hl
        pop bc
        djnz .c
        ret

; nw_name: A = favourite -> HL = its name
nw_name:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,NW_NAMES
        add hl,de
        ret

;------------------------------------------------------------------------------
; a feed (A = favourite) asked for; its headlines when it is in
nw_fetch:
        ld (nw_feed),a
        ld e,a
        ld a,C_NFETCH
        call cmd_u8
        ret c
        push af
        ld a,1
        ld (nw_wait),a
        xor a
        ld (nw_view),a
        ld (nw_n),a
        call tx_cls
        call nw_info.new
        ld a,#FF
        ld (nw_smin),a
        call nw_lhead
        call nw_keyline
        pop af
        ld hl,txt_nw_fetch
        jp z,nw_say
        xor a
        ld (nw_wait),a
        ld hl,txt_nw_nowifi
        jp nw_say

; the bar of the headlines: " BBC News, World ....  Headlines 1-17 of 38"
nw_lhead:
        ld a,(nw_feed)
        call nw_name
        ld de,linebuf
        ld a,' '
        ld (de),a
        inc de
        call strcpy
        ld hl,linebuf
        ld de,#0100
        ld b,52
        call tx_text
        ld de,linebuf
        ld a,(nw_wait)
        or a
        jr nz,.e
        ld a,(nw_n)
        or a
        jr z,.e
        ld hl,txt_nw_heads
        call strcpy
        ld a,(nw_first)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'-'
        ld (de),a
        inc de
        ld a,(nw_first)
        add a,NL_ROWS
        ld hl,nw_n
        cp (hl)
        jr c,.l
        ld a,(hl)
.l:     ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_nw_of
        call strcpy
        ld a,(nw_n)
        ld l,a
        ld h,0
        call fmt_u16
.e:     xor a
        ld (de),a
        ld hl,linebuf
        ld de,#0134
        ld b,28
        call tx_text
        ld de,#0100
        ld b,80
        jp tx_bar

; the headlines, the chosen one and its summary
nw_list:
        xor a
        ld (nw_view),a
        ld a,(nw_wait)
        or a
        jr nz,.w
        call tx_cls
        ld a,#FF
        ld (nw_smin),a
        call nw_info.new
.w:     call nw_lhead
        call nw_keyline
        ld a,(nw_n)
        or a
        jr nz,.h
        ld hl,txt_nw_none
        jp nw_say
.h:     ld d,19
        call tx_hline
        ld d,23
        call tx_hline
        ld a,(nw_first)         ; 9 and 8 headlines (a reply holds 1 KB)
        ld b,9
        ld d,2
        call nw_heads
        ld a,(nw_first)
        add a,9
        ld b,8
        ld d,11
        call nw_heads
        jp nw_selbar

; nw_heads: A = the first story, B = how many, D = row: "  20:15  Title"
nw_heads:
        ld (args),a
        ld a,b
        ld (args+1),a
        ld a,71
        ld (args+2),a
        push de
        push bc
        ld bc,3
        ld a,C_NLIST
        call cmd
        pop bc
        pop de
        ret c
        ld hl,reply
        ld a,(args)
        ld c,a
.r:     push bc
        ld a,(nw_n)
        dec a
        cp c
        jr c,.clr
        push de
        ld de,linebuf
        ld a,' '
        ld (de),a
        inc de
        ld b,6                  ; the time, 6 wide
.tc:    ld a,(hl)
        or a
        jr z,.tp
        ld (de),a
        inc hl
        inc de
        djnz .tc
.ts:    ld a,(hl)               ; (longer: the rest left out)
        inc hl
        or a
        jr nz,.ts
        jr .t
.tp:    inc hl
        ld a,' '
.sp:    ld (de),a
        inc de
        djnz .sp
.t:     ld a,' '
        ld (de),a
        inc de
        call strcpy0
        pop de
        push hl
        ld hl,linebuf
        ld e,0
        ld b,80
        call tx_text
        pop hl
        jr .n
.clr:   push hl
        push de
        call tx_clrrow
        pop de
        pop hl
.n:     pop bc
        inc d
        inc c
        djnz .r
        ret

; the bar on the chosen headline, its summary under the list
nw_selbar:
        ld a,(nw_sel)
        ld hl,nw_first
        sub (hl)
        add a,2
        ld d,a
        ld e,0
        ld b,80
        call tx_bar
        ld a,(nw_sel)           ; its first 3 lines
        ld (args),a
        xor a
        ld (args+1),a
        ld (args+2),a
        ld (args+3),a
        ld a,3
        ld (args+4),a
        ld a,78
        ld (args+5),a
        ld bc,6
        ld a,C_NTEXT
        call cmd
        ret c
        ld c,0
        jr nz,.p
        ld a,(reply)
        ld c,a
        ld a,(reply+1)
        or a
        jr nz,.three
        ld a,c
        cp 4
        jr c,.p
.three: ld c,3
.p:     ld hl,reply+3
        ld d,20
        ld b,3
        jp nw_lines

; a new chosen headline (A): the bar moves, or the list turns a page
nw_newsel:
        ld hl,nw_sel
        ld c,(hl)
        ld (hl),a
        ld b,a
        ld a,(nw_first)
        ld e,a
        ld a,b
        sub e
        jr c,.page
        cp NL_ROWS
        jr nc,.page
        ld a,c                  ; the bar off the old one
        sub e
        add a,2
        ld d,a
        ld b,0
        call tx_bar
        jp nw_selbar
.page:  ld a,b                  ; the page it is on
        ld c,0
.pg:    sub NL_ROWS
        jr c,.pe
        push af
        ld a,c
        add a,NL_ROWS
        ld c,a
        pop af
        jr .pg
.pe:    ld a,c
        ld (nw_first),a
        ld a,2                  ; (all bars off)
        ld b,NL_ROWS
.bo:    push bc
        push af
        ld d,a
        ld b,0
        call tx_bar
        pop af
        pop bc
        inc a
        djnz .bo
        jp nw_list.w

;------------------------------------------------------------------------------
; a story (nw_sel): its title, its date, its text from nw_top
nw_story:
        ld a,V_STORY
        ld (nw_view),a
        xor a
        ld (nw_which),a
        ld (nw_aflags),a
        ld hl,0
        ld (nw_top),hl
        ld (nw_alen),hl
nw_story2:
        call tx_cls
        ld a,#FF
        ld (nw_smin),a
        call nw_info.new
        call nw_keyline
        ld a,(nw_feed)          ; " BBC News, World | story 3 of 38"
        call nw_name
        ld de,linebuf
        ld a,' '
        ld (de),a
        inc de
        call strcpy
        ld hl,txt_nw_story
        call strcpy
        ld a,(nw_sel)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_nw_of
        call strcpy
        ld a,(nw_n)
        ld l,a
        ld h,0
        call fmt_u16
        xor a
        ld (de),a
        ld hl,linebuf
        ld de,#0100
        ld b,56
        call tx_text
        ld a,(nw_sel)           ; its date, its site
        ld e,a
        ld a,C_NITEM
        call cmd_u8
        ret c
        ld hl,reply
        ld de,#0138
        ld b,24
        call tx_text
        ld de,#0100
        ld b,80
        call tx_bar
        ld a,2                  ; the title, 2 lines
        ld hl,0
        ld b,2
        call nw_ask
        ret c
        ld c,a
        ld hl,reply+3
        ld d,2
        ld b,2
        call nw_lines
        ld d,4
        call tx_hline
        jp nw_stext

; nw_ask: A = what (0 summary, 1 article, 2 title), HL = first line, B = lines -> CF, the reply; A = lines in it
nw_ask: ld (args+1),a
        ld (args+2),hl
        ld a,b
        ld (args+4),a
        ld a,(nw_sel)
        ld (args),a
        ld a,78
        ld (args+5),a
        push hl
        push bc
        ld bc,6
        ld a,C_NTEXT
        call cmd
        pop bc
        pop de
        ret c
        ld a,0
        ret nz
        ld hl,(reply)           ; lines in all - first, at most B
        or a
        sbc hl,de
        jr c,.z
        jr z,.z
        ld a,h
        or a
        jr nz,.b
        ld a,l
        cp b
        jr c,.r
.b:     ld a,b
.r:     or a                    ; (CF = 0)
        ret
.z:     xor a
        ret

; the text: two parts of 9 lines (a reply holds 1 KB)
nw_stext:
        ld a,(nw_which)
        ld hl,(nw_top)
        ld b,9
        call nw_ask
        ret c
        ld c,a
        ld a,(reply+2)
        ld (nw_aflags),a
        ld hl,(reply)
        ld (nw_total),hl
        ld hl,reply+3
        ld d,5
        ld b,9
        call nw_lines
        ld a,(nw_which)
        ld hl,(nw_top)
        ld de,9
        add hl,de
        ld b,9
        call nw_ask
        ret c
        ld c,a
        ld hl,reply+3
        ld d,14
        ld b,9
        call nw_lines
        ; fall through
; the bar under the text: what it is, the lines shown
nw_status:
        ld de,linebuf
        ld a,(nw_aflags)
        ld hl,txt_nw_sload
        bit 0,a
        jr nz,.ld
        ld hl,txt_nw_sart
        bit 1,a
        jr nz,.s
        ld hl,txt_nw_snone
        bit 2,a
        jr nz,.s
        ld hl,txt_nw_ssum
.s:     call strcpy
        jr .r
.ld:    call strcpy
        ld hl,(ckb+CK_AKB)
        call fmt_u16
        ld hl,txt_nw_kb
        call strcpy
.r:     xor a
        ld (de),a
        ld hl,linebuf
        ld de,#1700
        ld b,58
        call tx_text
        ld de,linebuf           ; "lines 1-18 of 26"
        ld hl,(nw_total)
        ld a,h
        or l
        jr z,.e
        ld hl,txt_nw_lines
        call strcpy
        ld hl,(nw_top)
        inc hl
        call fmt_u16
        ld a,'-'
        ld (de),a
        inc de
        ld hl,(nw_top)
        ld bc,NS_ROWS
        add hl,bc
        ld bc,(nw_total)
        push hl
        or a
        sbc hl,bc
        pop hl
        jr c,.l
        ld hl,(nw_total)
.l:     call fmt_u16
        ld hl,txt_nw_of
        call strcpy
        ld hl,(nw_total)
        call fmt_u16
.e:     xor a
        ld (de),a
        ld hl,linebuf
        ld de,#173A
        ld b,22
        call tx_text
        ld de,#1700
        ld b,80
        jp tx_bar

; nw_scroll: HL = the new first line (kept within the text)
nw_scroll:
        bit 7,h
        jr z,.p
        ld hl,0
.p:     ld de,(nw_total)        ; at most total - 18 (0 when shorter)
        push hl
        ex de,hl
        ld bc,NS_ROWS
        or a
        sbc hl,bc
        jr nc,.m
        ld hl,0
.m:     pop de
        push hl
        or a
        sbc hl,de
        pop hl
        jr c,.s
        ex de,hl
.s:     ld de,(nw_top)
        or a
        push hl
        sbc hl,de
        pop hl
        ret z
        ld (nw_top),hl
        jp nw_stext

;------------------------------------------------------------------------------
; My feeds, and the catalogue: topics, a topic's feeds
nw_feeds:
        ld a,V_FEEDS
        ld (nw_view),a
        xor a
        ld (nw_pane),a
        ld (nw_tsel),a
        ld a,#FF
        ld (nw_topic),a
        ld a,(nw_fsel)
        ld hl,nw_nf
        cp (hl)
        jr c,nw_feeds2
        xor a
        ld (nw_fsel),a
nw_feeds2:
        call tx_cls
        ld a,#FF
        ld (nw_smin),a
        call nw_info.new
        call nw_keyline
        ld d,23
        call tx_hline
        ld b,21                 ; the line between the two sides
        ld d,2
.v:     push bc
        push de
        ld e,39
        ld b,1
        ld a,TX_VL
        call tx_fill
        pop de
        pop bc
        inc d
        djnz .v
        call nw_fleft
        jp nw_fright

nw_fleft:                       ; My feeds
        ld de,linebuf
        ld hl,txt_nw_my
        call strcpy
        ld a,(nw_nf)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_nw_of20
        call strcpy
        ld hl,linebuf
        ld de,#0100
        ld b,39
        call tx_text
        ld c,0
        ld d,3
.r:     push bc
        push de
        ld a,c
        ld hl,nw_nf
        cp (hl)
        ld hl,txt_nw_empty
        jr nc,.t
        ld a,c                  ; " 1 BBC News, World"
        inc a
        ld l,a
        ld h,0
        ld de,linebuf
        cp 10
        jr nc,.w
        ld a,' '
        ld (de),a
        inc de
.w:     call fmt_u16
        ld a,' '
        ld (de),a
        inc de
        ld a,c
        push de
        call nw_name
        pop de
        call strcpy
        ld hl,linebuf
.t:     pop de
        push de
        ld e,1
        ld b,37
        call tx_text
        pop de
        pop bc
        inc d
        inc c
        ld a,c
        cp NF_ROWS
        jr c,.r
        jp nw_fbars

nw_fright:                      ; the topics, or a topic's feeds
        ld a,(nw_topic)
        inc a
        jr nz,.cat
        ld a,C_NTOPICS
        call cmd0
        ret c
        ret nz
        ld hl,txt_nw_topics
        jr .h
.cat:   dec a
        ld e,a
        ld a,C_NCAT
        call cmd_u8
        ret c
        ret nz
        ld hl,txt_nw_add
        ld de,linebuf
        call strcpy
        ld a,(nw_topic)         ; its name: from the topics
        push af
        push de
        ld a,C_NTOPICS
        call cmd0
        pop de
        pop af
        ld hl,reply+1
        call nw_nth
        call strcpy
        push de
        ld a,(nw_topic)
        ld e,a
        ld a,C_NCAT
        call cmd_u8
        pop de
        ld hl,linebuf
.h:     push hl
        ld hl,reply
        ld a,(hl)
        cp NF_ROWS+1
        jr c,.n
        ld a,NF_ROWS
.n:     ld (nw_rn),a
        pop hl
        ld de,#0128
        ld b,40
        call tx_text
        ld hl,reply+1
        ld c,0
        ld d,3
.r:     push bc
        push de
        ld a,c
        push hl
        ld hl,nw_rn
        cp (hl)
        pop hl
        jr nc,.e
        ld e,41
        ld b,38
        call tx_text
.sk:    ld a,(hl)
        inc hl
        or a
        jr nz,.sk
        jr .x
.e:     push hl
        ld e,41
        ld b,38
        ld a,' '
        call tx_fill
        pop hl
.x:     pop de
        pop bc
        inc d
        inc c
        ld a,c
        cp NF_ROWS
        jr c,.r
        ; fall through
; the bars: the headings, the chosen line of the side in use ('>' on the other)
nw_fbars:
        ld de,#0100
        ld b,80
        call tx_bar
        ld b,NF_ROWS            ; (no markers)
        ld d,3
.c:     push bc
        push de
        ld e,0
        ld b,1
        ld a,' '
        call tx_fill
        pop de
        push de
        ld e,40
        ld b,1
        ld a,' '
        call tx_fill
        pop de
        pop bc
        inc d
        djnz .c
        ld a,(nw_fsel)
        add a,3
        ld d,a
        ld e,0
        ld a,(nw_pane)
        or a
        ld a,' '
        jr z,.l
        ld a,(nw_nf)
        or a
        ld a,'>'
        jr nz,.l
        ld a,' '
.l:     ld b,1
        call tx_fill
        ld a,(nw_tsel)
        add a,3
        ld d,a
        ld e,40
        ld a,(nw_pane)
        or a
        ld a,' '
        jr nz,.r
        ld a,(nw_rn)
        or a
        ld a,'>'
        jr nz,.r
        ld a,' '
.r:     ld b,1
        call tx_fill
        ld b,NF_ROWS            ; the rows' bars
        ld d,3
.b:     push bc
        push de
        ld a,d
        sub 3
        ld c,a
        ld b,0
        ld a,(nw_pane)
        or a
        jr nz,.rp
        ld a,(nw_nf)
        or a
        jr z,.o
        ld a,(nw_fsel)
        cp c
        jr nz,.o
        ld e,0
        ld b,39
        jr .o
.rp:    ld a,(nw_rn)
        or a
        jr z,.o
        ld a,(nw_tsel)
        cp c
        jr nz,.o
        ld e,40
        ld b,40
.o:     call tx_bar
        pop de
        pop bc
        inc d
        djnz .b
        ret

; the feeds' keys
nw_fkeys:
        cp 29
        jr z,.side
        cp 28
        jr z,.side
        cp 9
        jr z,.side
        cp 30
        jr z,.up
        cp 31
        jr z,.down
        cp 13
        jr z,.enter
        cp 8
        jr z,.bs
        cp 27
        jp z,nw_fback
        cp 127
        jp z,.del
        and #DF
        cp 'D'
        jp z,.del
        cp 'U'
        jp z,.mup
        cp 'J'
        jp z,.mdn
        jp nw_kcommon
.side:  ld a,(nw_pane)
        xor 1
        ld (nw_pane),a
        jp nw_fbars
.up:    call .sel
        ld a,(hl)
        or a
        ret z
        dec (hl)
        jp nw_fbars
.down:  call .sel
        ld a,(hl)
        inc a
        cp c
        ret nc
        ld (hl),a
        jp nw_fbars
.sel:   ld hl,nw_fsel           ; HL = the side's choice, C = its count
        ld a,(nw_nf)
        ld c,a
        ld a,(nw_pane)
        or a
        ret z
        ld hl,nw_tsel
        ld a,(nw_rn)
        ld c,a
        ret
.bs:    ld a,(nw_pane)
        or a
        jp z,nw_fback
        ld a,(nw_topic)
        inc a
        jp z,nw_fback
        ld a,#FF                ; a topic: the topics again
        ld (nw_topic),a
        xor a
        ld (nw_tsel),a
        jp nw_fright
.enter: ld a,(nw_pane)
        or a
        jr nz,.er
        ld a,(nw_nf)            ; read the feed
        or a
        ret z
        ld a,(nw_fsel)
        jp nw_fetch
.er:    ld a,(nw_rn)
        or a
        ret z
        ld a,(nw_topic)
        inc a
        jr nz,.add
        ld a,(nw_tsel)          ; a topic: its feeds
        ld (nw_topic),a
        xor a
        ld (nw_tsel),a
        jp nw_fright
.add:   ld a,(nw_topic)         ; a feed: to My feeds
        ld (args),a
        ld a,(nw_tsel)
        ld (args+1),a
        ld bc,2
        ld a,C_NADD
        call cmd
        ret c
        ld hl,txt_nw_added
        jr z,.done
        ld hl,txt_nw_there
        cp #0C
        jr z,.msg
        ld hl,txt_nw_full
        jr .msg
.done:  call nw_changed
        ld a,(nw_nf)
        dec a
        ld (nw_fsel),a
        call nw_fleft
        call nw_fright
        ld hl,txt_nw_added
.msg:   jp nw_msg
.del:   ld a,(nw_pane)
        or a
        ret nz
        ld a,(nw_nf)
        or a
        ret z
        ld a,(nw_fsel)
        ld e,a
        ld a,C_NDEL
        call cmd_u8
        ret c
        ret nz
        call nw_changed
        ld a,(nw_fsel)          ; (the one after it, or the last)
        ld hl,nw_nf
        cp (hl)
        jr c,.d2
        ld a,(hl)
        or a
        jr z,.d2
        dec a
.d2:    ld (nw_fsel),a
        call nw_fleft
        call nw_fright
        ld hl,txt_nw_removed
        jp nw_msg
.mup:   ld c,0
        jr .mv
.mdn:   ld c,1
.mv:    ld a,(nw_pane)
        or a
        ret nz
        ld a,(nw_fsel)
        ld (args),a
        ld a,c
        ld (args+1),a
        push bc
        ld bc,2
        ld a,C_NMOVE
        call cmd
        pop bc
        ret c
        ret nz
        ld a,(nw_fsel)
        dec a
        bit 0,c
        jr z,.m2
        add a,2
.m2:    ld (nw_fsel),a
        call nw_changed
        jp nw_fleft

nw_changed:                     ; My feeds changed: the names again, saved on leaving
        ld a,1
        ld (nw_dirty),a
        jp nw_favs

; out of My feeds: the headlines there are, else the first feed, else the player
nw_fback:
        ld a,(nw_n)
        or a
        jr z,.f
        ld a,(ckb+CK_NST)
        cp 2
        jr nz,.f
        ld a,(ckb+CK_NFEED)
        ld hl,nw_nf
        cp (hl)
        jr nc,.f
        ld (nw_feed),a
        jp nw_list
.f:     ld a,(nw_nf)
        or a
        jp z,fs_close
        xor a
        jp nw_fetch

;------------------------------------------------------------------------------
nw_keys:
        ld c,a
        ld a,(nw_msgon)         ; a key: the message goes
        or a
        jr z,.k
        xor a
        ld (nw_msgon),a
        push bc
        call nw_keyline
        pop bc
.k:     ld a,(eng_minor)
        cp 12
        ld a,c
        jp c,nw_kcommon
        ld a,(nw_view)
        cp V_FEEDS
        ld a,c
        jp z,nw_fkeys
        ld a,(nw_view)
        cp V_STORY
        ld a,c
        jp z,nw_skeys
        ; the headlines
        cp '1'
        jr c,.nd
        cp '9'+1
        jr nc,.nd
        sub '1'
        ld hl,nw_nf
        cp (hl)
        ret nc
        jp nw_fetch
.nd:    cp 30
        jr z,.up
        cp 31
        jr z,.down
        cp 29
        jr z,.left
        cp 28
        jr z,.right
        cp 13
        jr z,.enter
        cp 8
        jp z,nw_feeds
        cp 27
        jp z,fs_close
        and #DF
        cp 'F'
        jp z,nw_feeds
        jp nw_kcommon
.list:  ld a,(nw_wait)
        or a
        ret nz
        ld a,(nw_n)
        or a
        ret
.up:    call .list
        ret z
        ld a,(nw_sel)
        or a
        ret z
        dec a
        jp nw_newsel
.down:  call .list
        ret z
        ld a,(nw_sel)
        inc a
        ld hl,nw_n
        cp (hl)
        ret nc
        jp nw_newsel
.left:  call .list
        ret z
        ld a,(nw_sel)
        sub NL_ROWS
        jr nc,.l
        xor a
.l:     jp nw_newsel
.right: call .list
        ret z
        ld a,(nw_sel)
        add a,NL_ROWS
        ld hl,nw_n
        cp (hl)
        jr c,.r
        ld a,(hl)
        dec a
.r:     jp nw_newsel
.enter: call .list
        ret z
        jp nw_story

; a story's keys
nw_skeys:
        cp 30
        jr z,.up
        cp 31
        jr z,.down
        cp 29
        jr z,.pup
        cp 28
        jr z,.pdn
        cp 13
        jr z,.full
        cp 27
        jp z,nw_list
        cp 8
        jp z,nw_list
        and #DF
        cp 'F'
        jr z,.full
        cp 'N'
        jr z,.next
        cp 'P'
        jr z,.prev
        jp nw_kcommon
.up:    ld hl,(nw_top)
        dec hl
        jp nw_scroll
.down:  ld hl,(nw_top)
        inc hl
        jp nw_scroll
.pup:   ld hl,(nw_top)
        ld de,-NS_ROWS
        add hl,de
        jp nw_scroll
.pdn:   ld hl,(nw_top)
        ld de,NS_ROWS
        add hl,de
        jp nw_scroll
.full:  ld a,(nw_which)         ; the full article, or back to the summary
        xor 1
        ld (nw_which),a
        ld hl,0
        ld (nw_top),hl
        ld (nw_alen),hl
        or a
        jp z,nw_stext
        ld a,(nw_sel)
        ld e,a
        ld a,C_NFULL
        call cmd_u8
        ret c
        ld hl,txt_nw_nomem
        jp nz,nw_msg
        ld a,PVA_TXF_LOADING    ; (shown at once; nw_tick follows it)
        ld (nw_aflags),a
        jp nw_stext
.next:  ld a,(nw_sel)
        inc a
        ld hl,nw_n
        cp (hl)
        ret nc
        ld (nw_sel),a
        jp nw_story
.prev:  ld a,(nw_sel)
        or a
        ret z
        dec a
        ld (nw_sel),a
        jp nw_story

; the keys of every view: the pages, the playback keys (B = the key)
nw_kcommon:
        ld a,b
        and #DF
        cp 'T'
        jp z,fs_close
        cp 'C'
        ld c,PG_CLOCK
        jp z,pg_enter
        cp 'W'
        ld c,PG_WEATHER
        jp z,pg_enter
        cp 'G'
        ret z
        cp 'V'
        ret z
        cp 'Z'
        ret z
        ld a,b
        jp keys_common

;------------------------------------------------------------------------------
txt_nw_old:     db "The news needs engine 0.12 or newer",0
txt_nw_klist:   db " Enter read   Up/Down choose   Left/Right page   1-9 a feed   F My feeds",0
txt_nw_kstory:  db " Up/Down scroll  Left/Right page  Enter full article/summary  N/P next/prev  ESC",0
txt_nw_kfeeds:  db " Left/Right side  Enter read/add  D remove  U/J move  BS back  ESC headlines",0
txt_nw_kall:    db " C clock   W weather   T the player",0
txt_nw_fetch:   db "Fetching the stories...",0
txt_nw_fail:    db "The feed did not come (no internet, or the site does not answer)",0
txt_nw_nowifi:  db "The news needs the cartridge's WiFi",0
txt_nw_none:    db "No stories in this feed",0
txt_nw_nomem:   db "No room for the full article here",0
txt_nw_heads:   db "Headlines ",0
txt_nw_of:      db " of ",0
txt_nw_story:   db "  ",TX_VL,"  story ",0
txt_nw_lines:   db "lines ",0
txt_nw_ssum:    db " Summary   (Enter: the full article)",0
txt_nw_sart:    db " The full article",0
txt_nw_snone:   db " No full article from the site: the summary",0
txt_nw_sload:   db " Fetching the full article... ",0
txt_nw_kb:      db " KB",0
txt_nw_my:      db " My feeds: ",0
txt_nw_of20:    db " of 20",0
txt_nw_empty:   db 0
txt_nw_topics:  db " Add a feed: choose a topic",0
txt_nw_add:     db " Add a feed: ",0
txt_nw_added:   db " Added to My feeds",0
txt_nw_there:   db " That one is in My feeds already",0
txt_nw_full:    db " My feeds is full (20 feeds)",0
txt_nw_removed: db " Removed from My feeds",0
nw_wd:          db "Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0,"Sun",0
nw_mon:         db "Jan",0,"Feb",0,"Mar",0,"Apr",0,"May",0,"Jun",0,"Jul",0,"Aug",0,"Sep",0,"Oct",0,"Nov",0,"Dec",0
nw_bits:        db #80,#40,#20,#10,#08,#04,#02,#01
nw_glyphs:      db 0,0,0,#FC,0,0,0,0                    ; TX_HL
                db #20,#20,#20,#20,#20,#20,#20,#20      ; TX_VL
                db #FC,#FC,#FC,#FC,#FC,#FC,#FC,#FC      ; TX_BLK
                db #30,#38,#28,#28,#E8,#D8,#30,0        ; TX_NOTE

nw_view:        db 0
nw_nf:          db 0            ; My feeds
nw_feed:        db 0            ; the one shown
nw_n:           db 0            ; its stories
nw_first:       db 0
nw_sel:         db 0
nw_wait:        db 0
nw_which:       db 0            ; 0 the summary, 1 the full article
nw_aflags:      db 0
nw_top:         dw 0
nw_total:       dw 0
nw_alen:        dw 0
nw_adue:        dw 0
nw_pane:        db 0
nw_fsel:        db 0
nw_tsel:        db 0
nw_topic:       db #FF
nw_rn:          db 0
nw_dirty:       db 0
nw_msgon:       db 0
nw_msgt:        dw 0
nw_smin:        db 0
nw_tlen:        db 0
nw_toff:        db 0
nw_tdue:        dw 0
nw_bl:          ds 10
nw_t0:          ds 64
mod_news_end:
