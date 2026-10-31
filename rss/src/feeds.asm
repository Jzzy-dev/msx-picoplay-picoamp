;==============================================================================
; feeds.asm - My feeds (the favourites) and RSS.INI, the catalogue, and the
; news itself: a feed's stories, a story's full article (as pva_news.c).
;
; RSS.INI (next to RSS.COM, or on the boot disk for the ROM):
;   feeds=bbcw,alj,dw,guardw,nos     codes of the catalogue, or #n for feedN
;   feed1=My site|https://example.com/rss.xml
;   tz=+60                           local time - UTC in minutes (else the
;                                    MSX2's clock is compared with the web's)
;==============================================================================

MAX_FAVS equ 20
INI_MAX  equ 767
FV_MAX   equ 255

        VAR ini_buf, INI_MAX+1
        VAR ini_len, 2
        VAR ini_st, 1           ; 0 not read (no disk), 1 none yet, 2 read
        VAR fcb, 40
        VAR fv_tmp, FV_MAX+1
        VAR fv_name, 36
        VAR fv_url, PATH_MAX+1
        VAR has_disk, 1

;------------------------------------------------------------------------------
; the disk (FCB functions: MSX-DOS 1 and 2, and the disk BASIC's BDOS)
bdos:   ld a,(has_disk)
        or a
        scf
        ret z
        IFDEF ROMBUILD
        call #F37D
        ELSE
        call 5
        ENDIF
        ei
        or a
        ret

fcb_init:
        ld hl,fcb
        ld de,fcb+1
        ld bc,39
        ld (hl),0
        ldir
        ld hl,txt_ininame
        ld de,fcb+1
        ld bc,11
        ldir
        ret
fcb_rec:                        ; records of 1 byte from 0, the buffer
        ld hl,1
        ld (fcb+14),hl
        ld hl,0
        ld (fcb+33),hl
        ld (fcb+35),hl
        ld de,ini_buf
        ld c,#1A
        jp bdos
txt_ininame: db "RSS     INI"

ini_load:
        xor a
        ld (ini_st),a
        ld hl,0
        ld (ini_len),hl
        ld (ini_buf),a
        ld a,(has_disk)
        or a
        jr z,.def
        ld a,1
        ld (ini_st),a
        call fcb_init
        ld de,fcb
        ld c,#0F
        call bdos
        jr c,.def
        inc a
        jr z,.def               ; (FFh: not there)
        call fcb_rec
        ld de,fcb
        ld hl,INI_MAX
        ld c,#27
        call bdos
        ld (ini_len),hl
        ld de,fcb
        ld c,#10
        call bdos
        ld a,2
        ld (ini_st),a
        ld hl,ini_buf           ; to an EOF mark or a 0
        ld bc,(ini_len)
.e:     ld a,b
        or c
        jr z,.ee
        ld a,(hl)
        cp #1A
        jr z,.ee
        or a
        jr z,.ee
        inc hl
        dec bc
        jr .e
.ee:    ld (hl),0
        ld de,ini_buf
        or a
        sbc hl,de
        ld (ini_len),hl
.def:   ld de,txt_k_tz          ; tz=
        call ini_find
        jr nz,.nt
        ld a,(hl)
        cp '-'
        push af
        jr z,.tm
        cp '+'
        jr nz,.tn
.tm:    inc hl
.tn:    call num
        ex de,hl
        pop af
        call z,neg_hl
        ld (tz_min),hl
        ld a,1
        ld (tz_set),a
.nt:    ld de,txt_k_proxy       ; proxy=host:port (https for a network without TLS)
        call ini_find
        jr nz,.np
        ld de,prx_host
        ld b,HOST_MAX
.ph:    ld a,(hl)
        cp ':'
        jr z,.pe
        cp ' '+1
        jr c,.pe
        ld (de),a
        inc hl
        inc de
        djnz .ph
.pe:    xor a
        ld (de),a
        ld de,8080
        ld a,(hl)
        cp ':'
        jr nz,.pn
        inc hl
        call num
.pn:    ld (prx_port),de
.np:    ld de,txt_k_feeds       ; no feeds=: the default ones and feed1-9
        call ini_find
        ret z
        ld hl,cat_default
        ld de,fv_tmp
        call strcpy
        ld b,'1'
.k:     push bc
        push de
        ld a,b
        ld (txt_k_feedn+4),a
        call feedn_key
        call ini_find
        pop de
        pop bc
        jr nz,.kn
        ld a,','
        call putc
        ld a,'#'
        call putc
        ld a,b
        call putc
        xor a
        ld (de),a
.kn:    inc b
        ld a,b
        cp '9'+1
        jr c,.k
        jp fv_store.nosave

ini_save:
        ld a,(ini_st)
        or a
        scf
        ret z
        call fcb_init
        ld de,fcb
        ld c,#16
        call bdos
        ret c
        inc a
        scf
        ret z
        call fcb_rec
        ld de,fcb
        ld hl,(ini_len)
        ld c,#26
        call bdos
        ld de,fcb
        ld c,#10
        call bdos
        ld a,2
        ld (ini_st),a
        or a
        ret

txt_k_feeds: db "feeds=",0
txt_k_tz:    db "tz=",0
txt_k_proxy: db "proxy=",0
        VAR txt_k_feedn, 7      ; "feedN=" (made when needed)

; ini_find: DE = "key=" -> Z, HL = its value (to the end of the line)
ini_find:
        ld hl,ini_buf
.ln:    ld a,(hl)               ; a line: the key?
        or a
        jr z,.no
        push hl
        push de
.c:     ld a,(de)
        or a
        jr z,.y
        ld a,(hl)
        call lc
        ex de,hl
        cp (hl)
        ex de,hl
        jr nz,.nx
        inc hl
        inc de
        jr .c
.y:     pop de
        pop af
        cp a
        ret
.nx:    pop de
        pop hl
.sk:    ld a,(hl)               ; the next line
        or a
        jr z,.no
        inc hl
        cp 10
        jr nz,.sk
        jr .ln
.no:    or #FF
        ret

; fv_store: the favourites in fv_tmp to RSS.INI (feeds= first), saved
fv_store:
        call .put
        jp ini_save
.nosave:
.put:   ld de,txt_k_feeds       ; the old line out
        call ini_find
        jr nz,.ins
        ld de,-6
        add hl,de
        ld (fs_ls),hl
.e:     ld a,(hl)
        or a
        jr z,.ee
        inc hl
        cp 10
        jr nz,.e
.ee:    push hl
        ld de,ini_buf
        ld bc,(ini_len)
        ex de,hl
        add hl,bc
        ex de,hl
        pop hl
        ex de,hl
        or a
        sbc hl,de
        inc hl
        ld b,h
        ld c,l
        ex de,hl
        ld de,(fs_ls)
        ldir
        ld hl,ini_buf
        call strlen
        ld (ini_len),bc
.ins:   ld hl,fv_tmp            ; the new one: "feeds=" value CR LF
        call strlen
        ld hl,8
        add hl,bc
        ld (fs_l),hl
        ld de,(ini_len)
        add hl,de
        ld de,INI_MAX
        or a
        sbc hl,de
        ret nc                  ; (no room)
        ld hl,(ini_len)
        ld b,h
        ld c,l
        inc bc
        ld de,ini_buf
        add hl,de
        push hl
        ld de,(fs_l)
        add hl,de
        ex de,hl
        pop hl
        lddr
        ld hl,txt_k_feeds
        ld de,ini_buf
        call strcpy
        ld hl,fv_tmp
        call strcpy
        ld a,13
        call putc
        ld a,10
        ld (de),a
        ld hl,(ini_len)
        ld de,(fs_l)
        add hl,de
        ld (ini_len),hl
        ret
        VAR fs_ls, 2
        VAR fs_l, 2

;------------------------------------------------------------------------------
; the favourites: the value of feeds=, "code,code,#2"

; fv_tok: A = n -> HL = the n-th code, B = its length (CF: no such one)
fv_tok: ld c,a
        push bc
        ld de,txt_k_feeds
        call ini_find
        pop bc
        scf
        ret nz
.t:     ld a,(hl)               ; past spaces and commas
        cp ' '
        jr z,.s
        cp ','
        jr nz,.b
.s:     inc hl
        jr .t
.b:     cp ' '
        ret c                   ; (the end: CF)
        ld d,h
        ld e,l
        ld b,0
.l:     ld a,(hl)
        cp ','
        jr z,.e
        cp ' '
        jr c,.e
        inc hl
        inc b
        jr .l
.e:     push hl                 ; the spaces at its end off
.tr:    ld a,b
        or a
        jr z,.tz
        ld l,b
        ld h,0
        dec hl
        add hl,de
        ld a,(hl)
        cp ' '
        jr nz,.tz
        dec b
        jr .tr
.tz:    pop hl
        ld a,c
        or a
        jr z,.got
        dec c
        jr .t
.got:   ex de,hl
        or a
        ret

; fv_count -> A
fv_count:
        ld c,0
.c:     ld a,c
        push bc
        call fv_tok
        pop bc
        jr c,.e
        inc c
        ld a,c
        cp MAX_FAVS+5
        jr c,.c
.e:     ld a,c
        ret

; cat_find: HL = a code, B = its length -> HL = the catalogue's entry (CF: none)
cat_find:
        ld (cf_code),hl
        ld a,b
        ld (cf_len),a
        ld hl,cat_feeds
.e:     ld a,(hl)
        cp #FF
        scf
        ret z
        push hl
        inc hl
        ld de,(cf_code)
        ld a,(cf_len)
        ld b,a
.c:     ld a,(de)
        call lc
        cp (hl)
        jr nz,.no
        inc hl
        inc de
        djnz .c
        ld a,(hl)
        or a
        jr nz,.no
        pop hl
        or a
        ret
.no:    pop hl
        call cat_next
        jr .e
        VAR cf_code, 2
        VAR cf_len, 1

; cat_next: HL = an entry -> the next one
cat_next:
        inc hl
        call skipz
        call skipz
        jp skipz

; fv_res: A = favourite -> HL = its name, DE = its URL (CF: unknown, HL = "? code")
fv_res: call fv_tok
        ret c
        ld a,(hl)
        cp '#'
        jr z,.own
        push hl
        push bc
        call cat_find
        pop bc
        jr c,.unk
        pop af
        inc hl
        call skipz              ; the name
        push hl
        call skipz
        ex de,hl                ; DE = the URL
        pop hl
        or a
        ret
.own:   inc hl                  ; #n: feedN=Name|URL
        ld a,(hl)
        dec hl
        ld (txt_k_feedn+4),a
        push hl
        push bc
        call feedn_key
        call ini_find
        pop bc
        jr nz,.unk
        pop af
        ld de,fv_name
        ld b,34
.n:     ld a,(hl)
        cp '|'
        jr z,.ne
        cp ' '
        jr c,.bad
        ld (de),a
        inc hl
        inc de
        djnz .n
.ne:    xor a
        ld (de),a
        inc hl
        call skipsp
        ld de,fv_url
        ld b,PATH_MAX
        call url_copy
        ld hl,fv_name
        ld de,fv_url
        or a
        ret
.bad:   xor a
        ld (de),a
        ld hl,fv_name
        scf
        ret
.unk:   pop hl                  ; "? code"
        ld de,fv_name
        ld a,'?'
        call putc
        ld a,' '
        call putc
        ld a,b
        cp 30
        jr c,.u
        ld b,30
.u:     call strncpy
        ld hl,fv_name
        scf
        ret

feedn_key:                      ; txt_k_feedn = "feed" N "=" (N at +4 set)
        ld hl,txt_feedk
        ld de,txt_k_feedn
        ld bc,4
        ldir
        inc de
        ld a,'='
        ld (de),a
        inc de
        xor a
        ld (de),a
        ld de,txt_k_feedn
        ret
txt_feedk: db "feed"

; fv_has: HL = a catalogue entry -> Z when its code is in My feeds
fv_has: inc hl
        ld (fh_code),hl
        call strlen
        ld a,c
        ld (fh_len),a
        xor a
.l:     ld (fh_i),a
        call fv_tok
        jr c,.no
        ld a,(fh_len)
        cp b
        jr nz,.nx
        ld de,(fh_code)
.c:     ld a,(hl)
        call lc
        ex de,hl
        cp (hl)
        ex de,hl
        jr nz,.nx
        inc hl
        inc de
        djnz .c
        ret                     ; Z
.nx:    ld a,(fh_i)
        inc a
        jr .l
.no:    or #FF
        ret
        VAR fh_code, 2
        VAR fh_len, 1
        VAR fh_i, 1

;------------------------------------------------------------------------------
; the catalogue
cat_tname:                      ; A = topic -> HL = its name
        ld hl,cat_topics
        jp nth

cat_count:                      ; A = topic -> A = its feeds
        ld c,a
        ld b,0
        ld hl,cat_feeds
.l:     ld a,(hl)
        cp #FF
        ld a,b
        ret z
        ld a,(hl)
        cp c
        jr nz,.n
        inc b
.n:     call cat_next
        jr .l

cat_nth:                        ; A = topic, C = n -> HL = the entry (CF: none)
        ld b,a
        ld hl,cat_feeds
.l:     ld a,(hl)
        cp #FF
        scf
        ret z
        cp b
        jr nz,.n
        ld a,c
        or a
        ret z
        dec c
.n:     call cat_next
        jr .l

; fv_add: A = topic, C = n -> A = 0 added, 1 there already, 2 full
fv_add: call cat_nth
        ld a,1
        ret c
        push hl
        call fv_has
        pop hl
        ld a,1
        ret z
        push hl
        call fv_count
        pop hl
        cp MAX_FAVS
        ld a,2
        ret nc
        push hl
        ld de,txt_k_feeds
        call ini_find
        ld de,fv_tmp
        ld b,0
.c:     ld a,(hl)
        cp ' '
        jr c,.ce
        ld (de),a
        inc hl
        inc de
        inc b
        ld a,b
        cp 240
        jr c,.c
        pop hl
        ld a,2
        ret
.ce:    ld a,b
        or a
        ld a,','
        call nz,putc
        pop hl
        inc hl
        call strcpy
        call fv_store
        xor a
        ret

; fv_edit: A = n, C = 0 remove it, 1 swap with the next, FFh with the one before (CF: no)
fv_edit:
        ld (fe_i),a
        ld a,c
        ld (fe_d),a
        call fv_count
        ld (fe_n),a
        ld b,a
        ld a,(fe_i)
        cp b
        ccf
        ret c
        ld a,(fe_d)
        or a
        jr z,.go
        ld a,(fe_i)
        ld hl,fe_d
        add a,(hl)
        ld (fe_j),a
        cp b
        ccf
        ret c
.go:    ld de,fv_tmp
        xor a
        ld (de),a
        ld (fe_k),a
.k:     ld a,(fe_k)
        ld hl,fe_n
        cp (hl)
        jr nc,.done
        ld c,a
        ld a,(fe_d)
        or a
        jr nz,.sw
        ld a,(fe_i)
        cp c
        jr z,.nx
        jr .put
.sw:    ld a,(fe_i)
        cp c
        jr nz,.s2
        ld a,(fe_j)
        ld c,a
        jr .put
.s2:    ld a,(fe_j)
        cp c
        jr nz,.put
        ld a,(fe_i)
        ld c,a
.put:   push de
        ld a,c
        call fv_tok
        pop de
        ld a,(fv_tmp)
        or a
        ld a,','
        call nz,putc
.cp:    ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .cp
        xor a
        ld (de),a
.nx:    ld hl,fe_k
        inc (hl)
        jr .k
.done:  call fv_store
        or a
        ret
        VAR fe_i, 1
        VAR fe_j, 1
        VAR fe_d, 1
        VAR fe_n, 1
        VAR fe_k, 1

;------------------------------------------------------------------------------
; the news: a feed's stories, a story's full article
NS_IDLE   equ 0
NS_LOAD   equ 1
NS_DONE   equ 2
NS_FAILED equ 3

        VAR pool_base, 2        ; VRAM
        VAR pool_size, 2
        VAR art_base, 2
        VAR art_size, 2
        VAR pool_len, 2         ; the stories' bytes
        VAR n_st, 1
        VAR n_feed, 1
        VAR n_err, 1
        VAR n_url, PATH_MAX+1
        VAR a_st, 1
        VAR a_phase, 1
        VAR a_pend, 1
        VAR a_url, PATH_MAX+1
        VAR a_slen, 2           ; the summary's length

mem_init:
        ld a,(msx2)
        or a
        ld hl,#2000
        ld de,#6000
        ld bc,#8000
        ld ix,#6000
        jr nz,.s
        ld hl,#1000
        ld de,#1800
        ld bc,#2800
        ld ix,#1800
.s:     ld (pool_base),hl
        ld (pool_size),de
        ld (art_base),bc
        ld (art_size),ix
        ret

; news_fetch: A = favourite (CF: not asked for, net_err)
news_fetch:
        ld (n_feed),a
        call fv_res
        ld a,NE_URL
        ld (net_err),a
        ret c
        ex de,hl
        ld de,n_url
        ld b,PATH_MAX
        call url_copy
        xor a
        ld (a_st),a
        ld (a_pend),a
        ld (nitems),a
        ld (feed_full),a
        ld a,#FF
        ld (a_story),a
        ld hl,(pool_base)
        ld de,(pool_size)
        call w_open
        xor a                   ; M_LIST
        call x_reset
        ld hl,n_url
        ld de,feed_body
        ld bc,feed_done
        call http_get
        ld a,NS_FAILED
        jr c,.s
        ld a,NS_LOAD
.s:     ld (n_st),a
        ld a,(net_err)
        ld (n_err),a
        ret

feed_body:
        jp x_run

feed_done:
        push af
        call w_flush
        ld hl,(w_len)
        ld (pool_len),hl
        ld a,(net_err)
        ld (n_err),a
        pop af
        ld a,NS_DONE
        jr nc,.s
        ld a,(nitems)
        or a
        ld a,NS_DONE
        jr nz,.s
        ld a,NS_FAILED
.s:     ld (n_st),a
        ret

; news_full: A = story -> the full article coming (CF: no link)
news_full:
        ld b,a
        ld a,(a_story)
        cp b
        jr nz,.new
        ld a,(a_st)
        cp NS_LOAD
        ret z
        cp NS_DONE
        ret z
.new:   push bc
        call http_stop
        pop bc
        ld a,b
        ld (a_story),a
        push af
        ld c,'L'
        ld de,a_url
        ld b,PATH_MAX
        call it_get
        pop af
        push af
        ld c,'S'
        call it_find
        jr nc,.sl
        ld bc,0
.sl:    ld (a_slen),bc
        pop af
        call it_ptr
        ld bc,6
        add hl,bc
        ld a,(hl)               ; the content is in the feed: phase 1
        or a
        ld a,1
        jr nz,.ph
        ld a,(a_url)
        or a
        ld a,NS_FAILED
        jr z,.f
        ld a,2
.ph:    ld (a_phase),a
        ld a,1
        ld (a_pend),a
        ld a,NS_LOAD
.f:     ld (a_st),a
        ld hl,(art_base)        ; (nothing of it yet)
        ld de,(art_size)
        call w_open
        or a
        ret

; news_poll: the next part of the article to fetch
news_poll:
        ld a,(a_pend)
        or a
        ret z
        call http_busy
        ret nz
        xor a
        ld (a_pend),a
        ld hl,a_gen             ; (a new text: the index again)
        inc (hl)
        ld hl,(art_base)
        ld de,(art_size)
        call w_open
        ld a,(a_phase)
        cp 1
        jr nz,.p2
        ld a,M_ART
        call x_reset
        xor a
        ld c,0
        call h_start
        ld hl,n_url
        ld de,art_fbody
        ld bc,art_fdone
        jr .go
.p2:    ld a,1
        ld c,0
        call h_start
        ld hl,a_url
        ld de,art_pbody
        ld bc,art_pdone
.go:    call http_get
        ret nc
        ld a,NS_FAILED
        ld (a_st),a
        ret

art_fbody:
        jp x_run

art_pbody:
        ld a,(h_got+2)          ; at most 768 KB of a page
        cp 12
        ccf
        ret c
        ld de,0
        call h_run
        ret c
        ld a,b
        or c
        ret z
        push hl                 ; (a 0 byte: by itself)
        push bc
        xor a
        call h_byte
        pop bc
        pop hl
        inc hl
        dec bc
        jr art_pbody

; the feed's content: enough of it, else the page
art_fdone:
        call h_para
        call w_flush
        ld hl,(a_slen)
        ld de,200
        add hl,de
        ex de,hl
        ld hl,(w_len)
        or a
        sbc hl,de
        jr nc,art_in
        ld a,(w_full)
        or a
        jr z,.pg
        ld hl,(w_len)
        ld de,300
        or a
        sbc hl,de
        jr nc,art_in
.pg:    ld a,(a_url)
        or a
        jr z,art_fail
        ld a,2
        ld (a_phase),a
        ld a,1
        ld (a_pend),a
        ret

art_pdone:
        call h_para
        call w_flush
        ld hl,(w_len)
        ld de,200
        or a
        sbc hl,de
        jr c,art_fail
art_in: ld a,NS_DONE
        ld (a_st),a
        ret
art_fail:
        ld a,NS_FAILED
        ld (a_st),a
        ret

;------------------------------------------------------------------------------
; the stories in the pool

; it_ptr: A = story -> HL = its entry
it_ptr: ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        or a
        sbc hl,de
        ld de,items
        add hl,de
        ret

; it_range: A = story -> HL = its record in VRAM, BC = its length
it_range:
        push af
        call it_ptr
        ld e,(hl)
        inc hl
        ld d,(hl)
        pop af
        inc a
        ld hl,nitems
        cp (hl)
        ld hl,(pool_len)
        jr nc,.l
        push de
        call it_ptr
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop de
.l:     or a
        sbc hl,de
        ld b,h
        ld c,l
        ld hl,(pool_base)
        add hl,de
        ret

; it_find: A = story, C = the tag -> HL = its text in VRAM, BC = its length (CF: none)
it_find:
        push bc
        call it_range
        pop de
        ld a,e
        ld (if_tag),a
.rec:   ld a,b
        or c
        scf
        jr z,.e
        call vset_r
        call vr_get
        dec bc
        ld (if_t),a
        ld (if_s),hl
        ld de,0
.s:     ld a,b
        or c
        jr z,.got
        call vr_get
        dec bc
        or a
        jr z,.got
        inc de
        jr .s
.got:   ld a,(if_tag)
        push hl
        ld hl,if_t
        cp (hl)
        pop hl
        jr nz,.rec
        ld hl,(if_s)
        ld b,d
        ld c,e
        or a
.e:     ei
        ret
        VAR if_tag, 1
        VAR if_t, 1
        VAR if_s, 2

; it_get: A = story, C = the tag, DE = a buffer, B = at most -> the text there (CF: none, "")
it_get: ld (ig_dst),de
        push bc
        call it_find
        pop de
        jr c,.none
        ld a,b
        or a
        jr nz,.cl
        ld a,c
        cp d
        jr c,.ok
.cl:    ld c,d
        ld b,0
.ok:    ld de,(ig_dst)
        call vr_blk
        xor a
        ld (de),a
        ld hl,(ig_dst)
        or a
        ret
.none:  ld hl,(ig_dst)
        ld (hl),0
        scf
        ret
        VAR ig_dst, 2
