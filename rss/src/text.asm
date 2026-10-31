;==============================================================================
; text.asm - text in VRAM (a summary, an article) wrapped into lines: an
; index of where each line starts, built as the text comes in; a line shown
; is wrapped again from its start (the same rule).
; Paragraphs end at a 10; an empty line between paragraphs.
;==============================================================================

LINES_MAX equ 600
BLANK     equ #8000

        VAR ix_base, 2          ; the text: VRAM, length
        VAR ix_len, 2
        VAR ix_pos, 2           ; where the next line is looked for
        VAR ix_para, 1          ; a paragraph begins
        VAR ix_any, 1
        VAR ix_n, 2             ; lines
        VAR lines, LINES_MAX*2
        VAR win, 100            ; a line's window (the width + 1)
        VAR win_k, 1

; ix_reset: HL = VRAM, BC = length
ix_reset:
        ld (ix_base),hl
        ld (ix_len),bc
        ld hl,0
        ld (ix_pos),hl
        ld (ix_n),hl
        ld a,1
        ld (ix_para),a
        xor a
        ld (ix_any),a
        ret

; ix_run: lines to HL (a length: the text before it is complete)
ix_run: ld (ixr_lim),hl
.l:     ld hl,(ix_n)
        ld de,LINES_MAX-1
        or a
        sbc hl,de
        ret nc
        ld hl,(ix_pos)          ; spaces, paragraph ends
.sk:    ld de,(ixr_lim)
        push hl
        or a
        sbc hl,de
        pop hl
        jr nc,.e
        push hl
        ld de,(ix_base)
        add hl,de
        call vset_r
        in a,(VDP_D)
        ei
        pop hl
        cp ' '
        jr z,.sp
        cp 10
        jr nz,.tx
        ld a,1
        ld (ix_para),a
.sp:    inc hl
        jr .sk
.e:     ld (ix_pos),hl
        ret
.tx:    ld (ix_pos),hl
        ld a,(ix_para)          ; a new paragraph: an empty line before it
        or a
        jr z,.np
        xor a
        ld (ix_para),a
        ld a,(ix_any)
        or a
        ld a,1
        ld (ix_any),a
        jr z,.np
        ld hl,BLANK
        call ix_add
.np:    ld hl,(ix_pos)
        call ix_add
        ld hl,(ix_pos)
        ld de,(ixr_lim)
        call line_len
        ld hl,(ix_pos)
        ld e,a
        ld d,0
        add hl,de
        ld (ix_pos),hl
        jr .l
        VAR ixr_lim, 2

ix_add: ex de,hl
        ld hl,(ix_n)
        push hl
        add hl,hl
        ld bc,lines
        add hl,bc
        ld (hl),e
        inc hl
        ld (hl),d
        pop hl
        inc hl
        ld (ix_n),hl
        ret

; line_len: a line from HL (in the text, up to DE) -> A = the bytes it takes;
; win has them, win_k how many were read
line_len:
        push hl
        ex de,hl
        pop de
        push de
        or a
        sbc hl,de               ; bytes left
        ld a,(sw)
        dec a
        ld c,a                  ; the width + 1: (sw - 2) + 1
        ld b,0
        push hl
        or a
        sbc hl,bc
        pop hl
        jr nc,.w
        ld c,l
.w:     pop hl
        ld de,(ix_base)
        add hl,de
        ld de,win
        push bc
        call vr_blk
        pop bc
        ld hl,win               ; to a paragraph's end
        ld b,0
.n:     ld a,b
        cp c
        jr z,.ne
        ld a,(hl)
        cp 10
        jr z,.ne
        inc hl
        inc b
        jr .n
.ne:    ld a,b
        ld (win_k),a
        ld a,(sw)
        sub 2
        ld c,a                  ; C = the width
        ld a,b
        cp c
        ret c
        ret z                   ; (it fits)
        ld b,c                  ; longer: back to a space
.b:     ld hl,win
        ld a,b
        call add_hla
        ld a,(hl)
        cp ' '
        ld a,b
        ret z
        djnz .b
        ld a,c                  ; (a long word: cut)
        ret

; ix_show: the line k (HL) at row D (from column 1, the width), or empty
ix_show:
        push de
        ld de,(ix_n)
        push hl
        or a
        sbc hl,de
        pop hl
        jr nc,.empty
        add hl,hl
        ld de,lines
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        bit 7,h
        jr nz,.empty
        ld de,(ix_len)
        call line_len
        ld c,a                  ; without the spaces at its end
.t:     ld a,c
        or a
        jr z,.z
        ld hl,win
        dec a
        call add_hla
        ld a,(hl)
        cp ' '
        jr nz,.z
        dec c
        jr .t
.z:     ld hl,win
        ld a,c
        call add_hla
        ld (hl),0
        pop de
        ld hl,win
        ld e,1
        ld a,(sw)
        sub 2
        ld b,a
        jp tx_text
.empty: pop de
        jp tx_clrrow

; wrap_ram: the text at HL wrapped (no gaps) into rows from D, B rows, from column 1
wrap_ram:
.r:     push bc
        push de
        call skipsp
        ld a,(sw)
        sub 2
        ld c,a
        ld b,0                  ; its length to the end, at most the width + 1
        push hl
.l:     ld a,(hl)
        or a
        jr z,.le
        inc hl
        inc b
        ld a,b
        dec a
        cp c
        jr c,.l
.le:    pop hl
        ld a,b
        cp c
        jr c,.fit
        jr z,.fit
        ld b,c                  ; back to a space
.bk:    push hl
        ld a,b
        call add_hla
        ld a,(hl)
        pop hl
        cp ' '
        jr z,.fit
        djnz .bk
        ld b,c
.fit:   ld de,win
        push bc
        ld c,b
        ld b,0
        ld a,c
        or a
        jr z,.cz
        ldir
.cz:    xor a
        ld (de),a
        pop bc
        pop de
        push hl
        ld hl,win
        ld e,1
        ld a,(sw)
        sub 2
        ld b,a
        call tx_text
        pop hl
        inc d
        pop bc
        djnz .r
        ret
