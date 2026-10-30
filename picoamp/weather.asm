;==============================================================================
; weather.asm - PICOAMP's weather page, a page module (see clock.asm).
;
; The weather now (a big picture that moves: the sun's rays turn, clouds
; drift, rain and snow fall as sprites, lightning flashes) with the
; temperature, how it feels, the humidity and the wind; then the next days
; in columns: the day, a small picture, the highest and lowest temperature,
; the chance of rain. From the engine (engine 0.12: WX_GET, Open-Meteo).
; Keys: C clock, T news, W, Z, ESC, Enter, BS back; the playback keys.
;==============================================================================

WX_N     equ 10 + 6*9           ; the WX_GET reply
; pictures
K_SUN    equ 0
K_PART   equ 1
K_CLOUD  equ 2
K_FOG    equ 3
K_DRIZ   equ 4
K_RAIN   equ 5
K_SNOW   equ 6
K_THUN   equ 7
K_MOON   equ 8
K_MOONP  equ 9
; the three layers of a picture (back: sun, moon, lightning; cloud; rain, snow, fog)
WL0      equ vizbuf
WL1      equ vizbuf + 512
WL2      equ vizbuf + 1024
G_THUN   equ GREY_D                 ; the thunder cloud (it flashes)

mod_wx:
        jp wx_open              ; the jump table (M_OPEN ...)
        jp wx_tick
        jp wx_ret
        jp wx_keys
        jp wx_info
        jp wx_ret
        jp wx_leave

;------------------------------------------------------------------------------
wx_open:
        call cls
        call setpal
        ld a,WHITE*16+NAVY
        ld (dig_col),a
        ld a,#FF
        ld (wx_gen),a           ; (the weather comes with the first pass)
        ld (wx_smin),a
        call wx_info
        ld hl,txt_wx_keys
        ld de,#1700
        ld b,32
        ld c,GREY*16+NAVY
        call text6s
        ld hl,txt_wx_src
        ld de,#1500
        ld b,32
        ld c,GREY*16+NAVY
        call wx_ctext
        ld de,#0B00             ; a line between now and the days
        ld b,32
.l:     push bc
        ld ix,pat_hline
        ld a,BLUE*16+NAVY
        call put_cell
        inc e
        pop bc
        djnz .l
        ld hl,#3810             ; sprite patterns 2 (a drop) and 3 (a flake)
        call vwrite
        ld hl,wx_sprpat
        ld b,16
        ld c,VDP_D
        otir
        ei
        ld a,(eng_minor)
        cp 12
        ret nc
        ld hl,txt_wx_old
        ld de,#0600
        ld b,32
        ld c,RED*16+NAVY
        jp wx_ctext
wx_ret: ret

wx_leave:
        ld a,216
        ld (spr_next),a
        ld hl,#1E08
        call vwrite
        ld a,216
        out (VDP_D),a
        ei
        ret

; row 0: what plays
wx_info:  jp pg_row0             ; row 0: what plays

wx_keys:
        cp 27
        jp z,fs_close
        cp 13
        jp z,fs_close
        cp 8
        jp z,fs_close
        and #DF
        cp 'W'
        jp z,fs_close
        cp 'Z'
        jp z,fs_close
        cp 'C'
        ld c,PG_CLOCK
        jp z,pg_enter
        cp 'T'
        ld c,PG_NEWS
        jp z,pg_enter
        cp 'G'
        ret z
        cp 'V'
        ret z
        ld a,b
        jp keys_common

;------------------------------------------------------------------------------
wx_tick:
        ld a,(eng_minor)
        cp 12
        ret c
        ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz
        ld a,(ckb+CK_GEN)       ; new weather (or a new place)
        ld hl,wx_gen
        cp (hl)
        jr z,.t
        ld (hl),a
        call wx_load
.t:     ld a,(ckb+CK_FLAGS)     ; the date and time (each minute)
        and CKF_TIME
        jr z,.a
        ld a,(ckb+CK_SEC+1)
        ld hl,wx_smin
        cp (hl)
        jr z,.a
        ld (hl),a
        call wx_timeline
.a:     ld hl,(JIFFY)           ; the picture: a step every 6 interrupts
        ld de,(wx_jt)
        or a
        sbc hl,de
        ld a,h
        or a
        jr nz,.go
        ld a,l
        cp 6
        ret c
.go:    ld hl,(JIFFY)
        ld (wx_jt),hl
        ld a,(wx_have)
        or a
        ret z
        jp wx_anim

wx_load:
        ld a,C_CKINFO
        call cmd0
        jr c,.w
        jr nz,.w
        ld hl,reply
        ld de,wx_place
        ld bc,40
        call strncpy0
.w:     ld hl,txt_wx_in         ; row 1: the place
        ld de,linebuf
        call strcpy
        ld hl,wx_place
        call strcpy
        ld hl,linebuf
        ld de,#0100
        ld b,32
        ld c,YELLOW*16+NAVY
        call text6s
        ld a,C_WXGET
        call cmd0
        ret c
        jr nz,.none
        ld hl,reply
        ld de,wxb
        ld bc,WX_N
        ldir
        ld a,1
        ld (wx_have),a
        call wx_now
        call wx_days
        ld a,(wxb+7)            ; the big picture
        ld c,a
        ld a,(wxb+1)
        ld b,a
        ld a,c
        call wx_kind
        ld (wx_bk),a
        call wx_setkind
        jp wx_big
.none:  ld hl,txt_wx_wait
        ld de,#0500
        ld b,32
        ld c,WHITE*16+NAVY
        jp wx_ctext

; row 8 beside the picture: "Thursday 29 October  21:15"
wx_timeline:
        ld de,linebuf
        ld a,(ckb+CK_SEC+3)     ; the weekday
        cp 7
        jr c,.w
        xor a
.w:     ld hl,wx_days_l
        call wx_nth
        call strcpy
        ld a,' '
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+4)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,' '
        ld (de),a
        inc de
        ld a,(ckb+CK_SEC+5)
        dec a
        cp 12
        jr c,.m
        xor a
.m:     ld hl,wx_months
        call wx_nth
        call strcpy
        ld hl,txt_wx_sp2
        call strcpy
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
        ld de,#080A
        ld b,22
        ld c,CYAN*16+NAVY
        jp text6s

; wx_nth: HL = strings, A = index -> HL = that one
wx_nth: or a
        ret z
        ld b,a
.s:     ld a,(hl)
        inc hl
        or a
        jr nz,.s
        djnz .s
        ret

;------------------------------------------------------------------------------
; now: the temperature in big digits, the word, feels, humidity, wind
wx_now:
        ld d,3                  ; clear the digits' place
.c:     push de
        ld e,10
        ld b,7
        ld c,NAVY*16+NAVY
        call fill_row
        pop de
        inc d
        ld a,d
        cp 6
        jr c,.c
        ld hl,(wxb+2)
        call wx_round           ; HL = degrees, CF = below 0
        ld e,10
        jr nc,.p
        push hl
        ld de,#040A
        ld ix,wx_minus
        ld a,WHITE*16+NAVY
        call put_cell
        pop hl
        ld e,11
.p:     ld a,l
        cp 100
        jr c,.p2
        ld a,99
.p2:    ld d,3
        cp 10
        jr c,.one
        push de
        call two_digits
        ld a,d
        ld b,e
        pop de
        push bc
        push de
        call put_digit
        pop de
        pop bc
        inc e
        inc e
        ld a,b
.one:   push de
        call put_digit
        pop de
        inc e
        inc e
        ld d,3                  ; "C" after it
        ld hl,txt_wx_c
        ld b,1
        ld c,WHITE*16+NAVY
        call text6s
        ; the word for it
        ld a,(wxb+7)
        call wx_word
        ld de,#0311
        ld b,15
        ld c,YELLOW*16+NAVY
        call text6s
        ; feels
        ld hl,txt_wx_feels
        ld de,linebuf
        call strcpy
        ld hl,(wxb+4)
        call wx_t1
        ld hl,txt_wx_degc
        call strcpy
        ld hl,linebuf
        ld de,#0411
        ld b,15
        ld c,WHITE*16+NAVY
        call text6s
        ; humidity
        ld hl,txt_wx_hum
        ld de,linebuf
        call strcpy
        ld a,(wxb+6)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'%'
        ld (de),a
        inc de
        xor a
        ld (de),a
        ld hl,linebuf
        ld de,#0511
        ld b,15
        ld c,WHITE*16+NAVY
        call text6s
        ; wind
        ld hl,txt_wx_wind
        ld de,linebuf
        call strcpy
        ld a,(wxb+8)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_wx_kmh
        call strcpy
        ld hl,linebuf
        ld de,#0611
        ld b,15
        ld c,WHITE*16+NAVY
        jp text6s

; wx_round: HL = 0.1 degrees -> HL = whole degrees (rounded), CF = below 0
wx_round:
        bit 7,h
        jr z,.p
        xor a
        sub l
        ld l,a
        sbc a,a
        sub h
        ld h,a
        call .r
        ld a,h
        or l
        ret z                   ; (-0.4: 0, no minus)
        scf
        ret
.p:     call .r
        or a
        ret
.r:     ld de,5
        add hl,de
        ld de,10
        jp div16

; wx_t1: HL = 0.1 degrees -> "-3.5" at DE
wx_t1:  bit 7,h
        jr z,.p
        ld a,'-'
        ld (de),a
        inc de
        xor a
        sub l
        ld l,a
        sbc a,a
        sub h
        ld h,a
.p:     push de
        ld de,10
        call div16
        ld a,e
        pop de
        push af
        call fmt_u16
        ld a,'.'
        ld (de),a
        inc de
        pop af
        add a,'0'
        ld (de),a
        inc de
        xor a
        ld (de),a
        ret

; wx_t0: HL = 0.1 degrees -> "-3" at DE
wx_t0:  push de
        call wx_round
        pop de
        jr nc,.p
        ld a,'-'
        ld (de),a
        inc de
.p:     jp fmt_u16

; wx_word: A = WMO code -> HL = its word
wx_word:
        ld hl,wx_words
.f:     cp (hl)
        jr c,.g
        jr z,.g
        inc hl
.s:     ld b,a
        ld a,(hl)
        inc hl
        or a
        ld a,b
        jr nz,.s
        jr .f
.g:     inc hl
        ret

; wx_kind: A = WMO code, B = 1 by day -> A = the picture
wx_kind:
        ld hl,wx_kinds
.f:     cp (hl)
        jr c,.g
        jr z,.g
        inc hl
        inc hl
        jr .f
.g:     inc hl
        ld a,(hl)
        bit 0,b
        ret nz
        cp K_SUN                ; at night: the moon
        jr nz,.n
        ld a,K_MOON
        ret
.n:     cp K_PART
        ret nz
        ld a,K_MOONP
        ret

;------------------------------------------------------------------------------
; the next days: 6 columns of 5 cells from column 1, rows 12-19
wx_days:
        ld a,(wxb)
        cp 7
        jr c,.n
        ld a,6
.n:     or a
        ret z
        ld b,a                  ; the first column: (33 - 5 n) / 2, in the middle
        add a,a
        add a,a
        add a,b
        neg
        add a,33
        srl a
        ld (wx_col0),a
        ld c,0
.d:     push bc
        ld a,c                  ; the column: first + 5 c
        add a,a
        add a,a
        add a,c
        ld hl,wx_col0
        add a,(hl)
        ld (wx_col),a
        ld l,c                  ; the day's record: wxb + 10 + 9 c
        ld h,0
        ld e,l
        ld d,h
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,de
        ld de,wxb+10
        add hl,de
        ld (wx_dp),hl
        ld a,c                  ; the name
        or a
        ld hl,txt_wx_today
        jr z,.nm
        ld ix,(wx_dp)
        ld a,(ix+0)
        cp 7
        jr c,.w
        xor a
.w:     ld hl,wx_wd
        call wx_nth
.nm:    ld d,12
        ld c,YELLOW*16+NAVY
        call wx_ctext4
        ld ix,(wx_dp)           ; the picture (by day)
        ld a,(ix+2)
        ld b,1
        call wx_kind
        ld (wx_k),a
        ld a,1
        ld (wx_sh),a
        call wx_draw
        ld a,(wx_col)
        ld e,a
        ld d,13
        call wx_out
        ld ix,(wx_dp)           ; the highest
        ld l,(ix+5)
        ld h,(ix+6)
        ld de,linebuf
        call wx_t0
        ld hl,linebuf
        ld d,17
        ld c,ORANGE*16+NAVY
        call wx_ctext4
        ld ix,(wx_dp)           ; the lowest
        ld l,(ix+7)
        ld h,(ix+8)
        ld de,linebuf
        call wx_t0
        ld hl,linebuf
        ld d,18
        ld c,CYAN*16+NAVY
        call wx_ctext4
        ld ix,(wx_dp)           ; the chance of rain
        ld a,(ix+3)
        ld de,linebuf
        xor a
        ld (de),a
        ld a,(ix+3)
        cp #FF
        jr z,.r
        ld l,a
        ld h,0
        call fmt_u16
        ld a,'%'
        ld (de),a
        inc de
        xor a
        ld (de),a
.r:     ld hl,linebuf
        ld d,19
        ld c,GREY_L*16+NAVY
        call wx_ctext4
        pop bc
        inc c
        dec b
        jp nz,.d
        ret

; wx_ctext4: HL = text, D = row, the middle of 4 cells from (wx_col)
wx_ctext4:
        ld a,(wx_col)
        ld e,a
        ld b,4
; wx_ctext: HL = text, DE = cell, B = cells, C = colour: in the middle of them
wx_ctext:
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
.e:     ld a,e                  ; pad = (8 B - 6 n) / 2
        add a,a
        add a,e
        ld e,a                  ; 3 n
        ld a,b
        add a,a
        add a,a                 ; 4 B
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

;------------------------------------------------------------------------------
; a picture: (wx_k) drawn into the three layers, big ((wx_sh) = 0: 64 x 64,
; 8 x 8 cells) or small (1: 32 x 32, 4 x 4 cells). Shapes are given big.
wx_big:
        xor a
        ld (wx_sh),a
        ld a,(wx_bk)
        ld (wx_k),a
        call wx_draw
        ld de,#0201
        jp wx_out

wx_draw:
        ld a,(wx_sh)
        or a
        ld hl,512*3
        ld a,64                 ; the stride of a cell row
        jr z,.s
        ld hl,128*3
        ld a,32
.s:     ld (wx_stride),a
        push hl
        pop bc
        ld hl,vizbuf
        ld (hl),0
        ld d,h
        ld e,l
        inc de
        dec bc
        ldir
        ld a,(wx_sh)
        or a
        ld hl,512
        jr z,.l
        ld hl,128
.l:     ld (wx_lsize),hl
        ld a,(wx_k)
        add a,a
        ld hl,wx_drawtab
        call idx
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp (hl)

wx_drawtab:     dw wd_sun, wd_part, wd_cloud, wd_fog, wd_driz, wd_rain, wd_snow, wd_thun, wd_moon, wd_moonp

wd_sun: ld a,32
        ld c,32
        ld b,13
        call wl_disk0
        ld a,32
        ld c,32
        ld d,17
        ld e,25
        jp wx_rays
wd_moon:
        ld a,30
        ld c,32
        call wx_moon
        ld a,(wx_sh)            ; stars (they twinkle)
        or a
        ret nz
        ld hl,wx_stars
        ld b,5
.s:     push bc
        ld a,(wx_phase)
        add a,b
        and 3
        jr z,.n
        ld a,(hl)
        inc hl
        ld c,(hl)
        dec hl
        push hl
        call wl_star
        pop hl
.n:     inc hl
        inc hl
        pop bc
        djnz .s
        ret
wd_part:
        ld a,22
        ld c,22
        ld b,11
        call wl_disk0
        ld a,22
        ld c,22
        ld d,14
        ld e,20
        call wx_rays
        ld a,38
        jr wx_cloud_low
wd_moonp:
        ld a,22
        ld c,22
        call wx_moon
        ld a,38
wx_cloud_low:
        ld c,40
        jp wx_cloud
wd_cloud:
        ld a,(wx_drift)
        add a,32
        ld c,32
        jp wx_cloud
wd_fog: ld b,4                  ; four lines that drift
        ld c,18
.l:     push bc
        ld a,(wx_phase)
        add a,c
        and 7
        cp 4
        jr c,.u
        neg
        add a,8
.u:     add a,6                 ; x from 6..10
        ld d,a
        add a,44
        ld e,a
        ld b,c
        call wl_hline2
        pop bc
        ld a,c
        add a,10
        ld c,a
        djnz .l
        ret
wd_driz:
        call wx_cloud_high
        ld a,1                  ; small: three dots
        jr wx_marks
wd_rain:
        call wx_cloud_high
        ld a,2                  ; small: three streaks
        jr wx_marks
wd_snow:
        call wx_cloud_high
        ld a,3                  ; small: three flakes
        jr wx_marks
wd_thun:
        call wx_cloud_high
        ld a,(wx_flash)         ; the bolt while it flashes (always when small)
        ld b,a
        ld a,(wx_sh)
        or b
        ret z
        ld hl,wx_bolt
        ld b,3
.b:     push bc
        push hl
        ld a,(hl)
        ld (wn_x0),a
        inc hl
        ld a,(hl)
        ld (wn_y0),a
        inc hl
        ld d,(hl)
        inc hl
        ld e,(hl)
        ld a,0
        call wl_line
        pop hl
        push hl
        ld a,(hl)
        inc a
        ld (wn_x0),a
        inc hl
        ld a,(hl)
        ld (wn_y0),a
        inc hl
        ld a,(hl)
        inc a
        ld d,a
        inc hl
        ld e,(hl)
        ld a,0
        call wl_line
        pop hl
        inc hl
        inc hl
        pop bc
        djnz .b
        ret
wx_cloud_high:
        ld a,32
        ld c,24
        jp wx_cloud

; the small pictures' rain: A = 1 dots, 2 streaks, 3 flakes (big: sprites)
wx_marks:
        ld b,a
        ld a,(wx_sh)
        or a
        ret z
        ld hl,wx_markxy
        ld c,3
.m:     push bc
        push hl
        ld a,(hl)
        inc hl
        ld e,(hl)               ; (big coordinates)
        ld d,a
        ld a,b
        cp 2
        jr z,.st
        cp 3
        jr z,.fl
        ld a,d                  ; a dot
        ld c,e
        ld b,2
        call wl_disk2
        jr .n
.st:    ld a,d                  ; a streak
        ld (wn_x0),a
        ld a,e
        ld (wn_y0),a
        ld a,d
        sub 4
        ld d,a
        ld a,e
        add a,10
        ld e,a
        ld a,2
        call wl_line
        jr .n
.fl:    ld a,d
        ld c,e
        call wl_star
.n:     pop hl
        inc hl
        inc hl
        pop bc
        dec c
        jr nz,.m
        ret

; wx_cloud: A = x, C = y (big): three disks and a flat bottom in layer 1
wx_cloud:
        ld (wc_x),a
        ld a,c
        ld (wc_y),a
        ld a,(wc_x)
        sub 12
        ld b,a
        ld a,(wc_y)
        add a,2
        ld c,a
        ld a,b
        ld b,9
        call wl_disk1
        ld a,(wc_x)
        ld b,a
        ld a,(wc_y)
        sub 4
        ld c,a
        ld a,b
        ld b,12
        call wl_disk1
        ld a,(wc_x)
        add a,12
        ld b,a
        ld a,(wc_y)
        add a,2
        ld c,a
        ld a,b
        ld b,9
        call wl_disk1
        ld a,(wc_y)             ; the bottom: lines y+2 .. y+11
        add a,2
        ld c,a
        ld b,10
.r:     push bc
        ld a,(wc_x)
        sub 12
        ld d,a
        add a,24
        ld e,a
        ld b,c
        ld a,1
        call wl_hline
        pop bc
        inc c
        djnz .r
        ret

; wx_moon: A = x, C = y (big): a crescent in layer 0
wx_moon:
        ld (wc_x),a
        ld a,c
        ld (wc_y),a
        ld a,(wc_x)
        ld b,13
        call wl_disk0
        ld a,1
        ld (wx_erase),a
        ld a,(wc_x)
        add a,7
        ld b,a
        ld a,(wc_y)
        sub 6
        ld c,a
        ld a,b
        ld b,11
        call wl_disk0
        xor a
        ld (wx_erase),a
        ret

; wx_rays: A = x, C = y (centre), D = from, E = to (radius): 12 rays in layer
; 0, turning with (wx_phase)
wx_rays:
        ld (wc_x),a
        ld a,c
        ld (wc_y),a
        ld a,d
        ld (wr_r0),a
        ld a,e
        ld (wr_r1),a
        ld a,(wx_phase)         ; the first ray's angle: phase mod 5
.m5:    cp 5
        jr c,.a
        sub 5
        jr .m5
.a:     ld b,12
.r:     push bc
        push af
        ld e,a
        ld a,(wr_r0)
        call wx_pt              ; D, E = the point
        ld a,d
        ld (wn_x0),a
        ld a,e
        ld (wn_y0),a
        pop af
        push af
        ld e,a
        ld a,(wr_r1)
        call wx_pt
        xor a
        call wl_line
        pop af
        add a,5
        pop bc
        djnz .r
        ret

; wx_pt: E = angle (0-59), A = radius -> D = x, E = y (big, from wc_x, wc_y)
wx_pt:  ld (wp_r),a
        ld a,e
        ld (wp_a),a
        ld hl,wx_sin
        call idx
        ld a,(hl)
        call .mul
        ld b,a
        ld a,(wc_x)
        add a,b
        ld (wp_x),a
        ld a,(wp_a)
        add a,15
        cp 60
        jr c,.c
        sub 60
.c:     ld hl,wx_sin
        call idx
        ld a,(hl)
        call .mul
        neg
        ld b,a
        ld a,(wc_y)
        add a,b
        ld e,a
        ld a,(wp_x)
        ld d,a
        ret
.mul:   ; A (sin * 60, signed) * (wp_r) / 64
        ld e,a
        ld d,0
        bit 7,a
        jr z,.m1
        dec d
.m1:    ld hl,0
        ld a,(wp_r)
        or a
        ret z
        ld b,a
.m2:    add hl,de
        djnz .m2
        add hl,hl               ; / 64: * 4, the high byte
        add hl,hl
        ld a,h
        ret

;------------------------------------------------------------------------------
; drawing in the layers. Coordinates are big (0-63), halved when small; all
; is clipped to the picture.

; layer A's base -> (wl_base)
wl_sel: ld hl,vizbuf
        or a
        jr z,.s
        ld de,(wx_lsize)
.a:     add hl,de
        dec a
        jr nz,.a
.s:     ld (wl_base),hl
        ret

; small pictures: A halved
wl_sc:  push af
        ld a,(wx_sh)
        or a
        jr z,.n
        pop af
        sra a
        ret
.n:     pop af
        ret

wl_disk0:                       ; A = x, C = y, B = radius
        ld e,0
        jr wl_disk
wl_disk1:
        ld e,1
        jr wl_disk
wl_disk2:
        ld e,2
wl_disk:
        push af
        push bc
        ld a,e
        call wl_sel
        pop bc
        pop af
        call wl_sc
        ld (wd_x),a
        ld a,c
        call wl_sc
        ld (wd_y),a
        ld a,b
        call wl_sc
        ld (wd_r),a
        ld e,a                  ; r * r
        ld hl,wx_sq
        ld c,a
        ld b,0
        add hl,bc
        ld a,(hl)
        ld (wd_rr),a
        ld a,(wd_r)
        neg
        ld (wd_dy),a            ; dy = -r .. r
.y:     ld a,(wd_dy)            ; w: the largest with w*w <= r*r - dy*dy
        bit 7,a
        jr z,.ab
        neg
.ab:    ld c,a
        ld b,0
        ld hl,wx_sq
        add hl,bc
        ld a,(wd_rr)
        sub (hl)
        ld c,a                  ; C = r*r - dy*dy
        ld a,(wd_r)
        ld b,a
.w:     ld a,b
        ld hl,wx_sq
        push bc
        ld c,a
        ld b,0
        add hl,bc
        pop bc
        ld a,c
        cp (hl)
        jr nc,.got
        dec b
        jr .w
.got:   ld a,(wd_x)
        sub b
        ld d,a
        ld a,(wd_x)
        add a,b
        ld e,a
        ld a,(wd_y)
        ld hl,wd_dy
        add a,(hl)
        ld b,a
        call wl_span
        ld hl,wd_dy
        ld a,(wd_r)
        cp (hl)
        ret z
        inc (hl)
        jr .y

; wl_hline: A = layer, D = x0, E = x1, B = y (big)
wl_hline2:
        ld a,2
wl_hline:
        push de
        push bc
        call wl_sel
        pop bc
        pop de
        ld a,d
        call wl_sc
        ld d,a
        ld a,e
        call wl_sc
        ld e,a
        ld a,b
        call wl_sc
        ld b,a
        ; fall through

; wl_span: D = x0, E = x1, B = y (picture pixels, may be outside): in (wl_base)
wl_span:
        ld a,(wx_sh)            ; the size: 64 or 32
        or a
        ld c,64
        jr z,.s
        ld c,32
.s:     ld a,b
        cp c
        ret nc                  ; (also y < 0: 128 and up)
        bit 7,d
        jr z,.x0
        ld d,0
.x0:    ld a,e
        bit 7,a
        ret nz                  ; all left of the picture
        cp c
        jr c,.x1
        ld e,c
        dec e
.x1:    ld a,e
        cp d
        ret c
.px:    push de                 ; pixel by pixel (the spans are short)
        push bc
        call wl_px
        pop bc
        pop de
        ld a,d
        cp e
        ret z
        inc d
        jr .px

; wl_px: D = x, B = y (pixels, in the picture): set (or clear) it
wl_px:  ld a,b
        and #F8
        ld l,a
        ld h,0
        ld a,(wx_stride)        ; (y / 8) * stride: 64 -> * 8, 32 -> * 4
        cp 64
        add hl,hl
        add hl,hl
        jr nz,.s
        add hl,hl
.s:     ld a,d
        and #F8
        ld e,a
        ld a,b
        and 7
        or e
        ld e,a
        ld a,d                  ; (x & F8) | (y & 7) fits a byte: x < 64
        ld d,0
        add hl,de
        ld de,(wl_base)
        add hl,de
        and 7
        ld de,bitmask
        add a,e
        ld e,a
        jr nc,.m
        inc d
.m:     ld a,(de)
        ld e,a
        ld a,(wx_erase)
        or a
        ld a,e
        jr nz,.er
        or (hl)
        ld (hl),a
        ret
.er:    cpl
        and (hl)
        ld (hl),a
        ret

; a small star or flake: A = x, C = y (big) in layer 2: a plus
wl_star:
        call wl_sc
        ld (st_x),a
        ld a,c
        call wl_sc
        ld (st_y),a
        ld a,2
        call wl_sel
        ld a,(st_x)
        dec a
        ld d,a
        add a,2
        ld e,a
        ld a,(st_y)
        ld b,a
        call wl_span
        ld a,(st_x)
        ld d,a
        ld e,a
        ld a,(st_y)
        dec a
        ld b,a
        call wl_span
        ld a,(st_x)
        ld d,a
        ld e,a
        ld a,(st_y)
        inc a
        ld b,a
        jp wl_span

; wl_line: A = layer, from (wn_x0, wn_y0) to D, E (big)
wl_line:
        push de
        call wl_sel
        pop de
        ld a,d
        call wl_sc
        ld (wn_tx),a
        ld a,e
        call wl_sc
        ld (wn_ty),a
        ld a,(wn_x0)
        call wl_sc
        ld (wn_x0),a
        ld a,(wn_y0)
        call wl_sc
        ld (wn_y0),a
        ld a,(wn_tx)
        ld hl,wn_x0
        sub (hl)
        ld b,1
        jr nc,.x
        neg
        ld b,#FF
.x:     ld (wn_dx),a
        ld a,b
        ld (wn_sx),a
        ld a,(wn_ty)
        ld hl,wn_y0
        sub (hl)
        ld b,1
        jr nc,.y
        neg
        ld b,#FF
.y:     ld (wn_dy),a
        ld a,b
        ld (wn_sy),a
        ld a,(wn_dx)
        ld l,a
        ld h,0
        ld a,(wn_dy)
        ld e,a
        ld d,0
        or a
        sbc hl,de
        ld (wn_err),hl
.lp:    ld a,(wn_x0)
        ld d,a
        ld a,(wn_y0)
        ld b,a
        ld e,d
        call wl_span            ; (one pixel, clipped)
        ld a,(wn_x0)
        ld hl,wn_tx
        cp (hl)
        jr nz,.go
        ld a,(wn_y0)
        ld hl,wn_ty
        cp (hl)
        ret z
.go:    ld hl,(wn_err)
        add hl,hl
        push hl
        ld a,(wn_dy)
        ld e,a
        ld d,0
        add hl,de
        bit 7,h
        jr nz,.n1
        ld a,h
        or l
        jr z,.n1
        ld hl,(wn_err)
        or a
        sbc hl,de
        ld (wn_err),hl
        ld a,(wn_sx)
        ld hl,wn_x0
        add a,(hl)
        ld (hl),a
.n1:    pop hl
        ld a,(wn_dx)
        ld e,a
        ld d,0
        or a
        sbc hl,de
        bit 7,h
        jr z,.lp
        ld hl,(wn_err)
        add hl,de
        ld (wn_err),hl
        ld a,(wn_sy)
        ld hl,wn_y0
        add a,(hl)
        ld (hl),a
        jr .lp

;------------------------------------------------------------------------------
; out: the picture's cells at D = row, E = column; per cell line the cloud
; wins, then the rain, then the sun (two colours a cell line)
wx_out:
        ld a,(wx_k)
        ld l,a
        ld h,0
        add hl,hl
        ld c,a
        ld b,0
        add hl,bc               ; * 3: the colours of the layers
        ld bc,wx_cols
        add hl,bc
        ld a,(hl)
        ld (wo_c0),a
        inc hl
        ld a,(hl)
        ld (wo_c1),a
        inc hl
        ld a,(hl)
        ld (wo_c2),a
        ld a,(wx_sh)
        or a
        ld a,8
        jr z,.n
        ld a,4
.n:     ld (wo_n),a
        ld hl,vizbuf
        ld (wo_p),hl
        ld a,(wo_n)
        ld b,a
.r:     push bc
        push de
        ld a,(wo_n)
        ld b,a
.c:     push bc
        push de
        ld hl,(wo_p)
        ld ix,cellpat
        ld iy,cellclr
        ld b,8
.l:     push bc
        ld de,(wx_lsize)
        push hl
        add hl,de
        ld a,(hl)               ; the cloud
        ld c,a
        add hl,de
        ld b,(hl)               ; the rain
        pop hl
        ld a,c
        or a
        ld a,(wo_c1)
        jr nz,.w
        ld a,b
        or a
        ld c,b
        ld a,(wo_c2)
        jr nz,.w
        ld c,(hl)               ; the sun
        ld a,(wo_c0)
.w:     ld (ix+0),c
        add a,a
        add a,a
        add a,a
        add a,a
        or NAVY
        ld (iy+0),a
        inc ix
        inc iy
        inc hl
        pop bc
        djnz .l
        ld (wo_p),hl            ; (the next cell)
        pop de
        push de
        ld ix,cellpat
        ld iy,cellclr
        call put_cell2
        pop de
        inc e
        pop bc
        djnz .c
        pop de
        inc d
        pop bc
        djnz .r
        ret

;------------------------------------------------------------------------------
; the big picture moves: a step every 6 interrupts
wx_setkind:
        ld a,216                ; no rain sprites (yet)
        ld (spr_next),a
        ld hl,#1E08
        call vwrite
        ld a,216
        out (VDP_D),a
        ei
        xor a
        ld (wx_flash),a
        ld a,(wx_bk)            ; the thunder cloud's colour: dark grey
        cp K_THUN
        jr nz,.r
        ld de,#3403
        call wx_palg
.r:     ld a,(wx_bk)            ; rain and snow: the sprites' colours, places
        cp K_DRIZ
        ret c
        cp K_MOON
        ret nc
        ld e,CYAN
        cp K_SNOW
        jr nz,.c
        ld e,WHITE
.c:     ld hl,#1C20
        call vwrite
        ld b,96
        ld a,e
.cc:    out (VDP_D),a
        djnz .cc
        ei
        ld a,(ms_port)          ; no mouse: sprites 0 and 1 off the screen (not
        or a                    ; the end of the list)
        jr nz,.m
        ld hl,#1E00
        call vwrite
        ld hl,wx_offspr
        ld b,8
        ld c,VDP_D
        otir
        ei
.m:     ld hl,wx_drops
        ld b,6
.d:     call wx_rnd
        and 31
        add a,16
        ld (hl),a
        inc hl
        call wx_rnd
        and 31
        add a,30
        ld (hl),a
        inc hl
        djnz .d
        ret

wx_palg:                        ; the thunder cloud's palette entry = D (0RRR0BBB), E (G)
        ld a,G_THUN
        di
        out (VDP_C),a
        ld a,16+128
        out (VDP_C),a
        ld a,d
        out (VDP_P),a
        ld a,e
        out (VDP_P),a
        ei
        ret

wx_rnd: ld a,(wx_seed)          ; a byte of an LFSR
        ld c,a
        add a,a
        jr nc,.n
        xor #1D
.n:     ld (wx_seed),a
        xor c
        ret

wx_anim:
        ld hl,wx_phase
        inc (hl)
        ld a,(wx_bk)
        cp K_DRIZ
        jr c,.redraw            ; sun, part, cloud, fog: drawn again
        cp K_MOON
        jr nc,.moon
        ; rain, snow, thunder: the sprites fall
        cp K_THUN
        call z,wx_thunder
        jp wx_fall
.moon:  ld a,(wx_phase)         ; the stars twinkle: now and then
        and 3
        ret nz
.redraw:
        ld a,(wx_bk)            ; clouds drift: -2 .. +2
        cp K_CLOUD
        jr nz,.r
        ld a,(wx_phase)
        rrca
        rrca
        and 7
        cp 4
        jr c,.d
        neg
        add a,8
.d:     sub 2
        ld (wx_drift),a
.r:     jp wx_big

; thunder: a flash about every 3 seconds, 2 steps long
wx_thunder:
        ld a,(wx_flash)
        or a
        jr z,.w
        dec a
        ld (wx_flash),a
        ret nz
        ld de,#3403             ; dark again, the bolt gone
        call wx_palg
        jp wx_big
.w:     call wx_rnd
        cp 20
        ret nc
        ld a,2
        ld (wx_flash),a
        ld de,#7707             ; white, the bolt
        call wx_palg
        jp wx_big

; rain and snow: 6 sprites under the cloud (x 16-47, y 34-62 of the picture)
wx_fall:
        ld a,(wx_bk)
        ld c,3                  ; rain falls 3 a step, drizzle 2, snow 1
        cp K_DRIZ
        jr nz,.s1
        ld c,2
.s1:    cp K_SNOW
        jr nz,.s2
        ld c,1
.s2:    ld hl,wx_drops
        ld ix,wx_sprbuf
        ld b,6
.d:     ld a,(hl)               ; x
        ld d,a
        inc hl
        ld a,(hl)               ; y
        add a,c
        cp 62
        jr c,.k
        push hl
        push bc
        call wx_rnd
        and 31
        add a,16
        pop bc
        pop hl
        dec hl
        ld (hl),a
        ld d,a
        inc hl
        ld a,34
.k:     ld (hl),a
        inc hl
        ld e,a
        ld a,(wx_bk)            ; snow sways
        cp K_SNOW
        jr nz,.p
        ld a,(wx_phase)
        add a,b
        and 4
        rrca
        rrca
        add a,d
        ld d,a
.p:     ld a,e                  ; screen: rows 2-9 (y 16), columns 1-8 (x 8)
        add a,16-1
        ld (ix+0),a
        ld a,d
        add a,8
        ld (ix+1),a
        ld a,(wx_bk)
        cp K_SNOW
        ld a,2
        jr nz,.pt
        inc a
.pt:    ld (ix+2),a
        ld (ix+3),0
        inc ix
        inc ix
        inc ix
        inc ix
        djnz .d
        ld (ix+0),216
        ld a,(wx_sprbuf)
        ld (spr_next),a
        ld hl,#1E08
        call vwrite
        ld hl,wx_sprbuf
        ld b,25
        ld c,VDP_D
        otir
        ei
        ret

;------------------------------------------------------------------------------
; data
txt_wx_keys:    db "C clock  T news  W or ESC back",0
txt_wx_src:     db "Weather: Open-Meteo.com",0
txt_wx_old:     db "The weather needs engine 0.12 or newer",0
txt_wx_wait:    db "Waiting for the weather (it needs WiFi)",0
txt_wx_in:      db "Weather in ",0
txt_wx_c:       db "C",0
txt_wx_degc:    db " C",0
txt_wx_feels:   db "Feels ",0
txt_wx_hum:     db "Humidity ",0
txt_wx_wind:    db "Wind ",0
txt_wx_kmh:     db " km/h",0
txt_wx_sp2:     db "  ",0
txt_wx_today:   db "Today",0
wx_wd:          db "Mon",0,"Tue",0,"Wed",0,"Thu",0,"Fri",0,"Sat",0,"Sun",0
wx_days_l:      db "Monday",0,"Tuesday",0,"Wednesday",0,"Thursday",0,"Friday",0,"Saturday",0,"Sunday",0
wx_months:      db "January",0,"February",0,"March",0,"April",0,"May",0,"June",0,"July",0
                db "August",0,"September",0,"October",0,"November",0,"December",0
wx_words:       db 0,"Clear",0, 1,"Mainly clear",0, 2,"Partly cloudy",0, 3,"Overcast",0
                db 48,"Fog",0, 57,"Drizzle",0, 67,"Rain",0, 77,"Snow",0, 82,"Showers",0
                db 86,"Snow showers",0, 255,"Thunderstorm",0
wx_kinds:       db 0,K_SUN, 2,K_PART, 3,K_CLOUD, 48,K_FOG, 57,K_DRIZ, 67,K_RAIN, 77,K_SNOW
                db 82,K_RAIN, 86,K_SNOW, 99,K_THUN, 255,K_CLOUD
; the layers' colours per picture: back, cloud, rain
wx_cols:        db YELLOW,WHITE,CYAN, YELLOW,WHITE,CYAN, YELLOW,GREY_L,CYAN, YELLOW,WHITE,GREY_L
                db YELLOW,GREY_L,CYAN, YELLOW,GREY,CYAN, YELLOW,GREY_L,WHITE, YELLOW,G_THUN,CYAN
                db GREY_L,WHITE,WHITE, GREY_L,WHITE,WHITE
wx_sq:          db 0,1,4,9,16,25,36,49,64,81,100,121,144,169,196,225
wx_sin:         db 0,6,12,19,24,30,35,40,45,49,52,55,57,59,60,60,60,59,57,55,52,49,45,40,35,30,24,19,12,6
                db 0,-6,-12,-19,-24,-30,-35,-40,-45,-49,-52,-55,-57,-59,-60,-60,-60,-59,-57,-55,-52,-49,-45,-40,-35,-30,-24,-19,-12,-6
wx_stars:       db 8,10, 54,8, 56,44, 10,50, 46,56
wx_markxy:      db 18,46, 32,50, 46,46
wx_bolt:        db 34,38,28,48, 28,48,36,48, 36,48,30,60
wx_minus:       db 0,0,0,#7E,#7E,0,0,0
wx_offspr:      db 200,0,0,0, 200,0,0,0
wx_sprpat:      db #80,#80,#80,#80,0,0,0,0, #40,#E0,#40,0,0,0,0,0
; state
wx_gen:         db #FF
wx_smin:        db #FF
wx_have:        db 0
wx_jt:          dw 0
wx_bk:          db 0
wx_k:           db 0
wx_sh:          db 0
wx_stride:      db 64
wx_lsize:       dw 512
wx_phase:       db 0
wx_drift:       db 0
wx_flash:       db 0
wx_erase:       db 0
wx_seed:        db #5A
wx_col:         db 0
wx_col0:        db 1
wx_dp:          dw 0
wl_base:        dw vizbuf
wc_x:           db 0
wc_y:           db 0
wr_r0:          db 0
wr_r1:          db 0
wp_r:           db 0
wp_a:           db 0
wp_x:           db 0
wd_x:           db 0
wd_y:           db 0
wd_r:           db 0
wd_rr:          db 0
wd_dy:          db 0
st_x:           db 0
st_y:           db 0
wn_x0:          db 0
wn_y0:          db 0
wn_tx:          db 0
wn_ty:          db 0
wn_dx:          db 0
wn_dy:          db 0
wn_sx:          db 0
wn_sy:          db 0
wn_err:         dw 0
wo_c0:          db 0
wo_c1:          db 0
wo_c2:          db 0
wo_n:           db 0
wo_p:           dw 0
wx_drops:       ds 12,0
wx_sprbuf:      ds 25,0
wx_place:       db "?",0
                ds 40,0
wxb:            ds WX_N,0
mod_wx_end:
