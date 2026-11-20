;==============================================================================
; lyrics.asm - PICOAMP's lyrics page (L), a page module (see clock.asm).
;
; The words of what the PC plays, while the MSX is its screen and remote (the
; MSX link: PicoAmp for Windows' /screen station). The PC finds them (LRCLIB),
; wraps them to 40 characters and sends them with the song; the engine (0.18:
; LYRICS) keeps them and knows the line sung now from the PC's time.
;
;   row 0       what plays (a ticker)
;   row 1       LYRICS, synced or not
;   rows 2-21   the words, centred: synced, the line sung now in yellow on
;               row 9, the sung ones grey, the ones to come white; not
;               synced, they move through the song
;   row 22      where they come from
;   row 23      the keys
;
; Keys: Up/Down a row, Left/Right ten rows (they stay moved until the next
; song; 0 follows the song again), L, ESC, Enter, BS back; the playback keys.
;==============================================================================

LY_TOP   equ 2                  ; the first row of the words
LY_ROWS  equ 20
LY_NOW   equ 7                  ; the line sung now: this row of them (row 9)
LY_SYNC  equ 2                  ; PVA_LY_xxx
LY_PLAIN equ 3
LY_COL   equ WHITE*16+NAVY
LY_SUNG  equ GREY*16+NAVY
LY_LIT   equ YELLOW*16+BLUE_D
LY_ASK   equ 6                  ; interrupts between the engine's answers

mod_lyr:
        jp ly_open              ; the jump table (M_OPEN ...)
        jp ly_tick
        jp ly_ret
        jp ly_keys
        jp ly_info
        jp ly_ret
        jp ly_ret

;------------------------------------------------------------------------------
ly_open:
        call cls
        call setpal
        ld a,#FF
        ld (ly_gen),a           ; (the words come with the first pass)
        ld (ly_st),a
        ld hl,0
        ld (ly_man),hl
        ld hl,#8000
        ld (ly_top),hl          ; (nothing shown yet)
        call ly_info
        ld hl,txt_ly_head
        ld de,#0100
        ld b,32
        ld c,WHITE*16+BLUE_D
        call text6s
        ld hl,txt_ly_src
        ld de,#1600
        ld b,32
        ld c,GREY_D*16+NAVY
        call text6s
        ld hl,txt_ly_keys
        ld de,#1700
        ld b,32
        ld c,GREY*16+NAVY
        call text6s
        ld a,(eng_minor)
        cp 18
        ret nc
        ld hl,txt_ly_old
        ld d,LY_TOP+LY_NOW
        ld c,RED*16+NAVY
        jp ly_ctext
ly_ret: ret

; row 0: what plays
ly_info:  jp pg_row0

ly_keys:
        cp 27
        jp z,fs_close
        cp 13
        jp z,fs_close
        cp 8
        jp z,fs_close
        cp 30                   ; up
        ld hl,-1
        jr z,ly_move
        cp 31                   ; down
        ld hl,1
        jr z,ly_move
        cp 29                   ; left
        ld hl,-10
        jr z,ly_move
        cp 28                   ; right
        ld hl,10
        jr z,ly_move
        cp '0'
        jr z,ly_follow
        and #DF
        cp 'L'
        jp z,fs_close
        cp 'Z'
        jp z,fs_close
        cp 'G'
        ret z
        cp 'V'
        ret z
        ld a,b
        jp keys_common

; Up/Down/Left/Right: the words moved (HL rows) from where the song is
ly_move:
        ld de,(ly_man)
        add hl,de
        ld (ly_man),hl
        jr ly_ask
ly_follow:
        ld hl,0
        ld (ly_man),hl
        jr ly_ask

;------------------------------------------------------------------------------
; every few interrupts: the engine's head (state, gen, the row of now); the rows
; again when they or where they are changed
ly_tick:
        ld a,(eng_minor)
        cp 18
        ret c
        ld hl,(JIFFY)
        ld de,(ly_t)
        or a
        sbc hl,de
        ld de,LY_ASK
        or a
        sbc hl,de
        ret c
ly_ask:
        ld hl,(JIFFY)
        ld (ly_t),hl
        xor a                   ; the head only
        ld (args),a
        ld (args+1),a
        ld (args+2),a
        ld a,C_LYRICS
        ld bc,3
        call cmd
        ret c
        ret nz
        ld a,(reply)            ; the state and the words
        ld b,a
        ld a,(reply+1)
        ld c,a
        ld a,(ly_gen)
        cp c
        jr z,.same
        ld a,c                  ; new words: they follow the song again
        ld (ly_gen),a
        ld hl,0
        ld (ly_man),hl
        ld hl,#8000
        ld (ly_top),hl          ; (all rows again)
.same:  ld a,(ly_st)
        cp b
        jr z,.st
        ld a,b
        ld (ly_st),a
        call ly_state           ; the head's right side, a message
        ld hl,#8000
        ld (ly_top),hl
.st:    ld a,(ly_st)
        cp LY_SYNC
        jr z,.rows
        cp LY_PLAIN
        ret nz
.rows:  ; the first row shown: the row of now - LY_NOW + moved (none yet: -LY_NOW)
        ld hl,(reply+2)
        ld (ly_n),hl
        ld hl,(reply+4)
        ld a,h
        and l
        inc a
        jr nz,.n
        ld hl,0                 ; (before the first line: the first one there, not lit)
.n:     ld de,-LY_NOW
        add hl,de
        ld de,(ly_man)
        add hl,de
        ; not before -LY_NOW, not after the last row
        ld de,-LY_NOW
        call ly_cmp             ; HL < DE (signed): CF
        jr nc,.lo
        ex de,hl
.lo:    push hl
        ld hl,(ly_n)
        dec hl
        ex de,hl
        pop hl
        call ly_cmp
        jr c,.hi
        ex de,hl
.hi:    ld a,(reply+6)          ; the rows lit
        ld c,a
        ld de,(reply+4)
        ld a,(ly_lit)
        cp c
        jr nz,.draw
        push hl
        ld hl,(ly_now)
        or a
        sbc hl,de
        pop hl
        jr nz,.draw
        ld de,(ly_top)
        push hl
        or a
        sbc hl,de
        pop hl
        ret z                   ; the same rows, the same line: nothing to do
.draw:  ld (ly_top),hl
        ld a,c
        ld (ly_lit),a
        ld de,(reply+4)
        ld (ly_now),de
        jp ly_rows

; ly_cmp: HL - DE signed: CF when HL < DE
ly_cmp: push hl
        ld a,h
        xor d
        jp p,.same
        ld a,h                  ; signs differ: HL < DE when HL is negative
        rla
        pop hl
        ret
.same:  or a
        sbc hl,de
        pop hl
        ret

; the 20 rows from (ly_top): asked for (those that are there), then drawn
ly_rows:
        ld hl,(ly_top)
        ld a,h
        rla
        jr nc,.pos
        ld hl,0                 ; (the rows before the first: empty)
.pos:   ld (args),hl
        ld a,LY_ROWS
        ld (args+2),a
        ld a,C_LYRICS
        ld bc,3
        call cmd
        ret c
        ret nz
        ld ix,reply+8           ; the rows' texts, one after the other
        ld hl,(ly_top)
        ld (ly_i),hl
        ld d,LY_TOP
.row:   push de
        ld hl,(ly_i)
        ld a,h
        rla
        jr c,.empty             ; before the first
        ld de,(ly_n)
        or a
        sbc hl,de
        jr nc,.empty            ; after the last
        ld a,(ix+0)             ; the text to linebuf
        ld c,a
        ld b,0
        push ix
        pop hl
        inc hl
        ld de,linebuf
        ld a,c
        or a
        jr z,.z
        ldir
.z:     xor a
        ld (de),a
        ld c,(ix+0)
        ld b,0
        add ix,bc
        inc ix
        call ly_colour          ; C = the row's colours
        jr .put
.empty: xor a
        ld (linebuf),a
        ld c,LY_COL
.put:   pop de
        push de
        ld hl,linebuf
        call ly_ctext
        ld hl,(ly_i)
        inc hl
        ld (ly_i),hl
        pop de
        inc d
        ld a,d
        cp LY_TOP+LY_ROWS
        jr c,.row
        ret

; ly_colour: C = the colours of row (ly_i): lit (the line sung now), sung (before it), to come
ly_colour:
        ld c,LY_COL
        ld a,(ly_lit)
        or a
        ret z                   ; (none lit: not synced, or before the first line)
        ld hl,(ly_i)
        ld de,(ly_now)
        or a
        sbc hl,de
        ld c,LY_SUNG
        ret c                   ; before the line of now
        ld a,h
        or a
        ld c,LY_COL
        ret nz
        ld a,(ly_lit)
        cp l
        ret z
        ret c                   ; after it
        ld c,LY_LIT
        ret

; the head's right side for the state; the message for a state without words
ly_state:
        ld a,(ly_st)
        ld hl,txt_ly_sync
        cp LY_SYNC
        jr z,.h
        ld hl,txt_ly_plain
        cp LY_PLAIN
        jr z,.h
        ld hl,txt_ly_blank
.h:     ld de,#0114
        ld b,12
        ld c,CYAN*16+BLUE_D
        push af
        call text6s
        pop af
        cp LY_SYNC
        ret z
        cp LY_PLAIN
        ret z
        ; no rows: the message in the middle, the other rows empty
        ld hl,txt_ly_none
        or a
        jr z,.m
        ld hl,txt_ly_looking
        cp 1
        jr z,.m
        ld hl,txt_ly_instr
        cp 4
        jr z,.m
        ld hl,txt_ly_notfound
.m:     push hl
        ld d,LY_TOP
.cl:    push de
        ld hl,txt_ly_blank
        ld c,LY_COL
        call ly_ctext
        pop de
        inc d
        ld a,d
        cp LY_TOP+LY_ROWS
        jr c,.cl
        pop hl
        ld d,LY_TOP+LY_NOW
        ld c,LY_COL
        ; fall through

; ly_ctext: HL = text, D = row, C = colours: in the middle of the whole row
ly_ctext:
        push hl
        push bc
        push de
        ld e,0                  ; letters
.n:     ld a,(hl)
        or a
        jr z,.e
        inc hl
        inc e
        jr .n
.e:     ld a,e                  ; the pixels left of the start: -(256 - 6 n) / 2 = 3 n - 128
        add a,a
        add a,e
        sub 128
        ld l,a
        ld h,#FF
        jr c,.h
        ld h,0
.h:     ld (t6_off),hl
        ld hl,0
        ld (t6_cycle),hl
        pop de
        ld e,0
        pop bc
        ld b,32
        pop hl
        jp text6

txt_ly_head:     db " LYRICS",0
txt_ly_sync:     db "SYNCED",0
txt_ly_plain:    db "NOT SYNCED",0
txt_ly_blank:    db 0
txt_ly_src:      db " Words: LRCLIB.net (through the PC)",0
txt_ly_keys:     db " Up/Down Left/Right move, 0 follow, L back",0
txt_ly_none:     db "Play the PC's screen station to see its words",0
txt_ly_looking:  db "Looking for the words...",0
txt_ly_instr:    db "Instrumental: no words",0
txt_ly_notfound: db "LRCLIB has no words for this song",0
txt_ly_old:      db "The lyrics need engine 0.18",0
ly_gen:          db 0
ly_st:           db 0
ly_lit:          db 0
ly_t:            dw 0
ly_man:          dw 0
ly_top:          dw 0
ly_now:          dw 0
ly_n:            dw 0
ly_i:            dw 0
mod_lyr_end:
