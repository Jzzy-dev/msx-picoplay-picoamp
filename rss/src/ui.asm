;==============================================================================
; ui.asm - the reader's screens (PicoAmp's news page, on its own): the
; headlines of a feed with the chosen one's summary under them; a story, its
; title and its text, scrolled (the full article comes in from the web while
; one reads); My feeds beside the catalogue by topic, to add and remove them.
; TEXT 2 (80x26) on an MSX2 and up, TEXT 1 (40x24) on an MSX1.
;
; Keys: headlines: Up/Down, Left/Right a page, Enter the story, 1-9 a feed of
; My feeds, F My feeds, R again, I info, ESC quit. A story: Up/Down a line,
; Left/Right a page, Enter the full article / the summary, N/P the next /
; previous story, ESC the headlines. My feeds: Left/Right the side, Enter
; read (left) / add (right), D or DEL remove, U/J move, BS back.
;==============================================================================

V_LIST  equ 0
V_STORY equ 1
V_FEEDS equ 2
V_INFO  equ 3

        VAR v_view, 1
        VAR nf, 1               ; My feeds
        VAR n_n, 1              ; the stories shown
        VAR n_first, 1
        VAR n_sel, 1
        VAR n_wait, 1           ; a feed being fetched
        VAR n_which, 1          ; 0 the summary, 1 the full article
        VAR s_top, 2
        VAR s_total, 2
        VAR s_flags, 1          ; 1 loading, 2 the article, 4 failed
        VAR s_alen, 2
        VAR s_ast, 1
        VAR ix_src, 1           ; what the index is of: 0 nothing, 1 a summary, 2 the article
        VAR ix_story, 1
        VAR ix_gen, 1
        VAR a_gen, 1
        VAR adue, 2
        VAR pane, 1
        VAR fsel, 1
        VAR tsel, 1
        VAR topic, 1
        VAR rn, 1
        VAR msgon, 1
        VAR msgt, 2
        VAR smin, 2
        VAR quitask, 1
        VAR quit, 1
        VAR net_tried, 1
        VAR ldue, 2
        VAR tbuf, 164           ; a title
        VAR lb, 100             ; a line being put together

ui_start:
        xor a
        ld (msgon),a
        ld (quitask),a
        ld (quit),a
        ld (ix_src),a
        ld (n_n),a
        ld (n_wait),a
        ld (a_gen),a
        ld a,#FF
        ld (topic),a
        call ui_favs
        call nw_feeds           ; My feeds first
        ld a,(un_type)
        or a
        ret nz
        ld hl,txt_nonet
        jp nw_msg

; ui_splash: the screen while the network is looked for
ui_splash:
        call tx_cls
        call row0
        call credits
        ld hl,txt_look
        jp nw_say

; credits: "by JZZY & CLAUDE 2026" at the right above the key rows, the names in the bar
credits:
        ld a,(l_k1)
        sub 2
        ld d,a
        ld (bx_row),a
        ld a,(sw)
        sub 22
        ld e,a
        add a,3
        ld (bx_e),a
        ld a,13
        ld (bx_b),a
        ld hl,txt_credits
        ld b,21
        push de
        call tx_text
        pop de
        ld e,0
        ld b,0
        jp tx_bar

ui_favs:
        call fv_count
        cp MAX_FAVS+1
        jr c,.s
        ld a,MAX_FAVS
.s:     ld (nf),a
        ret

; the main loop's look: the clock, a message going, a feed or an article coming in
ui_tick:
        call clk_local
        jr c,.nc
        ld hl,(smin)
        or a
        sbc hl,de
        jr z,.nc
        ld (smin),de
        call row0_clock
.nc:    ld a,(msgon)
        or a
        jr z,.w
        ld hl,(JIFFY)
        ld de,(msgt)
        or a
        sbc hl,de
        ld de,180
        sbc hl,de
        jr c,.w
        xor a
        ld (msgon),a
        ld (quitask),a
        call nw_keyline
.w:     ld a,(n_wait)
        or a
        jr z,.art
        ld a,(n_st)
        cp NS_LOAD
        jr nz,.in
        call .due
        ret c
        ld de,lb                ; "Fetching the stories... 12 KB"
        ld hl,txt_fetch
        call strcpy
        call put_kb
        xor a
        ld (de),a
        ld hl,lb
        jp nw_say
.in:    xor a
        ld (n_wait),a
        ld a,(n_st)
        cp NS_DONE
        jr nz,.fail
        ld a,(nitems)
        ld (n_n),a
        xor a
        ld (n_sel),a
        ld (n_first),a
        jp nw_list
.fail:  call err_text
        ld hl,lb
        jp nw_say
.art:   ld a,(v_view)           ; the article coming in: more of it shown
        cp V_STORY
        ret nz
        ld a,(n_which)
        or a
        ret z
        ld a,(s_flags)
        and 1
        ret z
        call .due
        ret c
        ld hl,(w_len)
        ld de,(s_alen)
        or a
        sbc hl,de
        jr nz,.more
        ld a,(a_st)
        ld hl,s_ast
        cp (hl)
        jp z,nw_status          ; (the KB read)
.more:  jp nw_stext
.due:   ld hl,(JIFFY)           ; twice a second (NC)
        ld de,(ldue)
        or a
        sbc hl,de
        ld de,30
        sbc hl,de
        ret c
        ld hl,(JIFFY)
        ld (ldue),hl
        ret

; put_kb: " 12 KB" (and " (45%)" when the size is known) to DE
put_kb: ld a,(h_got+2)
        ld h,a
        ld a,(h_got+1)
        ld l,a
        srl h
        rr l
        srl h
        rr l                    ; KB
        push hl
        call fmt_u16
        ld hl,txt_kb
        call strcpy
        pop hl
        ld a,(h_clen+2)
        ld b,a
        ld a,(h_clen+1)
        ld c,a
        srl b
        rr c
        srl b
        rr c
        ld a,b
        or c
        ret z
        push de
        ld de,656
        push hl
        or a
        sbc hl,de
        pop hl
        pop de
        ret nc
        push de
        ld de,100
        call mul16
        ld d,b
        ld e,c
        call div16
        pop de
        ld a,h
        or a
        ret nz
        ld a,l
        cp 101
        ret nc
        push hl
        ld hl,txt_pct1
        call strcpy
        pop hl
        call fmt_u16
        ld a,'%'
        call putc
        ld a,')'
        call putc
        xor a
        ld (de),a
        ret

; put_tls: ", TLS" / ", https by the proxy" / ", no TLS (http only)" to DE
put_tls:
        ld hl,txt_tls
        ld a,(un_tls)
        or a
        jp nz,strcpy
        ld hl,txt_prx
        ld a,(prx_host)
        or a
        jp nz,strcpy
        ld hl,txt_notls
        jp strcpy

; err_text: the feed's trouble -> lb
err_text:
        ld de,lb
        ld hl,txt_e_head
        call strcpy
        ld a,(n_err)
        ld hl,txt_errs
        call nth
        call strcpy
        ld a,(n_err)
        cp NE_HTTP
        ret nz
        ld hl,(h_status)
        call fmt_u16
        xor a
        ld (de),a
        ret

;------------------------------------------------------------------------------
; row 0: the name, the network, the time
row0:   ld hl,lb
        ld de,lb
        ld hl,txt_title
        call strcpy
        ld a,(sw)
        cp 80
        jr nz,.s
        ld a,(net_tried)
        or a
        jr z,.s
        ld hl,txt_sep
        call strcpy
        ld hl,txt_nonet0
        ld a,(un_type)
        or a
        jr z,.nn
        ld hl,un_name
        call strcpy
        call put_tls
        jr .s
.nn:    call strcpy
.s:     ld hl,lb
        ld de,#0000
        ld a,(sw)
        cp 80
        jr nz,.w
        ld a,57                 ; (the time at the right)
.w:     ld b,a
        call tx_text
        ld hl,#FFFF
        ld (smin),hl
        ; fall through
row0_clock:
        call clk_local
        ret c
        push de
        ld a,(sw)
        cp 80
        jr nz,.sh
        ld a,1
        call fmt_date
        pop de
        ld hl,fmt_buf
        ld de,#003A
        ld b,22
        jp tx_text
.sh:    xor a
        push hl
        call fmt_date           ; "30 Oct 09:53"
        pop hl
        ld de,fmt_buf
.e:     ld a,(de)
        or a
        jr z,.ee
        inc de
        jr .e
.ee:    ld a,' '
        call putc
        pop hl
        call fmt_hm
        xor a
        ld (de),a
        ld hl,fmt_buf
        ld de,#001B
        ld b,13
        jp tx_text

;------------------------------------------------------------------------------
; nw_say: HL = a message in the middle of the list
nw_say: ld de,#0A02
        ld a,(sw)
        sub 4
        ld b,a
        jp tx_text

; nw_msg: HL = a message on the key line for a while
nw_msg: ld a,(l_k1)
        ld d,a
        ld e,0
        ld a,(sw)
        ld b,a
        call tx_text
        ld hl,(JIFFY)
        ld (msgt),hl
        ld a,1
        ld (msgon),a
        ret

nw_keyline:                     ; the last two rows: the view's keys
        ld a,(sw)
        cp 80
        ld a,(v_view)
        ld hl,txt_k80
        jr z,.w
        ld hl,txt_k40
.w:     add a,a
        call nth
        ld a,(l_k1)
        ld d,a
        ld e,0
        ld a,(sw)
        ld b,a
        push bc
        call tx_text
        call skipz
        pop bc
        ld a,(l_k1)
        inc a
        ld d,a
        ld e,0
        jp tx_text

; nw_name: A = favourite -> HL = its name
nw_name:
        call fv_res
        ret

;------------------------------------------------------------------------------
; a feed (A = favourite) asked for; its headlines when it is in
nw_fetch:
        push af
        xor a
        ld (v_view),a
        ld (n_n),a
        ld (ix_src),a
        call tx_cls
        call row0
        pop af
        call news_fetch
        ld a,(n_st)
        cp NS_LOAD
        ld a,1
        jr z,.w
        xor a
.w:     ld (n_wait),a
        call nw_lhead
        call nw_keyline
        ld a,(n_wait)
        or a
        ld hl,txt_fetch
        jp nz,nw_say
        call err_text
        ld hl,lb
        jp nw_say

; the bar of the headlines: " BBC News, World ....  Headlines 1-17 of 38"
nw_lhead:
        ld a,(n_feed)
        call nw_name
        ld de,lb
        ld a,' '
        call putc
        call strcpy
        ld hl,lb
        ld de,#0100
        ld a,(sw)
        sub 15
        ld b,a
        call tx_text
        ld de,lb
        ld a,(n_wait)
        or a
        jr nz,.e
        ld a,(n_n)
        or a
        jr z,.e
        ld a,(sw)
        cp 80
        ld hl,txt_heads
        call z,strcpy
        ld a,(n_first)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'-'
        call putc
        ld a,(l_nl)
        ld b,a
        ld a,(n_first)
        add a,b
        ld hl,n_n
        cp (hl)
        jr c,.l
        ld a,(hl)
.l:     ld l,a
        ld h,0
        call fmt_u16
        ld a,'/'
        call putc
        ld a,(n_n)
        ld l,a
        ld h,0
        call fmt_u16
.e:     xor a
        ld (de),a
        ld hl,lb                ; at the right
        call strlen
        ld a,(sw)
        sub c
        dec a
        ld e,a
        ld d,1
        ld b,c
        inc b
        call tx_text
        ld de,#0100
        ld a,(sw)
        ld b,a
        jp tx_bar

; the headlines, the chosen one and its summary
nw_list:
        xor a
        ld (v_view),a
        call tx_cls
        call row0
.w:     call nw_lhead
        call nw_keyline
        ld a,(n_n)
        or a
        jr nz,.h
        ld hl,txt_none
        jp nw_say
.h:     ld a,(l_h1)
        ld d,a
        call tx_hline
        ld a,(l_h2)
        ld d,a
        call tx_hline
        ld a,(n_first)
        ld b,a
        ld a,(l_nl)
        ld c,a
        ld d,2
.r:     push bc
        push de
        ld a,b
        call nw_head
        pop de
        pop bc
        inc d
        inc b
        dec c
        jr nz,.r
        jp nw_selbar

; nw_head: story A at row D: "  20:15  Title" (an empty row when there is none)
nw_head:
        ld hl,n_n
        cp (hl)
        jp nc,tx_clrrow
        push de
        push af
        ld de,lb
        ld a,' '
        call putc
        pop af
        push af
        call st_time            ; the time, 6 wide
        ld hl,lb+7
.p:     push hl
        or a
        sbc hl,de
        pop hl
        jr z,.t
        ld a,' '
        call putc
        jr .p
.t:     ld a,' '
        call putc
        pop af
        push de
        ld c,'T'
        ld de,tbuf
        ld b,160
        call it_get
        pop de
        call strlen             ; at most sw - 9 (then "...")
        ld a,(sw)
        sub 9
        cp c
        jr nc,.all
        sub 3
        ld b,a
        call strncpy
        ld hl,txt_dots
        call strcpy
        jr .sh
.all:   call strcpy
.sh:    pop de
        ld hl,lb
        ld e,0
        ld a,(sw)
        ld b,a
        jp tx_text

; st_time: story A's time to DE: "20:15" today, else "29 Oct"
st_time:
        ld (st_i),a
        push de
        call it_ptr
        inc hl
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ex de,hl                ; HL = days, DE = minutes
        ld a,h
        or l
        jr z,.raw
        call to_local
        push de
        push hl
        call clk_local
        pop bc                  ; BC = its day, HL = today
        jr c,.d
        or a
        sbc hl,bc
        jr nz,.d
        pop hl                  ; today: the time
        pop de
        call fmt_hm
        ret
.d:     pop de
        ld h,b
        ld l,c
        xor a
        call fmt_date
        pop de
        ld hl,fmt_buf
        jp strcpy
.raw:   pop de                  ; a date not understood: its first 5
        ld a,(st_i)
        push de
        ld c,'D'
        ld de,fmt_buf
        ld b,5
        call it_get
        pop de
        jp strcpy
        VAR st_i, 1

; the bar on the chosen headline, its summary under the list
nw_selbar:
        ld a,(n_sel)
        ld hl,n_first
        sub (hl)
        add a,2
        ld d,a
        ld e,0
        ld a,(sw)
        ld b,a
        call tx_bar
        ld a,(n_sel)
        call ix_summary
        ld a,(l_sum)
        ld d,a
        ld hl,0
        ld b,3
.l:     push bc
        push de
        push hl
        call ix_show
        pop hl
        pop de
        pop bc
        inc hl
        inc d
        djnz .l
        ret

; ix_summary: the index of story A's summary
ix_summary:
        ld (ix_story),a
        ld c,'S'
        call it_find
        jr nc,.s
        ld bc,0
        ld hl,(pool_base)
.s:     push bc
        call ix_reset
        pop hl
        call ix_run
        ld a,1
        ld (ix_src),a
        ret

; a new chosen headline (A): the bar moves, or the list turns a page
nw_newsel:
        ld hl,n_sel
        ld c,(hl)
        ld (hl),a
        ld b,a
        ld a,(n_first)
        ld e,a
        ld a,b
        sub e
        jr c,.page
        ld hl,l_nl
        cp (hl)
        jr nc,.page
        ld a,c                  ; the bar off the old one
        sub e
        add a,2
        ld d,a
        ld b,0
        call tx_bar
        jp nw_selbar
.page:  ld a,(l_nl)             ; the page it is on
        ld e,a
        ld a,b
        ld c,0
.pg:    sub e
        jr c,.pe
        push af
        ld a,c
        add a,e
        ld c,a
        pop af
        jr .pg
.pe:    ld a,c
        ld (n_first),a
        jp nw_list

;------------------------------------------------------------------------------
; a story (n_sel): its title, its date, its text from s_top
nw_story:
        ld a,V_STORY
        ld (v_view),a
        xor a
        ld (n_which),a
        ld (s_flags),a
        ld hl,0
        ld (s_top),hl
        ld (s_alen),hl
nw_story2:
        call tx_cls
        call row0
        call nw_keyline
        ld de,lb
        ld a,(sw)
        cp 80
        jr nz,.n4
        ld a,(n_feed)           ; " BBC News, World | story 3 of 38"
        push de
        call nw_name
        pop de
        ld a,' '
        call putc
        ld b,40
        call strncpy
        ld hl,txt_story
        call strcpy
        jr .num
.n4:    ld a,' '
        call putc
.num:   ld a,(n_sel)
        inc a
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_of
        call strcpy
        ld a,(n_n)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,' '
        call putc
        ld a,' '
        call putc
        xor a
        ld (de),a
        ld hl,lb
        call strlen
        ld a,c
        ld (.c),a
        ld de,#0100
        ld a,(sw)
        ld b,a
        call tx_text
        ld a,(n_sel)            ; its date (long)
        call it_ptr
        inc hl
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ex de,hl
        ld a,h
        or l
        jr z,.raw
        call to_local
        ld a,1
        call fmt_date
        jr .dt
.raw:   ld a,(n_sel)
        ld c,'D'
        ld de,fmt_buf
        ld b,24
        call it_get
.dt:    ld hl,fmt_buf
        ld a,(sw)
        cp 80
        ld e,56
        jr z,.dp
        ld a,(.c)
        ld e,a
.dp:    ld d,1
        ld a,(sw)
        sub e
        ld b,a
        call tx_text
        ld de,#0100
        ld a,(sw)
        ld b,a
        call tx_bar
        ld a,(n_sel)            ; the title, 2 lines
        ld c,'T'
        ld de,tbuf
        ld b,160
        call it_get
        ld hl,tbuf
        ld d,2
        ld b,2
        call wrap_ram
        ld d,4
        call tx_hline
        jp nw_stext
.c:     equ sc_col
        VAR sc_col, 1

; s_index: the index of what is shown (the summary, or the article as far as it is in)
s_index:
        xor a
        ld (s_flags),a
        ld a,(a_story)          ; the article of this story?
        ld hl,n_sel
        cp (hl)
        jp nz,.sum
        ld a,(n_which)
        or a
        jr z,.sum
        ld a,(a_st)
        ld (s_ast),a
        cp NS_LOAD
        jr nz,.n1
        ld a,1
        ld (s_flags),a
        ld hl,(w_len)           ; (nothing in yet: the summary)
        ld a,h
        or l
        jr z,.sum2
        jr .art
.n1:    cp NS_DONE
        jr z,.art
        cp NS_FAILED
        jr nz,.sum
        ld a,4
        ld (s_flags),a
        jr .sum
.art:   call w_flush
        ld a,(s_flags)
        or 2
        ld (s_flags),a
        ld a,(ix_src)
        cp 2
        jr nz,.ar
        ld a,(ix_gen)
        ld hl,a_gen
        cp (hl)
        jr nz,.ar
        ld hl,(w_len)
        ld de,(ix_pos)
        or a
        sbc hl,de
        jr nc,.go
.ar:    ld hl,(art_base)
        ld bc,0
        call ix_reset
        ld a,2
        ld (ix_src),a
        ld a,(a_gen)
        ld (ix_gen),a
.go:    ld hl,(w_len)
        ld (ix_len),hl
        ld (s_alen),hl
        ld a,(s_flags)          ; loading: the paragraphs that are complete
        and 1
        jr z,.all
        ld hl,(w_lastnl)
.all:   jp ix_run
.sum2:  ld a,1
        ld (s_flags),a
.sum:   ld a,(ix_src)
        cp 1
        jr nz,.sr
        ld a,(ix_story)
        ld hl,n_sel
        cp (hl)
        ret z
.sr:    ld a,(n_sel)
        jp ix_summary

; the text: l_ns lines from s_top
nw_stext:
        call s_index
        ld hl,(ix_n)
        ld (s_total),hl
        ld hl,(s_top)
        ld d,5
        ld a,(l_ns)
        ld b,a
.l:     push bc
        push de
        push hl
        call ix_show
        pop hl
        pop de
        pop bc
        inc hl
        inc d
        djnz .l
        ; fall through
; the bar under the text: what it is, the lines shown
nw_status:
        ld de,lb
        ld a,(sw)               ; (short words in 40 columns)
        cp 80
        ld a,0
        jr z,.w
        ld a,4
.w:     ld c,a
        ld a,(s_flags)
        ld b,0
        bit 0,a
        jr nz,.ld
        inc b
        bit 1,a
        jr nz,.s
        inc b
        bit 2,a
        jr nz,.s
        inc b
.s:     ld a,b
        add a,c
        ld hl,txt_sts
        call nth
        call strcpy
        jr .r
.ld:    ld a,c
        ld hl,txt_sts
        call nth
        call strcpy
        call put_kb
.r:     xor a
        ld (de),a
        ld hl,lb
        ld a,(l_st)
        ld d,a
        ld e,0
        ld a,(sw)
        sub 18
        ld b,a
        call tx_text
        ld de,lb                ; "lines 1-18 of 26"
        ld hl,(s_total)
        ld a,h
        or l
        jr z,.e
        ld hl,(s_top)
        inc hl
        call fmt_u16
        ld a,'-'
        call putc
        ld hl,(s_top)
        ld a,(l_ns)
        call add_hla
        ld bc,(s_total)
        push hl
        or a
        sbc hl,bc
        pop hl
        jr c,.l
        ld hl,(s_total)
.l:     call fmt_u16
        ld a,'/'
        call putc
        ld hl,(s_total)
        call fmt_u16
.e:     xor a
        ld (de),a
        ld hl,lb
        ld a,(l_st)
        ld d,a
        ld a,(sw)
        sub 18
        ld e,a
        ld b,18
        call tx_text
        ld a,(l_st)
        ld d,a
        ld e,0
        ld a,(sw)
        ld b,a
        jp tx_bar

; nw_scroll: HL = the new first line (kept within the text)
nw_scroll:
        bit 7,h
        jr z,.p
        ld hl,0
.p:     push hl
        ld hl,(s_total)         ; at most total - rows (0 when shorter)
        ld a,(l_ns)
        ld c,a
        ld b,0
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
.s:     ld de,(s_top)
        or a
        push hl
        sbc hl,de
        pop hl
        ret z
        ld (s_top),hl
        jp nw_stext

;------------------------------------------------------------------------------
; My feeds, and the catalogue: topics, a topic's feeds
nw_feeds:
        ld a,V_FEEDS
        ld (v_view),a
        xor a
        ld (pane),a
        ld (tsel),a
        ld a,#FF
        ld (topic),a
        ld a,(fsel)
        ld hl,nf
        cp (hl)
        jr c,nw_feeds2
        xor a
        ld (fsel),a
nw_feeds2:
        call tx_cls
        call row0
        call nw_keyline
        ld a,(l_k1)
        dec a
        ld d,a
        call tx_hline
        ld a,(l_nf)             ; the line between the two sides
        inc a
        ld b,a
        ld d,2
.v:     push bc
        push de
        ld a,(sw)
        srl a
        dec a
        ld e,a
        ld b,1
        ld a,TX_VL
        call tx_fill
        pop de
        pop bc
        inc d
        djnz .v
        call nw_fleft
        jp nw_fright

pw_get: ld a,(sw)               ; A = half the width
        srl a
        ret

nw_fleft:                       ; My feeds
        ld de,lb
        ld hl,txt_my
        call strcpy
        ld a,(nf)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_of20
        call strcpy
        ld hl,lb
        ld de,#0100
        call pw_get
        dec a
        ld b,a
        call tx_text
        ld c,0
        ld d,3
.r:     push bc
        push de
        ld a,c
        ld hl,nf
        cp (hl)
        ld hl,txt_empty
        jr nc,.t
        ld a,c                  ; " 1 BBC News, World"
        inc a
        ld l,a
        ld h,0
        ld de,lb
        cp 10
        jr nc,.w
        ld a,' '
        call putc
.w:     call fmt_u16
        ld a,' '
        call putc
        ld a,c
        push de
        call nw_name
        pop de
        call strcpy
        ld hl,lb
.t:     pop de
        push de
        ld e,1
        call pw_get
        sub 3
        ld b,a
        call tx_text
        pop de
        pop bc
        inc d
        inc c
        ld a,(l_nf)
        cp c
        jr nz,.r
        jp nw_fbars

nw_fright:                      ; the topics, or a topic's feeds
        ld a,(topic)
        inc a
        jr nz,.cat
        ld a,CAT_NTOPICS
        ld (rn),a
        ld hl,txt_topics
        jr .h
.cat:   dec a
        call cat_count
        ld (rn),a
        ld de,lb
        ld hl,txt_add
        call strcpy
        ld a,(topic)
        call cat_tname
        call strcpy
        ld hl,lb
.h:     ld a,(rn)
        ld b,a
        ld a,(l_nf)
        cp b
        jr nc,.n
        ld (rn),a
.n:     push hl
        call pw_get
        ld e,a
        ld d,1
        ld b,a
        pop hl
        call tx_text
        ld c,0
        ld d,3
.r:     push bc
        push de
        ld a,(rn)
        cp c
        jr z,.e
        jr c,.e
        ld a,(topic)
        inc a
        jr nz,.f
        ld a,c                  ; a topic
        call cat_tname
        jr .x
.f:     dec a                   ; a feed: "*Name" (in My feeds) or " Name"
        call cat_nth
        push hl
        call fv_has
        ld a,'*'
        jr z,.in
        ld a,' '
.in:    ld de,lb
        call putc
        pop hl
        inc hl
        call skipz
        call strcpy
        ld hl,lb
.x:     pop de
        push de
        call pw_get
        inc a
        ld e,a
        call pw_get
        sub 2
        ld b,a
        call tx_text
        jr .y
.e:     pop de
        push de
        call pw_get
        inc a
        ld e,a
        call pw_get
        sub 2
        ld b,a
        ld a,' '
        call tx_fill
.y:     pop de
        pop bc
        inc d
        inc c
        ld a,(l_nf)
        cp c
        jr nz,.r
        ld a,(sw)               ; 80 columns: the credits at the bottom right
        cp 80
        call z,credits
        ; fall through
; the bars: the headings, the chosen line of the side in use ('>' on the other)
nw_fbars:
        ld de,#0100
        ld a,(sw)
        ld b,a
        call tx_bar
        ld a,(l_nf)             ; (no markers)
        ld b,a
        ld d,3
.c:     push bc
        push de
        ld e,0
        ld b,1
        ld a,' '
        call tx_fill
        pop de
        push de
        call pw_get
        ld e,a
        ld b,1
        ld a,' '
        call tx_fill
        pop de
        pop bc
        inc d
        djnz .c
        ld a,(fsel)
        add a,3
        ld d,a
        ld e,0
        ld a,(pane)
        or a
        ld a,' '
        jr z,.l
        ld a,(nf)
        or a
        ld a,'>'
        jr nz,.l
        ld a,' '
.l:     ld b,1
        call tx_fill
        ld a,(tsel)
        add a,3
        ld d,a
        call pw_get
        ld e,a
        ld a,(pane)
        or a
        ld a,' '
        jr nz,.r
        ld a,(rn)
        or a
        ld a,'>'
        jr nz,.r
        ld a,' '
.r:     ld b,1
        call tx_fill
        ld a,(l_nf)             ; the rows' bars
        ld b,a
        ld d,3
.b:     push bc
        push de
        ld a,d
        sub 3
        ld c,a
        ld b,0
        ld a,(pane)
        or a
        jr nz,.rp
        ld a,(nf)
        or a
        jr z,.o
        ld a,(fsel)
        cp c
        jr nz,.o
        ld e,0
        call pw_get
        dec a
        ld b,a
        jr .o
.rp:    ld a,(rn)
        or a
        jr z,.o
        ld a,(tsel)
        cp c
        jr nz,.o
        call pw_get
        ld e,a
        ld b,a
.o:     call tx_bar
        pop de
        pop bc
        inc d
        djnz .b
        ret

; the feeds' keys
nw_fkeys:
        cp '1'                  ; 1-9: a feed of My feeds
        jr c,.nd
        cp '9'+1
        jr nc,.nd
        sub '1'
        ld hl,nf
        cp (hl)
        ret nc
        ld c,a
        ld a,(un_type)
        or a
        ld hl,txt_nonet
        jp z,nw_msg
        ld a,c
        jp nw_fetch
.nd:    cp 29
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
.side:  ld a,(pane)
        xor 1
        ld (pane),a
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
.sel:   ld hl,fsel              ; HL = the side's choice, C = its count
        ld a,(nf)
        ld c,a
        ld a,(pane)
        or a
        ret z
        ld hl,tsel
        ld a,(rn)
        ld c,a
        ret
.bs:    ld a,(pane)
        or a
        jp z,nw_fback
        ld a,(topic)
        inc a
        jp z,nw_fback
        ld a,#FF                ; a topic: the topics again
        ld (topic),a
        xor a
        ld (tsel),a
        jp nw_fright
.enter: ld a,(pane)
        or a
        jr nz,.er
        ld a,(nf)               ; read the feed
        or a
        ret z
        ld a,(un_type)
        or a
        ld hl,txt_nonet
        jp z,nw_msg
        ld a,(fsel)
        jp nw_fetch
.er:    ld a,(rn)
        or a
        ret z
        ld a,(topic)
        inc a
        jr nz,.add
        ld a,(tsel)             ; a topic: its feeds
        ld (topic),a
        xor a
        ld (tsel),a
        jp nw_fright
.add:   ld a,(tsel)             ; a feed: to My feeds
        ld c,a
        ld a,(topic)
        call fv_add
        ld hl,txt_there
        cp 1
        jr z,.msg
        ld hl,txt_full
        cp 2
        jr z,.msg
        call ui_favs
        ld a,(nf)
        dec a
        ld (fsel),a
        call nw_fleft
        call nw_fright
        call ini_note
        ld hl,txt_added
.msg:   jp nw_msg
.del:   ld a,(pane)
        or a
        ret nz
        ld a,(nf)
        or a
        ret z
        ld a,(fsel)
        ld c,0
        call fv_edit
        ret c
        call ui_favs
        ld a,(fsel)             ; (the one after it, or the last)
        ld hl,nf
        cp (hl)
        jr c,.d2
        ld a,(hl)
        or a
        jr z,.d2
        dec a
.d2:    ld (fsel),a
        call nw_fleft
        call nw_fright
        call ini_note
        ld hl,txt_removed
        jp nw_msg
.mup:   ld c,#FF
        jr .mv
.mdn:   ld c,1
.mv:    ld a,(pane)
        or a
        ret nz
        ld a,(fsel)
        push bc
        call fv_edit
        pop bc
        ret c
        ld a,(fsel)
        add a,c
        ld (fsel),a
        call ini_note
        jp nw_fleft

; after a change: a word when it could not be saved
ini_note:
        ld a,(ini_st)
        or a
        ret nz
        ld hl,txt_nosave
        jp nw_msg

; out of My feeds: the headlines there are, else the first feed
nw_fback:
        ld a,(n_n)
        or a
        jr z,.f
        ld a,(n_st)
        cp NS_DONE
        jr nz,.f
        ld a,(n_feed)
        ld hl,nf
        cp (hl)
        jr nc,.f
        jp nw_list
.f:     ld a,(nf)
        or a
        ret z
        ld a,(un_type)
        or a
        ret z
        xor a
        jp nw_fetch

;------------------------------------------------------------------------------
ui_key: ld c,a
        ld a,(quitask)          ; "Quit? Y/N"
        or a
        jr z,.nq
        xor a
        ld (quitask),a
        ld (msgon),a
        ld a,c
        and #DF
        cp 'Y'
        jr nz,.no
        ld a,1
        ld (quit),a
        ret
.no:    jp nw_keyline
.nq:    ld a,(msgon)            ; a key: the message goes
        or a
        jr z,.k
        xor a
        ld (msgon),a
        push bc
        call nw_keyline
        pop bc
.k:     ld a,(v_view)
        cp V_INFO
        jr nz,.ni
        ld a,c                  ; the info: Enter, ESC or BS back
        cp 27
        jp z,nw_fback2
        cp 8
        jp z,nw_fback2
        cp 13
        jp z,nw_fback2
        ld b,c
        jp nw_kcommon
.ni:    cp V_FEEDS
        ld a,c
        ld b,c
        jp z,nw_fkeys
        ld a,(v_view)
        cp V_STORY
        ld a,c
        jp z,nw_skeys
        ; the headlines
        cp '1'
        jr c,.nd
        cp '9'+1
        jr nc,.nd
        sub '1'
        ld hl,nf
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
        jp z,ask_quit
        and #DF
        cp 'F'
        jp z,nw_feeds
        cp 'R'
        jr z,.again
        jp nw_kcommon
.again: ld a,(nf)
        or a
        ret z
        ld a,(n_feed)
        ld hl,nf
        cp (hl)
        ret nc
        jp nw_fetch
.list:  ld a,(n_wait)
        or a
        jr nz,.z
        ld a,(n_n)
        or a
        ret
.z:     xor a
        ret
.up:    call .list
        ret z
        ld a,(n_sel)
        or a
        ret z
        dec a
        jp nw_newsel
.down:  call .list
        ret z
        ld a,(n_sel)
        inc a
        ld hl,n_n
        cp (hl)
        ret nc
        jp nw_newsel
.left:  call .list
        ret z
        ld a,(l_nl)
        ld b,a
        ld a,(n_sel)
        sub b
        jr nc,.l
        xor a
.l:     jp nw_newsel
.right: call .list
        ret z
        ld a,(l_nl)
        ld b,a
        ld a,(n_sel)
        add a,b
        ld hl,n_n
        cp (hl)
        jr c,.r
        ld a,(hl)
        dec a
.r:     jp nw_newsel
.enter: call .list
        ret z
        jp nw_story

nw_fback2:                      ; from the info: the headlines (or My feeds)
        ld a,(n_n)
        or a
        jp nz,nw_list
        jp nw_feeds

ask_quit:
        ld hl,txt_quit
        call nw_msg
        ld a,1
        ld (quitask),a
        ret

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
        jp z,.next
        cp 'P'
        jp z,.prev
        jp nw_kcommon
.up:    ld hl,(s_top)
        dec hl
        jp nw_scroll
.down:  ld hl,(s_top)
        inc hl
        jp nw_scroll
.pup:   ld hl,(s_top)
        ld a,(l_ns)
        cpl
        ld e,a
        ld d,#FF
        inc de
        add hl,de
        jp nw_scroll
.pdn:   ld hl,(s_top)
        ld a,(l_ns)
        call add_hla
        jp nw_scroll
.full:  ld a,(n_which)          ; the full article, or back to the summary
        xor 1
        ld (n_which),a
        ld hl,0
        ld (s_top),hl
        ld (s_alen),hl
        or a
        jp z,nw_stext
        ld a,(un_type)
        or a
        ld hl,txt_nonet
        jp z,nw_msg
        ld a,(n_sel)
        call news_full
        jp nw_stext
.next:  ld a,(n_sel)
        inc a
        ld hl,n_n
        cp (hl)
        ret nc
        ld (n_sel),a
        jp nw_story
.prev:  ld a,(n_sel)
        or a
        ret z
        dec a
        ld (n_sel),a
        jp nw_story

; I: the reader's state
nw_infov:
        ld a,V_INFO
        ld (v_view),a
        call tx_cls
        call row0
        ld hl,txt_ihead
        ld de,#0100
        ld a,(sw)
        ld b,a
        call tx_text
        ld de,#0100
        ld a,(sw)
        ld b,a
        call tx_bar
        call nw_keyline
        ld de,lb                ; the network
        ld hl,txt_i_net
        call strcpy
        ld a,(un_type)
        or a
        jr nz,.n1
        ld hl,txt_i_none
        call strcpy
        jr .n2
.n1:    ld hl,un_name
        call strcpy
        ld a,' '
        call putc
        ld a,(un_ver+1)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'.'
        call putc
        ld a,(un_ver)
        ld l,a
        ld h,0
        call fmt_u16
        call put_tls
.n2:    ld d,3
        call .line
        ld de,lb                ; the machine
        ld hl,txt_i_msx
        call strcpy
        ld a,(msxver)
        ld hl,txt_msxs
        call nth
        call strcpy
        ld hl,txt_i_hz
        call strcpy
        ld a,(hz)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_i_hz2
        call strcpy
        xor a
        ld (de),a
        ld d,4
        call .line
        ld de,lb                ; the feed
        ld hl,txt_i_feed
        call strcpy
        ld a,(n_st)
        ld hl,txt_nst
        call nth
        call strcpy
        ld hl,txt_i_st
        call strcpy
        ld a,(nitems)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_i_http
        call strcpy
        ld hl,(h_status)
        call fmt_u16
        ld hl,txt_i_err
        call strcpy
        ld a,(n_err)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'/'
        call putc
        ld a,(net_code)
        ld l,a
        ld h,0
        call fmt_u16
        xor a
        ld (de),a
        ld d,5
        call .line
        ld hl,n_url
        ld d,6
        call .line2
        ld de,lb                ; the memory
        ld hl,txt_i_mem
        call strcpy
        ld hl,(pool_len)
        call fmt_u16
        ld hl,txt_of
        call strcpy
        ld hl,(pool_size)
        call fmt_u16
        ld hl,txt_i_art
        call strcpy
        ld a,(a_st)
        ld hl,txt_nst
        call nth
        call strcpy
        ld hl,txt_i_bytes
        call strcpy
        ld hl,(art_size)
        call fmt_u16
        xor a
        ld (de),a
        ld d,7
        call .line
        ld de,lb                ; RSS.INI, the time zone
        ld hl,txt_i_ini
        call strcpy
        ld a,(ini_st)
        ld hl,txt_inis
        call nth
        call strcpy
        ld hl,txt_i_tz
        call strcpy
        ld hl,(tz_min)
        bit 7,h
        ld a,'+'
        jr z,.tp
        call neg_hl
        ld a,'-'
.tp:    call putc
        call fmt_u16
        ld hl,txt_i_min
        call strcpy
        ld a,(tz_set)
        ld hl,txt_tzs
        call nth
        call strcpy
        xor a
        ld (de),a
        ld d,8
        call .line
        ld hl,txt_i_keys
        ld d,10
        jr .line2
.line:  ld hl,lb
.line2: ld e,1
        ld a,(sw)
        sub 2
        ld b,a
        jp tx_text

; the keys of every view
nw_kcommon:
        ld a,b
        and #DF
        cp 'I'
        jp z,nw_infov
        cp 'Q'
        jp z,ask_quit
        ret

;------------------------------------------------------------------------------
txt_title:  db " MSX RSS reader 1.0",0
txt_sep:    db "   ",TX_VL,"  ",0
txt_tls:    db ", TLS",0
txt_notls:  db ", no TLS (http only)",0
txt_prx:    db ", https by proxy",0
txt_nonet0: db "no TCP/IP UNAPI network",0
txt_look:   db "Looking for the network...",0
txt_credits:db "by JZZY & CLAUDE 2026",0
txt_k80:    db " Enter read  Up/Down choose  Left/Right page  1-9 a feed  F My feeds  R again",0
            db " I info   ESC quit",0
            db " Up/Down scroll  Left/Right page  Enter full article/summary  N/P next/prev",0
            db " ESC the headlines   I info",0
            db " Left/Right side  Enter read/add  D remove  U/J move  BS back",0
            db " ESC the headlines   I info   Q quit",0
            db " ESC, Enter or BS: back",0
            db " Q quit",0
txt_k40:    db " Enter Up/Down Left/Right 1-9 F R",0
            db " F My feeds  I info  ESC quit",0
            db " Up/Down Left/Right Enter N/P",0
            db " Enter: the full article  ESC back",0
            db " Left/Right Enter D U/J BS",0
            db " Enter read/add  ESC back  Q quit",0
            db " ESC back",0
            db " Q quit",0
txt_fetch:  db "Fetching the stories... ",0
txt_kb:     db " KB",0
txt_pct1:   db " (",0
txt_none:   db "No stories in this feed",0
txt_nonet:  db " No TCP/IP UNAPI network (an ESP8266 cartridge, GR8NET, ...)",0
txt_e_head: db "The feed did not come: ",0
txt_errs:   db "?",0
            db "no TCP/IP UNAPI network",0
            db "the name was not found (DNS)",0
            db "no connection",0
            db "no answer in time",0
            db "HTTP ",0
            db "not a URL",0
            db "it needs https, the network has no TLS",0
            db "closed before it answered",0
txt_heads:  db "Headlines ",0
txt_of:     db " of ",0
txt_dots:   db "...",0
txt_story:  db "  ",TX_VL,"  story ",0
txt_sts:    db " Fetching the full article... ",0
            db " The full article",0
            db " No full article from the site: the summary",0
            db " Summary  (Enter: the full article)",0
            db " Fetching...",0
            db " The full article",0
            db " No article: summary",0
            db " Summary (Enter: all)",0
txt_my:     db " My feeds: ",0
txt_of20:   db " of 20",0
txt_empty:  db 0
txt_topics: db " Add a feed: a topic",0
txt_add:    db " Add: ",0
txt_added:  db " Added to My feeds",0
txt_there:  db " That one is in My feeds already",0
txt_full:   db " My feeds is full (20 feeds)",0
txt_removed:db " Removed from My feeds",0
txt_nosave: db " (Not saved: no disk for RSS.INI)",0
txt_quit:   db " Quit the RSS reader?  Y / N",0
txt_ihead:  db " The reader",0
txt_i_net:  db "Network: ",0
txt_i_none: db "no TCP/IP UNAPI implementation found",0
txt_i_msx:  db "Machine: ",0
txt_msxs:   db "MSX1, 40 columns",0,"MSX2, 80 columns",0,"MSX2+, 80 columns",0,"MSX turbo R, 80 columns",0,"MSX",0
txt_i_hz:   db ", ",0
txt_i_hz2:  db " Hz",0
txt_i_feed: db "Feed: ",0
txt_nst:    db "idle",0,"loading",0,"in",0,"failed",0
txt_i_st:   db ", stories ",0
txt_i_http: db ", HTTP ",0
txt_i_err:  db ", error ",0
txt_i_mem:  db "VRAM: stories ",0
txt_i_art:  db ", article ",0
txt_i_bytes:db ", room ",0
txt_i_ini:  db "RSS.INI: ",0
txt_inis:   db "no disk",0,"not there yet",0,"read",0
txt_i_tz:   db ", local time UTC",0
txt_i_min:  db " min",0
txt_tzs:    db " (not known)",0," (RSS.INI tz=)",0," (the MSX clock)",0
txt_i_keys: db "Errors: 1 no network, 2 DNS, 3 connection, 4 time, 5 HTTP, 6 URL, 7 TLS, 8 closed",0
