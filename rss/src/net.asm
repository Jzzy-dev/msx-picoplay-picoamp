;==============================================================================
; net.asm - the network: a TCP/IP UNAPI implementation (found through EXTBIO;
; in ROM, in a mapper segment through the RAM helper, or in page 3) and a
; small HTTP client on it: one GET at a time, run a step at a time from the
; main loop, the body given to a routine as it comes in. Redirects are
; followed; https uses TLS (TCP/IP UNAPI 1.1) when the implementation has it,
; else the same URL is tried over http.
;==============================================================================

TCPIP_GET_CAPAB equ 1
TCPIP_DNS_Q     equ 6
TCPIP_DNS_S     equ 7
TCPIP_TCP_OPEN  equ 13
TCPIP_TCP_ABORT equ 15
TCPIP_TCP_STATE equ 16
TCPIP_TCP_SEND  equ 17
TCPIP_TCP_RCV   equ 18
TCPIP_WAIT      equ 29

; errors (net_err)
NE_NONET  equ 1                 ; no TCP/IP UNAPI
NE_DNS    equ 2                 ; the name was not found
NE_CONN   equ 3                 ; no connection
NE_TIME   equ 4                 ; no answer in time
NE_HTTP   equ 5                 ; the server said no (h_status)
NE_URL    equ 6
NE_TLS    equ 7                 ; https only, and no TLS here
NE_CLOSED equ 8                 ; closed before the reply

RX_SIZE equ 256
HOST_MAX equ 63
PATH_MAX equ 255

        VAR un_type, 1          ; 0 none, 1 page 3, 2 a ROM, 3 a mapper segment
        VAR un_jp, 3            ; JP to it (or to CALSLT / CALL_MAP)
        VAR un_entry, 2
        VAR un_iy, 2            ; segment (low), slot (high)
        VAR un_helper, 2        ; the RAM helper's jump table
        VAR un_tls, 1           ; TLS for active connections
        VAR un_name, 40
        VAR un_ver, 2
        VAR stage, 130          ; what goes to the implementation (page 2/3)
        VAR rxbuf, RX_SIZE

        VAR h_st, 1
        VAR h_conn, 1
        VAR h_tls, 1
        VAR h_down, 1           ; https tried as http (no TLS)
        VAR h_port, 2
        VAR h_host, HOST_MAX+1
        VAR h_path, PATH_MAX+1
        VAR h_loc, PATH_MAX+1
        VAR h_ip, 4
        VAR h_par, 13           ; TCP_OPEN's parameters
        VAR h_redir, 1
        VAR h_proxy, 1          ; this one through the proxy (https without TLS)
        VAR prx_host, HOST_MAX+1 ; proxy= in RSS.INI (host:port)
        VAR prx_port, 2
        VAR h_status, 2
        VAR h_hdr, 1            ; 0 the header, 1 the body
        VAR h_end, 1            ; the body routine has enough
        VAR h_clen, 3           ; Content-Length (0: not said)
        VAR h_got, 3            ; body bytes in
        VAR h_t0, 2             ; the last sign of life
        VAR h_tq, 2             ; (seconds since the start)
        VAR h_tqf, 1
        VAR h_body, 2           ; body routine: HL = bytes, BC = count -> CF: enough
        VAR h_done, 2           ; done routine: CF = failed (net_err)
        VAR h_line, 162
        VAR h_ll, 1
        VAR h_seen, 1
        VAR net_err, 1
        VAR net_code, 1         ; the implementation's error code with it

HS_IDLE equ 0
HS_DNSQ equ 1
HS_DNSW equ 2
HS_OPEN equ 3
HS_EST  equ 4
HS_SEND equ 5
HS_RECV equ 6

; unapi: A = routine, BC DE HL as it takes them (IX, IY used)
unapi:  ld ix,(un_entry)
        ld iy,(un_iy)
        call un_jp
        ei                      ; (CALSLT leaves the interrupts off)
        ret

; un_rd: A = the implementation's byte at HL
un_rd:  ld a,(un_type)
        cp 2
        jr z,.rom
        cp 3
        jr z,.map
        ld a,(hl)
        ret
.rom:   ld a,(un_iy+1)
        push hl
        call RDSLT
        ei
        pop hl
        ret
.map:   push hl
        push de
        push bc
        ld a,(un_iy+1)
        ld b,a
        ld a,(un_iy)
        ld c,a
        ld a,b
        ld b,c
        ld ix,(un_helper)
        inc ix
        inc ix
        inc ix
        call .jix
        ei
        pop bc
        pop de
        pop hl
        ret
.jix:   jp (ix)

; net_init: find the implementation (CF: none), its name, TLS or not
net_init:
        xor a
        ld (un_type),a
        ld (un_tls),a
        ld (h_st),a
        ld (un_name),a
        ld a,(HOKVLD)
        rrca
        ccf
        ret c
        call .arg
        xor a
        ld b,a
        ld de,#2222
        call EXTBIO
        ld a,b
        or a
        scf
        ret z
        call .arg
        ld a,1
        ld de,#2222
        call EXTBIO
        ld (un_entry),hl
        ld (un_iy+1),a          ; slot
        ld a,b
        ld (un_iy),a            ; segment
        ld a,#C3
        ld (un_jp),a
        ld a,h
        cp #C0
        jr c,.np3
        ld (un_jp+1),hl         ; in page 3: called as it is
        ld a,1
        jr .t
.np3:   ld a,b
        inc a
        jr nz,.map
        ld hl,CALSLT            ; in a ROM: an inter-slot call
        ld (un_jp+1),hl
        ld a,2
        jr .t
.map:   ld a,#FF                ; in a mapper segment: the RAM helper's CALL_MAP
        ld de,#2222
        ld hl,0
        call EXTBIO
        ld a,h
        or l
        scf
        ret z
        ld (un_helper),hl
        ld (un_jp+1),hl
        ld a,3
.t:     ld (un_type),a
        xor a                   ; its name and version
        call unapi
        ld (un_ver),bc
        ld de,un_name
        ld b,38
.n:     push bc
        push de
        call un_rd
        pop de
        pop bc
        or a
        jr z,.ne
        cp ' '
        jr c,.ne
        ld (de),a
        inc de
        inc hl
        djnz .n
.ne:    xor a
        ld (de),a
        ld a,TCPIP_GET_CAPAB    ; TLS (the second set of capabilities, bit 8)
        ld b,4
        call unapi
        or a
        jr nz,.nt
        ld a,h
        and 1
        ld (un_tls),a
.nt:    ld a,TCPIP_TCP_ABORT    ; (connections left open by someone)
        ld b,0
        call unapi
        or a
        ret
.arg:   ld hl,txt_tcpip
        ld de,ARG
        ld bc,7
        ldir
        ret
txt_tcpip: db "TCP/IP",0

net_wait:
        ld a,(un_type)
        or a
        ret z
        ld a,TCPIP_WAIT
        jp unapi

;------------------------------------------------------------------------------
; url_parse: HL = URL ("http(s)://host[:port]/path", "//host/path" or "/path")
; -> h_tls, h_port, h_host, h_path; CF: not a URL
url_parse:
        call skipsp
        push hl
        ld de,txt_http
        call .pre
        jr nc,.http
        pop hl
        push hl
        ld de,txt_https
        call .pre
        jr nc,.https
        pop hl
        ld a,(hl)
        cp '/'
        scf
        ret nz
        inc hl
        ld a,(hl)
        dec hl
        cp '/'
        jr z,.rel2
        ld de,h_path            ; the same host
        ld b,PATH_MAX
        call url_copy
        or a
        ret
.rel2:  inc hl                  ; "//host": the same scheme
        inc hl
        jr .host
.http:  pop af
        xor a
        ld (h_tls),a
        ld de,80
        jr .port
.https: pop af
        ld a,1
        ld (h_tls),a
        ld de,443
.port:  ld (h_port),de
.host:  ld de,h_host
        ld b,HOST_MAX
.h:     ld a,(hl)
        cp '/'
        jr z,.he
        cp ':'
        jr z,.he
        cp '?'
        jr z,.he
        cp ' '+1
        jr c,.he
        ld (de),a
        inc hl
        inc de
        djnz .h
        scf
        ret
.he:    xor a
        ld (de),a
        ld a,b
        cp HOST_MAX
        scf
        ret z                   ; (no host)
        ld a,(hl)
        cp ':'
        jr nz,.pa
        inc hl
        call num
        ld (h_port),de
.pa:    ld de,h_path
        ld a,(hl)
        cp '/'
        jr z,.cp
        ld a,'/'
        ld (de),a
        inc de
        ld a,(hl)
        cp '?'
        jr z,.cp
        xor a                   ; nothing after the host
        ld (de),a
        or a
        ret
.cp:    ld b,PATH_MAX-1
        call url_copy
        or a
        ret
; .pre: HL begins with DE (lower case)? NC: yes, HL after it
.pre:   ld a,(de)
        or a
        ret z
        ld a,(hl)
        call lc
        ex de,hl
        cp (hl)
        ex de,hl
        scf
        ret nz
        inc hl
        inc de
        jr .pre

; url_copy: HL to DE, at most B, to a space or control character (spaces as %20 are kept)
url_copy:
.c:     ld a,(hl)
        cp ' '+1
        jr c,.e
        ld (de),a
        inc hl
        inc de
        djnz .c
.e:     xor a
        ld (de),a
        ret
txt_http:  db "http://",0
txt_https: db "https://",0

;------------------------------------------------------------------------------
; http_get: HL = URL, DE = body routine, BC = done routine. CF: not started (net_err)
http_get:
        push hl
        push de
        push bc
        call http_stop
        pop bc
        pop de
        pop hl
        ld (h_body),de
        ld (h_done),bc
        ld a,NE_NONET
        ld (net_err),a
        ld a,(un_type)
        or a
        scf
        ret z
        call url_parse
        ld a,NE_URL
        ld (net_err),a
        ret c
        xor a
        ld (h_redir),a
        ld (h_down),a
        ld (net_err),a
        ld (net_code),a
        ld (h_tq),a
        ld (h_tq+1),a
        ld (h_tqf),a
        ld hl,0
        ld (h_status),hl
; hreq_start: the next request (also after a redirect)
hreq_start:
        xor a
        ld (h_hdr),a
        ld (h_end),a
        ld (h_ll),a
        ld (h_seen),a
        ld (h_loc),a
        ld (h_conn),a
        ld hl,h_clen
        ld b,6
.z:     ld (hl),a
        inc hl
        djnz .z
        ld (h_proxy),a
        ld a,(h_tls)            ; https without TLS here: the proxy, else http
        or a
        jr z,.d
        ld a,(un_tls)
        or a
        jr nz,.d
        ld a,(prx_host)
        or a
        jr z,.dg
        ld a,1
        ld (h_proxy),a
        jr .d
.dg:    call h_downgrade
.d:     ld a,HS_DNSQ
        ld (h_st),a
        ld hl,(JIFFY)
        ld (h_t0),hl
        or a
        ret

h_downgrade:
        xor a
        ld (h_tls),a
        inc a
        ld (h_down),a
        ld hl,(h_port)
        ld de,443
        or a
        sbc hl,de
        ret nz
        ld hl,80
        ld (h_port),hl
        ret

http_busy:                      ; NZ: a request is running
        ld a,(h_st)
        or a
        ret

; http_stop: no more of it (the done routine is not called)
http_stop:
        xor a
        ld (h_st),a
h_close:
        ld a,(h_conn)
        or a
        ret z
        ld b,a
        xor a
        ld (h_conn),a
        ld a,TCPIP_TCP_ABORT
        jp unapi

; h_fail: A = error
h_fail: ld (net_err),a
        call http_stop
        scf
        jr h_call
h_ok:   call http_stop
        xor a
        ld (net_err),a
h_call: ld hl,(h_done)
        jp (hl)

; the time since h_t0 in interrupts -> HL
h_since:
        ld hl,(JIFFY)
        ld de,(h_t0)
        or a
        sbc hl,de
        ret

h_alive:
        ld hl,(JIFFY)
        ld (h_t0),hl
        ret

; CF when HL (interrupts) is less than A seconds
h_older:
        push hl
        ld l,a
        ld h,0
        ld a,(hz)
        ld e,a
        ld d,0
        call mul16
        ex de,hl
        pop hl
        or a
        sbc hl,de
        ret

;------------------------------------------------------------------------------
; http_poll: a step (in the body: until an interrupt has gone by); NZ: data came
http_poll:
        ld a,(h_st)
        or a
        ret z
        dec a
        jr z,hp_dnsq
        dec a
        jr z,hp_dnsw
        dec a
        jp z,hp_open
        dec a
        jp z,hp_est
        dec a
        jp z,hp_send
        jp hp_recv

hp_dnsq:
        ld a,(h_proxy)
        or a
        ld hl,h_host
        jr z,.q
        ld hl,prx_host
.q:     ld a,TCPIP_DNS_Q
        ld b,0
        call unapi
        or a
        jr nz,.f
        ld a,b
        or a
        jr nz,hp_ip
        ld a,HS_DNSW
        ld (h_st),a
        call h_alive
        xor a
        ret
.f:     ld (net_code),a
        ld a,NE_DNS
        call h_fail
        xor a
        ret

hp_dnsw:
        ld a,TCPIP_DNS_S
        ld b,0
        call unapi
        or a
        jr nz,hp_dnsq.f
        ld a,b
        cp 2
        jr z,hp_ip
        cp 1
        ld a,0
        jr nz,hp_dnsq.f         ; (no query: gone)
        call h_since
        ld a,20
        call h_older
        ld a,NE_DNS
        jr nc,.t
        xor a
        ret
.t:     call h_fail
        xor a
        ret

hp_ip:  ld a,l                  ; L.H.E.D
        ld (h_ip),a
        ld a,h
        ld (h_ip+1),a
        ld a,e
        ld (h_ip+2),a
        ld a,d
        ld (h_ip+3),a
        ld a,HS_OPEN
        ld (h_st),a
        xor a
        ret

hp_open:
        ld hl,h_ip
        ld de,h_par
        ld bc,4
        ldir
        ld hl,(h_port)
        ld a,(h_proxy)
        or a
        jr z,.pp
        ld hl,(prx_port)
.pp:    ld (h_par+4),hl
        ld hl,#FFFF
        ld (h_par+6),hl
        ld hl,0
        ld (h_par+8),hl
        ld a,(h_proxy)
        or a
        jr nz,.f                ; (to the proxy: plain)
        ld a,(h_tls)
        or a
        jr z,.f
        ld a,4                  ; TLS (the certificate is not checked)
.f:     ld (h_par+10),a
        ld hl,h_host            ; (the name, for the server's certificate / SNI)
        ld (h_par+11),hl
        ld a,TCPIP_TCP_OPEN
        ld hl,h_par
        call unapi
        or a
        jr nz,.err
        ld a,b
        ld (h_conn),a
        ld a,HS_EST
        ld (h_st),a
        call h_alive
        xor a
        ret
.err:   ld (net_code),a
        cp 1                    ; ERR_NOT_IMP with TLS: try http
        jr nz,.no
        ld a,(h_tls)
        or a
        jr z,.no
        xor a
        ld (un_tls),a
        call h_downgrade
        xor a
        ret
.no:    ld a,NE_CONN
        call h_fail
        xor a
        ret

hp_est: ld a,(h_conn)
        ld b,a
        ld a,TCPIP_TCP_STATE
        ld hl,0
        call unapi
        or a
        jr nz,.cl
        ld a,b
        cp 4                    ; ESTABLISHED
        jr z,.go
        cp 7                    ; CLOSE-WAIT (it said something and closed)
        jr z,.go
        call h_since
        ld a,25
        call h_older
        ld a,0
        ret c
        ld a,NE_TIME
        call h_fail
        xor a
        ret
.cl:    ld (net_code),a
        ld a,c                  ; (the close reason)
        ld (net_code),a
        xor a
        ld (h_conn),a
        ld a,NE_CONN
        call h_fail
        xor a
        ret
.go:    ld a,HS_SEND
        ld (h_st),a
        xor a
        ret

; the request: GET path HTTP/1.0, the host
hp_send:
        ld hl,txt_get
        call h_send
        jr c,.f
        ld a,(h_proxy)          ; (to the proxy: the whole URL)
        or a
        jr z,.p
        ld hl,txt_https
        call h_send
        jr c,.f
        ld hl,h_host
        call h_send
        jr c,.f
.p:     ld hl,h_path
        call h_send
        jr c,.f
        ld hl,txt_get2
        call h_send
        jr c,.f
        ld hl,h_host
        call h_send
        jr c,.f
        ld hl,txt_get3
        call h_send
        jr c,.f
        ld a,HS_RECV
        ld (h_st),a
        call h_alive
        xor a
        ret
.f:     ld a,NE_CONN
        call h_fail
        xor a
        ret
txt_get:  db "GET ",0
txt_get2: db " HTTP/1.0",13,10,"Host: ",0
txt_get3: db 13,10,"User-Agent: MSX-RSS/1.0 (MSX; TCP/IP UNAPI)",13,10
          db "Accept: */*",13,10,"Connection: close",13,10,13,10,0

; h_send: the text at HL to the connection (through the stage); CF: failed
h_send: ld de,stage
        ld bc,0
.c:     ld a,(hl)
        or a
        jr z,.go
        ld (de),a
        inc hl
        inc de
        inc c
        ld a,c
        cp 128
        jr c,.c
.go:    ld a,c
        or a
        ret z
        push hl
        ld hl,(JIFFY)
        ld (h_t0),hl
.try:   push bc
        ld a,(h_conn)
        ld b,a
        ld de,stage
        ld h,0
        ld l,c
        ld c,1                  ; PUSH
        ld a,TCPIP_TCP_SEND
        call unapi
        pop bc
        or a
        jr z,.ok
        cp 13                   ; ERR_BUFFER: again in a moment
        jr nz,.f
        push bc
        call net_wait
        call h_since
        ld a,10
        call h_older
        pop bc
        jr c,.try
.f:     pop hl
        scf
        ret
.ok:    pop hl
        jr h_send

;------------------------------------------------------------------------------
hp_recv:
        ld hl,(JIFFY)
        ld (hp_j),hl
        ld a,0
        ld (hp_any),a
        ld a,8                  ; (at most 8 pieces a pass)
        ld (hp_n),a
.r:     ld a,(h_conn)
        ld b,a
        ld de,rxbuf
        ld hl,RX_SIZE
        ld a,TCPIP_TCP_RCV
        call unapi
        or a
        jr nz,.done             ; (closed, all read)
        ld a,b
        or c
        jr z,.none
        ld a,1
        ld (hp_any),a
        call h_alive
        ld hl,rxbuf
        call h_data
        ld a,(h_st)             ; (stopped by the body routine's done)
        or a
        ret z
        ld a,(h_end)
        or a
        jr nz,.done
        ld hl,hp_n
        dec (hl)
        jr z,.ret
        ld hl,(JIFFY)           ; more while no interrupt went by
        ld de,(hp_j)
        or a
        sbc hl,de
        jr z,.r
        jr .ret
.none:  ld a,(hp_any)
        or a
        jr nz,.ret
        ld a,(h_conn)
        ld b,a
        ld a,TCPIP_TCP_STATE
        ld hl,0
        call unapi
        or a
        jr nz,.done
        ld a,h
        or l
        jr nz,.ret
        ld a,b
        cp 4
        jr nz,.done
        call h_since
        ld a,30
        call h_older
        jr c,.ret
        ld a,NE_TIME
        call h_fail
        xor a
        ret
.ret:   ld a,(hp_any)
        or a
        ret
.done:  call h_complete
        ld a,1
        or a
        ret
        VAR hp_j, 2
        VAR hp_any, 1
        VAR hp_n, 1

; the reply is complete: a redirect, the body, or trouble
h_complete:
        call h_close
        ld a,(h_hdr)
        or a
        ld a,NE_CLOSED
        jp z,h_fail
        ld hl,(h_status)
        ld de,300
        or a
        sbc hl,de
        jr c,.n3
        ld de,100
        sbc hl,de
        jr nc,.n3
        ld a,(h_loc)
        or a
        jr z,.n3
        ld a,(h_redir)
        cp 5
        jr nc,.n3
        inc a
        ld (h_redir),a
        ld a,(h_down)           ; tried as http, and sent to https: no
        or a
        jr z,.go
        ld hl,h_loc
        ld de,txt_https
        call url_parse.pre
        ld a,NE_TLS
        jp nc,h_fail
.go:    ld hl,h_loc
        call url_parse
        ld a,NE_URL
        jp c,h_fail
        call hreq_start
        xor a
        ret
.n3:    ld hl,(h_status)
        ld de,200
        or a
        sbc hl,de
        ld a,NE_HTTP
        jp nz,h_fail
        jp h_ok

; h_data: BC bytes at HL (the header's lines, then the body)
h_data: ld a,(h_hdr)
        or a
        jr nz,h_bodyb
.c:     ld a,b
        or c
        ret z
        ld a,(hl)
        inc hl
        dec bc
        cp 10
        jr z,.nl
        cp 13
        jr z,.c
        push hl
        ld e,a
        ld a,(h_ll)
        cp 160
        jr nc,.sk
        ld hl,h_line
        call add_hla
        ld (hl),e
        ld hl,h_ll
        inc (hl)
.sk:    pop hl
        jr .c
.nl:    ld a,(h_ll)
        or a
        jr z,.body
        push hl
        push bc
        call h_hline
        pop bc
        pop hl
        xor a
        ld (h_ll),a
        jr .c
.body:  ld a,1
        ld (h_hdr),a
        ; fall through: the rest is the body
h_bodyb:
        ld a,b
        or c
        ret z
        ld a,(h_end)
        or a
        ret nz
        ; at most Content-Length
        push hl
        ld a,(h_clen)
        ld hl,(h_clen+1)
        or h
        or l
        jr z,.k
        ld a,(h_clen)           ; rest = clen - got (24 bits)
        ld hl,h_got
        sub (hl)
        ld e,a
        ld a,(h_clen+1)
        inc hl
        sbc a,(hl)
        ld d,a
        ld a,(h_clen+2)
        inc hl
        sbc a,(hl)
        jr c,.end               ; (more than said)
        jr nz,.k                ; (a lot more to come)
        ld a,d                  ; rest < BC: only the rest
        cp b
        jr c,.cut
        jr nz,.k
        ld a,e
        cp c
        jr nc,.k
.cut:   ld b,d
        ld c,e
        ld a,b
        or c
        jr z,.end
.k:     ld hl,h_got             ; got += BC
        ld a,(hl)
        add a,c
        ld (hl),a
        inc hl
        ld a,(hl)
        adc a,b
        ld (hl),a
        inc hl
        ld a,(hl)
        adc a,0
        ld (hl),a
        pop hl
        push bc
        ld a,(h_status)
        cp 200
        jr nz,.sk
        ld a,(h_status+1)
        or a
        jr nz,.sk
        ld de,.ret
        push de
        ld de,(h_body)
        push de
        ret                     ; (the body routine, back to .ret)
.ret:   pop bc
        jr nc,.lim
        ld a,1
        ld (h_end),a
        ret
.sk:    pop bc
.lim:   ld a,(h_clen)           ; all of Content-Length in: the end
        ld hl,(h_clen+1)
        or h
        or l
        ret z
        ld hl,h_got
        ld de,h_clen
        ld a,(hl)
        ex de,hl
        sub (hl)
        ex de,hl
        inc hl
        inc de
        ld a,(hl)
        ex de,hl
        sbc a,(hl)
        ex de,hl
        inc hl
        inc de
        ld a,(hl)
        ex de,hl
        sbc a,(hl)
        ret c
        ld a,1
        ld (h_end),a
        ret
.end:   pop hl
        ld a,1
        ld (h_end),a
        ret

; a header line in h_line (h_ll long)
h_hline:
        ld a,(h_ll)
        ld e,a
        ld d,0
        ld hl,h_line
        add hl,de
        ld (hl),0
        ld a,(h_seen)
        or a
        jr nz,.hdr
        inc a
        ld (h_seen),a
        ld hl,h_line            ; "HTTP/1.1 200 OK"
.sp:    ld a,(hl)
        or a
        ret z
        inc hl
        cp ' '
        jr nz,.sp
        call num
        ld (h_status),de
        ret
.hdr:   ld hl,h_line            ; the name in lower case, to the ':'
.lc:    ld a,(hl)
        or a
        ret z
        cp ':'
        jr z,.col
        call lc
        ld (hl),a
        inc hl
        jr .lc
.col:   ld (hl),0
        inc hl
        call skipsp
        push hl
        ld hl,h_line
        ld de,txt_location
        call str_eq
        pop hl
        jr nz,.n1
        ld de,h_loc
        ld b,PATH_MAX
        jp url_copy
.n1:    push hl
        ld hl,h_line
        ld de,txt_clen
        call str_eq
        pop hl
        jr nz,.n2
        ld de,0                 ; 24 bits
        ld c,0
.d:     ld a,(hl)
        sub '0'
        cp 10
        jr nc,.de
        inc hl
        push hl
        push af
        ; CDE = CDE * 10 + digit
        ld h,d
        ld l,e
        ld a,c
        add hl,hl
        rla
        add hl,hl
        rla
        add hl,de
        adc a,c
        add hl,hl
        rla
        ld c,a
        pop af
        add a,l
        ld l,a
        jr nc,.nc
        inc h
        jr nz,.nc
        inc c
.nc:    ex de,hl
        pop hl
        jr .d
.de:    ld (h_clen),de
        ld a,c
        ld (h_clen+2),a
        ret
.n2:    push hl
        ld hl,h_line
        ld de,txt_date
        call str_eq
        pop hl
        ret nz
        call parse_date
        ret c
        jp clk_set

; str_eq: Z when the strings at HL and DE are the same
str_eq: ld a,(de)
        cp (hl)
        ret nz
        or a
        ret z
        inc hl
        inc de
        jr str_eq

txt_location: db "location",0
txt_clen:     db "content-length",0
txt_date:     db "date",0
