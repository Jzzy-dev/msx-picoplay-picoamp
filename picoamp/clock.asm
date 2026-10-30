;==============================================================================
; clock.asm - PICOAMP's clock page, a page module.
;
; Assembled with picoamp.asm at MODBASE (the ticker strips' buffer, which is
; free while a page shows) and copied there when the page opens: from the COM
; file, or from bank 1 of the ROM. It calls the main program's routines.
;
; Digital or analog; the time of the place from the engine (internet time,
; engine 0.11: PVA_R_CLOCK) or from the MSX's clock chip; the date, the place,
; the weather now; colours that turn with the music; a small spectrum.
; Keys: Left/Right or V the other face, T internet time / MSX clock, L the
; place, M music colours on/off, B the small spectrum on/off, K set the MSX's
; clock from the internet time; C, Z, ESC, Enter, BS back. The playback keys
; keep working. Settings: PICOAMP.INI [clock] face, time, colours, spectrum.
;==============================================================================

; the clock block (PVA_R_CLOCK)
CK_SEQ   equ 0
CK_FLAGS equ 1
CK_SEC   equ 2
CK_OFF   equ 10
CK_LOCST equ 12
CK_LOCN  equ 13
CK_GEN   equ 14
CK_WCODE equ 15
CK_TEMP  equ 16
CK_SLEEP equ 28
CK_ALARM equ 29
CK_AL_HOUR equ 30
CK_AL_MIN equ 31
CK_NST   equ 32
CK_NCOUNT equ 33
CK_NFEED equ 34
CK_NERR  equ 35
CK_ASTATE equ 36
CK_ASTORY equ 37
CK_ALEN  equ 38
CK_AKB   equ 40
CK_APCT  equ 42
CKF_TIME equ 1
CKF_ZONE equ 2
CKF_WX   equ 4
; ck_t: the time shown (the clock block's order)
T_SEC    equ 0
T_MIN    equ 1
T_HOUR   equ 2
T_WDAY   equ 3
T_DAY    equ 4
T_MONTH  equ 5
T_YEAR   equ 6

; glow colours: palette entries the page takes over (setpal gives them back)
G1      equ MAGENTA
G2      equ GREY_D
G3      equ GREY_L
G4      equ GREEN_D
A_KEYS  equ GREY*16+NAVY

mod_clock:
        jp ck_open              ; the page's jump table (M_OPEN ...)
        jp ck_tick
        jp ck_frame
        jp ck_keys
        jp ck_info
        jp ck_click
        jp ck_leave
;------------------------------------------------------------------------------
ck_open:
        xor a
        ld (tk_built),a         ; (the strips' buffer holds this page now)
        call ck_load_cfg
        ld a,(eng_minor)
        cp 11
        jr nc,.new
        xor a
        ld (ck_place),a         ; (no place without the engine's clock)
        jr ck_redraw
.new:
        call ck_getinfo
        ld a,(ckb+CK_GEN)
        ld (ck_gen),a
; the whole page
ck_redraw:
        call cls
        call setpal
        call ck_calm
        xor a
        ld (ck_list),a
        ld a,#FF
        ld (ck_ssec),a
        ld (ck_smin),a
        ld (ck_sday),a
        call ck_info
        call ck_line23
        call ck_bars_setup
        call ck_sprites_off
        ld a,(ck_face)
        or a
        jr nz,.an
        call ck_dcols
        call ck_secbar_cols
        jr .t
.an:    call ck_acols
        call ck_sprites_init
.t:     ld hl,0
        ld (ck_rtcl),hl         ; the clock chip now
        call ck_now
        jp ck_second

; leaving the page (fs_close): the sprites off, the settings to the card
ck_leave:
        call ck_sprites_off
        ld a,(ck_dirty)
        or a
        ret z
        jp ini_save

;------------------------------------------------------------------------------
; settings (PICOAMP.INI, through the engine)
ck_load_cfg:
        ld a,(eng_minor)
        cp 11
        ret c
        ld hl,k_face
        call ck_get
        jr nz,.k1
        ld a,(reply)
        cp 'a'
        ld a,0
        jr nz,.f
        inc a
.f:     ld (ck_face),a
.k1:     ld hl,k_time
        call ck_get
        jr nz,.k2
        ld a,(reply)
        cp 'm'
        ld a,0
        jr nz,.t
        inc a
.t:     ld (ck_src),a
.k2:     ld hl,k_cols
        call ck_get
        jr nz,.k3
        ld hl,ck_colnames       ; music, cyan, ... ("calm": cyan)
        ld c,0
.cn:    ld de,reply
        push hl
.cc:    ld a,(de)
        cp (hl)
        jr nz,.cx
        or a
        jr z,.cf
        inc hl
        inc de
        jr .cc
.cx:    pop hl
        xor a                   ; the next name
        push bc
        ld bc,16
        cpir
        pop bc
        inc c
        ld a,(hl)
        or a
        jr nz,.cn
        ld c,1                  ; (calm, or not known)
        jr .c
.cf:    pop hl
.c:     ld a,c
        cp CK_NCOL
        jr c,.c2
        ld a,1
.c2:    ld (ck_col),a
.k3:     ld hl,k_bars
        call ck_get
        ret nz
        ld a,(reply+1)
        cp 'f'
        ld a,0
        jr z,.b
        inc a
.b:     ld (ck_bars),a
        ret

; ck_get: HL = "section.key" -> ZF=1 set, the value in 'reply'
ck_get: ld de,args
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
        or 1                    ; no answer: not set
        ret

; ck_set: HL = key, DE = value (engine 0.11)
ck_set: ld a,(eng_minor)
        cp 11
        ret c
        push de
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
        ld (ck_dirty),a
        ret

; the place's name and the zone's abbreviation
ck_getinfo:
        ld a,C_CKINFO
        call cmd0
        ret c
        ret nz
        ld hl,reply
        ld de,ck_place
        ld bc,40
        call strncpy0
        ld de,linebuf           ; (the zone's name)
        ld bc,40
        call strncpy0
        ld de,ck_abbr
        ld bc,7
        jp strncpy0

;------------------------------------------------------------------------------
; the time: the engine's (internet) or the clock chip's -> ck_t
ck_now:
        ld a,(ck_src)
        or a
        jr nz,.msx
        ld a,(eng_minor)
        cp 11
        jr c,.msx
        ld a,(ckb+CK_FLAGS)
        and CKF_TIME
        jr z,.msx
        ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz                  ; caught while the engine wrote it
        ld hl,ckb+CK_SEC
        ld de,ck_t
        ld bc,8
        ldir
        ld a,1
        ld (ck_isnet),a
        ret
.msx:   xor a
        ld (ck_isnet),a
        ld hl,(JIFFY)           ; the chip 10 times a second
        ld de,(ck_rtcl)
        or a
        sbc hl,de
        ld a,h
        or a
        jr nz,.due
        ld a,l
        cp 6
        ret c
.due:   ld hl,(JIFFY)
        ld (ck_rtcl),hl
        ; fall through

; the MSX2's clock chip (RP5C01, block 0)
ck_rtc: ld a,13
        out (#B4),a
        ld a,8                  ; block 0, the timer running
        out (#B5),a
        ld hl,ck_rbuf
        ld c,0
.l:     ld a,c
        out (#B4),a
        in a,(#B5)
        and #0F
        ld (hl),a
        inc hl
        inc c
        ld a,c
        cp 13
        jr c,.l
        ld ix,ck_rbuf
        ld a,(ix+1)
        ld b,(ix+0)
        call .bcd
        ld (ck_t+T_SEC),a
        ld a,(ix+3)
        ld b,(ix+2)
        call .bcd
        ld (ck_t+T_MIN),a
        ld a,(ix+5)
        and 3
        ld b,(ix+4)
        call .bcd
        ld (ck_t+T_HOUR),a
        ld a,(ix+6)             ; 0 = Sunday -> 0 = Monday
        add a,6
        cp 7
        jr c,.w
        sub 7
.w:     ld (ck_t+T_WDAY),a
        ld a,(ix+8)
        and 3
        ld b,(ix+7)
        call .bcd
        ld (ck_t+T_DAY),a
        ld a,(ix+10)
        and 1
        ld b,(ix+9)
        call .bcd
        ld (ck_t+T_MONTH),a
        ld a,(ix+12)
        ld b,(ix+11)
        call .bcd
        ld l,a
        ld h,0
        ld de,1980
        add hl,de
        ld (ck_t+T_YEAR),hl
        ret
.bcd:   ld c,a                  ; A * 10 + B
        add a,a
        add a,a
        add a,c
        add a,a
        add a,b
        ret

; K: the clock chip set to the internet time
ck_setrtc:
        ld a,(ck_isnet)
        or a
        ld hl,txt_ck_nonet
        jp z,ck_msg_err
        ld a,13
        out (#B4),a
        xor a                   ; block 0, the timer stopped
        out (#B5),a
        ld ix,ck_t
        ld c,0
        ld a,(ix+T_SEC)
        call .two
        ld a,(ix+T_MIN)
        call .two
        ld a,(ix+T_HOUR)
        call .two
        ld a,(ix+T_WDAY)        ; 0 = Monday -> 0 = Sunday
        inc a
        cp 7
        jr c,.w
        xor a
.w:     call .one
        ld a,(ix+T_DAY)
        call .two
        ld a,(ix+T_MONTH)
        call .two
        ld a,(ix+T_YEAR)
        sub 1980 & #FF          ; (the low byte: 2026 - 1980 = 46)
        call .two
        ld a,13
        out (#B4),a
        ld a,8
        out (#B5),a
        ld hl,txt_ck_rtcset
        jp ck_msg_ok
.two:   call two_digits         ; units, then tens
        ld a,e
        call .one
        ld a,d
.one:   ld b,a
        ld a,c
        out (#B4),a
        ld a,b
        out (#B5),a
        inc c
        ret

;------------------------------------------------------------------------------
; each pass of the main loop
ck_tick:
        call ck_wait_poll
        ld a,(ck_list)
        or a
        ret nz
        call ck_now
        ld a,(ck_t+T_SEC)
        ld hl,ck_ssec
        cp (hl)
        call nz,ck_second
        ld a,(ckb+CK_SEQ)       ; the sleep timer or the alarm changed
        bit 0,a
        jr nz,.sa
        ld hl,ckb+CK_SLEEP
        ld de,ck_salshown
        ld b,4
.sc:    ld a,(de)
        cp (hl)
        jr nz,.sn
        inc hl
        inc de
        djnz .sc
        jr .sa
.sn:    call ck_salline
.sa:    ld a,(eng_minor)
        cp 11
        jr c,.m
        ld a,(ckb+CK_GEN)       ; the place, zone or weather changed
        ld hl,ck_gen
        cp (hl)
        jr z,.m
        ld (hl),a
        call ck_getinfo
        call ck_lines
.m:     ld a,(ck_msgon)         ; the message's time is up
        or a
        ret z
        ld hl,(JIFFY)
        ld de,(ck_msgt)
        or a
        sbc hl,de
        ld a,(hold)
        add a,a
        ld e,a
        ld d,0
        or a
        sbc hl,de
        ret c
        xor a
        ld (ck_msgon),a
        jp ck_line23

; a new second (A = it): what changes with it
ck_second:
        ld (ck_ssec),a
        ld a,(ck_t+T_MIN)
        ld hl,ck_smin
        cp (hl)
        jr z,.s
        ld (hl),a
        call ck_face_draw
.s:     ld a,(ck_t+T_DAY)
        ld hl,ck_sday
        cp (hl)
        jr z,.d
        ld (hl),a
        call ck_lines
.d:     ld a,(ck_face)
        or a
        jr nz,.an
        call ck_colon
        jp ck_secbar
.an:    call ck_sec_hand
        ld de,linebuf           ; ":SS" beside the digits
        ld a,':'
        ld (de),a
        inc de
        ld a,(ck_t+T_SEC)
        call put2
        xor a
        ld (de),a
        ld hl,linebuf
        ld de,#051B
        ld b,4
        ld c,RED*16+NAVY
        jp text6s

ck_face_draw:
        ld a,(ck_face)
        or a
        jp z,ck_digits
        call ck_dial
        ; HH:MM in the big red digits
        ld a,(ck_t+T_HOUR)
        call two_digits
        push de
        ld a,d
        ld de,#0312
        call put_digit
        pop de
        ld a,e
        ld de,#0314
        call put_digit
        ld de,#0316
        call put_colon
        ld a,(ck_t+T_MIN)
        call two_digits
        push de
        ld a,d
        ld de,#0317
        call put_digit
        pop de
        ld a,e
        ld de,#0319
        jp put_digit

;------------------------------------------------------------------------------
; the text lines: date, place, zone, weather, the time's source
ck_lines:
        ld a,(ck_list)
        or a
        ret nz
        ld de,linebuf
        call ck_datestr
        ld a,(ck_face)
        or a
        jr nz,.an
        ld hl,linebuf
        ld d,14
        ld c,YELLOW*16+NAVY
        call ck_ctext
        ld hl,ck_place
        ld d,15
        ld c,WHITE*16+NAVY
        call ck_ctext
        ld de,linebuf           ; weather and source in one line
        call ck_wxstr
        call ck_sep
        call ck_srcstr
        ld hl,linebuf
        ld d,16
        ld c,CYAN*16+NAVY
        call ck_ctext
        jp ck_salline
.an:    ; beside the dial (columns 18-31): the day, the date, ...
        ld hl,linebuf           ; "Thursday" alone, then the rest
.sp:    ld a,(hl)
        inc hl
        cp ' '
        jr nz,.sp
        dec hl
        ld (hl),0
        inc hl
        push hl
        ld hl,linebuf
        ld de,#0712
        ld b,14
        ld c,YELLOW*16+NAVY
        call text6s
        pop hl
        ld de,#0812
        ld b,14
        ld c,WHITE*16+NAVY
        call text6s
        ld hl,ck_place          ; the place: the city, the rest below it
        ld de,linebuf
        call strcpy0
        ld hl,linebuf
.pc:    ld a,(hl)
        or a
        jr z,.pe
        inc hl
        cp ','
        jr nz,.pc
        dec hl
        ld (hl),0
        inc hl
        inc hl                  ; (after ", ")
.pe:    push hl
        ld hl,linebuf
        ld de,#0A12
        ld b,14
        ld c,WHITE*16+NAVY
        call text6s
        pop hl
        ld de,#0B12
        ld b,14
        ld c,WHITE*16+NAVY
        call text6s
        call ck_salline
        ld de,linebuf
        call ck_wxstr
        ld hl,linebuf
        ld de,#0E12
        ld b,14
        ld c,WHITE*16+NAVY
        call text6s
        ld de,linebuf
        call ck_srcstr
        ld hl,linebuf
        ld de,#1011
        ld b,15
        ld c,A_KEYS
        jp text6s

ck_sep: ld hl,linebuf            ; "  " after a part (none at the start, none twice)
        or a
        sbc hl,de
        ret z
        dec de
        ld a,(de)
        inc de
        cp ' '
        ret z
        ld hl,txt_ck_sep
        jp strcpy

; ck_ctext: HL = text, D = row, C = colour: in 6-pixel letters, in the middle
ck_ctext:
        push hl
        push bc
        push de
        ld b,0                  ; letters
.n:     ld a,(hl)
        or a
        jr z,.e
        inc hl
        inc b
        ld a,b
        cp 42
        jr c,.n
.e:     ld a,b                  ; pad = (256 - 6 n) / 2 = 128 - 3 n
        add a,a
        add a,b
        ld b,a
        ld a,128
        sub b
        jr nc,.p
        xor a
.p:     neg
        ld l,a
        ld h,#FF
        or a
        jr nz,.h
        ld h,a
.h:     ld (t6_off),hl          ; minus the pad: the text starts further right
        ld hl,0
        ld (t6_cycle),hl
        pop de
        pop bc
        pop hl
        ld e,0
        ld b,32
        jp text6

; "Thursday 29 October 2026" at DE
ck_datestr:
        ld a,(ck_t+T_WDAY)
        cp 7
        jr c,.w
        xor a
.w:     ld hl,ck_days
        call ck_nth
        call strcpy
        ld a,' '
        ld (de),a
        inc de
        ld a,(ck_t+T_DAY)
        ld l,a
        ld h,0
        call fmt_u16
        ld a,' '
        ld (de),a
        inc de
        ld a,(ck_t+T_MONTH)
        dec a
        cp 12
        jr c,.m
        xor a
.m:     ld hl,ck_months
        call ck_nth
        call strcpy
        ld a,' '
        ld (de),a
        inc de
        ld hl,(ck_t+T_YEAR)
        jp fmt_u16

; ck_nth: HL = strings (0 after each), A = index -> HL = that one
ck_nth: or a
        ret z
        ld b,a
.s:     ld a,(hl)
        inc hl
        or a
        jr nz,.s
        djnz .s
        ret

; the sleep timer and the alarm: "Sleep 25 min  Alarm 07:30" (digital: row
; 17 in the middle; analog: row 12 beside the dial)
ck_salline:
        ld hl,ckb+CK_SLEEP
        ld de,ck_salshown
        ld bc,4
        ldir
        ld de,linebuf
        xor a
        ld (de),a
        ld a,(eng_minor)
        cp 12
        jr c,.out
        ld a,(ckb+CK_SLEEP)
        or a
        jr z,.al
        ld hl,txt_ck_sleep
        call strcpy
        ld a,(ckb+CK_SLEEP)
        ld l,a
        ld h,0
        call fmt_u16
        ld hl,txt_ck_min
        call strcpy
.al:    ld a,(ckb+CK_ALARM)
        rrca
        jr nc,.out
        call ck_sep
        ld hl,txt_ck_alarm
        call strcpy
        ld a,(ckb+CK_AL_HOUR)
        call put2
        ld a,':'
        ld (de),a
        inc de
        ld a,(ckb+CK_AL_MIN)
        call put2
        xor a
        ld (de),a
        ld a,(ckb+CK_ALARM)
        and 4
        ld hl,txt_ck_wkd
        call nz,strcpy
        ld a,(ckb+CK_ALARM)
        and 2
        ld hl,txt_ck_ring
        call nz,strcpy
.out:   ld hl,linebuf
        ld a,(ck_face)
        or a
        ld c,YELLOW*16+NAVY
        jr nz,.an
        ld d,17
        jp ck_ctext
.an:    ld de,#0C12
        ld b,14
        jp text6s

; "-0.4 C Rain", else nothing
ck_wxstr:
        xor a
        ld (de),a
        ld a,(eng_minor)
        cp 11
        ret c
        ld a,(ckb+CK_FLAGS)
        and CKF_WX
        ret z
        ld hl,(ckb+CK_TEMP)     ; 0.1 degrees
        bit 7,h
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
        ld hl,txt_ck_deg
        call strcpy
        ld a,(ckb+CK_WCODE)     ; the word for the WMO code
        ld hl,ck_wx
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
        jp strcpy

ck_srcstr:
        ld hl,txt_ck_net
        ld a,(ck_isnet)
        or a
        jp nz,strcpy
        ld hl,txt_ck_msx
        ld a,(ck_src)
        or a
        jp nz,strcpy
        ld hl,txt_ck_old        ; internet time wanted, not there
        ld a,(eng_minor)
        cp 11
        jp c,strcpy
        ld hl,txt_ck_wait
        jp strcpy

;------------------------------------------------------------------------------
; row 0: what plays; row 23: the keys (or a message, or the place being typed)
ck_info:  jp pg_row0             ; row 0: what plays

ck_line23:
        ld a,(ck_inp)
        or a
        jp nz,ck_inp_draw
        ld hl,txt_ck_keys
        ld c,A_KEYS
ck_row23:
        ld de,#1700
        ld b,32
        jp text6s

ck_msg_ok:
        ld c,GREEN*16+NAVY
        jr ck_msg
ck_msg_err:
        ld c,RED*16+NAVY
ck_msg: call ck_row23
        ld hl,(JIFFY)
        ld (ck_msgt),hl
        ld a,1
        ld (ck_msgon),a
        ret

;------------------------------------------------------------------------------
; keys: A = key (also in B)
ck_keys:
        ld c,a
        ld a,(ck_inp)
        or a
        ld a,c
        jp nz,ck_inp_keys
        ld a,(ck_list)
        or a
        ld a,c
        jp nz,ck_list_keys
        cp 29
        jp z,ck_toggle_face
        cp 28
        jp z,ck_toggle_face
        cp 27
        jp z,fs_close
        cp 13
        jp z,fs_close
        cp 8
        jp z,fs_close
        and #DF
        cp 'V'
        jp z,ck_toggle_face
        cp 'C'
        jp z,fs_close
        cp 'Z'
        jp z,fs_close
        cp 'I'
        jr z,ck_toggle_src
        cp 'T'
        ld c,PG_NEWS
        jp z,pg_enter
        cp 'W'
        ld c,PG_WEATHER
        jp z,pg_enter
        cp 'O'
        jp z,ck_sleep
        cp 'A'
        jp z,ck_alarm_open
        cp 'M'
        jp z,ck_toggle_col
        cp 'B'
        jp z,ck_toggle_bars
        cp 'L'
        jp z,ck_inp_open
        cp 'K'
        jp z,ck_setrtc
        cp 'G'
        ret z
        ld a,b                  ; the playback keys
        jp keys_common

ck_click:
        ld a,(ck_inp)
        ld hl,ck_list
        or (hl)
        ret nz
ck_toggle_face:
        ld a,(ck_face)
        xor 1
        ld (ck_face),a
        ld hl,k_face
        ld de,txt_ck_digital
        or a
        jr z,.s
        ld de,txt_ck_analog
.s:     call ck_set
        jp ck_redraw

ck_toggle_src:
        ld a,(ck_src)
        xor 1
        ld (ck_src),a
        ld hl,k_time
        ld de,txt_ck_internet
        or a
        jr z,.s
        ld de,txt_ck_msxv
.s:     call ck_set
        jp ck_redraw

; M: the music's colours, then one colour after the other
ck_toggle_col:
        ld a,(ck_col)
        inc a
        cp CK_NCOL
        jr c,.n
        xor a
.n:     ld (ck_col),a
        ld hl,ck_colnames
        or a
        jr z,.s
        ld b,a
.f:     xor a
        push bc
        ld bc,16
        cpir
        pop bc
        djnz .f
.s:     push hl
        ld de,linebuf           ; "Colours: amber"
        ld hl,txt_ck_colmsg
        call strcpy
        pop hl
        push hl
        call strcpy
        pop de
        ld hl,k_cols
        call ck_set
        ld hl,linebuf
        call ck_msg_ok
        ld a,#FF                ; shown again by ck_frame / now
        ld (ck_phase),a
        jp ck_calm

ck_toggle_bars:
        ld a,(ck_bars)
        xor 1
        ld (ck_bars),a
        ld hl,k_bars
        ld de,txt_ck_on
        or a
        jr nz,.s
        ld de,txt_ck_off
.s:     call ck_set
        ld a,(ck_bars)
        or a
        jp nz,ck_bars_setup
        ld d,19                 ; off: the rows of the spectrum cleared
.c:     push de
        ld e,0
        ld b,32
        ld c,NAVY*16+NAVY
        call fill_row
        pop de
        inc d
        ld a,d
        cp 23
        jr c,.c
        ret

;------------------------------------------------------------------------------
; the place: L opens a line in row 23; a name is looked for (Open-Meteo),
; Enter alone takes the internet connection's place
ck_alarm_open:
        ld a,(eng_minor)
        cp 12
        ld hl,txt_ck_needs
        jp c,ck_msg_err
        ld a,1
        jr ck_inp_go
ck_inp_open:
        ld a,(eng_minor)
        cp 11
        ld hl,txt_ck_needs
        jp c,ck_msg_err
        xor a
ck_inp_go:
        ld (ck_imode),a
        ld a,1
        ld (ck_inp),a
        xor a
        ld (ck_ilen),a
        ld (ck_itext),a
        ld (ck_msgon),a
ck_inp_draw:
        ld hl,txt_ck_place
        ld a,(ck_imode)
        or a
        jr z,.p
        ld hl,txt_ck_alin
.p:     ld de,linebuf
        call strcpy
        ld hl,ck_itext
        call strcpy
        ld a,'_'
        ld (de),a
        inc de
        xor a
        ld (de),a
        ld hl,linebuf
        ld c,WHITE*16+BLUE
        jp ck_row23

ck_inp_keys:
        cp 27
        jr z,.close
        cp 13
        jr z,.go
        cp 8
        jr nz,.ch
        ld a,(ck_ilen)
        or a
        ret z
        dec a
        jr .end
.ch:    cp ' '
        ret c
        cp 127
        ret nc
        ld b,a
        ld a,(ck_ilen)
        cp 18
        ret nc
        ld e,a
        ld d,0
        ld hl,ck_itext
        add hl,de
        ld (hl),b
        inc a
.end:   ld (ck_ilen),a
        ld e,a
        ld d,0
        ld hl,ck_itext
        add hl,de
        ld (hl),0
        jr ck_inp_draw
.close: xor a
        ld (ck_inp),a
        jp ck_line23
.go:    xor a
        ld (ck_inp),a
        ld a,(ck_imode)
        or a
        jp nz,ck_alarm_set
        ld a,(ck_ilen)
        or a
        jr nz,.find
        ld a,C_LOCIP            ; by the internet connection
        call cmd0
        ld a,1
        ld (ck_dirty),a
        ld hl,txt_ck_byip
        jp ck_msg_ok
.find:  ld hl,ck_itext
        ld de,args
        call strcpy0
        ld a,(ck_ilen)
        inc a
        ld c,a
        ld b,0
        ld a,C_LOCSRCH
        call cmd
        ret c
        ld hl,txt_ck_nowifi
        jp nz,ck_msg_err
        ld a,1
        ld (ck_wait),a
        ld hl,txt_ck_looking
        ld c,WHITE*16+NAVY
        jp ck_row23

; the alarm's time typed: "7:30", "0730", "07.30" ("w" after it: weekdays only);
; nothing: the alarm off
ck_alarm_set:
        ld hl,ck_itext
        ld de,0                 ; D = digits so far, E = 0
        ld bc,0                 ; B = the number, C = weekdays
        ld ix,ck_rbuf           ; (the digits)
.d:     ld a,(hl)
        inc hl
        or a
        jr z,.e
        cp 'w'
        jr z,.w
        cp 'W'
        jr z,.w
        sub '0'
        cp 10
        jr nc,.d
        ld e,a
        ld a,d
        cp 4                    ; (more than 4 digits: the rest is left out,
        jr nc,.d                ; a "w" after them still counts)
        ld (ix+0),e
        inc ix
        inc d
        jr .d
.w:     ld c,4
        jr .d
.e:     ld a,d
        or a
        jr z,.off
        cp 3
        jr c,.bad
        ld ix,ck_rbuf           ; HMM or HHMM
        cp 4
        jr z,.h2
        ld a,(ix+0)
        ld b,a                  ; (H MM)
        jr .mm
.h2:    ld a,(ix+0)
        ld b,a
        add a,a
        add a,a
        add a,b
        add a,a
        add a,(ix+1)
        ld b,a
        inc ix
.mm:    ld a,(ix+1)
        add a,a
        ld e,a
        add a,a
        add a,a
        add a,e
        add a,(ix+2)
        cp 60
        jr nc,.bad
        ld e,a
        ld a,b
        cp 24
        jr nc,.bad
        ld a,c
        or 1                    ; PVA_AL_ON
        ld (args),a
        ld a,b
        ld (args+1),a
        ld a,e
        ld (args+2),a
        ld bc,3
        ld a,C_ALARM
        call cmd
        ret c
        ld hl,txt_ck_alnone
        jp nz,ck_msg_err
        ld a,1
        ld (ck_dirty),a
        ld hl,txt_ck_alset
        jp ck_msg_ok
.off:   xor a
        ld (args),a
        ld a,(ckb+CK_AL_HOUR)
        ld (args+1),a
        ld a,(ckb+CK_AL_MIN)
        ld (args+2),a
        ld bc,3
        ld a,C_ALARM
        call cmd
        ld a,1
        ld (ck_dirty),a
        ld hl,txt_ck_aloff
        jp ck_msg_ok
.bad:   ld hl,txt_ck_albad
        jp ck_msg_err

; O: the sleep timer 15, 30, 45, 60, 90 minutes, off
ck_sleep:
        ld a,(eng_minor)
        cp 12
        ld hl,txt_ck_needs
        jp c,ck_msg_err
        ld a,(ck_sleepi)
        inc a
        cp 6
        jr c,.i
        xor a
.i:     ld (ck_sleepi),a
        ld hl,ck_sleeps
        call idx
        ld l,(hl)
        ld h,0
        ld (args),hl
        push hl
        ld bc,2
        ld a,C_SLEEP
        call cmd
        pop hl
        ld a,h
        or l
        ld hl,txt_ck_sloff
        jp z,ck_msg_ok
        ld hl,txt_ck_slon
        jp ck_msg_ok

; the place search's outcome
ck_wait_poll:
        ld a,(ck_wait)
        or a
        ret z
        ld a,(ckb+CK_SEQ)
        bit 0,a
        ret nz
        ld a,(ckb+CK_LOCST)
        cp 2
        jr z,.done
        cp 3
        ret nz
        xor a
        ld (ck_wait),a
        ld hl,txt_ck_sfail
        jp ck_msg_err
.done:  xor a
        ld (ck_wait),a
        ld a,(ckb+CK_LOCN)
        or a
        ld hl,txt_ck_none
        jp z,ck_msg_err
        ld a,C_LOCLIST
        call cmd0
        ret c
        ret nz
        ld a,(reply)
        cp 9
        jr c,.n
        ld a,8
.n:     ld (ck_n),a
        ld b,a                  ; the names, 32 bytes each
        ld hl,reply+1
        ld de,CK_NAMES
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
        xor a
        ld (ck_lsel),a
        inc a
        ld (ck_list),a
        call ck_sprites_off
        call cls
        call ck_info
        ld hl,txt_ck_choose
        ld de,#0300
        ld b,32
        ld c,YELLOW*16+NAVY
        call text6s
        ld hl,txt_ck_lkeys
        ld c,A_KEYS
        call ck_row23
; the list, the chosen one highlighted (rows 5..)
ck_list_draw:
        ld c,0
.l:     ld a,(ck_n)
        cp c
        ret z
        push bc
        ld a,c
        add a,5
        ld d,a
        ld e,1
        ld l,c                  ; CK_NAMES + 32 c
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        push de
        ld de,CK_NAMES
        add hl,de
        pop de
        ld a,(ck_lsel)
        cp c
        ld c,A_SEL
        jr z,.s
        ld c,A_NORM
.s:     ld b,30
        call text6s
        pop bc
        inc c
        jr .l

ck_list_keys:
        cp 30
        jr z,.up
        cp 31
        jr z,.dn
        cp 13
        jr z,.pick
        cp 27
        ret nz
        jp ck_redraw            ; (ck_redraw ends the list)
.up:    ld a,(ck_lsel)
        or a
        ret z
        dec a
        jr .set
.dn:    ld a,(ck_n)
        ld b,a
        ld a,(ck_lsel)
        inc a
        cp b
        ret nc
.set:   ld (ck_lsel),a
        jr ck_list_draw
.pick:  ld a,(ck_lsel)
        ld e,a
        ld a,C_LOCPICK
        call cmd_u8
        ld a,1
        ld (ck_dirty),a
        ld a,(ck_lsel)          ; its name, for the page until the engine has it
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,CK_NAMES
        add hl,de
        ld de,ck_place
        call strcpy0
        xor a
        ld (ck_abbr),a
        jp ck_redraw

;------------------------------------------------------------------------------
; colours: the four glow entries, calm, or turning with the music
ck_calm:
        ld a,(ck_col)           ; 0 (music): its calm colours are cyan
        or a
        jr z,.c1
        dec a
.c1:    add a,a
        add a,a
        add a,a
        ld l,a
        ld h,0
        ld de,ck_calmpal
        add hl,de
        ld c,0
.c:     ld a,c
        push hl
        ld hl,ck_gents
        call idx
        ld a,(hl)
        pop hl
        di
        out (VDP_C),a
        ld a,16+128
        out (VDP_C),a
        ld a,(hl)
        out (VDP_P),a
        inc hl
        ld a,(hl)
        out (VDP_P),a
        inc hl
        ei
        inc c
        ld a,c
        cp 4
        jr c,.c
        ret

ck_music:
        ld a,(viz+V_VU)         ; faster round the wheel when it is loud
        ld b,a
        ld a,(viz+V_VU+1)
        add a,b
        rrca
        rrca
        rrca
        rrca
        and #0F
        inc a
        ld b,a
        ld a,(ck_phase)
        add a,b
        cp 192
        jr c,.p
        sub 192
.p:     ld (ck_phase),a         ; (FF: calm colours shown)
        ld a,(viz+V_LEVEL)      ; brighter with the bass
        ld b,a
        ld a,(viz+V_LEVEL+1)
        cp b
        jr c,.b1
        ld b,a
.b1:    ld a,b
        rrca
        rrca
        rrca
        and #03
        add a,5
        cp 8
        jr c,.b2
        ld a,7
.b2:    add a,a
        add a,a
        add a,a
        ld (pl_br),a
        ld c,0
.c:     ld a,(ck_phase)         ; (phase / 4 + 6 c) mod 48
        rrca
        rrca
        and #3F
        ld b,a
        ld a,c
        add a,a
        add a,c
        add a,a
        add a,b
.m:     cp 48
        jr c,.m2
        sub 48
        jr .m
.m2:    ld l,a
        ld h,0
        ld e,l
        ld d,h
        add hl,hl
        add hl,de
        ld de,wheel
        add hl,de
        ld a,(hl)
        call plasma_colours.sc
        add a,a
        add a,a
        add a,a
        add a,a
        ld d,a
        inc hl
        ld a,(hl)
        call plasma_colours.sc
        ld e,a
        inc hl
        ld a,(hl)
        call plasma_colours.sc
        or d
        ld d,a
        push de
        ld a,c
        ld hl,ck_gents
        call idx
        ld a,(hl)
        pop de
        di
        out (VDP_C),a
        ld a,16+128
        out (VDP_C),a
        ld a,d
        out (VDP_P),a
        ld a,e
        out (VDP_P),a
        ei
        inc c
        ld a,c
        cp 4
        jr c,.c
        ret

; a new picture from the engine: colours, the small spectrum
ck_frame:
        ld a,(viz+V_SEQ)
        bit 0,a
        ret nz
        ld a,(ck_col)           ; the music's colours while something plays
        or a
        jr nz,.nm
        ld a,(st+ST_STATE)
        cp 1
        jr nz,.calm
        call ck_music
        jr .nm
.calm:  ld a,(ck_phase)         ; (once: calm again)
        cp #FF
        call nz,ck_calm
        ld a,#FF
        ld (ck_phase),a
.nm:    ld a,(ck_bars)
        or a
        ret z
        ld a,(ck_list)
        or a
        ret nz
        ld hl,scope_tick        ; 25 a second
        inc (hl)
        bit 0,(hl)
        ret nz
        jp draw_bars

; the small spectrum: 24 bars of 4 cells (8 steps), rows 19-22
ck_bars_setup:
        ld hl,ck_segof
        ld (bp_segof),hl
        ld hl,ck_segcol
        ld (bp_segcol),hl
        ld hl,cellcache
        ld (bp_cache),hl
        ld a,4
        ld (bp_cells),a
        ld a,8
        ld (bp_segs),a
        ld a,22
        ld (bp_bottom),a
        xor a
        ld (bp_mirror),a
        ld a,4
        ld (bp_col0),a
        ld a,NBARS
        ld (bp_nbars),a
        ld hl,bar_last          ; every bar drawn again
        ld bc,(NBARS+2)*4
        ld a,#FF
        call memset
        ld hl,cellcache
        ld bc,NBARS*4
        ld a,#FF
        jp memset

;------------------------------------------------------------------------------
; the digital face: HH:MM in 7-segment digits 80 pixels high, drawn into
; vizbuf (24 x 10 cells) and shown in rows 2-11, columns 4-27
ck_digits:
        call vb_clear
        ld a,(ck_t+T_HOUR)
        call two_digits
        push de
        ld a,d
        ld c,4
        call ck_digit
        pop de
        ld a,e
        ld c,48
        call ck_digit
        ld a,(ck_t+T_MIN)
        call two_digits
        push de
        ld a,d
        ld c,108
        call ck_digit
        pop de
        ld a,e
        ld c,152
        call ck_digit
        ld b,22                 ; the colon (it blinks by its colours)
        call .dot
        ld b,50
        call .dot
        ; out: rows 2-11 at column 4
        ld hl,vizbuf
        ld d,2
.r:     push hl
        ld h,d
        ld l,32
        call vwrite
        pop hl
        ld b,192
        ld c,VDP_D
        otir
        ei
        inc d
        ld a,d
        cp 12
        jr c,.r
        ret
.dot:   ld c,8
.dl:    push bc
        ld d,92
        ld e,99
        call ck_hfill
        pop bc
        inc b
        dec c
        jr nz,.dl
        ret

; ck_digit: A = digit, C = x
ck_digit:
        ld hl,ck_segs
        call idx
        ld a,(hl)
        ld (sg_bits),a
        ld a,c
        ld (sg_dx),a
        ld hl,ck_seglist        ; per segment: dx, y, length, kind (0 = across)
        ld b,7
.s:     ld a,(sg_bits)
        rrca
        ld (sg_bits),a
        jr nc,.n
        push bc
        push hl
        ld a,(sg_dx)
        add a,(hl)
        ld c,a
        inc hl
        ld b,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld e,(hl)
        inc e
        dec e
        jr nz,.v
        call ck_hseg
        jr .d
.v:     call ck_vseg
.d:     pop hl
        pop bc
.n:     inc hl
        inc hl
        inc hl
        inc hl
        djnz .s
        ret

; ck_hseg: C = x, B = y, A = length: across, 8 lines, the ends cut off
ck_hseg:
        ld (sg_len),a
        ld a,c
        ld (sg_x),a
        ld a,b
        ld (sg_y),a
        ld hl,ck_taper
        ld b,8
.r:     push bc
        push hl
        ld c,(hl)               ; the cut
        ld a,(sg_x)
        add a,c
        ld d,a
        ld a,(sg_len)
        dec a
        sub c
        sub c
        add a,d
        ld e,a
        ld a,(sg_y)
        ld b,a
        call ck_hfill
        ld hl,sg_y
        inc (hl)
        pop hl
        inc hl
        pop bc
        djnz .r
        ret

; ck_vseg: C = x, B = y, A = lines: down, 8 wide, the ends cut off
ck_vseg:
        ld (sg_len),a
        ld a,c
        ld (sg_x),a
        ld a,b
        ld (sg_y),a
        xor a
        ld (sg_r),a
.r:     ld a,(sg_r)
        cp 4
        jr nc,.m
        neg
        add a,3                 ; the top: 3 - r
        jr .t
.m:     ld b,a
        ld a,(sg_len)
        sub 4
        ld c,a
        ld a,b
        sub c                   ; the bottom: r - (len - 4)
        jr nc,.t
        xor a
.t:     ld c,a
        ld a,(sg_x)
        add a,c
        ld d,a
        ld a,(sg_x)
        add a,7
        sub c
        ld e,a
        ld a,(sg_y)
        ld b,a
        call ck_hfill
        ld hl,sg_y
        inc (hl)
        ld hl,sg_r
        inc (hl)
        ld a,(sg_len)
        cp (hl)
        jr nz,.r
        ret

; ck_hfill: D = x0, E = x1, B = y: pixels x0..x1 of line y in vizbuf
ck_hfill:
        ld a,e
        cp d
        ret c
        ld a,d
        rrca
        rrca
        rrca
        and #1F
        ld c,a
        ld a,b
        call vb_ptr             ; HL (DE kept)
        ld a,e
        rrca
        rrca
        rrca
        and #1F
        sub c
        ld b,a                  ; cells after the first
        push hl
        ld a,d
        and 7
        ld c,a
        ld a,#FF
        jr z,.l1
.l0:    srl a
        dec c
        jr nz,.l0
.l1:    ld d,a                  ; the first cell's bits
        ld a,e
        and 7
        xor 7
        ld c,a
        ld a,#FF
        jr z,.r1
.r0:    add a,a
        dec c
        jr nz,.r0
.r1:    ld e,a                  ; the last cell's
        pop hl
        ld a,b
        or a
        jr nz,.many
        ld a,d
        and e
        or (hl)
        ld (hl),a
        ret
.many:  ld a,d
        or (hl)
        ld (hl),a
.m:     ld a,l
        add a,8
        ld l,a
        jr nc,.m1
        inc h
.m1:    dec b
        jr z,.last
        ld (hl),#FF
        jr .m
.last:  ld a,e
        or (hl)
        ld (hl),a
        ret

; the digital face's colours: a band of a glow colour every 20 lines
ck_dcols:
        ld d,2
.r:     ld a,d
        add a,#20
        ld h,a
        ld l,32
        call vwrite
        ld a,d
        sub 2
        add a,a
        add a,a
        add a,a
        ld e,a                  ; the first line's y
        ld b,24
.c:     push bc
        ld b,8
        ld a,e
.l:     push af
        call ck_dgrad
        out (VDP_D),a
        pop af
        inc a
        djnz .l
        pop bc
        djnz .c
        ei
        inc d
        ld a,d
        cp 12
        jr c,.r
        ret

ck_dgrad:                       ; A = y (0-79) -> colour byte
        ld hl,ck_gents
        cp 20
        jr c,.g
        inc hl
        cp 40
        jr c,.g
        inc hl
        cp 60
        jr c,.g
        inc hl
.g:     ld a,(hl)
        add a,a
        add a,a
        add a,a
        add a,a
        or NAVY
        ret

; the colon: on in even seconds (the colours of its two cells)
ck_colon:
        ld a,(ck_t+T_SEC)
        rrca
        ld a,NAVY*16+NAVY
        jr c,.s
        xor a
.s:     ld (sg_bits),a          ; 0: the glow colours
        ld d,2
.r:     ld a,d
        add a,#20
        ld h,a
        ld l,15*8
        call vwrite
        ld a,d
        sub 2
        add a,a
        add a,a
        add a,a
        ld e,a
        ld b,2
.c:     push bc
        ld b,8
        ld a,e
.l:     push af
        ld a,(sg_bits)
        or a
        jr nz,.o
        pop af
        push af
        call ck_dgrad
.o:     out (VDP_D),a
        pop af
        inc a
        djnz .l
        pop bc
        djnz .c
        ei
        inc d
        ld a,d
        cp 12
        jr c,.r
        ret

; the seconds: a bar in row 13 (lines 1-5), with its track (line 6)
ck_secbar_cols:
        ld hl,#2000+13*256+32
        call vwrite
        ld b,24
.c:     push bc
        ld hl,ck_barcol
        ld b,8
        ld c,VDP_D
        otir
        pop bc
        djnz .c
        ei
        ret

ck_secbar:
        ld a,(ck_t+T_SEC)       ; lit pixels: (s + 1) * 16 / 5 (all at 59)
        inc a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,5
        call div16
        ld a,l
        ld (sg_len),a
        ld hl,13*256+32
        call vwrite
        ld b,24
        ld c,0                  ; the cell's first pixel
.c:     ld a,(sg_len)
        sub c
        jr nc,.n
        xor a
.n:     cp 8
        jr c,.n2
        ld a,8
.n2:    push bc
        ld hl,ck_lbits
        call idx_bc
        ld a,(hl)
        ld hl,sg_pat+1          ; lines 1-5 lit, line 6 the track
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        ld hl,sg_pat
        ld b,8
        ld c,VDP_D
        otir
        pop bc
        ld a,c
        add a,8
        ld c,a
        djnz .c
        ei
        ret

;------------------------------------------------------------------------------
; the analog face: a dial of 128 x 128 pixels in vizbuf (16 cells a row),
; rows 2-17, columns 1-16; the second hand is four sprites
ck_dial:
        ld hl,vizbuf
        ld bc,2048
        xor a
        call memset
        ld b,0                  ; the 60 marks
.t:     push bc
        ld a,b
        ld c,0
        call ck_pt
        call ck_apx
        inc d
        call ck_apx
        pop bc
        push bc
        ld a,b                  ; every fifth: a stroke inwards
.f:     or a
        jr z,.h
        sub 5
        jr nc,.f
        jr .n
.h:     ld a,b
        ld c,1
        call ck_pt
        ld a,d
        ld (ln_x),a
        ld a,e
        ld (ln_y),a
        pop bc
        push bc
        ld a,b
        ld c,0
        call ck_pt
        call ck_line
        pop bc
        push bc
        ld a,b
        ld c,1
        call ck_pt
        inc d
        ld a,d
        ld (ln_x),a
        ld a,e
        ld (ln_y),a
        pop bc
        push bc
        ld a,b
        ld c,0
        call ck_pt
        inc d
        call ck_line
.n:     pop bc
        inc b
        ld a,b
        cp 60
        jr c,.t
        ; the hour hand: (hour mod 12) * 5 + minute / 12
        ld a,(ck_t+T_HOUR)
.h12:   cp 12
        jr c,.h2
        sub 12
        jr .h12
.h2:    ld b,a
        add a,a
        add a,a
        add a,b
        ld b,a
        ld a,(ck_t+T_MIN)
        ld c,0
.d12:   sub 12
        jr c,.d2
        inc c
        jr .d12
.d2:    ld a,b
        add a,c
        ld c,3                  ; 5/8 long
        ld b,4                  ; 4 lines thick
        call ck_hand
        ld a,(ck_t+T_MIN)
        ld c,1                  ; 7/8 long
        ld b,3
        call ck_hand
        ld de,#3F3F             ; the centre
        call ck_apx
        ld de,#403F
        call ck_apx
        ld de,#3F40
        call ck_apx
        ld de,#4040
        call ck_apx
        ; out: rows 2-17 at column 1
        ld hl,vizbuf
        ld d,2
.r:     push hl
        ld h,d
        ld l,8
        call vwrite
        pop hl
        ld b,128
        ld c,VDP_D
        otir
        ei
        inc d
        ld a,d
        cp 18
        jr c,.r
        ret

; ck_hand: A = angle (0-59), C = length (ck_scale), B = lines thick (1-4)
ck_hand:
        push bc
        call ck_pt
        pop bc
        ld a,d
        ld (hd_x),a
        ld a,e
        ld (hd_y),a
        ld hl,ck_hoffs
.v:     push bc
        push hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld a,64
        add a,c
        ld (ln_x),a
        ld a,64
        add a,b
        ld (ln_y),a
        ld a,(hd_x)
        add a,c
        ld d,a
        ld a,(hd_y)
        add a,b
        ld e,a
        call ck_line
        pop hl
        inc hl
        inc hl
        pop bc
        djnz .v
        ret

; ck_pt: A = angle (0-59), C = length -> D = x, E = y (centre 64, 64)
ck_pt:  ld (pt_ang),a
        ld a,c
        ld (pt_mode),a
        ld a,(pt_ang)
        ld hl,ck_sin
        call idx
        ld a,(hl)
        call .sc
        add a,64
        ld (pt_x),a
        ld a,(pt_ang)
        add a,15
        cp 60
        jr c,.c
        sub 60
.c:     ld hl,ck_sin
        call idx
        ld a,(hl)
        call .sc
        neg
        add a,64
        ld e,a
        ld a,(pt_x)
        ld d,a
        ret
.sc:    ld b,a                  ; A = B scaled: 0 all, 1 7/8, 2 3/4, 3 5/8, 4 1/2, 5 1/4
        ld a,(pt_mode)
        or a
        ld a,b
        ret z
        ld a,(pt_mode)
        dec a
        jr nz,.m2
        ld a,b
        sra a
        sra a
        sra a
        neg
        add a,b
        ret
.m2:    dec a
        jr nz,.m3
        ld a,b
        sra a
        ld c,a
        sra a
        add a,c
        ret
.m3:    dec a
        jr nz,.m4
        ld a,b
        sra a
        ld c,a
        sra a
        sra a
        add a,c
        ret
.m4:    dec a
        ld a,b
        jr nz,.m5
        sra a                   ; a half
        ret
.m5:    sra a                   ; a quarter
        sra a
        ret

; ck_line: from (ln_x, ln_y) to (D, E), in the dial
ck_line:
        ld a,d
        ld (ln_tx),a
        ld a,e
        ld (ln_ty),a
        ld a,(ln_x)
        ld b,a
        ld a,d
        sub b
        ld b,1
        jr nc,.x
        neg
        ld b,#FF
.x:     ld (ln_dx),a
        ld a,b
        ld (ln_sx),a
        ld a,(ln_y)
        ld b,a
        ld a,e
        sub b
        ld b,1
        jr nc,.y
        neg
        ld b,#FF
.y:     ld (ln_dy),a
        ld a,b
        ld (ln_sy),a
        ld a,(ln_dx)              ; err = dx - dy
        ld l,a
        ld h,0
        ld a,(ln_dy)
        ld e,a
        ld d,0
        or a
        sbc hl,de
        ld (ln_err),hl
.lp:    ld a,(ln_x)
        ld d,a
        ld a,(ln_y)
        ld e,a
        call ck_apx
        ld a,(ln_x)
        ld hl,ln_tx
        cp (hl)
        jr nz,.go
        ld a,(ln_y)
        ld hl,ln_ty
        cp (hl)
        ret z
.go:    ld hl,(ln_err)
        add hl,hl
        push hl                 ; e2 = 2 err
        ld a,(ln_dy)
        ld e,a
        ld d,0
        add hl,de               ; e2 > -dy ?
        bit 7,h
        jr nz,.n1
        ld a,h
        or l
        jr z,.n1
        ld hl,(ln_err)
        or a
        sbc hl,de
        ld (ln_err),hl
        ld a,(ln_sx)
        ld hl,ln_x
        add a,(hl)
        ld (hl),a
.n1:    pop hl
        ld a,(ln_dx)              ; e2 < dx ?
        ld e,a
        ld d,0
        or a
        sbc hl,de
        bit 7,h
        jr z,.lp
        ld hl,(ln_err)
        add hl,de
        ld (ln_err),hl
        ld a,(ln_sy)
        ld hl,ln_y
        add a,(hl)
        ld (hl),a
        jr .lp

; ck_apx: the pixel D = x, E = y (0-127) of the dial
ck_apx: ld a,e
        and #F8
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; (y / 8) * 128
        ld a,d
        and #F8
        ld c,a
        ld b,0
        add hl,bc
        ld a,e
        and 7
        ld c,a
        add hl,bc
        ld bc,vizbuf
        add hl,bc
        ld a,d
        and 7
        push hl
        ld hl,bitmask
        call idx_bc
        ld a,(hl)
        pop hl
        or (hl)
        ld (hl),a
        ret
idx_bc: ld c,a                  ; HL += A (DE kept)
        ld b,0
        add hl,bc
        ret

; the dial's colours: a band of a glow colour every 32 lines
ck_acols:
        ld d,2
.r:     ld a,d
        add a,#20
        ld h,a
        ld l,8
        call vwrite
        ld a,d
        sub 2
        rrca
        rrca                    ; band = (row - 2) / 4
        and 3
        ld hl,ck_gents
        call idx_bc
        ld a,(hl)
        add a,a
        add a,a
        add a,a
        add a,a
        or NAVY
        ld b,128
.c:     out (VDP_D),a
        djnz .c
        ei
        inc d
        ld a,d
        cp 18
        jr c,.r
        ret

; the second hand: sprites 2-5 (a red dot each) at 1/4, 1/2, 3/4, 7/8
ck_sprites_init:
        ld hl,#3808             ; pattern 1: a 3 x 3 dot
        call vwrite
        ld hl,ck_dotpat
        ld b,8
        ld c,VDP_D
        otir
        ld hl,#1C20             ; colours of sprites 2-5
        call vwrite
        ld b,64
        ld a,RED
.c:     out (VDP_D),a
        djnz .c
        ei
        ld a,(ms_port)          ; no mouse: sprites 0 and 1 off the screen (not
        or a                    ; the end of the list)
        ret nz
        ld hl,#1E00
        call vwrite
        ld hl,ck_offspr
        ld b,8
        ld c,VDP_D
        otir
        ei
        ret

ck_sprites_off:
        ld a,216
        ld (spr_next),a
        ld hl,#1E08
        call vwrite
        ld a,216
        out (VDP_D),a
        ei
        ret

ck_sec_hand:
        ld hl,ck_handpos
        ld de,ck_sprbuf
        ld b,4
.s:     push bc
        push hl
        push de
        ld a,(hl)               ; the length
        ld c,a
        ld a,(ck_t+T_SEC)
        call ck_pt
        ld a,e                  ; screen: x = 8 + x - 1, y = 16 + y - 1, Y - 1
        add a,16-2
        ld b,a
        ld a,d
        add a,8-1
        pop hl                  ; (the sprite buffer)
        ld (hl),b
        inc hl
        ld (hl),a
        inc hl
        ld (hl),1
        inc hl
        ld (hl),0
        inc hl
        ex de,hl
        pop hl
        inc hl
        pop bc
        djnz .s
        ld a,216
        ld (de),a
        ld a,(ck_sprbuf)
        ld (spr_next),a         ; (the mouse ends its two sprites with it)
        ld hl,#1E08
        call vwrite
        ld hl,ck_sprbuf
        ld b,17
        ld c,VDP_D
        otir
        ei
        ret

;------------------------------------------------------------------------------
; data (copied with the page)
k_face:         db "clock.face",0
k_time:         db "clock.time",0
k_cols:         db "clock.colours",0
k_bars:         db "clock.spectrum",0
txt_ck_digital: db "digital",0
txt_ck_analog:  db "analog",0
txt_ck_internet: db "internet",0
txt_ck_msxv:    db "msx",0
txt_ck_on:      db "on",0
txt_ck_off:     db "off",0
txt_ck_keys:    db "</> face I time L place O sleep A alarm",0
txt_ck_sleep:   db "Sleep ",0
txt_ck_min:     db " min",0
txt_ck_alarm:   db "Alarm ",0
txt_ck_wkd:     db " Mo-Fr",0
txt_ck_ring:    db " !",0
txt_ck_alin:    db "Alarm at (e.g. 7:30, w: Mo-Fr): ",0
txt_ck_alset:   db "Alarm set: it plays what plays now",0
txt_ck_aloff:   db "Alarm off",0
txt_ck_alnone:  db "Play the station for the alarm first",0
txt_ck_albad:   db "The alarm's time: HH:MM",0
txt_ck_slon:    db "Sleep timer on: the music fades out",0
txt_ck_sloff:   db "Sleep timer off",0
ck_sleeps:      db 15,30,45,60,90,0
ck_sleepi:      db 5
ck_imode:       db 0
ck_salshown:    ds 4,#FF
txt_ck_lkeys:   db "Up/Down, Enter: this place   ESC: back",0
txt_ck_choose:  db "Which place?",0
txt_ck_place:   db "Place (Enter alone: by IP): ",0
txt_ck_looking: db "Looking for the place...",0
txt_ck_none:    db "No place of that name found",0
txt_ck_sfail:   db "Place search failed (no internet?)",0
txt_ck_nowifi:  db "Place search: no WiFi (the ESP)",0
txt_ck_byip:    db "Place: where the internet connection is",0
txt_ck_rtcset:  db "MSX clock set to the internet time",0
txt_ck_nonet:   db "No internet time to set the clock from",0
txt_ck_net:     db "internet time",0
txt_ck_msx:     db "MSX clock",0
txt_ck_wait:    db "MSX clock (waiting)",0
txt_ck_old:     db "MSX clock (old engine)",0
txt_ck_needs:   db "Places need engine 0.11 or newer",0
txt_ck_deg:     db " C ",0
txt_ck_sep:     db "  ",0
ck_days:        db "Monday",0,"Tuesday",0,"Wednesday",0,"Thursday",0,"Friday",0,"Saturday",0,"Sunday",0
ck_months:      db "January",0,"February",0,"March",0,"April",0,"May",0,"June",0,"July",0
                db "August",0,"September",0,"October",0,"November",0,"December",0
CK_NAMES        equ vizbuf              ; the places found (8 x 32; no dial meanwhile)
; WMO weather codes: up to this code, this word
ck_wx:          db 0,"Clear",0, 1,"Mainly clear",0, 2,"Partly cloudy",0, 3,"Overcast",0
                db 48,"Fog",0, 57,"Drizzle",0, 67,"Rain",0, 77,"Snow",0, 82,"Showers",0
                db 86,"Snow showers",0, 255,"Thunderstorm",0
ck_gents:       db G1,G2,G3,G4
ck_calmpal:     db #37,7, #27,6, #16,5, #15,4       ; 0RRR0BBB, 00000GGG: cyan to blue
                db #22,7, #11,6, #01,5, #00,4       ; green
                db #70,6, #70,5, #60,3, #50,2       ; amber
                db #72,2, #71,1, #60,0, #40,0       ; red
                db #67,2, #57,1, #46,0, #35,0       ; purple
                db #77,7, #66,6, #55,5, #44,4       ; white
CK_NCOL         equ 7
ck_colnames:    db "music",0,"cyan",0,"green",0,"amber",0,"red",0,"purple",0,"white",0,0
txt_ck_colmsg:  db "Colours: ",0
ck_segof:       db 0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,6,6,6,6,7,7,7,7,8,8
ck_segcol:      db G1*16+NAVY,G1*16+NAVY,G2*16+NAVY,G2*16+NAVY,G3*16+NAVY,G3*16+NAVY,G4*16+NAVY,RED*16+NAVY
ck_barcol:      db NAVY*16+NAVY,G1*16+NAVY,G1*16+NAVY,G2*16+NAVY,G2*16+NAVY,G3*16+NAVY,BLUE*16+NAVY,NAVY*16+NAVY
; 7 segments (bit 0 = a .. bit 6 = g) of 0-9
ck_segs:        db #3F,#06,#5B,#4F,#66,#6D,#7D,#07,#7F,#6F
; a: dx, y, length, 0 = across / 1 = down; for a b c d e f g
ck_seglist:     db 2,0,32,0, 28,2,37,1, 28,41,37,1, 2,72,32,0, 0,41,37,1, 0,2,37,1, 2,36,32,0
ck_taper:       db 3,2,1,0,0,1,2,3
ck_sin:         db 0,6,12,19,24,30,35,40,45,49,52,55,57,59,60,60,60,59,57,55,52,49,45,40,35,30,24,19,12,6
                db 0,-6,-12,-19,-24,-30,-35,-40,-45,-49,-52,-55,-57,-59,-60,-60,-60,-59,-57,-55,-52,-49,-45,-40,-35,-30,-24,-19,-12,-6
ck_hoffs:       db 0,0, 1,0, 0,1, 1,1
ck_handpos:     db 5,4,2,1
ck_dotpat:      db #E0,#E0,#E0,0,0,0,0,0
ck_offspr:      db 200,0,0,0, 200,0,0,0
ck_lbits:       db #00,#80,#C0,#E0,#F0,#F8,#FC,#FE,#FF
sg_pat:         db 0,0,0,0,0,0,#FF,0
; state (fresh each time the page opens)
ck_face:        db 0
ck_src:         db 0
ck_col:         db 0
ck_bars:        db 1
ck_dirty:       db 0
ck_isnet:       db 0
ck_list:        db 0
ck_inp:         db 0
ck_ilen:        db 0
ck_wait:        db 0
ck_n:           db 0
ck_lsel:        db 0
ck_msgon:       db 0
ck_msgt:        dw 0
ck_rtcl:        dw 0
ck_gen:         db 0
ck_ssec:        db #FF
ck_smin:        db #FF
ck_sday:        db #FF
ck_phase:       db 0
ck_t:           db 0,0,0,0,1,1
                dw 2026
ck_abbr:        ds 8,0
ck_place:       db "?",0
                ds 40,0
ck_itext:       ds 20,0
ck_rbuf:        ds 13,0
ck_sprbuf:      ds 17,0
sg_bits:        db 0
sg_dx:          db 0
sg_x:           db 0
sg_y:           db 0
sg_len:         db 0
sg_r:           db 0
pt_ang:         db 0
pt_mode:        db 0
pt_x:           db 0
hd_x:             db 0
hd_y:             db 0
ln_x:             db 0
ln_y:             db 0
ln_tx:             db 0
ln_ty:             db 0
ln_dx:            db 0
ln_dy:            db 0
ln_sx:            db 0
ln_sy:            db 0
ln_err:           dw 0
mod_clock_end:
