;==============================================================================
; news.asm - PICOAMP's news page, teletext style: a page module (see
; clock.asm).
;
; Page 100 is the index of the feeds (engine 0.12: NEWS_FEEDS), 101.. a feed's
; stories, six to a subpage (they turn over by themselves after a while,
; as on teletext), a story's own page with its text. The header has the page
; number and the clock; a feed's name is in double-height letters.
; Keys: three digits go to a page; Up/Down choose, Enter opens; Left/Right
; the subpage (or the story); I the index; ESC or BS back; C clock, W
; weather, T back to the player; the playback keys keep working.
;==============================================================================

NW_PER   equ 6                  ; stories a subpage
V_INDEX  equ 0
V_LIST   equ 1
V_STORY  equ 2

mod_news:
        jp nw_open              ; the jump table (M_OPEN ...)
        jp nw_tick
        jp nw_ret
        jp nw_keys
        jp nw_ret
        jp nw_ret
        jp nw_leave

;------------------------------------------------------------------------------
nw_open:
        ld a,BLK                ; black, as teletext
        ld b,7
        call vreg
        ld a,(eng_minor)
        cp 12
        jr nc,.ok
        call nw_cls
        ld hl,txt_nw_old
        ld de,#0A00
        ld b,32
        ld c,RED*16+BLK
        jp text6s
.ok:    ld a,C_NFEEDS           ; the feeds' names
        call cmd0
        ret c
        ld hl,reply
        ld a,(hl)
        inc hl
        cp 9
        jr c,.n
        ld a,8
.n:     ld (nw_nf),a
        ld b,a
        or a
        jr z,.e
        ld de,nw_names
.c:     push bc
        push de
        ld bc,23
        call strncpy0
        pop de
        ex de,hl
        ld bc,24
        add hl,bc
        ex de,hl
        pop bc
        djnz .c
.e:     ld a,(ckb+CK_NST)       ; a feed that is there already: its list
        cp 2
        jr nz,nw_index
        ld a,(ckb+CK_NFEED)
        ld hl,nw_nf
        cp (hl)
        jr nc,nw_index
        ld (nw_feed),a
        ld a,(ckb+CK_NCOUNT)
        ld (nw_n),a
        xor a
        ld (nw_sel),a
        jp nw_list

nw_leave:
        ld a,NAVY
        ld b,7
        jp vreg

nw_ret: ret

; the whole screen black
nw_cls: call cls
        ld hl,#2000
        ld bc,#1800
        ld a,BLK*16+BLK
        jp vfill

;------------------------------------------------------------------------------
; page 100: the feeds
nw_index:
        xor a
        ld (nw_view),a
        ld (nw_wait),a
        ld a,100
        ld (nw_page),a
        call nw_cls
        call nw_hdr
        ld hl,txt_nw_title
        call nw_banner
        ld hl,txt_nw_ihead
        ld de,#0401
        ld b,31
        ld c,GREEN*16+BLK
        call text6s
        ld a,(nw_nf)
        or a
        jr nz,.l
        ld hl,txt_nw_nofeeds
        ld de,#0601
        ld b,31
        ld c,WHITE*16+BLK
        call text6s
        jr .f
.l:     call nw_ilines
.f:     ld hl,txt_nw_ifoot
        ld de,#1500
        ld b,32
        ld c,CYAN*16+BLK
        call text6s
        jp nw_foot

nw_ilines:                      ; the feeds, rows 6.., the chosen one highlighted
        ld c,0
.l:     ld a,(nw_nf)
        cp c
        ret z
        push bc
        ld a,c                  ; " 101  BBC World"
        add a,101
        ld l,a
        ld h,0
        ld de,linebuf
        ld a,' '
        ld (de),a
        inc de
        call fmt_u16
        ld a,' '
        ld (de),a
        inc de
        ld (de),a
        inc de
        ld a,c
        push de
        call nw_name
        pop de
        call strcpy
        pop bc
        push bc
        ld a,c
        add a,a
        add a,6
        ld d,a
        ld e,1
        ld a,(nw_isel)
        cp c
        ld c,WHITE*16+BLUE
        jr z,.s
        ld c,CYAN*16+BLK
.s:     ld hl,linebuf
        ld b,30
        call text6s
        pop bc
        inc c
        jr .l

; nw_name: A = feed -> HL = its name
nw_name:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld e,l
        ld d,h
        add hl,hl
        add hl,de               ; * 24
        ld de,nw_names
        add hl,de
        ret

;------------------------------------------------------------------------------
; a feed: fetched, then its stories six to a subpage
nw_feed_open:                   ; A = feed
        ld (nw_feed),a
        add a,101
        ld (nw_page),a
        ld a,V_LIST
        ld (nw_view),a
        xor a
        ld (nw_sel),a
        ld (nw_n),a
        call nw_cls
        call nw_hdr
        ld a,(nw_feed)
        call nw_name
        call nw_banner
        ld a,(nw_feed)
        ld e,a
        ld a,C_NFETCH
        call cmd_u8
        ret c
        ld hl,txt_nw_nomem
        jr nz,nw_say
        ld a,1
        ld (nw_wait),a
        ld hl,txt_nw_fetch
        ld c,WHITE*16+BLK
nw_say_c:
        ld de,#0A00
        ld b,32
        jp nw_ctext
nw_say: ld c,RED*16+BLK
        jr nw_say_c

; the list of the stories (subpage of nw_sel)
nw_list:
        ld a,V_LIST
        ld (nw_view),a
        ld a,(nw_feed)
        add a,101
        ld (nw_page),a
        ld hl,(JIFFY)
        ld (nw_idle),hl
        call nw_cls
        call nw_hdr
        ld a,(nw_feed)
        call nw_name
        call nw_banner
        ld a,(nw_n)
        or a
        ld hl,txt_nw_none
        jr z,nw_say
        ; the subpage: sel / 6
        ld a,(nw_sel)
        ld c,0
.d:     sub NW_PER
        jr c,.dd
        inc c
        jr .d
.dd:    ld a,c
        ld (nw_sub),a
        add a,a                 ; its first story: 6 c
        add a,c
        add a,a
        ld (nw_first),a
        ld (args),a
        ld a,NW_PER
        ld (args+1),a
        ld bc,2
        ld a,C_NLIST
        call cmd
        ret c
        ret nz
        call nw_subno           ; "2/7" in row 3
        ld hl,reply
        ld d,4
        ld a,(nw_first)
        ld c,a
.s:     ld a,(nw_n)             ; story C at row D
        cp c
        jr z,.e
        ld a,d
        cp 22
        jr nc,.e
        ld a,(nw_first)
        add a,NW_PER
        cp c
        jr z,.e
        push bc
        push hl
        push de
        ld a,c                  ; its number
        inc a
        ld l,a
        ld h,0
        ld de,linebuf
        call fmt_u16
        pop de
        push de
        ld hl,linebuf
        ld e,0
        ld b,2
        ld c,CYAN*16+BLK
        call text6s
        pop de
        pop hl
        pop bc
        push bc
        ld a,(nw_sel)           ; the title: two rows at most
        cp c
        ld c,WHITE*16+BLK
        jr nz,.n
        ld c,YELLOW*16+BLUE
.n:     ld e,3
        ld b,2
        call nw_wrap            ; HL after it, D the next row
.k:     ld a,(hl)               ; (the rest of a long title)
        inc hl
        or a
        jr nz,.k
        inc d                   ; a row between
        pop bc
        inc c
        jr .s
.e:     ld hl,txt_nw_lfoot
        ld de,#1600
        ld b,32
        ld c,CYAN*16+BLK
        call text6s
        jp nw_foot

nw_subno:                       ; "1/5" at the right of row 3
        ld de,linebuf
        ld a,(nw_sub)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'/'
        ld (de),a
        inc de
        ld a,(nw_n)             ; subpages: (n + 5) / 6
        add a,NW_PER-1
        ld c,0
.d:     sub NW_PER
        jr c,.dd
        inc c
        jr .d
.dd:    ld l,c
        ld h,0
        ld a,c
        ld (nw_subs),a
        call fmt_u16
        ld hl,linebuf
        ld de,#031B
        ld b,5
        ld c,WHITE*16+BLK
        jp text6s

;------------------------------------------------------------------------------
; a story's page
nw_story:
        ld a,V_STORY
        ld (nw_view),a
        ld a,(nw_sel)
        ld e,a
        ld a,C_NITEM
        call cmd_u8
        ret c
        ret nz
        call nw_cls
        call nw_hdr
        ld a,(nw_feed)
        call nw_name
        call nw_banner
        ld hl,reply             ; the title (reply: title 0 text 0 date 0)
        ld de,#0400
        ld b,3
        ld c,YELLOW*16+BLK
        call nw_wrap
        push de
        ld hl,reply             ; the date
        call nw_skip
        call nw_skip
        pop de
        ld e,0
        ld b,1
        ld c,CYAN*16+BLK
        call nw_wrap
        inc d
        ld hl,reply             ; the text
        call nw_skip
        ld a,(hl)
        or a
        jr nz,.t
        ld hl,txt_nw_notext
.t:     ld a,21
        sub d
        ld b,a
        ld e,0
        ld c,WHITE*16+BLK
        call nw_wrap
        ld de,linebuf           ; "</>: story 3/25"
        ld hl,txt_nw_story
        call strcpy
        ld a,(nw_sel)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'/'
        ld (de),a
        inc de
        ld a,(nw_n)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_nw_sfoot
        call strcpy
        ld hl,linebuf
        ld de,#1600
        ld b,32
        ld c,CYAN*16+BLK
        call text6s
        jp nw_foot

nw_skip:                        ; HL after the 0 of a text
        ld a,(hl)
        inc hl
        or a
        jr nz,nw_skip
        ret

;------------------------------------------------------------------------------
; rows 0-3 and 23
nw_hdr:                         ; "P101  BBC World ......  Thu 29 Oct 21:15:07"
        ld de,linebuf
        ld a,'P'
        ld (de),a
        inc de
        ld a,(nw_ndig)          ; a page number being typed
        or a
        jr z,.p
        ld hl,nw_digs
        ld b,a
.t:     ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .t
        ld a,(nw_ndig)
.u:     cp 3
        jr nc,.e
        ld b,a
        ld a,'-'
        ld (de),a
        inc de
        ld a,b
        inc a
        jr .u
.p:     ld a,(nw_page)
        ld l,a
        ld h,0
        call fmt_u16
.e:     ld hl,txt_nw_pname
        call strcpy
        ld hl,linebuf
        ld de,#0000
        ld b,17
        ld c,WHITE*16+BLK
        call text6s
        ; fall through
nw_clock:
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
        ld a,'/'
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC)
        call put2
        xor a
        ld (de),a
        ld hl,linebuf
        ld de,#0011
        ld b,15
        ld c,YELLOW*16+BLK
        jp text6s

nw_foot:
        ld hl,txt_nw_foot
        ld de,#1700
        ld b,32
        ld c,GREEN*16+BLK
        jp text6s

; nw_banner: HL = text: rows 1-2 in double-height letters, yellow on blue
nw_banner:
        push hl
        ld d,1
.r:     push de
        ld e,0
        ld b,32
        ld c,BLUE*16+BLUE
        call fill_row
        pop de
        inc d
        ld a,d
        cp 3
        jr c,.r
        pop hl
        push hl                 ; in the middle: column (32 - n) / 2
        ld b,0
.n:     ld a,(hl)
        or a
        jr z,.ne
        inc hl
        inc b
        jr .n
.ne:    pop hl
        ld a,32
        sub b
        jr nc,.c
        xor a
.c:     srl a
        ld e,a
.ch:    ld a,(hl)
        or a
        ret z
        inc hl
        push hl
        push de
        sub 32
        jr nc,.ok
        xor a
.ok:    cp 96
        jr c,.ok2
        ld a,'?'-32
.ok2:   ld l,a                  ; the glyph: font + 8 (c - 32)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,font
        add hl,de
        ld de,nw_dhb            ; each line twice: 16 lines
        ld b,8
.g:     ld a,(hl)
        ld (de),a
        inc de
        ld (de),a
        inc de
        inc hl
        djnz .g
        pop de
        push de
        ld d,1
        ld ix,nw_dhb
        ld a,YELLOW*16+BLUE
        call put_cell
        pop de
        push de
        ld d,2
        ld ix,nw_dhb+8
        ld a,YELLOW*16+BLUE
        call put_cell
        pop de
        pop hl
        inc e
        ld a,e
        cp 32
        jr c,.ch
        ret

; nw_ctext: HL = text, DE = cell, B = cells, C = colour, in the middle
nw_ctext:
        push hl
        push bc
        push de
        ld e,0
.n:     ld a,(hl)
        or a
        jr z,.e
        inc hl
        inc e
        jr .n
.e:     ld a,e
        add a,a
        add a,e
        ld e,a
        ld a,b
        add a,a
        add a,a
        sub e
        jr nc,.p
        xor a
.p:     neg
        ld l,a
        ld h,#FF
        or a
        jr nz,.h
        ld h,a
.h:     ld (t6_off),hl
        ld hl,0
        ld (t6_cycle),hl
        pop de
        pop bc
        pop hl
        jp text6

; nw_wrap: HL = text, D = row, E = column, B = rows at most, C = colour:
; the text in lines cut at spaces -> HL after what was shown, D the next row
nw_wrap:
        ld a,b
        ld (nw_rows),a
        ld a,c
        ld (nw_col),a
        ld a,e
        ld (nw_c0),a
        ld a,32                 ; letters a line: (32 - E) * 4 / 3
        sub e
        add a,a
        add a,a
        ld c,0
.dv:    sub 3
        jr c,.dd
        inc c
        jr .dv
.dd:    ld a,c
        ld (nw_w),a
.line:  ld a,(hl)
        or a
        ret z
        ld a,(nw_rows)
        or a
        ret z
        dec a
        ld (nw_rows),a
        push de
        ; this line: up to nw_w letters, back to the last space when it is cut
        ld de,0                 ; E = letters, D = letters up to the last space
        push hl
.c:     ld a,(hl)
        or a
        jr z,.end
        cp ' '
        jr nz,.nc
        ld d,e
.nc:    inc hl
        inc e
        ld a,(nw_w)
        cp e
        jr nz,.c
        ld a,(hl)               ; full: does a word go on?
        or a
        jr z,.end
        cp ' '
        jr z,.end
        ld a,d
        or a
        jr z,.end               ; (one long word: cut it)
        ld e,d
.end:   pop hl
        push de
        ld b,0
        ld c,e
        ld de,linebuf
        ld a,c
        or a
        jr z,.z
        ldir
.z:     xor a
        ld (de),a
.sp:    ld a,(hl)               ; the spaces after it
        cp ' '
        jr nz,.o
        inc hl
        jr .sp
.o:     pop de
        pop de
        push hl
        push de
        ld hl,linebuf
        ld a,(nw_c0)
        ld e,a
        ld a,32
        sub e
        ld b,a
        ld a,(nw_col)
        ld c,a
        call text6s
        pop de
        pop hl
        inc d
        jr .line

; nw_nth: HL = strings, A = index -> HL
nw_nth: or a
        ret z
        ld b,a
.s:     ld a,(hl)
        inc hl
        or a
        jr nz,.s
        djnz .s
        ret

;------------------------------------------------------------------------------
nw_tick:
        ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz
        ld a,(ckb+CK_SEC)       ; the clock in the header
        ld hl,nw_ssec
        cp (hl)
        jr z,.w
        ld (hl),a
        call nw_clock
.w:     ld a,(nw_wait)          ; a feed being fetched
        or a
        jr z,.r
        ld a,(ckb+CK_NST)
        cp 1
        ret z
        xor a
        ld (nw_wait),a
        ld a,(ckb+CK_NST)
        cp 2
        ld hl,txt_nw_fail
        jp nz,nw_say
        ld a,(ckb+CK_NCOUNT)
        ld (nw_n),a
        xor a
        ld (nw_sel),a
        jp nw_list
.r:     ld a,(nw_view)          ; a list left alone: the next subpage after 20 s
        cp V_LIST
        ret nz
        ld a,(nw_n)
        cp NW_PER+1
        ret c
        ld hl,(JIFFY)
        ld de,(nw_idle)
        or a
        sbc hl,de
        ld a,(hold)
        ld e,a
        ld d,0
        push hl
        ld l,e
        ld h,d
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        add hl,hl               ; 20 seconds
        ex de,hl
        pop hl
        or a
        sbc hl,de
        ret c
        ld a,(nw_first)         ; the first story of the next subpage
        add a,NW_PER
        ld hl,nw_n
        cp (hl)
        jr c,.s
        xor a
.s:     ld (nw_sel),a
        jp nw_list

;------------------------------------------------------------------------------
nw_keys:
        ld c,a
        ld hl,(JIFFY)
        ld (nw_idle),hl
        ld a,c
        cp '0'                  ; a page number
        jr c,.nd
        cp '9'+1
        jp c,nw_digit
.nd:    ld hl,nw_view
        cp 27
        jr z,.back
        cp 8
        jr z,.back
        cp 13
        jr z,.enter
        cp 30
        jp z,.up
        cp 31
        jp z,.down
        cp 29
        jp z,.left
        cp 28
        jp z,.right
        and #DF
        cp 'I'
        jp z,nw_index
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
.back:  ld a,(hl)
        cp V_STORY
        jp z,nw_list
        cp V_LIST
        jp z,nw_index
        jp fs_close
.enter: ld a,(hl)
        cp V_INDEX
        jr nz,.e2
        ld a,(nw_nf)
        or a
        ret z
        ld a,(nw_isel)
        jp nw_feed_open
.e2:    cp V_LIST
        ret nz
        ld a,(nw_n)
        or a
        ret z
        jp nw_story
.up:    ld a,(hl)
        cp V_INDEX
        jr nz,.u2
        ld a,(nw_isel)
        or a
        ret z
        dec a
        ld (nw_isel),a
        jp nw_ilines
.u2:    cp V_LIST
        ret nz
        ld a,(nw_sel)
        or a
        ret z
        dec a
        jr .newsel
.down:  ld a,(hl)
        cp V_INDEX
        jr nz,.d2
        ld a,(nw_nf)
        ld b,a
        ld a,(nw_isel)
        inc a
        cp b
        ret nc
        ld (nw_isel),a
        jp nw_ilines
.d2:    cp V_LIST
        ret nz
        ld a,(nw_n)
        ld b,a
        ld a,(nw_sel)
        inc a
        cp b
        ret nc
.newsel:
        ld (nw_sel),a
        jp nw_list
.left:  ld a,(hl)
        cp V_STORY
        jr nz,.l2
        ld a,(nw_sel)           ; the story before
        or a
        ret z
        dec a
        ld (nw_sel),a
        jp nw_story
.l2:    cp V_LIST
        ret nz
        ld a,(nw_first)         ; the subpage before
        sub NW_PER
        ret c
        jr .newsel
.right: ld a,(hl)
        cp V_STORY
        jr nz,.r2
        ld a,(nw_n)
        ld b,a
        ld a,(nw_sel)
        inc a
        cp b
        ret nc
        ld (nw_sel),a
        jp nw_story
.r2:    cp V_LIST
        ret nz
        ld a,(nw_n)
        ld b,a
        ld a,(nw_first)
        add a,NW_PER
        cp b
        ret nc
        jr .newsel

; a digit of a page number: three of them go to the page
nw_digit:
        ld hl,nw_ndig
        ld e,(hl)
        ld d,0
        inc (hl)
        ld hl,nw_digs
        add hl,de
        ld (hl),a
        ld a,(nw_ndig)
        cp 3
        jp c,nw_hdr
        xor a
        ld (nw_ndig),a
        ld a,(nw_digs)          ; 1 0 0 + feed
        cp '1'
        jp nz,nw_hdr
        ld a,(nw_digs+1)
        cp '0'
        jp nz,nw_hdr
        ld a,(nw_digs+2)
        sub '0'
        jp z,nw_index
        dec a
        ld hl,nw_nf
        cp (hl)
        jp nc,nw_hdr            ; (no such page)
        jp nw_feed_open

;------------------------------------------------------------------------------
txt_nw_old:     db "The news needs engine 0.12 or newer",0
txt_nw_title:   db "PICOAMP NEWS",0
txt_nw_pname:   db "  PICOAMP",0
txt_nw_ihead:   db "Page  Feed",0
txt_nw_nofeeds: db "No feeds ([news] feed1=Name|URL in PICOAMP.INI)",0
txt_nw_ifoot:   db "Type a page number, or Up/Down and Enter",0
txt_nw_foot:    db "C clock  W weather  T or ESC: the player",0
txt_nw_lfoot:   db "Enter: the story  </>: subpage  I: index",0
txt_nw_story:   db "</>: story ",0
txt_nw_sfoot:   db "   ESC: the list",0
txt_nw_fetch:   db "Fetching the stories...",0
txt_nw_fail:    db "Page not available (no internet?)",0
txt_nw_nomem:   db "The news: no memory for it here",0
txt_nw_none:    db "No stories in this feed",0
txt_nw_notext:  db "(No more text)",0
nw_wd:          db "Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0,"Sun",0
nw_mon:         db "Jan",0,"Feb",0,"Mar",0,"Apr",0,"May",0,"Jun",0,"Jul",0,"Aug",0,"Sep",0,"Oct",0,"Nov",0,"Dec",0
; state
nw_view:        db 0
nw_page:        db 100
nw_nf:          db 0
nw_feed:        db 0
nw_isel:        db 0
nw_sel:         db 0
nw_n:           db 0
nw_sub:         db 0
nw_subs:        db 0
nw_first:       db 0
nw_wait:        db 0
nw_idle:        dw 0
nw_ssec:        db #FF
nw_ndig:        db 0
nw_digs:        ds 3,0
nw_row:         db 0
nw_rows:        db 0
nw_col:         db 0
nw_c0:          db 0
nw_w:           db 0
nw_dhb:         ds 16,0
nw_names:       ds 8*24,0
mod_news_end:
