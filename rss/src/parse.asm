;==============================================================================
; parse.asm - a feed (RSS 2.0, RSS 1.0/RDF, Atom) read as it comes in, and
; HTML to plain text (a field of the feed, its <content:encoded>, or a web
; page's <p> paragraphs), into VRAM through a small writer. As PicoAmp's
; engine (pva_news.c) does it.
;
; The stories go to the pool in VRAM, one after the other, each as tagged
; strings: 'T' title, 'S' summary, 'L' link, 'D' a date not understood
; (each with its 0); items[] has where each starts, its time and flags.
;==============================================================================

MAX_ITEMS equ 50

        VAR w_base, 2           ; the writer: VRAM where it goes,
        VAR w_size, 2           ; the room,
        VAR w_len, 2            ; the bytes put,
        VAR w_fl, 2             ; the bytes written out to VRAM,
        VAR w_left, 2           ; the room left,
        VAR w_cnt, 1            ; the bytes in wbuf,
        VAR w_ptr, 2            ; where the next goes in it,
        VAR w_full, 1           ; no more room,
        VAR w_lastnl, 2         ; after the last paragraph's end
        VAR wbuf, 64

; w_open: HL = VRAM, DE = room
w_open: ld (w_base),hl
        ld (w_size),de
        ld (w_left),de
        ld hl,0
        ld (w_len),hl
        ld (w_fl),hl
        ld (w_lastnl),hl
        xor a
        ld (w_full),a
        ld (w_cnt),a
        ld hl,wbuf
        ld (w_ptr),hl
        ret

; w_put: A (all registers kept)
w_put:  push hl
        ld hl,(w_left)
        dec hl
        bit 7,h
        jr nz,.full
        ld (w_left),hl
        ld hl,(w_ptr)
        ld (hl),a
        inc hl
        ld (w_ptr),hl
        ld hl,(w_len)
        inc hl
        ld (w_len),hl
        cp 10
        jr z,.nl
.c:     ld hl,w_cnt
        inc (hl)
        bit 6,(hl)
        jr nz,.fl
        pop hl
        ret
.nl:    ld (w_lastnl),hl
        jr .c
.fl:    push af
        call w_flush
        pop af
        pop hl
        ret
.full:  push af
        ld a,1
        ld (w_full),a
        pop af
        pop hl
        ret

w_flush:
        push hl
        push de
        push bc
        ld a,(w_cnt)
        or a
        jr z,.e
        ld c,a
        ld b,0
        ld hl,(w_base)
        ld de,(w_fl)
        add hl,de
        ld de,wbuf
        call vw_blk
        ld hl,(w_len)
        ld (w_fl),hl
        xor a
        ld (w_cnt),a
        ld hl,wbuf
        ld (w_ptr),hl
.e:     pop bc
        pop de
        pop hl
        ret

; w_trunc: back to HL bytes
w_trunc:
        push de
        push bc
        ex de,hl                ; DE = the new length
        ld hl,(w_len)           ; the room again: + (len - new)
        or a
        sbc hl,de
        ld bc,(w_left)
        add hl,bc
        ld (w_left),hl
        ld (w_len),de
        ld hl,(w_fl)
        ex de,hl
        or a
        sbc hl,de               ; new - flushed
        jr nc,.b
        add hl,de               ; (before what is out: from there)
        ld (w_fl),hl
        xor a
        jr .c
.b:     ld a,l                  ; (in the buffer still)
.c:     ld (w_cnt),a
        push af
        ld hl,wbuf
        call add_hla
        ld (w_ptr),hl
        pop af
        ld hl,(w_len)
        ex de,hl
        ld hl,(w_lastnl)
        or a
        sbc hl,de
        jr c,.n
        ld (w_lastnl),de
.n:     ex de,hl
        pop bc
        pop de
        ret

;------------------------------------------------------------------------------
; HTML to text
H_TEXT    equ 0
H_TAG     equ 1
H_ATTR    equ 2
H_COMMENT equ 3
H_RAW     equ 4
H_ENT     equ 5

        VAR hs, 1
        VAR htag, 12
        VAR htl, 1
        VAR hclose, 1
        VAR hqd, 1
        VAR hqs, 1
        VAR hraw, 12            ; "script" while in it
        VAR hrafter, 1          ; (raw after the attributes)
        VAR hrm, 1
        VAR hcm, 1
        VAR hent, 10
        VAR hel, 1
        VAR hu8, 2
        VAR hu8n, 1
        VAR hbig, 1
        VAR hsp, 1              ; a space is due
        VAR hnl, 1              ; a paragraph's end is due
        VAR hpara, 2            ; where the paragraph began
        VAR hpage, 1            ; a web page: only <p> text, not in menus etc.
        VAR htitle, 1           ; a title: paragraphs become spaces
        VAR hinp, 1
        VAR hskip, 1
        VAR hart, 1
        VAR hdone, 1

; h_start: A = page, C = title
h_start:
        push af
        ld hl,hs
        ld de,hs+1
        ld bc,hdone-hs
        ld (hl),0
        ldir
        pop af
        ld (hpage),a
        ld a,c
        ld (htitle),a
        ld hl,(w_len)
        ld (hpara),hl
        ret

h_emit: ld c,a
        ld a,(hpage)
        or a
        jr z,.on
        ld a,(hinp)
        or a
        ret z
        ld a,(hskip)
        or a
        ret nz
.on:    ld a,(w_full)
        or a
        ret nz
        ld a,c
        cp ' '
        jr nz,.ch
        ld hl,(w_len)
        ld de,(hpara)
        or a
        sbc hl,de
        ret z
        ld a,1
        ld (hsp),a
        ret
.ch:    ld a,(hnl)
        or a
        jr z,.s
        xor a
        ld (hnl),a
        ld (hsp),a
        ld a,10
        call w_put
        ld hl,(w_len)
        ld (hpara),hl
.s:     ld a,(hsp)
        or a
        jr z,.p
        xor a
        ld (hsp),a
        ld a,' '
        call w_put
.p:     ld a,c
        jp w_put

; the end of a paragraph: short ones on a web page are left out (buttons, captions)
h_para: xor a
        ld (hsp),a
        ld hl,(w_len)
        ld de,(hpara)
        or a
        sbc hl,de
        jr z,.e
        ld a,(hpage)
        or a
        jr z,.keep
        ld a,h
        or a
        jr nz,.keep
        ld a,l
        cp 40
        jr nc,.keep
        ld hl,(hpara)
        call w_trunc
        jr .e
.keep:  ld a,(htitle)
        or a
        ld a,1
        jr nz,.t
        ld (hnl),a
        jr .e
.t:     ld (hsp),a
.e:     ld hl,(w_len)
        ld (hpara),hl
        ret

; h_cp: DE = a character (Unicode) out as text
h_cp:   ld a,d
        or a
        jr nz,.f
        ld a,e
        cp 9
        jr z,.sp
        cp 10
        jr z,.sp
        cp 13
        jr z,.sp
        cp #A0
        jr nz,.f
.sp:    ld e,' '
.f:     call fold
        or a
        ret z
        cp 1
        jr z,.dots
        cp 2
        jp nz,h_emit
        ld a,'E'
        call h_emit
        ld a,'U'
        call h_emit
        ld a,'R'
        jp h_emit
.dots:  ld a,'.'
        call h_emit
        ld a,'.'
        call h_emit
        ld a,'.'
        jp h_emit

; fold: DE (Unicode) -> A: the MSX's character (0: none, 1: "...", 2: "EUR")
fold:   ld a,d
        or a
        jr nz,.hi
        ld a,e
        cp #7F
        jr nc,.up
        cp ' '
        ret nc
        xor a
        ret
.up:    cp #A0
        jr nc,.a0
        xor a                   ; (C1 controls)
        ret
.a0:    cp #C0
        jr nc,.acc
        sub #A0
        ld c,a
        ld a,(intl)
        or a
        jr z,.a1
        ld hl,fold_a0i
        ld a,c
        call add_hla
        ld a,(hl)
        or a
        ret nz
.a1:    ld hl,fold_a0
        ld a,c
        call add_hla
        ld a,(hl)
        cp '_'                  ; (none)
        ret nz
        xor a
        ret
.acc:   sub #C0
        ld c,a
        ld a,(intl)
        or a
        jr z,.ac1
        ld hl,fold_c0i
        ld a,c
        call add_hla
        ld a,(hl)
        or a
        ret nz
.ac1:   ld hl,fold_c0
        ld a,c
        call add_hla
        ld a,(hl)
        ret
.hi:    ld hl,fold_hi
.h:     ld a,(hl)
        inc hl
        or (hl)
        jr z,.q
        dec hl
        ld a,(hl)
        cp e
        inc hl
        jr nz,.nx
        ld a,(hl)
        cp d
        jr nz,.nx
        inc hl
        ld a,(hl)
        ret
.nx:    inc hl
        inc hl
        jr .h
.q:     ld a,'?'
        ret

fold_a0: db " !cL$Y|S",'"',"cA",'"',"-_R-o+23'uP*,1o",'"',"???"   ; A0-BF ('_' none)
         db "?"
fold_a0i:db 0,#AD,#9B,#9C,0,#9D,0,0, 0,0,#A6,#AE,#AA,0,0,0
         db #F8,#F1,#FD,0,0,#E6,0,#FA, 0,0,#A7,#AF,#AC,#AB,0,#A8
fold_c0: db "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty"
fold_c0i:db 0,0,0,0,#8E,#8F,#92,#80, 0,#90,0,0,0,0,0,0
         db 0,#A5,0,0,0,0,#99,0, 0,0,0,0,#9A,0,0,#E1
         db #85,#A0,#83,0,#84,#86,#91,#87, #8A,#82,#88,#89,#8D,#A1,#8C,#8B
         db 0,#A4,#95,#A2,#93,0,#94,#F6, 0,#97,#A3,#96,#81,0,0,#98
fold_hi: dw #2022 : db '*'
         dw #2032 : db "'"
         dw #2018 : db "'"
         dw #2019 : db "'"
         dw #201A : db ","
         dw #201C : db '"'
         dw #201D : db '"'
         dw #201E : db '"'
         dw #2013 : db '-'
         dw #2014 : db '-'
         dw #2212 : db '-'
         dw #2026 : db 1
         dw #20AC : db 2
         dw #200B : db 0
         dw #200C : db 0
         dw #200D : db 0
         dw #FEFF : db 0
         dw #2122 : db 0
         dw 0

; the tags
h_tag:  ld a,(htl)
        or a
        ret z
        ld hl,htag
        call add_hla
        ld (hl),0
        ld a,(hclose)
        or a
        jr nz,.nr
        ld hl,tl_raws
        call in_list
        jr nz,.nr
        ld hl,htag              ; raw text to its end tag
        ld de,hraw
        ld bc,12
        ldir
        xor a
        ld (hrm),a
        ld a,H_RAW
        ld (hs),a
        ret
.nr:    ld a,(hpage)
        or a
        jr z,.bl
        ld hl,tl_skips
        call in_list
        jr nz,.np
        ld hl,hskip
        ld a,(hclose)
        or a
        jr z,.si
        ld a,(hl)
        or a
        jr z,.np
        dec (hl)
        jr .np
.si:    ld a,(hl)
        cp 200
        jr nc,.np
        inc (hl)
.np:    ld hl,htag
        ld de,tg_p
        call str_eq
        jr nz,.na
        call h_para
        ld a,(hclose)
        or a
        ld a,1
        jr z,.pi
        ld a,(hinp)
        or a
        ret z
        dec a
.pi:    ld (hinp),a
        ret
.na:    ld hl,htag
        ld de,tg_article
        call str_eq
        jr nz,.bl
        ld a,(hclose)
        or a
        jr nz,.ac
        ld a,1
        ld (hart),a
        jr .bl
.ac:    ld a,(hart)
        or a
        jr z,.bl
        ld hl,(w_len)
        ld de,600
        or a
        sbc hl,de
        jr c,.bl
        ld a,1
        ld (hdone),a
.bl:    ld hl,tl_blocks
        call in_list
        ret nz
        jp h_para

; in_list: Z when htag is one of the strings at HL (an empty one ends them)
in_list:
        ld a,(hl)
        or a
        jr z,.no
        push hl
        ld de,htag
        ex de,hl
        call str_eq
        pop hl
        ret z
        call skipz
        jr in_list
.no:    inc a                   ; NZ
        ret

tl_blocks: db "p",0,"br",0,"div",0,"li",0,"h1",0,"h2",0,"h3",0,"h4",0,"h5",0,"h6",0
           db "blockquote",0,"tr",0,"ul",0,"ol",0,"section",0,"article",0,"table",0,"hr",0,0
tl_raws:   db "script",0,"style",0,"noscript",0,"svg",0,"template",0,"iframe",0,"head",0,0
tl_skips:  db "nav",0,"header",0,"footer",0,"aside",0,"form",0,"figure",0,"figcaption",0
           db "button",0,"label",0,"select",0,"menu",0,0
tg_p:      db "p",0
tg_article:db "article",0

; an entity: &name; or &#n; / &#xh;
h_entity:
        ld a,(hel)
        ld hl,hent
        call add_hla
        ld (hl),0
        ld a,(hent)
        cp '#'
        jr nz,.nm
        ld hl,hent+1
        call ent_num
        jp h_cp
.nm:    ld hl,ent_names
.l:     ld a,(hl)
        or a
        jr z,.un
        push hl
        ld de,hent
        call str_eq
        pop hl
        jr z,.f
        call skipz
        inc hl
        inc hl
        jr .l
.f:     call skipz
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or e
        ret z                   ; (&shy;)
        jp h_cp
.un:    ld a,'&'                ; not known: as it was
        call h_emit
        ld hl,hent
.u:     ld a,(hl)
        or a
        jr z,.ue
        push hl
        call h_emit
        pop hl
        inc hl
        jr .u
.ue:    ld a,';'
        jp h_emit

; ent_num: HL = "123" or "x7B" -> DE
ent_num:
        ld a,(hl)
        or #20
        cp 'x'
        jp nz,num
        inc hl
        ld de,0
.h:     ld a,(hl)
        call lc
        sub '0'
        cp 10
        jr c,.d
        sub 'a'-'0'
        cp 6
        ret nc
        add a,10
.d:     ex de,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        or l
        ld l,a
        ex de,hl
        inc hl
        jr .h

ent_names:
        db "amp",0 : dw '&'
        db "lt",0 : dw '<'
        db "gt",0 : dw '>'
        db "quot",0 : dw '"'
        db "apos",0 : dw "'"
        db "nbsp",0 : dw ' '
        db "rsquo",0 : dw "'"
        db "lsquo",0 : dw "'"
        db "rdquo",0 : dw '"'
        db "ldquo",0 : dw '"'
        db "ndash",0 : dw '-'
        db "mdash",0 : dw '-'
        db "hellip",0 : dw #2026
        db "euro",0 : dw #20AC
        db "eacute",0 : dw #E9
        db "egrave",0 : dw #E8
        db "euml",0 : dw #EB
        db "auml",0 : dw #E4
        db "ouml",0 : dw #F6
        db "uuml",0 : dw #FC
        db "szlig",0 : dw #DF
        db "iuml",0 : dw #EF
        db "ccedil",0 : dw #E7
        db "aacute",0 : dw #E1
        db "oacute",0 : dw #F3
        db "iacute",0 : dw #ED
        db "ntilde",0 : dw #F1
        db "agrave",0 : dw #E0
        db "ecirc",0 : dw #EA
        db "copy",0 : dw 'c'
        db "shy",0 : dw 0
        db 0

; h_byte: A = the next byte of HTML
h_byte: ld c,a
        ld a,(hs)
        or a
        jp z,hb_text
        dec a
        jp z,hb_tag
        dec a
        jp z,hb_attr
        dec a
        jp z,hb_comment
        dec a
        jp z,hb_raw
        ; H_ENT
        ld a,c
        cp ';'
        jr nz,.n
        xor a
        ld (hs),a
        jp h_entity
.n:     call isalnum
        jr nz,.no
        ld a,(hel)
        cp 9
        jr nc,.no
        ld hl,hent
        call add_hla
        ld (hl),c
        ld hl,hel
        inc (hl)
        ret
.no:    push bc                 ; not an entity: as it was, then this byte
        xor a
        ld (hs),a
        ld (hent+9),a
        ld a,(hel)
        ld hl,hent
        call add_hla
        ld (hl),0
        ld a,'&'
        call h_emit
        ld hl,hent
.u:     ld a,(hl)
        or a
        jr z,.ue
        push hl
        call h_emit
        pop hl
        inc hl
        jr .u
.ue:    pop bc
        ld a,c
        jr h_byte

; h_run: BC bytes of HTML at HL, to a byte D or E (HL there, NC), or the end (BC = 0);
; on a page: CF when it has what it wants (the article's end, no more room)
; (text, scripts, attributes and comments go by without h_byte for each byte)
h_run:  ld a,b
        or c
        ret z
        ld a,(hl)
        cp d
        ret z
        cp e
        ret z
        ld a,(hs)
        or a
        jr nz,.nt
        ld a,(hu8n)
        or a
        jr nz,.sl
        ld a,(hl)               ; text: a plain character straight out
        cp ' '
        jr c,.sl
        cp #7F
        jr nc,.sl
        cp '<'
        jr z,.sl
        cp '&'
        jr z,.sl
        push hl
        push de
        push bc
        call h_emit
        jr .nx
.nt:    cp H_RAW
        jr nz,.n2
        ld a,(hrm)
        or a
        jr nz,.sl
.r:     ld a,(hl)               ; a script: to the next '<'
        cp '<'
        jr z,.sl
        cp d
        ret z
        cp e
        ret z
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.r
        ret
.n2:    cp H_ATTR
        jr nz,.n3
.a:     ld a,(hl)               ; attributes: to a quote or the '>'
        cp '"'
        jr z,.sl
        cp "'"
        jr z,.sl
        cp '>'
        jr z,.sl
        cp d
        ret z
        cp e
        ret z
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.a
        ret
.n3:    cp H_COMMENT
        jr nz,.sl
        ld a,(hcm)
        cp 10
        jr nz,.sl
.c:     ld a,(hl)               ; in a comment: to a '-'
        cp '-'
        jr z,.sl
        cp d
        ret z
        cp e
        ret z
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.c
        ret
.sl:    push hl
        push de
        push bc
        ld a,(hl)
        call h_byte
.nx:    pop bc
        pop de
        pop hl
        inc hl
        dec bc
        ld a,(hpage)
        or a
        jp z,h_run
        ld a,(hdone)
        push hl
        ld hl,w_full
        or (hl)
        pop hl
        jp z,h_run
        scf
        ret

; Z when C is a letter, a digit or '#'
isalnum:
        ld a,c
        cp '#'
        ret z
        call lc
        sub 'a'
        cp 26
        jr c,.y
        ld a,c
        sub '0'
        cp 10
        jr c,.y
        or #FF                  ; NZ
        ret
.y:     cp a
        ret

hb_text:
        ld a,c
        cp '<'
        jr nz,.n1
        ld a,H_TAG
        ld (hs),a
        xor a
        ld (htl),a
        ld (hclose),a
        ret
.n1:    cp '&'
        jr nz,.n2
        ld a,H_ENT
        ld (hs),a
        xor a
        ld (hel),a
        ret
.n2:    cp #80
        jr nc,.u8
        xor a
        ld (hu8n),a
        ld e,c
        ld d,0
        jp h_cp
.u8:    cp #C0
        jr c,.cont
        ld b,1                  ; the first byte of a sequence
        ld e,#1F
        cp #E0
        jr c,.s
        ld b,2
        ld e,#0F
        cp #F0
        jr c,.s
        ld b,3
        ld e,#07
.s:     and e
        ld (hu8),a
        xor a
        ld (hu8+1),a
        ld a,b
        ld (hu8n),a
        cp 3                    ; (4 bytes: emoji and the like, left out)
        ld a,0
        jr nz,.sb
        inc a
.sb:    ld (hbig),a
        ret
.cont:  ld a,(hu8n)
        or a
        ret z
        dec a
        ld (hu8n),a
        ld hl,(hu8)             ; hu8 << 6 | (c & 3F)
        ld b,6
.sh:    add hl,hl
        djnz .sh
        ld a,c
        and #3F
        or l
        ld l,a
        ld (hu8),hl
        ld a,(hu8n)
        or a
        ret nz
        ld a,(hbig)
        or a
        ret nz
        ex de,hl
        jp h_cp

hb_tag: ld a,(htl)
        or a
        jr nz,.n
        ld a,(hclose)
        or a
        jr nz,.n
        ld a,c
        cp '/'
        jr nz,.n0
        ld a,1
        ld (hclose),a
        ret
.n0:    cp '!'
        jr nz,.n
        ld a,H_COMMENT
        ld (hs),a
        xor a
        ld (hcm),a
        ret
.n:     ld a,c
        cp '>'
        jr z,.end
        cp ' '
        jr z,.end
        cp 9
        jr z,.end
        cp 13
        jr z,.end
        cp 10
        jr z,.end
        cp '/'
        jr z,.end
        ld a,(htl)
        cp 11
        ret nc
        ld hl,htag
        call add_hla
        ld a,c
        call lc
        ld (hl),a
        ld hl,htl
        inc (hl)
        ret
.end:   ld a,c
        cp '>'
        ld a,H_TEXT
        jr z,.e2
        ld a,H_ATTR
.e2:    ld (hs),a
        xor a
        ld (hqd),a
        ld (hqs),a
        push bc
        call h_tag
        pop bc
        ld a,(hs)
        cp H_RAW
        ret nz
        ld a,c
        cp '>'
        ret z
        ld a,H_ATTR             ; (raw after the attributes)
        ld (hs),a
        ld a,1
        ld (hrafter),a
        ret

hb_attr:
        ld a,c
        cp '"'
        jr nz,.n1
        ld a,(hqs)
        or a
        ret nz
        ld a,(hqd)
        xor 1
        ld (hqd),a
        ret
.n1:    cp "'"
        jr nz,.n2
        ld a,(hqd)
        or a
        ret nz
        ld a,(hqs)
        xor 1
        ld (hqs),a
        ret
.n2:    cp '>'
        ret nz
        ld a,(hqd)
        ld hl,hqs
        or (hl)
        ret nz
        ld a,(hrafter)
        or a
        jr z,.t
        xor a
        ld (hrafter),a
        ld (hrm),a
        ld a,H_RAW
        ld (hs),a
        ret
.t:     xor a
        ld (hs),a
        ret

hb_comment:                     ; <!-- ... --> (hcm 10..12: dashes seen) and <!DOCTYPE ...> (hcm FF)
        ld a,(hcm)
        or a
        jr nz,.n0
        ld a,c
        cp '>'
        jr z,.text
        cp '-'
        ld a,1
        jr z,.set
        ld a,#FF
.set:   ld (hcm),a
        ret
.n0:    cp #FF
        jr nz,.n1
        ld a,c
        cp '>'
        ret nz
.text:  xor a
        ld (hs),a
        ret
.n1:    cp 1
        jr nz,.n2
        ld a,c
        cp '-'
        ld a,10
        jr z,.set
        ld a,#FF
        jr .set
.n2:    ld a,c
        cp '-'
        jr nz,.n3
        ld a,(hcm)
        cp 12
        ret nc
        inc a
        ld (hcm),a
        ret
.n3:    cp '>'
        jr nz,.n4
        ld a,(hcm)
        cp 12
        jr z,.text
.n4:    ld a,10
        ld (hcm),a
        ret

hb_raw: push bc                 ; to "</name"
        ld hl,hraw
        call strlen
        ld e,c
        pop bc
        ld a,(hrm)
        or a
        ld b,'<'
        jr z,.w
        cp 1
        ld b,'/'
        jr z,.w
        sub 2
        ld hl,hraw
        call add_hla
        ld b,(hl)
.w:     ld a,c
        call lc
        cp b
        jr nz,.no
        ld a,(hrm)
        inc a
        ld (hrm),a
        sub e
        sub 2
        ret nz
        ld a,H_ATTR
        ld (hs),a
        xor a
        ld (hqd),a
        ld (hqs),a
        ld (hraw),a
        ret
.no:    ld a,c
        cp '<'
        ld a,1
        jr z,.r
        xor a
.r:     ld (hrm),a
        ret

;------------------------------------------------------------------------------
; the feed
X_TEXT    equ 0
X_TAG     equ 1
X_CDATA   equ 2
X_COMMENT equ 3
X_SKIP    equ 4
M_LIST    equ 0
M_ART     equ 1
F_NONE    equ 0
F_TITLE   equ 1
F_TEXT    equ 2
F_DATE    equ 3
F_LINK    equ 4
F_CONTENT equ 5
FBUF_MAX  equ 319

        VAR xs, 1
        VAR xmode, 1
        VAR xitem, 1
        VAR xtag, 24
        VAR xtl, 1
        VAR tag_close, 1
        VAR tag_skip, 1
        VAR tag_link, 1
        VAR cd_match, 1
        VAR cdpre, 9
        VAR cdpre_n, 1
        VAR in_item, 1
        VAR field, 1
        VAR in_ent, 1
        VAR xent, 10
        VAR xel, 1
        VAR fbuf, FBUF_MAX+1    ; a link / a date as it comes (or a tag's attributes)
        VAR alen, 2
        VAR items, MAX_ITEMS*7  ; per story: where in the pool, days, minutes, flags
        VAR nitems, 1
        VAR feed_full, 1
        VAR it_start, 2
        VAR it_have, 1          ; 1 title, 2 summary, 4 link, 8 date
        VAR it_days, 2
        VAR it_min, 2
        VAR it_clen, 2
        VAR it_tlen, 2
        VAR fstart, 2
        VAR a_story, 1          ; (M_ART: the story whose content is wanted)
        VAR a_stop, 1

; x_run: BC bytes of the feed at HL -> CF: enough (the stories are full, or the article in)
; (the bytes that change nothing go by quickly: text between the tags, attributes,
; CDATA that is only counted or left out)
x_run:
.l:     ld a,b
        or c
        jr z,.e
        ld a,(xs)
        or a
        jr nz,.n
        ld a,(field)
        or a
        jr z,.t
        cp F_DATE               ; a title or a summary: through h_run to '<' or '&'
        jp nc,.slow
        ld a,(in_ent)
        or a
        jp nz,.slow
        ld de,'<'*256+'&'
.hr:    call h_run
        ld a,b
        or c
        jr z,.e
        jp .slow
.t:     ld a,(hl)               ; text, not in a field: to the next '<'
        cp '<'
        jr z,.slow
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.t
.e:     or a
        ret
.n:     cp X_CDATA
        jr nz,.n2
        ld a,(cd_match)
        or a
        jr nz,.slow
        ld a,(field)
        or a
        jr z,.sk
        ld de,']'*257
        cp F_DATE
        jr c,.hr                ; (a title, a summary: HTML in CDATA)
        cp F_CONTENT
        jr nz,.slow
        ld a,(xmode)
        or a
        jr nz,.hr               ; (the article's content)
        ld de,(it_clen)         ; content in the list: only counted, to the next ']'
.c:     ld a,(hl)
        cp ']'
        jr z,.cd
        inc de
        ld a,d
        or e
        jr nz,.c1
        dec de
.c1:    inc hl
        dec bc
        ld a,b
        or c
        jr nz,.c
.cd:    ld (it_clen),de
        ld a,b
        or c
        jr z,.e
        jr .slow
.sk:    ld a,(hl)               ; CDATA not in a field: to the next ']'
        cp ']'
        jr z,.slow
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.sk
        jr .e
.n2:    cp X_SKIP
        jr nz,.slow
        ld a,(tag_link)
        or a
        jr nz,.slow
.s:     ld a,(hl)               ; attributes: to the '>' (after a '/': an empty tag)
        cp '>'
        jr z,.slow
        cp '/'
        jr nz,.s1
        ld a,1
        jr .s0
.s1:    cp ' '
        jr z,.s2
        xor a
.s0:    ld (tag_skip),a
.s2:    inc hl
        dec bc
        ld a,b
        or c
        jr nz,.s
        jr .e
.slow:  ld a,(hl)
        push hl
        push bc
        call x_byte
        pop bc
        pop hl
        inc hl
        dec bc
        ld a,(feed_full)
        ld d,a
        ld a,(a_stop)
        or d
        jr nz,.stop
        ld a,(xmode)
        or a
        jp z,.l
        ld a,(w_full)
        or a
        jp z,.l
.stop:  scf
        ret

; x_reset: A = mode
x_reset:
        ld (xmode),a
        xor a
        ld (xs),a
        ld (xitem),a
        ld (in_item),a
        ld (field),a
        ld (in_ent),a
        ld (tag_link),a
        ld (a_stop),a
        ret

x_byte: ld c,a
        ld a,(xs)
        or a
        jr nz,.n0
        ld a,c                  ; X_TEXT
        cp '<'
        jp nz,text_char
        ld a,X_TAG
        ld (xs),a
        xor a
        ld (xtl),a
        ld (tag_close),a
        ld (tag_skip),a
        ld (cdpre_n),a
        ret
.n0:    dec a
        jp z,xb_tag
        dec a
        jp z,xb_cdata
        dec a
        jp z,xb_comment
        ; X_SKIP: the rest of a tag (attributes)
        ld a,(tag_link)
        or a
        jr z,.s1
        call fb_add
.s1:    ld a,c
        cp '/'
        jr nz,.s2
        ld a,1
        ld (tag_skip),a
        ret
.s2:    cp '>'
        jr nz,.s3
        xor a
        ld (xs),a
        ld a,(tag_link)
        or a
        jr z,.s4
        call link_attrs
        xor a
        ld (tag_link),a
        ld hl,0                 ; (the link's text from here)
        ld (alen),hl
.s4:    ld a,(tag_skip)
        or a
        ret z
        ld a,(tag_close)
        or a
        ret nz
        ld a,(field)
        or a
        ret z
        jp field_end
.s3:    cp ' '
        ret z
        xor a
        ld (tag_skip),a
        ret

; fb_add: C to fbuf (to its size, by the field)
fb_add: ld hl,(alen)
        ld de,FBUF_MAX
        ld a,(field)
        cp F_DATE
        jr nz,.l
        ld de,47
.l:     push hl
        or a
        sbc hl,de
        pop hl
        ret nc
        ld de,fbuf
        add hl,de
        ld (hl),c
        ld hl,(alen)
        inc hl
        ld (alen),hl
        ret

xb_tag: ld a,(xtl)
        or a
        jr nz,.nm
        ld a,(tag_close)
        or a
        jr nz,.nm
        ld a,(cdpre_n)
        or a
        jr nz,.cd
        ld a,c
        cp '/'
        jr nz,.n1
        ld a,1
        ld (tag_close),a
        ret
.n1:    cp '!'
        jr nz,.nm
.cd:    ; <![CDATA[ ... ]]> or <!-- ... -->
        ld a,(cdpre_n)
        cp 8
        jr nc,.c1
        ld hl,cdpre
        call add_hla
        ld (hl),c
        inc hl
        ld (hl),0
        ld hl,cdpre_n
        inc (hl)
.c1:    ld hl,cdpre
        ld de,txt_cdata
        call str_eq
        jr nz,.c2
        ld a,X_CDATA
        jr .cm
.c2:    ld hl,cdpre
        ld de,txt_comm
        call str_eq
        jr nz,.c3
        ld a,X_COMMENT
.cm:    ld (xs),a
        xor a
        ld (cd_match),a
        ret
.c3:    ld hl,cdpre             ; still the beginning of one?
        ld de,txt_cdata
        call str_pre
        ret z
        ld hl,cdpre
        ld de,txt_comm
        call str_pre
        ret z
        ld a,X_SKIP
        ld (xs),a
        ret
.nm:    ld a,c
        cp '?'
        jr nz,.n2
        ld a,X_SKIP
        ld (xs),a
        ret
.n2:    cp '>'
        jr z,.end
        cp ' '
        jr z,.end
        cp 9
        jr z,.end
        cp 13
        jr z,.end
        cp 10
        jr z,.end
        cp '/'
        jr z,.end
        ld a,(xtl)
        cp 23
        ret nc
        ld hl,xtag
        call add_hla
        ld (hl),c
        ld hl,xtl
        inc (hl)
        ret
.end:   ld a,c
        cp '/'
        jr nz,.e1
        ld a,(tag_close)
        or a
        jr nz,.e1
        ld a,1
        ld (tag_skip),a
.e1:    push bc
        call tag_done
        pop bc
        ld a,c
        cp '>'
        ld a,X_SKIP
        jr nz,.e2
        xor a
        ld (xs),a
        ld a,(tag_skip)
        or a
        ret z
        ld a,(field)
        or a
        ret z
        jp field_end
.e2:    ld (xs),a
        ret
txt_cdata: db "![CDATA[",0
txt_comm:  db "!--",0

; str_pre: Z when the string at HL is the start of the one at DE
str_pre:
        ld a,(hl)
        or a
        ret z
        ex de,hl
        cp (hl)
        ex de,hl
        ret nz
        inc hl
        inc de
        jr str_pre

xb_cdata:
        ld a,c
        cp ']'
        jr nz,.n1
        ld a,(cd_match)
        cp 2
        jr nc,.p
        inc a
        ld (cd_match),a
        ret
.p:     ld a,']'
        jp put
.n1:    cp '>'
        jr nz,.n2
        ld a,(cd_match)
        cp 2
        jr nz,.n2
        xor a
        ld (xs),a
        ret
.n2:    ld a,(cd_match)
        or a
        jr z,.n3
        dec a
        ld (cd_match),a
        push bc
        ld a,']'
        call put
        pop bc
        jr .n2
.n3:    ld a,c
        jp put

xb_comment:
        ld a,c
        cp '-'
        jr nz,.n1
        ld a,(cd_match)
        cp 2
        ret nc
        inc a
        ld (cd_match),a
        ret
.n1:    cp '>'
        jr nz,.n2
        ld a,(cd_match)
        cp 2
        jr nz,.n2
        xor a
        ld (xs),a
        ret
.n2:    xor a
        ld (cd_match),a
        ret

; text_char: C, a character of the text (entities taken out)
text_char:
        ld a,(field)
        or a
        ret z
        ld a,(in_ent)
        or a
        jr z,.ne
        ld a,c
        cp ';'
        jr nz,.n1
        xor a
        ld (in_ent),a
        jp x_entity
.n1:    cp ' '
        jr z,.bad
        cp '<'
        jr z,.bad
        ld a,(xel)
        cp 9
        jr nc,.bad
        ld hl,xent
        call add_hla
        ld (hl),c
        ld hl,xel
        inc (hl)
        ret
.bad:   xor a                   ; not an entity: '&' and what came
        ld (in_ent),a
        push bc
        ld a,'&'
        call put
        call x_entpass
        pop bc
.ne:    ld a,c
        cp '&'
        jr nz,.p
        ld a,1
        ld (in_ent),a
        xor a
        ld (xel),a
        ret
.p:     ld a,c
        jp put

x_entpass:                      ; the entity's characters as text
        ld a,(xel)
        or a
        ret z
        ld b,a
        ld hl,xent
.c:     push bc
        push hl
        ld a,(hl)
        call put
        pop hl
        pop bc
        inc hl
        djnz .c
        ret

; an XML entity: the character goes on as text (in HTML fields: as HTML, so
; "&lt;b&gt;" is a tag and "&amp;amp;" an ampersand)
x_entity:
        ld a,(xel)
        ld hl,xent
        call add_hla
        ld (hl),0
        ld a,(xent)
        cp '#'
        jr nz,.nm
        ld hl,xent+1
        call ent_num
        ld a,d
        or a
        jr nz,put_cp
        ld a,e
        cp '&'
        jr nz,put_cp
        ld a,(field)
        cp F_LINK
        ld a,'&'
        jp z,put
        ld hl,txt_amp
        jp put_str
.nm:    ld hl,x_ents
.l:     ld a,(hl)
        or a
        jr z,.un
        push hl
        ld de,xent
        call str_eq
        pop hl
        jr z,.f
        call skipz
        inc hl
        jr .l
.f:     call skipz
        ld a,(hl)
        jp put
.un:    ld a,'&'
        call put
        call x_entpass
        ld a,';'
        jp put
x_ents: db "amp",0,"&","lt",0,"<","gt",0,">","quot",0,'"',"apos",0,"'",0
txt_amp: db "&amp;",0

put_str:
        ld a,(hl)
        or a
        ret z
        push hl
        call put
        pop hl
        inc hl
        jr put_str

; put_cp: DE (Unicode) as UTF-8
put_cp: ld a,d
        or a
        jr nz,.u3
        ld a,e
        cp #80
        jp c,put
        ; two bytes: 110xxxxx 10xxxxxx
        push de
        ld a,e
        rlca
        rlca
        and 3
        or #C0
        call put
        pop de
        ld a,e
        and #3F
        or #80
        jp put
.u3:    push de
        ld a,d
        cp 8
        jr c,.u2
        rrca
        rrca
        rrca
        rrca
        and #0F
        or #E0
        call put
        pop de
        push de
        ld a,d                  ; 10 dddd ee (bits 11-6)
        and #0F
        add a,a
        add a,a
        ld b,a
        ld a,e
        rlca
        rlca
        and 3
        or b
        or #80
        call put
        pop de
        ld a,e
        and #3F
        or #80
        jp put
.u2:    ld a,d                  ; 080h-7FFh: 110ddd ee
        add a,a
        add a,a
        ld b,a
        ld a,e
        rlca
        rlca
        and 3
        or b
        or #C0
        call put
        pop de
        ld a,e
        and #3F
        or #80
        jp put

; put: A, a character of the field
put:    ld c,a
        ld a,(field)
        cp F_CONTENT
        jr nz,.n1
        ld a,(xmode)
        or a
        ld a,c
        jp nz,h_byte
        ld hl,(it_clen)
        inc hl
        ld a,h
        or l
        ret z
        ld (it_clen),hl
        ret
.n1:    cp F_DATE
        jp nc,fb_add            ; (F_DATE, F_LINK)
        or a
        ret z
        ld a,c
        jp h_byte               ; title, summary

; <link href="..." rel="alternate"/> (Atom)
link_attrs:
        ld hl,(alen)
        ld de,fbuf
        add hl,de
        ld (hl),0
        ld a,(it_have)
        and 4
        ret nz
        ld hl,fbuf
        ld de,txt_rel
        call str_find
        jr nz,.h
        inc hl                  ; (the quote)
        ld de,txt_alt
        call str_beg
        ret nz
.h:     ld hl,fbuf
        ld de,txt_href
        call str_find
        ret nz
        ld a,(hl)
        cp '"'
        jr z,.q
        cp "'"
        ret nz
.q:     ld c,a
        inc hl
        push hl
.e:     ld a,(hl)
        or a
        jr z,.no
        cp c
        jr z,.ok
        inc hl
        jr .e
.no:    pop hl
        ret
.ok:    ld (hl),0
        pop hl
        ld a,'L'
        call w_put
.w:     ld a,(hl)
        or a
        jr z,.d
        call w_put
        inc hl
        jr .w
.d:     xor a
        call w_put
        ld hl,it_have
        set 2,(hl)
        ret
txt_rel:  db "rel=",0
txt_alt:  db "alternate",0
txt_href: db "href=",0

; str_find: DE in the string at HL? Z: yes, HL after it
str_find:
        ld a,(hl)
        or a
        jr z,.no
        push hl
        push de
        call str_beg
        pop de
        jr z,.y
        pop hl
        inc hl
        jr str_find
.y:     pop af
        ret
.no:    inc a
        ret

; str_beg: Z when HL begins with DE; HL after it
str_beg:
        ld a,(de)
        or a
        ret z
        cp (hl)
        ret nz
        inc hl
        inc de
        jr str_beg

tag_done:
        ld hl,xtag
        ld a,(xtl)
        call add_hla
        ld (hl),0
        ld hl,xtag              ; the name without a namespace ("dc:date" -> "date")
        ld b,0
.ns:    ld a,(hl)
        or a
        jr z,.nse
        inc hl
        cp ':'
        jr nz,.ns
        ld (.t),hl
        ld b,1
        jr .nsd
.nse:   ld hl,xtag
        ld (.t),hl
.nsd:   ld a,b
        ld (tg_ns),a
        xor a
        ld (tag_link),a
        ld a,(tag_close)
        or a
        jp nz,.close
        ld de,tg_item
        call .is
        jp z,item_start
        ld de,tg_entry
        call .is
        jp z,item_start
        ld a,(in_item)
        or a
        ret z
        ld a,(tag_skip)
        or a
        ret nz
        ld de,tg_title
        call .is
        ld b,F_TITLE
        jr z,.f
        ld de,tg_desc
        call .is
        ld b,F_TEXT
        jr z,.f
        ld de,tg_summary
        call .is
        jr z,.f
        ld b,F_DATE
        ld de,tg_pubdate
        call .is
        jr z,.f
        ld de,tg_date
        call .is
        jr z,.f
        ld de,tg_updated
        call .is
        jr z,.f
        ld de,tg_published
        call .is
        jr z,.f
        ld b,F_LINK
        ld a,(tg_ns)
        or a
        jr nz,.nl
        ld de,tg_link
        call .is
        jr z,.f
.nl:    ld b,F_CONTENT
        ld de,tg_encoded
        call .is
        jr z,.f
        ld a,(tg_ns)
        or a
        ret nz
        ld de,tg_content
        call .is
        ret nz
.f:     ld a,(xmode)            ; the article: only the story's content
        or a
        jp z,field_begin
        ld a,b
        cp F_CONTENT
        ret nz
        ld a,(a_story)
        ld hl,xitem
        cp (hl)
        ret nz
        jr field_begin
.close: ld a,(field)
        or a
        call nz,field_end
        ld de,tg_item
        call .is
        jp z,item_end
        ld de,tg_entry
        call .is
        ret nz
        jp item_end
.is:    ld hl,(.t)
        jp str_eq
.t:     equ tg_tp
        VAR tg_tp, 2
        VAR tg_ns, 1

tg_item:      db "item",0
tg_entry:     db "entry",0
tg_title:     db "title",0
tg_desc:      db "description",0
tg_summary:   db "summary",0
tg_pubdate:   db "pubDate",0
tg_date:      db "date",0
tg_updated:   db "updated",0
tg_published: db "published",0
tg_link:      db "link",0
tg_encoded:   db "encoded",0
tg_content:   db "content",0

; field_begin: B = the field
field_begin:
        xor a
        ld (in_ent),a
        ld hl,0
        ld (alen),hl
        ld a,b
        cp F_TITLE
        jr nz,.n1
        ld a,(it_have)
        and 1
        ret nz
        ld a,'T'
        ld c,1
        jr .h
.n1:    cp F_TEXT
        jr nz,.n2
        ld a,(it_have)
        and 2
        ret nz
        ld a,'S'
        ld c,0
.h:     call w_put
        ld hl,(w_len)
        ld (fstart),hl
        ld a,b
        ld (field),a
        xor a                   ; (not a page)
        jp h_start
.n2:    cp F_DATE
        jr nz,.n3
        ld a,(it_have)
        and 8
        ret nz
        ld a,b
        ld (field),a
        ret
.n3:    ld (field),a
        cp F_LINK
        ret nz
        ld a,1
        ld (tag_link),a
        ret

field_end:
        ld a,(field)
        ld b,a
        xor a
        ld (field),a
        ld a,(xmode)
        or a
        jr z,.list
        ld a,b
        cp F_CONTENT
        ret nz
        jp h_para
.list:  ld a,b
        cp F_TITLE
        jr z,.ts
        cp F_TEXT
        jr nz,.n2
.ts:    ld hl,(w_len)           ; nothing in it: not there
        ld de,(fstart)
        or a
        sbc hl,de
        jr nz,.has
        ex de,hl
        dec hl
        jp w_trunc
.has:   ld (it_tlen),hl
        xor a
        call w_put
        ld a,b
        ld hl,it_have
        cp F_TITLE
        jr nz,.s
        set 0,(hl)
        ret
.s:     set 1,(hl)
        ret
.n2:    cp F_LINK
        jr nz,.n3
        ld a,(it_have)
        and 4
        ret nz
        call fb_trim
        ret z
        ld a,'L'
        call w_put
        call fb_out
        ld hl,it_have
        set 2,(hl)
        ret
.n3:    cp F_DATE
        ret nz
        ld hl,(alen)
        ld de,fbuf
        add hl,de
        ld (hl),0
        ld hl,fbuf
        call parse_date
        jr c,.raw
        ld hl,(pd_days)
        ld (it_days),hl
        ld hl,(pd_min)
        ld (it_min),hl
        ld hl,it_have
        set 3,(hl)
        ret
.raw:   call fb_trim
        ret z
        ld a,'D'
        call w_put
        call fb_out
        ld hl,it_have
        set 3,(hl)
        ret

; fb_trim: fbuf without its spaces round it -> HL, BC (Z: empty)
fb_trim:
        ld hl,fbuf
        ld bc,(alen)
.l:     ld a,b
        or c
        ret z
        ld a,(hl)
        cp ' '+1
        jr nc,.t
        inc hl
        dec bc
        jr .l
.t:     push hl
        add hl,bc
.r:     dec hl
        ld a,(hl)
        cp ' '+1
        jr nc,.e
        dec bc
        jr .r
.e:     pop hl
        ld a,b
        or c
        ret
; fb_out: BC bytes at HL and a 0 to the writer
fb_out: ld a,b
        or c
        jr z,.z
        ld a,(hl)
        call w_put
        inc hl
        dec bc
        jr fb_out
.z:     jp w_put

item_start:
        ld a,1
        ld (in_item),a
        xor a
        ld (it_have),a
        ld hl,0
        ld (it_clen),hl
        ld (it_tlen),hl
        ld (it_days),hl
        ld (it_min),hl
        ld hl,(w_len)
        ld (it_start),hl
        ret

item_end:
        xor a
        ld (in_item),a
        ld a,(xmode)
        or a
        jr z,.list
        ld a,(a_story)          ; the article: the story's content is in
        ld hl,xitem
        cp (hl)
        jr nz,.nx
        ld a,1
        ld (a_stop),a
.nx:    inc (hl)
        ret
.list:  ld a,(feed_full)
        or a
        ret nz
        ld a,(w_full)
        or a
        jr nz,.full
        ld a,(it_have)
        and 1
        jr z,.drop
        ld a,(nitems)           ; its entry
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        or a
        sbc hl,de               ; * 7
        ld de,items
        add hl,de
        ld de,(it_start)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld de,(it_days)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld de,(it_min)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        push hl                 ; a content much longer than the summary: the article is in the feed
        ld hl,(it_tlen)
        ld de,400
        add hl,de
        ld de,(it_clen)
        ex de,hl
        or a
        sbc hl,de
        pop hl
        ld a,0
        jr c,.f
        jr z,.f
        inc a
.f:     ld (hl),a
        ld hl,nitems
        inc (hl)
        ld a,(hl)
        cp MAX_ITEMS
        ret c
        ld a,1
        ld (feed_full),a
        ret
.full:  ld a,1
        ld (feed_full),a
.drop:  ld hl,(it_start)
        jp w_trunc

;------------------------------------------------------------------------------
; parse_date: HL = "Thu, 29 Oct 2026 20:15:00 GMT" / "+0100" / "EST",
; "2026-10-29T18:30:00Z" / "+01:00" -> pd_days, pd_min, pd_sec (UTC); CF: not understood
        VAR pd_h, 1
        VAR pd_mi, 1
parse_date:
        call skipsp
        xor a
        ld (pd_sec),a
        push hl
        ld bc,4
        add hl,bc
        ld a,(hl)
        pop hl
        cp '-'
        jr nz,.rfc
        call num                ; ISO: 2026-10-29T18:30[:00][.000][Z|+01:00]
        ret c
        ld (dc_y),de
        inc hl
        call num
        ret c
        ld a,e
        ld (dc_m),a
        inc hl
        call num
        ret c
        ld a,e
        ld (dc_d),a
        ld a,(hl)
        inc hl
        cp 'T'
        jr z,.it
        cp ' '
        scf
        ret nz
.it:    call .hms
        ret c
.fr:    ld a,(hl)
        cp '.'
        jr z,.f1
        sub '0'
        cp 10
        jr nc,.zone
.f1:    inc hl
        jr .fr
.rfc:   push hl                 ; "Thu, " (a ',' in the first 5)
        ld b,5
.c:     ld a,(hl)
        inc hl
        cp ','
        jr z,.cf
        or a
        jr z,.cn
        djnz .c
.cn:    pop hl
        jr .r2
.cf:    pop af
.r2:    call skipsp
        call num
        ret c
        ld a,e
        ld (dc_d),a
        call skipsp
        ld de,months            ; "Oct"
        ld b,1
.mo:    push hl
        push de
        call .m3
        pop de
        pop hl
        jr z,.mf
        ex de,hl
        call skipz
        ex de,hl
        inc b
        ld a,b
        cp 13
        jr c,.mo
        scf
        ret
.mf:    ld a,b
        ld (dc_m),a
        inc hl
        inc hl
        inc hl
        call skipsp
        call num
        ret c
        ld (dc_y),de
        call skipsp
        call .hms
        ret c
        call skipsp
.zone:  ; HL at the zone
        ld de,0                 ; the offset in minutes
        ld a,(hl)
        cp '+'
        jr z,.off
        cp '-'
        jr z,.off
        push hl
        ld ix,zones
.z:     ld a,(ix)
        or a
        jr z,.zn
        pop hl
        push hl
        ld a,(ix)
        cp (hl)
        jr nz,.zx
        inc hl
        ld a,(ix+1)
        cp (hl)
        jr nz,.zx
        inc hl
        ld a,(ix+2)
        cp (hl)
        jr nz,.zx
        ld a,(ix+3)
        ld l,a
        ld h,0
        bit 7,a
        jr z,.zp
        dec h
.zp:    ld de,60
        call mul16
        ex de,hl
        jr .zn
.zx:    inc ix
        inc ix
        inc ix
        inc ix
        jr .z
.zn:    pop hl
        jr .calc
.off:   push af
        inc hl                  ; +hh:mm or +hhmm
        ld a,(hl)
        sub '0'
        cp 10
        jr nc,.ob
        ld b,a
        add a,a
        add a,a
        add a,b
        add a,a
        ld b,a
        inc hl
        ld a,(hl)
        sub '0'
        add a,b
        inc hl
        push hl
        ld l,a
        ld h,0
        ld de,60
        call mul16
        ex de,hl
        pop hl
        ld a,(hl)
        cp ':'
        jr nz,.om
        inc hl
.om:    ld a,(hl)
        sub '0'
        cp 10
        jr nc,.oe
        ld b,a
        add a,a
        add a,a
        add a,b
        add a,a
        ld b,a
        inc hl
        ld a,(hl)
        sub '0'
        add a,b
        ex de,hl
        call add_hla
        ex de,hl
.oe:    pop af
        cp '-'
        jr nz,.calc
        ex de,hl
        call neg_hl
        ex de,hl
        jr .calc
.ob:    pop af
        ld de,0
.calc:  ; days, then minutes - the offset (into the day before / after)
        push de
        ld hl,(dc_y)
        ld de,100
        or a
        sbc hl,de
        jr nc,.y4
        ld hl,(dc_y)
        ld de,2000
        add hl,de
        ld (dc_y),hl
.y4:    call days_civ_in
        pop de
        ret c
        ld a,(pd_h)
        cp 24
        ccf
        ret c
        ld a,(pd_mi)
        cp 60
        ccf
        ret c
        ld (pd_days),hl
        push de
        ld a,(pd_h)
        ld l,a
        ld h,0
        ld de,60
        call mul16
        ld a,(pd_mi)
        call add_hla
        pop de
        or a
        sbc hl,de               ; UTC = local - offset
        ex de,hl
        ld hl,(pd_days)
        bit 7,d
        jr z,.p
        dec hl
        ex de,hl
        ld bc,1440
        add hl,bc
        ex de,hl
        jr .st
.p:     push hl
        ex de,hl
        ld bc,1440
        or a
        sbc hl,bc
        ex de,hl
        pop hl
        jr c,.u
        inc hl
        jr .st
.u:     ex de,hl
        add hl,bc
        ex de,hl
.st:    ld (pd_days),hl
        ld (pd_min),de
        or a
        ret
; .hms: hh:mm[:ss]
.hms:   call num
        ret c
        ld a,e
        ld (pd_h),a
        ld a,(hl)
        cp ':'
        scf
        ret nz
        inc hl
        call num
        ret c
        ld a,e
        ld (pd_mi),a
        ld a,(hl)
        cp ':'
        jr nz,.hx
        inc hl
        call num
        ld a,e
        ld (pd_sec),a
.hx:    or a
        ret
; .m3: Z when HL begins with the 3 letters at DE
.m3:    ld c,3
.m3l:   ld a,(de)
        cp (hl)
        ret nz
        inc hl
        inc de
        dec c
        jr nz,.m3l
        ret

zones:  db "GMT",0, "UTC",0, "EST",-5, "EDT",-4, "CST",-6, "CDT",-5, "MST",-7, "MDT",-6
        db "PST",-8, "PDT",-7, "CET",1, "CES",2, "BST",1, "MET",1, "EET",2, "JST",9, 0
