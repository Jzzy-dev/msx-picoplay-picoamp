; fakeunapi.asm - a TCP/IP UNAPI "implementation" ROM for testing in openMSX:
; the discovery through EXTBIO is real, the routines at 4010h are a RET that
; an openMSX Tcl breakpoint (unapi.tcl) carries out.
EXTBIO  equ #FFCA
HOKVLD  equ #FB20
HIMEM   equ #FC4A
ARG     equ #F847
EXPTBL  equ #FCC1
        org #4000
        db "AB"
        dw 0
        dw 0,0,0
        ds 6
        ds #4010-$
entry:  ret                     ; (the breakpoint)
        ds #4020-$
; the EXTBIO hook: page 3's stub (below) calls it with CALLF, HL = the old
; hook's copy, the caller's HL after that copy
hook:   push hl                 ; (the old hook, for RET)
        push de
        ld de,5
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                ; HL = the caller's
        pop de
        push af
        ld a,d
        cp #22
        jr nz,.no
        ld a,e
        cp #22
        jr nz,.no
        pop af
        push af
        cp #FF
        jr z,.no
        push hl
        push de
        ld hl,ARG               ; "TCP/IP"?
        ld de,name_id
.c:     ld a,(de)
        cp (hl)
        jr nz,.ne
        or a
        jr z,.ne
        inc hl
        inc de
        jr .c
.ne:    pop de
        pop hl
        jr nz,.no
        pop af
        or a
        jr nz,.n1
        inc b                   ; A=0: count us
        ret                     ; (to the old one)
.n1:    dec a
        ret nz                  ; (another one's index: the old one)
        inc sp                  ; ours: the answer
        inc sp
        call myslot
        ld b,#FF
        ld hl,entry
        ret
.no:    pop af
        ret                     ; to the old one
name_id: db "TCP/IP",0
        ds #4100-$
        db "openMSX test UNAPI (Tcl)",0

myslot: in a,(#A8)
        rrca
        rrca
        and 3
        ld c,a
        ld b,0
        push hl
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
.p:     ld a,c
        pop hl
        ret

; INIT: 18 bytes of page 3 below HIMEM: a stub that calls the hook, the old hook
init:   ld hl,#F55D             ; (test only: the end of KBUF, free outside BASIC)
        ld de,-18
        add hl,de
        push hl
        pop ix
        ld (ix+0),#22           ; ld (blk+16),hl
        ld de,16
        add hl,de
        ld (ix+1),l
        ld (ix+2),h
        push ix
        pop hl
        ld de,11
        add hl,de
        ld (ix+3),#21           ; ld hl,blk+11
        ld (ix+4),l
        ld (ix+5),h
        ld (ix+6),#F7           ; rst 30h
        call myslot
        ld (ix+7),a
        ld (ix+8),low hook
        ld (ix+9),high hook
        ld (ix+10),#C9
        ld a,(HOKVLD)
        rrca
        jr c,.v
        ld hl,EXTBIO            ; (no hook yet: RETs)
        ld b,5
.r:     ld (hl),#C9
        inc hl
        djnz .r
        ld a,(HOKVLD)
        or 1
        ld (HOKVLD),a
.v:     push ix
        pop de
        ld hl,11
        add hl,de
        ex de,hl                ; DE = blk+11
        ld hl,EXTBIO
        ld bc,5
        ldir
        push ix
        pop de
        ld hl,EXTBIO
        ld (hl),#C3             ; JP blk
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ret
        ds #8000-$,#FF
