;==============================================================================
; pictures.asm - PICOAMP's pictures page and screensaver, a page module (see
; clock.asm). Engine 0.17.
;
; A browser of the card's folders that shows only folders and JPEG pictures.
; Enter on a picture shows it full screen; Space marks pictures; G plays the
; marked ones (or, with none marked, all of the folder) as a slideshow. The
; settings: O the screensaver (off, or after 1-30 minutes without a key),
; R how long each picture shows, U in order or shuffled, F this folder for
; the screensaver. They go to PICOAMP.INI ([pictures]).
;
; The pictures are SCREEN 8 (256 x 192, 256 colours): the engine decodes any
; size of (baseline) JPEG, fits and dithers it, and gives its rows; they go to
; the VRAM page that does not show (0 or 1), which shows when it is complete.
; The music plays on meanwhile.
;
; The screensaver: the main loop counts the seconds without a key and opens
; this page with pic_saver set; it plays [pictures] folder; any key ends it.
;
; The full screen cover (Z, the fourth picture: pic_saver 2): the cover that
; shows, bigger (PIC_COVER: the file's own picture again, a default picture
; whole, a picture from the internet fetched again at up to 281 x 192), made
; again when the engine has another cover. Left / Right and V the other full
; screen pictures, Z, ESC, Enter or BS back; the playback keys as always.
;==============================================================================

C_PDIR   equ #53
C_PNAMES equ #54
C_PSHOW  equ #55
C_PGET   equ #56
C_PCLOSE equ #57
C_PCOVER equ #58
PC_ROWS  equ 19                 ; list rows (2-20)
PC_W     equ 39                 ; characters of a name shown
VDP_I    equ #9B                ; (the VDP's register port, indirect)

M_BROWSE equ 0
M_VIEW   equ 1                  ; one picture
M_SHOW   equ 2                  ; the slideshow
M_SAVER  equ 3                  ; the slideshow as the screensaver
M_COVER  equ 4                  ; the full screen cover

mod_pic:
        jp pc_open              ; the jump table (M_OPEN ...)
        jp pc_tick
        jp pc_ret
        jp pc_keys
        jp pc_info
        jp pc_ret
        jp pc_leave

;------------------------------------------------------------------------------
pc_open:
        xor a
        ld (pc_mode),a
        ld (pc_dirty),a
        ld (pc_s8),a
        ld hl,0
        ld (pc_nmark),hl
        ld hl,pc_marks
        ld bc,50
        call memset             ; (A = 0)
        call pc_settings
        ld a,(pic_saver)
        or a
        jr z,.page
        cp 2
        jr z,.cover
        xor a
        ld (pic_saver),a
        ld hl,pc_sfolder        ; the screensaver: its folder, its slideshow
        call pc_setpath
        call pc_dir
        jp c,fs_close           ; (no memory, no folder: no screensaver)
        call pc_first_pic
        jp c,fs_close           ; (no pictures)
        ld a,M_SAVER
        jp pc_start_show
.cover: xor a
        ld (pic_saver),a
        ld a,M_COVER
        ld (pc_mode),a
        call pc_s8_on
        ld a,(st+ST_COVGEN)
        ld (pc_cgen),a
        ld a,1                  ; (made again: the screen is black)
        jp pc_cover_req
.page:  ld hl,pc_sfolder        ; the page: the screensaver's folder, else the root
        call pc_setpath
        call pc_dir
        jr nc,.ok
        ld hl,txt_pc_root
        call pc_setpath
        call pc_dir
.ok:    jp pc_draw_all

pc_ret: ret

; row 0: what plays (not on the pictures)
pc_info:
        ld a,(pc_s8)
        or a
        ret nz
        jp pg_row0

pc_leave:
        call pc_s8_off
        ld a,C_PCLOSE
        call cmd0
        xor a
        ld (pic_saver),a
        ld a,(pc_dirty)
        or a
        ret z
        jp ini_save

;------------------------------------------------------------------------------
; settings: [pictures] interval, shuffle, folder ([pictures] saver: the engine's status)
pc_settings:
        ld a,1                  ; 10 s
        ld (pc_int),a
        xor a
        ld (pc_shuf),a
        ld hl,txt_pc_defdir
        ld de,pc_sfolder
        call strcpy0
        ld hl,txt_k_int
        call pc_get
        jr nz,.s
        ld a,(reply)            ; the seconds (1 or 2 digits) -> its index
        sub '0'
        ld c,a
        ld a,(reply+1)
        sub '0'
        cp 10
        jr nc,.one
        ld b,a
        ld a,c
        add a,a
        add a,a
        add a,c
        add a,a                 ; * 10
        add a,b
        ld c,a
.one:   ld a,c
        ld hl,pc_ints
        ld b,5
.f5:    cp (hl)
        jr z,.got
        inc hl
        djnz .f5
        jr .s
.got:   ld a,5
        sub b
        ld (pc_int),a
.s:     ld hl,txt_k_shuf
        call pc_get
        jr nz,.f
        ld a,(reply)
        cp '1'
        jr nz,.f
        ld (pc_shuf),a
.f:     ld hl,txt_k_folder
        call pc_get
        ret nz
        ld a,(reply)
        cp '/'
        ret nz
        ld hl,reply
        ld de,pc_sfolder
        ld bc,127
        jp strncpy0

; pc_get: HL = "section.key" -> ZF=1 set, the value in 'reply'
pc_get: ld de,args
        call strcpy0
        ex de,hl
        ld de,args
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ld a,C_CFGGET
        call cmd
        ret nc
        or 1
        ret

; pc_set: HL = key, DE = value
pc_set: push de
        ld de,args
        call strcpy0
        pop hl
        call strcpy0
        ex de,hl
        ld de,args
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ld a,C_CFGSET
        call cmd
        ld a,1
        ld (pc_dirty),a
        ret

;------------------------------------------------------------------------------
; the folder: pc_path (HL: a path to it)
pc_setpath:
        ld de,pc_path
        ld bc,127
        jp strncpy0

; pc_dir: the folder's list from the engine (CF: none)
pc_dir: ld hl,pc_path
        ld de,args
        call strcpy0
        ex de,hl
        ld de,args
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ld a,C_PDIR
        call cmd
        jr c,.f
        jr nz,.f
        ld hl,(reply)
        ld (pc_n),hl
        ld hl,(reply+2)
        ld (pc_nd),hl
        ld hl,0
        ld (pc_top),hl
        ld (pc_cur),hl
        ld (pc_nmark),hl
        ld hl,pc_marks
        ld bc,50
        xor a
        call memset
        ld hl,0
        ld (pc_msg),hl
        or a
        ret
.f:     cp E_FULL
        ld hl,txt_pc_nomem
        jr z,.m
        ld hl,txt_pc_nodir
.m:     ld (pc_msg),hl
        scf
        ret

; the number of pictures in the folder: HL (and ZF: none)
pc_npics:
        ld hl,(pc_n)
        ld de,(pc_nd)
        or a
        sbc hl,de
        ret

;------------------------------------------------------------------------------
; the browser
pc_draw_all:
        call cls
        call setpal
        call pg_row0
        call pc_draw_title
        call pc_draw_list
        call pc_draw_status
        ld hl,txt_pc_keys
        ld de,#1600
        ld b,32
        ld c,GREY*16+NAVY
        call text6s
        jp pc_draw_set

pc_draw_title:
        ld de,linebuf
        ld hl,txt_pc_title
        call strcpy
        ld hl,pc_path
        call strcpy
        ld hl,linebuf
        ld de,#0100
        ld b,32
        ld c,A_TITLE
        jp text6s

; the list: rows 2-20
pc_draw_list:
        ld hl,(pc_top)
        ld (args),hl
        ld a,PC_ROWS
        ld (args+2),a
        ld a,PC_W
        ld (args+3),a
        ld bc,4
        ld a,C_PNAMES
        call cmd
        ld hl,reply
        ld (pc_rp),hl
        ld hl,(pc_top)
        ld (pc_ri),hl
        ld d,2
.row:   push de
        ld hl,(pc_ri)
        ld de,(pc_n)
        or a
        sbc hl,de
        jr nc,.empty
        ld hl,(pc_rp)           ; 'D' or 'J', the name
        ld a,(hl)
        inc hl
        ld (pc_rt),a
        ld de,linebuf
        push hl
        ld hl,(pc_ri)
        call pc_marked
        pop hl
        ld a,' '
        jr z,.nm
        ld a,'*'
.nm:    ld (de),a
        inc de
        call strcpy0            ; (HL after the name)
        ld (pc_rp),hl
        dec de
        ld a,(pc_rt)
        cp 'D'
        jr nz,.nd
        ld a,'/'
        ld (de),a
        inc de
        xor a
        ld (de),a
.nd:    ld c,WHITE*16+NAVY
        ld a,(pc_rt)
        cp 'D'
        jr nz,.c1
        ld c,CYAN*16+NAVY
.c1:    ld a,(linebuf)
        cp '*'
        jr nz,.c2
        ld c,YELLOW*16+NAVY
.c2:    ld hl,(pc_ri)
        ld de,(pc_cur)
        or a
        sbc hl,de
        jr nz,.out
        ld c,A_SEL
        jr .out
.empty: xor a
        ld (linebuf),a
        ld c,WHITE*16+NAVY
.out:   pop de
        push de
        ld e,0
        ld hl,linebuf
        ld b,32
        call text6s
        ld hl,(pc_ri)
        inc hl
        ld (pc_ri),hl
        pop de
        inc d
        ld a,d
        cp 2+PC_ROWS
        jr c,.row
        ret

; row 21: how many, or a message
pc_draw_status:
        ld hl,(pc_msg)
        ld a,h
        or l
        jr nz,.t
        call pc_npics
        ld de,linebuf
        call fmt_u16
        ld hl,txt_pc_pics
        call strcpy
        ld hl,(pc_nmark)
        ld a,h
        or l
        jr z,.d
        push hl
        ld hl,txt_pc_comma
        call strcpy
        pop hl
        call fmt_u16
        ld hl,txt_pc_marked
        call strcpy
.d:     ld hl,linebuf
.t:     ld de,#1500
        ld b,32
        ld c,GREEN*16+NAVY
        jp text6s

; row 23: the settings
pc_draw_set:
        ld de,linebuf
        ld hl,txt_pc_saver
        call strcpy
        ld a,(st+ST_SAVER)
        or a
        jr nz,.min
        ld hl,txt_pc_off
        call strcpy
        jr .i
.min:   ld l,a
        ld h,0
        call fmt_u16
        ld a,'m'
        ld (de),a
        inc de
.i:     ld hl,txt_pc_every
        call strcpy
        ld a,(pc_int)
        call pc_int_s
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_pc_shuf
        call strcpy
        ld a,(pc_shuf)
        or a
        ld hl,txt_pc_off
        jr z,.u
        ld hl,txt_pc_on
.u:     call strcpy
        ld hl,txt_pc_fkey
        call strcpy
        ld hl,linebuf
        ld de,#1700
        ld b,32
        ld c,GREY*16+NAVY
        jp text6s

; A = the interval's index -> A = seconds
pc_int_s:
        ld hl,pc_ints
        add a,l
        ld l,a
        jr nc,.n
        inc h
.n:     ld a,(hl)
        ret
pc_ints: db 5, 10, 20, 30, 60

; is entry HL marked? (NZ: yes; HL kept)
pc_marked:
        push hl
        push de
        call pc_bit
        and (hl)
        pop de
        pop hl
        ret
; HL = entry -> HL = its byte in pc_marks, A = its bit
pc_bit: ld a,l
        and 7
        ld b,a
        ld a,1
        jr z,.s
.l:     add a,a
        djnz .l
.s:     srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ld de,pc_marks
        add hl,de
        ret

;------------------------------------------------------------------------------
pc_keys:
        ld c,a
        ld a,(pc_mode)
        or a
        ld a,c
        jp nz,pc_keys_pic
        cp 27
        jp z,fs_close
        cp 30
        ld hl,-1
        jp z,pc_move
        cp 31
        ld hl,1
        jp z,pc_move
        cp 29
        ld hl,-PC_ROWS
        jp z,pc_move
        cp 28
        ld hl,PC_ROWS
        jp z,pc_move
        cp 13
        jp z,pc_enter
        cp 8
        jp z,pc_parent
        cp ' '
        jp z,pc_mark
        cp '$'
        ld c,PG_MARKETS
        jp z,pg_enter
        and #DF
        cp 'A'
        jp z,pc_mark_all
        cp 'G'
        jp z,pc_go
        cp 'O'
        jp z,pc_set_saver
        cp 'R'
        jp z,pc_set_int
        cp 'U'
        jp z,pc_set_shuf
        cp 'F'
        jp z,pc_set_folder
        cp 'I'
        jp z,fs_close
        cp 'C'
        ld c,PG_CLOCK
        jp z,pg_enter
        cp 'W'
        ld c,PG_WEATHER
        jp z,pg_enter
        cp 'T'
        ld c,PG_NEWS
        jp z,pg_enter
        cp 'Z'
        ret z
        cp 'V'
        ret z
        ld a,b
        jp keys_common

; the cursor by HL (signed)
pc_move:
        ld de,(pc_cur)
        add hl,de
        bit 7,h
        jr z,.p
        ld hl,0
.p:     ld de,(pc_n)
        ld a,d
        or e
        ret z
        ex de,hl
        dec hl                  ; the last
        or a
        sbc hl,de
        jr nc,.in
        add hl,de               ; (past the end: the last)
        ex de,hl
.in:    ex de,hl
        ld (pc_cur),hl
        ; the list follows
        ld de,(pc_top)
        or a
        sbc hl,de
        jr nc,.below
        ld hl,(pc_cur)
        ld (pc_top),hl
        jp pc_draw_list
.below: ld de,PC_ROWS
        or a
        sbc hl,de
        jp c,pc_draw_list
        ld hl,(pc_cur)
        ld de,PC_ROWS-1
        or a
        sbc hl,de
        ld (pc_top),hl
        jp pc_draw_list

; is the cursor's entry a folder? (CF: yes)
pc_isdir:
        ld hl,(pc_cur)
        ld de,(pc_nd)
        or a
        sbc hl,de
        ret

pc_enter:
        ld hl,(pc_n)
        ld a,h
        or l
        ret z
        call pc_isdir
        jr nc,.pic
        ; a folder: its name to the path
        ld hl,(pc_cur)
        ld (args),hl
        ld a,1
        ld (args+2),a
        ld a,60                 ; (a folder's name: 60 characters at most)
        ld (args+3),a
        ld bc,4
        ld a,C_PNAMES
        call cmd
        ld hl,pc_path
        call pc_end
        ld de,pc_path+64        ; (deeper than that: not)
        or a
        push hl
        sbc hl,de
        pop hl
        ret nc
        dec hl
        ld a,(hl)
        inc hl
        cp '/'
        jr z,.sl
        ld (hl),'/'
        inc hl
.sl:    ex de,hl
        ld hl,reply+1
        call strcpy0
        jp pc_newdir
.pic:   ld hl,(pc_cur)
        ld (pc_shown),hl
        ld a,M_VIEW
        jp pc_start_view

; HL = a string -> HL on its 0
pc_end: ld a,(hl)
        or a
        ret z
        inc hl
        jr pc_end

pc_parent:
        ld hl,pc_path
        call pc_end
.b:     dec hl                  ; back to the last '/'
        ld a,(hl)
        cp '/'
        jr nz,.b
        ld de,pc_path
        or a
        push hl
        sbc hl,de
        pop hl
        jr nz,.cut
        inc hl                  ; (the root stays "/")
.cut:   ld (hl),0
        ; fall through
pc_newdir:
        call pc_dir
        jp pc_draw_all

pc_mark:
        call pc_isdir
        ret c
        ld hl,(pc_cur)
        call pc_bit
        ld c,a
        xor (hl)
        ld (hl),a
        and c
        ld hl,(pc_nmark)
        jr z,.un
        inc hl
        jr .s
.un:    dec hl
.s:     ld (pc_nmark),hl
        call pc_draw_status
        ld hl,1                 ; and on to the next
        jp pc_move

; A: all pictures marked, or (all marked already) none
pc_mark_all:
        call pc_npics
        ret z
        ld de,(pc_nmark)
        or a
        sbc hl,de
        ld a,0
        jr z,.set               ; (all: none)
        dec a
.set:   ld (pc_ma),a
        ld hl,(pc_nd)
        ld (pc_ri),hl
.l:     ld hl,(pc_ri)
        ld de,(pc_n)
        or a
        sbc hl,de
        jr nc,.d
        ld hl,(pc_ri)
        call pc_bit
        ld c,a
        ld a,(pc_ma)
        or a
        ld a,c
        jr z,.clr
        or (hl)
        jr .w
.clr:   cpl
        and (hl)
.w:     ld (hl),a
        ld hl,(pc_ri)
        inc hl
        ld (pc_ri),hl
        jr .l
.d:     ld a,(pc_ma)
        or a
        ld hl,0
        jr z,.n
        call pc_npics
.n:     ld (pc_nmark),hl
        call pc_draw_list
        jp pc_draw_status

; G: the slideshow (the marked pictures, or all of them)
pc_go:  call pc_first_pic
        ret c
        ld a,M_SHOW
        jp pc_start_show

; the settings' keys
pc_set_saver:
        ld a,(st+ST_SAVER)
        ld hl,pc_savers
        ld b,7
.f:     cp (hl)
        inc hl
        jr z,.n
        djnz .f
        ld hl,pc_savers         ; (not one of them: off)
.n:     ld a,b
        cp 1
        jr nz,.v
        ld hl,pc_savers         ; (after 30: off)
.v:     ld a,(hl)
        ld (st+ST_SAVER),a      ; (shown now; the engine's status says so soon)
        ld l,a
        ld h,0
        ld de,pc_num
        call fmt_u16
        ld hl,txt_k_saver
        ld de,pc_num
        call pc_set
        jp pc_draw_set
pc_savers: db 0, 1, 2, 5, 10, 15, 30

pc_set_int:
        ld a,(pc_int)
        inc a
        cp 5
        jr c,.s
        xor a
.s:     ld (pc_int),a
        call pc_int_s
        ld l,a
        ld h,0
        ld de,pc_num
        call fmt_u16
        ld hl,txt_k_int
        ld de,pc_num
        call pc_set
        jp pc_draw_set

pc_set_shuf:
        ld a,(pc_shuf)
        xor 1
        ld (pc_shuf),a
        add a,'0'
        ld (pc_num),a
        xor a
        ld (pc_num+1),a
        ld hl,txt_k_shuf
        ld de,pc_num
        call pc_set
        jp pc_draw_set

pc_set_folder:
        ld hl,pc_path
        ld de,pc_sfolder
        call strcpy0
        ld hl,txt_k_folder
        ld de,pc_path
        call pc_set
        ld hl,txt_pc_fset
        ld (pc_msg),hl
        call pc_draw_status
        ld hl,0
        ld (pc_msg),hl
        ret

;------------------------------------------------------------------------------
; pictures full screen
pc_start_view:                  ; A = the mode; pc_shown = the picture
        ld (pc_mode),a
        call pc_s8_on
        ld hl,(pc_shown)
        jp pc_load

pc_start_show:                  ; A = the mode; pc_shown = the first picture
        ld (pc_mode),a
        xor a
        ld (pc_fails),a
        call pc_s8_on
        ld hl,(pc_shown)
        jp pc_load

; pc_first_pic: the first picture of the slideshow into pc_shown (CF: none)
pc_first_pic:
        ld hl,(pc_nd)
        dec hl                  ; (the one "before" the first)
        ld (pc_shown),hl
        call pc_next
        ret c
        ld (pc_shown),hl
        ret

; pc_next: the picture after pc_shown (in order or at random; the marked ones
; when there are) -> HL (CF: none)
pc_next:
        call pc_npics
        scf
        ret z
        ld hl,(pc_shown)
        ld a,(pc_shuf)
        or a
        jr z,.seq
        ; at random: (n * r) / 256 pictures after the folders
        call pc_npics
        ex de,hl
        ld a,r
        ld hl,(JIFFY)
        xor l
        ld c,0
        ld hl,0
        ld b,8
.mul:   add hl,hl
        rl c
        rla
        jr nc,.nx
        add hl,de
        jr nc,.nx
        inc c
.nx:    djnz .mul
        ld l,h                  ; (C:H = the result's high 16 bits)
        ld h,c
        ld de,(pc_nd)
        add hl,de
        dec hl                  ; (the search starts after it)
.seq:   ld (pc_ri),hl
        ld bc,(pc_n)            ; at most n steps
.step:  ld hl,(pc_ri)
        inc hl
        ld de,(pc_n)
        push hl
        or a
        sbc hl,de
        pop hl
        jr c,.in
        ld hl,(pc_nd)           ; (past the end: the first picture)
.in:    ld (pc_ri),hl
        ld de,(pc_nmark)
        ld a,d
        or e
        jr z,.ok
        push bc
        call pc_marked
        pop bc
        jr nz,.ok
        dec bc
        ld a,b
        or c
        jr nz,.step
        scf
        ret
.ok:    ld hl,(pc_ri)
        or a
        ret

; pc_load: picture HL into the page that does not show
pc_load:
        ld (args),hl
        ld bc,2
        ld a,C_PSHOW
        call cmd
        ld a,1
        ld (pc_ld),a
        ret

; each main loop pass: the rows that are made to VRAM; then show it
pc_tick:
        ld a,(pc_mode)
        or a
        ret z
        ld a,(pc_ld)
        cp 1
        jr nz,.ready
        ld b,2                  ; two takes of 3 rows a pass
.take:  push bc
        ld a,3
        ld (args),a
        ld bc,1
        ld a,C_PGET
        call cmd
        pop bc
        ret c
        ld a,(reply+3)
        or a
        jr z,.nr
        push bc
        call pc_rows
        pop bc
.nr:    ld a,(reply)
        cp 2
        jr z,.made
        cp 3
        jr z,.fail
        djnz .take
        ret
.made:  xor a
        ld (pc_fails),a
        ld a,2
        ld (pc_ld),a
.ready: cp 2
        jp nz,pc_cov_gen
        ld a,(pc_mode)          ; the first, one picture, the cover: at once; the slideshow: its time
        cp M_VIEW
        jr z,.show
        cp M_COVER
        jr z,.show
        ld a,(pc_first)
        or a
        jr nz,.show
        ld a,(pc_int)
        call pc_int_s
        ld l,a
        ld h,0
        ld a,(hold)
        ld e,a
        ld d,0
        call pc_mul             ; HL = seconds * interrupts a second
        ex de,hl
        ld hl,(JIFFY)
        ld bc,(pc_t)
        or a
        sbc hl,bc
        sbc hl,de
        ret c
.show:  ld a,(pc_hid)           ; it shows; the next is made in the other page
        call pc_page
        ld hl,(JIFFY)
        ld (pc_t),hl
        xor a
        ld (pc_ld),a
        ld (pc_first),a
        ld a,(pc_hid)
        xor 1
        ld (pc_hid),a
        ld a,(pc_mode)
        cp M_VIEW
        ret z
        cp M_COVER
        jp z,pc_cov_done
.next:  call pc_next
        ret c
        ld (pc_shown),hl
        jp pc_load
.fail:  ld a,(pc_mode)          ; one picture: back, and why
        cp M_COVER
        jp z,pc_cov_fail
        cp M_VIEW
        jr nz,.skip
        ld a,(reply+1)
        ld hl,txt_pc_prog
        cp 3
        jr z,.m
        ld hl,txt_pc_bad
.m:     ld (pc_msg),hl
        call pc_back
        ld hl,0
        ld (pc_msg),hl
        ret
.stop:  ld a,(pc_mode)          ; (none of them could be shown)
        cp M_SAVER
        jp z,fs_close
        jp pc_back
.skip:  ld a,(pc_fails)         ; the slideshow: the next (not for ever)
        inc a
        ld (pc_fails),a
        ld hl,(pc_n)
        inc h
        dec h
        jr nz,.nx
        cp l
        jr nc,.stop
.nx:    xor a
        ld (pc_ld),a
        jr .next

; HL * E (E < 256) -> HL
pc_mul: ld b,8
        ex de,hl
        ld a,l
        ld hl,0
.l:     add hl,hl
        rlca
        jr nc,.n
        add hl,de
.n:     djnz .l
        ret

; the rows of the reply to the page that does not show: reply+2 the first, reply+3 how many
pc_rows:
        ld a,(reply+3)
        ld b,a
        ld a,(reply+2)
        ld c,a
        ld hl,reply+4
.r:     push bc
        ld a,(pc_hid)           ; R#14: page * 4 + row / 64
        add a,a
        add a,a
        ld e,a
        ld a,c
        rlca
        rlca
        and 3
        or e
        di
        out (VDP_C),a
        ld a,#80+14
        out (VDP_C),a
        xor a
        out (VDP_C),a
        ld a,c
        and 63
        or #40
        out (VDP_C),a
        ld bc,VDP_D             ; B = 0: 256 bytes
        otir
        xor a                   ; (R#14 back to 0: the rest of PICOAMP writes the first 16 KB)
        out (VDP_C),a
        ld a,#80+14
        out (VDP_C),a
        ei
        pop bc
        inc c
        djnz .r
        ret

; the keys on a picture: the slideshow / screensaver: any key ends it (the arrows: on)
pc_keys_pic:
        ld c,a
        ld a,(pc_mode)
        cp M_SAVER
        jp z,fs_close           ; the screensaver: back to the player
        cp M_COVER
        jp z,pc_cov_keys
        ld a,c
        cp 28
        jr z,.next
        cp 29
        jr z,.prev
        ld a,(pc_mode)
        cp M_VIEW
        ld a,c
        jp nz,pc_back           ; the slideshow: any other key ends it
        cp ' '
        jp nz,pc_back
        ld hl,(pc_shown)        ; one picture: Space marks it
        ld (pc_cur),hl
        jp pc_mark_quiet
.next:  ld a,(pc_mode)
        cp M_VIEW
        jr nz,.sn
        call pc_next
        ret c
        ld (pc_shown),hl
        jp pc_load
.sn:    ld a,1                  ; the slideshow: the next one now
        ld (pc_first),a
        ret
.prev:  ld hl,(pc_shown)        ; (the one before, among the pictures)
        ld de,(pc_nd)
        or a
        sbc hl,de
        ret z
        add hl,de
        dec hl
        ld (pc_shown),hl
        jp pc_load

; the full screen cover ------------------------------------------------------
; pc_cover_req: A = 1 made again (else: only when the engine has another)
pc_cover_req:
        ld (args),a
        ld bc,1
        ld a,C_PCOVER
        call cmd
        ret c
        ld a,(reply)            ; 0 being made, 1 the one that shows, 2 none
        or a
        ret nz
        inc a
        ld (pc_ld),a
        ret

; (pc_ld 0) another cover in the engine: made, when it is ready
pc_cov_gen:
        ld a,(pc_mode)
        cp M_COVER
        ret nz
        ld a,(st+ST_COVGEN)
        ld hl,pc_cgen
        cp (hl)
        ret z
        ld b,a
        ld a,(st+ST_COVST)
        cp 2
        ret nz
        ld (hl),b
        xor a
        jr pc_cover_req

; made (it shows) or failed (the one before stays): the memory back to the covers
pc_cov_fail:
        xor a
        ld (pc_ld),a
pc_cov_done:
        ld a,C_PCLOSE
        jp cmd0

pc_cov_keys:
        ld a,c
        cp 28
        jr z,.nx
        cp 29
        jr z,.pv
        cp 27
        jp z,fs_close
        cp 13
        jp z,fs_close
        cp 8
        jp z,fs_close
        and #DF
        cp 'Z'
        jp z,fs_close
        cp 'V'
        jr z,.nx
        cp 'G'
        ret z
        cp 'E'
        jp z,next_eq
        ld a,b                  ; the playback keys
        jp keys_common
.nx:    call .out
        jp fs_next
.pv:    call .out
        jp fs_prev
.out:   call pc_leave           ; (the other pictures are the main program's)
        xor a
        ld (pg_on),a
        ret

pc_mark_quiet:
        ld hl,(pc_cur)
        call pc_bit
        ld c,a
        xor (hl)
        ld (hl),a
        and c
        ld hl,(pc_nmark)
        jr z,.un
        inc hl
        jr .s
.un:    dec hl
.s:     ld (pc_nmark),hl
        ret

; back to the browser
pc_back:
        call pc_s8_off
        xor a
        ld (pc_mode),a
        ld hl,(pc_shown)        ; the cursor on the picture that showed
        ld de,(pc_n)
        or a
        sbc hl,de
        jr nc,.d
        add hl,de
        ld (pc_cur),hl
        ld de,(pc_top)
        or a
        sbc hl,de
        jr c,.top
        ld de,PC_ROWS
        sbc hl,de
        jr c,.d
.top:   ld hl,(pc_cur)
        ld (pc_top),hl
.d:     jp pc_draw_all

;------------------------------------------------------------------------------
; SCREEN 8: 256 x 192, both pages black, page 0 shows
pc_s8_on:
        ld a,1
        ld (pc_s8),a
        ld (pc_first),a
        ld (pc_hid),a           ; (the first picture into page 1)
        xor a
        ld (pc_ld),a
        ld a,(RG0SAV)           ; G7: M3, M4, M5 (R#0), no M1 or M2 (R#1)
        and #F1
        or #0E
        ld b,0
        call vreg
        ld a,(RG1SAV)
        and #E7
        ld b,1
        call vreg
        xor a                   ; the border black
        ld b,7
        call vreg
        ld a,(RG8SAV)           ; no sprites
        or #02
        ld b,8
        call vreg
        ld a,(RG9SAV)           ; 192 lines
        and #7F
        ld b,9
        call vreg
        xor a
        ld b,14
        call vreg
        call pc_page
        ; both pages black: HMMV 256 x 512 from 0,0 (the VDP fills them)
        di
        ld a,36                 ; R#17: from R#36 on, one after another
        out (VDP_C),a
        ld a,#80+17
        out (VDP_C),a
        ld hl,pc_hmmv
        ld bc,11*256+VDP_I
        otir
        ei
.w:     ld a,2                  ; until it is done (S#2 CE)
        di
        out (VDP_C),a
        ld a,#80+15
        out (VDP_C),a
        in a,(VDP_C)
        ld b,a
        xor a
        out (VDP_C),a
        ld a,#80+15
        out (VDP_C),a
        ei
        bit 0,b
        jr nz,.w
        ret
pc_hmmv: db 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, #C0     ; DX, DY, NX 256, NY 512, colour 0, ARG, HMMV

; A = the page that shows (0 or 1)
pc_page:
        rrca
        rrca
        rrca                    ; (bit 0 -> bit 5)
        or #1F
        ld b,2
        jp vreg

; back to SCREEN 4 (when it is in SCREEN 8)
pc_s8_off:
        ld a,(pc_s8)
        or a
        ret z
        xor a
        ld (pc_s8),a
        ld a,(RG9SAV)
        ld b,9
        call vreg
        jp screen_init

;------------------------------------------------------------------------------
txt_pc_title:   db "Pictures  ",0
txt_pc_root:    db "/",0
txt_pc_defdir:  db "/PICTURES",0
txt_pc_keys:    db "Enter view  Space mark  A all  G slideshow",0
txt_pc_saver:   db "O saver ",0
txt_pc_every:   db "  R ",0
txt_pc_shuf:    db "s  U shuffle ",0
txt_pc_fkey:    db "  F here",0
txt_pc_off:     db "off",0
txt_pc_on:      db "on",0
txt_pc_pics:    db " pictures",0
txt_pc_comma:   db ", ",0
txt_pc_marked:  db " marked",0
txt_pc_fset:    db "The screensaver shows this folder",0
txt_pc_nomem:   db "Not enough engine memory right now",0
txt_pc_nodir:   db "That folder is not there",0
txt_pc_prog:    db "A progressive JPEG: it reads baseline ones",0
txt_pc_bad:     db "Not a JPEG it can read",0
txt_k_saver:    db "pictures.saver",0
txt_k_int:      db "pictures.interval",0
txt_k_shuf:     db "pictures.shuffle",0
txt_k_folder:   db "pictures.folder",0

pc_mode:        db 0
pc_cgen:        db 0            ; the cover's generation asked for
pc_dirty:       db 0
pc_s8:          db 0            ; SCREEN 8 now
pc_first:       db 0            ; the next picture shows at once
pc_hid:         db 0            ; the page that does not show (the picture is made there)
pc_ld:          db 0            ; 0 nothing, 1 being made, 2 made
pc_fails:       db 0
pc_int:         db 1            ; the interval's index
pc_shuf:        db 0
pc_ma:          db 0
pc_rt:          db 0
pc_n:           dw 0            ; entries
pc_nd:          dw 0            ; of them folders (first)
pc_top:         dw 0
pc_cur:         dw 0
pc_shown:       dw 0            ; the picture showing (or being made)
pc_nmark:       dw 0
pc_t:           dw 0            ; JIFFY when it showed
pc_ri:          dw 0
pc_rp:          dw 0
pc_msg:         dw 0
pc_num:         ds 6
pc_marks:       ds 50           ; 400 entries
pc_path:        ds 128
pc_sfolder:     ds 128          ; the screensaver's folder
mod_pic_end:
