;==============================================================================
; PVTEST.COM - PicoVerse Audio Engine test for MSX-DOS / Nextor
;
;   PVTEST                  find the engine, show diagnostics and the root folder
;   PVTEST /MUSIC           list a folder and play its first track
;   PVTEST /MUSIC/SONG.MP3  play a file (or an .M3U play list)
;
; While playing: SPACE pause, N next, P previous, S stop, + / - volume,
; L engine log, ESC or Q quit (the music keeps playing: the cartridge plays it).
;
; The engine is reached with the BIOS slot routines RDSLT/WRSLT, so no page is
; switched. Every wait for the engine has a 3 second limit (JIFFY).
;
; Assemble: sjasmplus --raw=PVTEST.COM pvtest.asm
;==============================================================================

        org #0100

BDOS    equ #0005
RDSLT   equ #000C
WRSLT   equ #0014
EXPTBL  equ #FCC1
JIFFY   equ #FC9E
LINLEN  equ #F3B0

W_ID     equ #4000
W_TOKEN  equ #4010
W_CODE   equ #4011
W_DONE   equ #4012
W_RESULT equ #4013
W_RLEN   equ #4014
W_HB     equ #4016
W_STATUS equ #4020
W_ARGS   equ #4100
W_REPLY  equ #4400

C_PING   equ #01
C_LOG    equ #03
C_DIAG   equ #04
C_DOPEN  equ #10
C_DREAD  equ #11
C_PLAYI  equ #20
C_PLAYP  equ #21
C_PAUSE  equ #22
C_STOP   equ #23
C_NEXT   equ #24
C_PREV   equ #25
C_VOLUME equ #27
C_PLAYU  equ #29

ST_STATE equ 1
ST_FLAGS equ 2
ST_ERROR equ 13
ST_NETST equ 162
ST_BUFP  equ 163
ST_NRATE equ 164
ST_NERR  equ 168
ST_HTTP  equ 169
F_STREAM equ #10
F_BUFFER equ #20
ST_VOL   equ 3
ST_ELAPS equ 4
ST_TOTAL equ 6
ST_PLPOS equ 19
ST_PLCNT equ 21
ST_TITLE equ 32
ST_ARTIST equ 80

start:
        ld de,txt_hello
        call print
        call find
        jp c,notfound
        ld de,txt_found
        call print
        ld a,(slot)
        and 3
        add a,'0'
        call putc
        ld a,(slot)
        bit 7,a
        jr z,.prim
        ld a,'-'
        call putc
        ld a,(slot)
        rrca
        rrca
        and 3
        add a,'0'
        call putc
.prim:  call crlf
        ; continue with the engine's own token sequence
        ld hl,W_DONE
        call rd
        ld (token),a

        ld a,C_PING
        ld bc,0
        call cmd
        jp c,noanswer
        ld hl,reply
        call prints
        call crlf

        ; argument?
        ld hl,#0080
        ld a,(hl)
        or a
        jp z,diag
        ld b,a
        inc hl
.skip:  ld a,(hl)
        cp ' '
        jr nz,.arg
        inc hl
        djnz .skip
        jp diag
.arg:   ; copy the path to argbuf, upper case not needed (FatFS ignores case)
        ld de,argbuf
.copy:  ld a,(hl)
        cp ' '
        jr z,.cend
        cp 13
        jr z,.cend
        or a
        jr z,.cend
        ld (de),a
        inc hl
        inc de
        djnz .copy
.cend:  xor a
        ld (de),a
        ; a stream URL? "http://" or "https://"
        ld hl,argbuf
        ld a,(hl)
        and #df
        cp 'H'
        jr nz,.nourl
        inc hl
        ld a,(hl)
        and #df
        cp 'T'
        jr nz,.nourl
        inc hl
        ld a,(hl)
        and #df
        cp 'T'
        jr nz,.nourl
        inc hl
        ld a,(hl)
        and #df
        cp 'P'
        jp z,playurl
.nourl: call mkabs
        ; a folder or a file? files have a dot in the last path element
        ld hl,argbuf
        ld c,0
.dot:   ld a,(hl)
        or a
        jr z,.dotend
        cp '/'
        jr z,.slash
        cp '\'
        jr z,.slash
        cp '.'
        jr nz,.dnext
        ld c,1
        jr .dnext
.slash: ld c,0
.dnext: inc hl
        jr .dot
.dotend:
        ld a,c
        or a
        jp nz,playfile
        ; folder: list it and play the first track
        ld hl,argbuf
        call argstr
        ld a,C_DOPEN
        call cmd
        jp c,noanswer
        jp nz,failed
        call listing
        ld a,(firsttrack)
        cp #ff
        jr nz,.play
        ld a,(firsttrack+1)
        cp #ff
        jp z,exit
.play:  ld hl,(firsttrack)
        ld (args),hl
        ld bc,2
        ld a,C_PLAYI
        call cmd
        jp c,noanswer
        jp nz,failed
        jp playing

; play a stream: args = URL, 0, station name (none), 0
playurl:
        ld hl,argbuf
        call argstr
        xor a
        ld (de),a
        inc bc
        ld a,C_PLAYU
        call cmd
        jp c,noanswer
        jp nz,failed
        jp playing

playfile:
        ld hl,argbuf
        call argstr
        ld a,C_PLAYP
        call cmd
        jp c,noanswer
        jp nz,failed
        jp playing

diag:   ld a,C_DIAG
        ld bc,0
        call cmd
        jp c,noanswer
        ld hl,reply
        call prints
        ld hl,txt_root
        call argstr
        ld a,C_DOPEN
        call cmd
        jp c,noanswer
        jp nz,failed
        call listing
        ld de,txt_usage
        call print
        jp exit

;------------------------------------------------------------------------------
; listing - print the open folder (reply of DIR_OPEN in 'reply'), remember the
; first playable entry in 'firsttrack' (#FFFF = none)
listing:
        ld hl,#ffff
        ld (firsttrack),hl
        ld hl,(reply)
        ld (count),hl
        ld de,txt_folder
        call print
        ld hl,reply+2
        call prints
        ld de,txt_entries
        call print
        ld hl,(count)
        call printdec
        call crlf
        ld hl,0
        ld (index),hl
.page:  ld hl,(index)
        ld de,(count)
        or a
        sbc hl,de
        ret nc
        ld hl,(index)
        ld (args),hl
        ld a,20
        ld (args+2),a
        ld bc,3
        ld a,C_DREAD
        call cmd
        ret c
        ret nz
        ld hl,(rlen)
        ld a,h
        or l
        ret z
        ld ix,reply
        ex de,hl                ; DE = bytes left
.entry: ld a,d
        or e
        jp z,.page
        ld a,(ix+0)             ; type
        ld (etype),a
        ld b,(ix+5)             ; name length
        cp 1
        jr z,.dir
        cp 5
        jr z,.dir
        cp 4
        jr z,.m3u
        ; a track
        ld hl,(firsttrack)
        ld a,h
        and l
        inc a
        jr nz,.notfirst
        ld hl,(index)
        ld (firsttrack),hl
.notfirst:
        ld a,' '
        call putc
        call putc
        jr .name
.m3u:   ld a,'*'
        call putc
        ld a,' '
        call putc
        jr .name
.dir:   ld a,'['
        call putc
        ld a,' '
        call putc
.name:  push de
        push ix
        pop hl
        ld de,6
        add hl,de
        ld a,b
        or a
        jr z,.nend
.nloop: ld a,(hl)
        call putc
        inc hl
        djnz .nloop
.nend:  ld a,(etype)
        cp 1
        jr z,.close
        cp 5
        jr nz,.nclose
.close: ld a,']'
        call putc
.nclose:
        call crlf
        pop de
        ; advance
        ld a,(ix+5)
        add a,6
        ld c,a
        ld b,0
        add ix,bc
        ex de,hl
        or a
        sbc hl,bc
        ex de,hl
        ld hl,(index)
        inc hl
        ld (index),hl
        jp .entry

;------------------------------------------------------------------------------
; playing - status line until ESC/Q
playing:
        ld de,txt_keys
        call print
        ld a,#ff
        ld (lastsec),a
.loop:  ld b,6                  ; about 0.1 s
.wait:  halt
        djnz .wait
        call status
        jr c,.keys
        ld hl,tick
        inc (hl)
        ld a,(hl)
        cp 10                   ; at least once a second (streams: buffer, rate)
        jr nc,.show
        ld a,(st+ST_ELAPS)
        ld hl,lastsec
        cp (hl)
        jr z,.keys
.show:  xor a
        ld (tick),a
        ld a,(st+ST_ELAPS)
        ld (lastsec),a
        call showstatus
.keys:  ld c,#0b                ; console status
        call BDOS
        or a
        jr z,.loop
        ld c,#08                ; read key, no echo
        call BDOS
        cp 27
        jp z,.quit
        cp ' '
        jr z,.pause
        cp '+'
        jr z,.volup
        cp '-'
        jr z,.voldn
        and #df                 ; upper case
        cp 'Q'
        jp z,.quit
        cp 'N'
        jr z,.next
        cp 'P'
        jr z,.prev
        cp 'S'
        jr z,.stop
        cp 'L'
        jr z,.log
        jp .loop
.pause: ld a,C_PAUSE
        jr .simple
.next:  ld a,C_NEXT
        jr .simple
.prev:  ld a,C_PREV
        jr .simple
.stop:  ld a,C_STOP
.simple:
        ld bc,0
        call cmd
        ld a,#ff
        ld (lastsec),a
        jp .loop
.log:   ld a,C_LOG
        ld bc,0
        call cmd
        call crlf
        ld hl,reply
        call prints
        jp .loop
.volup: ld a,(st+ST_VOL)
        add a,5
        cp 101
        jr c,.vset
        ld a,100
        jr .vset
.voldn: ld a,(st+ST_VOL)
        sub 5
        jr nc,.vset
        xor a
.vset:  ld (args),a
        ld (st+ST_VOL),a
        ld bc,1
        ld a,C_VOLUME
        call cmd
        jp .loop
.quit:  call crlf
        jp exit

showstatus:
        ld a,13
        call putc
        ld a,(st+ST_STATE)
        ld de,txt_stopped
        or a
        jr z,.s1
        ld de,txt_playing
        dec a
        jr z,.s1
        ld de,txt_paused
.s1:    ld a,(st+ST_FLAGS)
        and F_BUFFER
        jr z,.s2
        ld de,txt_buffer
.s2:    call print
        ld a,(st+ST_FLAGS)
        and F_STREAM
        jp nz,.stream
        ld a,(st+ST_STATE)
        or a
        jr nz,.s3
        ld a,(st+ST_ERROR)
        cp 9
        jp z,.neterr
.s3:    ld hl,(st+ST_PLPOS)
        inc hl
        call printdec
        ld a,'/'
        call putc
        ld hl,(st+ST_PLCNT)
        call printdec
        ld a,' '
        call putc
        ld hl,(st+ST_ELAPS)
        call printtime
        ld a,'/'
        call putc
        ld hl,(st+ST_TOTAL)
        call printtime
        ld a,' '
        call putc
        ; title: what fits on the line (LINLEN - 21 columns), then blanks
        ld a,(LINLEN)
        sub 21
        jr c,.tnone
        cp 4
        jr nc,.tok
.tnone: ld a,4
.tok:   ld b,a
        ld hl,st+ST_TITLE
.t:     ld a,(hl)
        or a
        jr z,.tpad
        call putc
        inc hl
        djnz .t
        ret
.tpad:  ld a,' '
        call putc
        djnz .tpad
        ret
; stream: "Play 1:23 B 45% 16.1K title"
.stream:
        ld hl,(st+ST_ELAPS)
        call printtime
        ld de,txt_b
        call print
        ld a,(st+ST_BUFP)
        ld l,a
        ld h,0
        call printdec
        ld de,txt_pct
        call print
        ld hl,(st+ST_NRATE)     ; 0.1 KB/s
        ld de,10
        call div16              ; HL = KB/s, A = tenths
        push af
        call printdec
        ld a,'.'
        call putc
        pop af
        add a,'0'
        call putc
        ld de,txt_k
        call print
        ld a,(LINLEN)
        sub 23
        jr c,.snone
        cp 4
        jr nc,.sok
.snone: ld a,4
.sok:   ld b,a
        ld hl,st+ST_TITLE
        jr .t
; a stream that failed: "Stop net error N HTTP H"
.neterr:
        ld de,txt_nerr
        call print
        ld a,(st+ST_NERR)
        ld l,a
        ld h,0
        call printdec
        ld de,txt_http
        call print
        ld hl,(st+ST_HTTP)
        call printdec
        ld a,(nerrshown)
        or a
        ret nz
        inc a
        ld (nerrshown),a
        ld de,txt_nerrs
        call print
        ret

; div16 - HL / DE -> HL quotient, A remainder (DE < 256)
div16:  push bc
        ld b,16
        xor a
        ld c,a
.d1:    add hl,hl
        rla
        cp e
        jr c,.d2
        sub e
        inc l
.d2:    djnz .d1
        pop bc
        ret

;------------------------------------------------------------------------------
; status - copy the status block to 'st', CF=1 if it was never consistent
status: ld b,5
.try:   push bc
        ld hl,W_STATUS
        call rd
        ld (seq),a
        ld hl,W_STATUS
        ld de,st
        ld bc,224
        call rdblock
        pop bc
        ld a,(seq)
        bit 0,a
        jr nz,.again
        ld hl,st
        cp (hl)
        ret z
.again: djnz .try
        scf
        ret

;------------------------------------------------------------------------------
; argstr - copy the 0-terminated string HL to 'args', BC = length incl. 0
;------------------------------------------------------------------------------
; mkabs - make argbuf an absolute path: "A:" is dropped, and a path without a
; leading \ or / gets the current folder of that drive (Nextor _GETCD) in
; front, so "PVTEST SONG.MP3" works inside A:\MUSIC. The engine then sees
; "\MUSIC\SONG.MP3".
mkabs:  ld hl,argbuf
        ld b,0                  ; drive: 0 = default
        inc hl
        ld a,(hl)
        dec hl
        cp ':'
        jr nz,.nodrv
        ld a,(hl)
        and #df                 ; upper case
        sub 'A'-1
        ld b,a
        inc hl
        inc hl
.nodrv: ld a,(hl)
        cp '\'
        jr z,.abs
        cp '/'
        jr z,.abs
        ; relative: tmpbuf = "\" + current folder (+ "\") + rest
        push hl
        ld de,tmpbuf+1
        ld c,#59                ; _GETCD: B = drive, DE = 64 byte buffer
        call BDOS
        pop hl
        or a
        jr z,.cdok
        xor a
        ld (tmpbuf+1),a         ; no current folder (error): from the root
.cdok:  ld a,'\'
        ld (tmpbuf),a
        ld de,tmpbuf
.cdend: ld a,(de)
        or a
        jr z,.cdz
        inc de
        jr .cdend
.cdz:   dec de                  ; DE = last char ("\" when at the root)
        ld a,(de)
        inc de
        cp '\'
        jr z,.rest
        ld a,'\'
        ld (de),a
        inc de
.rest:  ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,.rest
        ld hl,tmpbuf
.abs:   ; copy HL (inside argbuf or tmpbuf) to argbuf
        ld de,argbuf
.cp:    ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,.cp
        ret

argstr: ld de,args
        ld bc,0
.c:     ld a,(hl)
        ld (de),a
        inc hl
        inc de
        inc bc
        or a
        jr nz,.c
        ret

; cmd - A = command, BC = argument bytes in 'args'
; Output: CF=1 no answer (3 s), else ZF=1 if the result is PVA_OK, A = result,
;         reply copied to 'reply' (0-terminated), length in 'rlen'
cmd:    ld (code),a
        ld a,b
        or c
        jr z,.noargs
        ld hl,args
        ld de,W_ARGS
        call wrblock
.noargs:
        ld a,(token)
        inc a
        ld (token),a
        ld e,a
        ld hl,W_TOKEN
        call wr
        ld a,(code)
        ld e,a
        ld hl,W_CODE
        call wr
        ld hl,(JIFFY)
        ld (t0),hl
.wait:  ld hl,W_DONE
        call rd
        ld hl,token
        cp (hl)
        jr z,.done
        ld hl,(JIFFY)
        ld de,(t0)
        or a
        sbc hl,de
        ld de,180               ; 3 s at 60 Hz
        or a
        sbc hl,de
        jr c,.wait
        scf
        ret
.done:  ld hl,W_RLEN
        call rd
        ld (rlen),a
        ld hl,W_RLEN+1
        call rd
        and 7
        ld (rlen+1),a
        ld hl,W_REPLY
        ld de,reply
        ld bc,(rlen)
        ld a,b
        or c
        call nz,rdblock
        ld hl,(rlen)
        ld de,reply
        add hl,de
        ld (hl),0
        ld hl,W_RESULT
        call rd
        ld (result),a
        or a                    ; CF=0, ZF=1 if OK
        ret

; rd - A = byte at engine address HL
rd:     push bc
        push de
        ld a,(slot)
        call RDSLT
        ei
        pop de
        pop bc
        ret

; wr - write E to engine address HL
wr:     push bc
        push de
        ld a,(slot)
        call WRSLT
        ei
        pop de
        pop bc
        ret

; rdblock - copy BC bytes from engine address HL to DE
rdblock:
.l:     ld a,b
        or c
        ret z
        call rd
        ld (de),a
        inc hl
        inc de
        dec bc
        jr .l

; wrblock - copy BC bytes from HL to engine address DE
wrblock:
.l:     ld a,b
        or c
        ret z
        ld a,(hl)
        push hl
        push de
        push bc
        ex de,hl                ; HL = engine address
        ld e,a
        call wr
        pop bc
        pop de
        pop hl
        inc hl
        inc de
        dec bc
        jr .l

;------------------------------------------------------------------------------
; find - look for "PVAUDIO" at 4000h in every slot and sub-slot. CF=1 not found.
find:   ld b,0                  ; primary 0..3
.p:     ld hl,EXPTBL
        ld e,b
        ld d,0
        add hl,de
        ld a,(hl)
        and #80
        or b
        ld c,a                  ; slot id, expanded flag
        bit 7,a
        jr z,.one
        ld d,0                  ; sub-slot 0..3
.s:     ld a,d
        rlca
        rlca
        or c
        ld (slot),a
        push bc
        push de
        call check
        pop de
        pop bc
        ret nc
        inc d
        ld a,d
        cp 4
        jr c,.s
        jr .nextp
.one:   ld a,c
        ld (slot),a
        push bc
        call check
        pop bc
        ret nc
.nextp: inc b
        ld a,b
        cp 4
        jr c,.p
        scf
        ret

check:  ld hl,W_ID
        ld de,idtext
        ld b,8
.c:     push bc
        push de
        call rd
        pop de
        pop bc
        ex de,hl
        cp (hl)
        ex de,hl
        scf
        ret nz
        inc hl
        inc de
        djnz .c
        or a
        ret

;------------------------------------------------------------------------------
; output helpers
print:  ld c,#09                ; DE = "$"-terminated text
        jp BDOS

putc:   push bc
        push de
        push hl
        ld e,a
        ld c,#02
        call BDOS
        pop hl
        pop de
        pop bc
        ret

crlf:   ld a,13
        call putc
        ld a,10
        jp putc

; prints - HL = 0-terminated text (CR/LF kept)
prints: ld a,(hl)
        or a
        ret z
        call putc
        inc hl
        jr prints

; printdec - HL as decimal
printdec:
        ld b,0
        ld de,10000
        call .digit
        ld de,1000
        call .digit
        ld de,100
        call .digit
        ld de,10
        call .digit
        ld a,l
        add a,'0'
        jp putc
.digit: ld a,'0'-1
.d:     inc a
        or a
        sbc hl,de
        jr nc,.d
        add hl,de
        cp '0'
        jr nz,.out
        bit 0,b
        ret z
.out:   ld b,1
        jp putc

; printtime - HL seconds as m:ss
printtime:
        ld de,0
.m:     ld bc,60
        or a
        sbc hl,bc
        jr c,.mend
        inc de
        jr .m
.mend:  add hl,bc
        push hl
        ex de,hl
        call printdec
        ld a,':'
        call putc
        pop hl
        ld a,l
        cp 10
        jr nc,.two
        ld a,'0'
        call putc
.two:   ld h,0
        jp printdec

notfound:
        ld de,txt_notfound
        call print
        jp exit
noanswer:
        ld de,txt_noanswer
        call print
        ; what core 1 left in the window (engine 0.4 and later)
        ld de,txt_where
        call print
        ld hl,#4018
        call rd
        ld l,a
        ld h,0
        call printdec
        ld de,txt_lastcmd
        call print
        ld hl,#4019
        call rd
        call printhex
        ld de,txt_fault
        call print
        ld hl,#401A
        call rd
        push af
        ld l,a
        ld h,0
        call printdec
        pop af
        or a
        jr z,.nofault
        ld de,txt_pc
        call print
        ld hl,#401F
        ld b,4
.pc:    call rd
        call printhex
        dec hl
        djnz .pc
        call crlf
        ld hl,#4F00
        ld b,64
.txt:   call rd
        or a
        jr z,.nofault
        call putc
        inc hl
        djnz .txt
.nofault:
        call crlf
        jp exit

; printhex - A as two hex digits
printhex:
        push af
        rrca
        rrca
        rrca
        rrca
        call .nib
        pop af
.nib:   and #0F
        add a,'0'
        cp '9'+1
        jr c,.p
        add a,7
.p:     jp putc
failed: ld de,txt_failed
        call print
        ld a,(result)
        ld l,a
        ld h,0
        call printdec
        ld a,(result)
        cp 3
        ld de,txt_nocard
        jr z,.why
        cp 4
        ld de,txt_nf
        jr z,.why
        cp 5
        ld de,txt_fmt
        jr z,.why
        cp 6
        ld de,txt_io
        jr z,.why
        cp 9
        ld de,txt_net
        jr z,.why
        cp 10
        ld de,txt_nowifi
        jr z,.why
        cp 2
        ld de,txt_args
        jr z,.why
        call crlf
        jp exit
.why:   call print
        jp exit

exit:   ld c,0
        jp BDOS

;------------------------------------------------------------------------------
idtext:         db "PVAUDIO",0
txt_hello:      db "PicoVerse Audio Engine test 0.3",13,10,"$"
txt_found:      db "Engine found in slot $"
txt_notfound:   db "No PicoVerse Audio Engine found. Flash LoadROM -p1.",13,10,"$"
txt_noanswer:   db "The engine does not answer (3 s).",13,10,"$"
txt_where:      db "Core 1 was at $"
txt_lastcmd:    db " (1 loop 2 command 3 stream 4 radio 5 decode 6 status 7 card), last command $"
txt_fault:      db "h, fault $"
txt_pc:         db ", PC $"
txt_failed:     db "Engine error $"
txt_nocard:     db ": microSD not mounted",13,10,"$"
txt_nf:         db ": not found",13,10,"$"
txt_fmt:        db ": not a playable file",13,10,"$"
txt_io:         db ": read error",13,10,"$"
txt_net:        db ": network error (L shows the log)",13,10,"$"
txt_nowifi:     db ": no WiFi link (flash LoadROM -p1 -w)",13,10,"$"
txt_args:       db ": bad path or URL",13,10,"$"
txt_buffer:     db "Buf  $"
txt_b:          db " B$"
txt_pct:        db "% $"
txt_k:          db "K $"
txt_nerr:       db "net error $"
txt_http:       db " HTTP $"
txt_nerrs:      db 13,10,"(1 WiFi 2 DNS 3 connect 4 HTTP 5 format 6 timeout 7 closed 8 URL)",13,10,"L log, ESC quit",13,10,"$"
txt_folder:     db "Folder $"
txt_entries:    db ", entries: $"
txt_root:       db "/",0
txt_usage:      db 13,10,"PVTEST <folder> or PVTEST <file.mp3|.wav|.m3u> to play,",13,10,"PVTEST http://... for an MP3 stream.",13,10,"$"
txt_keys:       db "SPACE pause N/P next/prev S stop",13,10,"+/- volume L log ESC quit",13,10,"$"
txt_playing:    db "Play $"
txt_paused:     db "Paus $"
txt_stopped:    db "Stop $"

slot:           db 0
token:          db 0
code:           db 0
result:         db 0
seq:            db 0
etype:          db 0
lastsec:        db 0
tick:           db 0
nerrshown:      db 0
t0:             dw 0
rlen:           dw 0
count:          dw 0
index:          dw 0
firsttrack:     dw 0
argbuf:         ds 128
tmpbuf:         ds 200
args:           ds 260
st:             ds 224
reply:          ds 2049
