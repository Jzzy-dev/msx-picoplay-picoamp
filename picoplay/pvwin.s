; PicoPlay - access to the PicoVerse Audio Engine register window (SymbOS, MSX)
;
; The engine sits in page 1 (4000h-4FFFh) of its cartridge (sub-)slot. To reach
; it, page 1 is switched to that slot with interrupts off, using the slot helper
; SymbOS keeps in page 0 (the method of the SymbOS GR8NET, DenYoNet and
; PicoVerse ESP network drivers):
;   0202h  helper: 1 OUT (A8h),(0203h)  page 3 = target slot
;                  2 LD (FFFFh),(0207h) expander register of the target slot
;                  3 OUT (A8h),(020Ch)  final layout, page 1 = target slot
;   0218h  normal primary slot register, 0219h normal sub-slot register
; Everything touched while the window is open (this code, its data, the stack
; and the copy buffers) lives in the transfer segment, which SymbOS places in
; page 3. Copies are split into blocks of 128 bytes so interrupts are never
; off for long.
;
; C interface (SCC: arguments on the stack, BC and IX preserved, result in HL):
;   void pv_setslot(unsigned char prim, unsigned char sub);
;   unsigned char pv_peek(unsigned short addr);
;   void pv_poke(unsigned short addr, unsigned char value);
;   void pv_read(unsigned short addr, char* dst, unsigned short len);   dst in transfer
;   void pv_write(unsigned short addr, char* src, unsigned short len);  src in transfer
;   void pv_post(unsigned char token, unsigned char code);

	.symtrans

sys_slthlp	.equ 0x0202
sys_slt1	.equ 0x0203
sys_slt2	.equ 0x0207
sys_slt3	.equ 0x020c
sys_pri		.equ 0x0218
sys_sub		.equ 0x0219

.export _pv_prim
.export _pv_sub
_pv_prim:	.byte 0
_pv_sub:	.byte 0
pv_open:	.byte 0
pv_sv1:		.byte 0
pv_sv2:		.byte 0
pv_sv3:		.byte 0

; pv_enter - map the engine slot into page 1, interrupts off. Keeps BC,DE,HL.
pv_enter:
	push bc
	push hl
	di
	ld a,(sys_slt1)
	ld (pv_sv1),a
	ld a,(sys_slt2)
	ld (pv_sv2),a
	ld a,(sys_slt3)
	ld (pv_sv3),a
	ld a,(_pv_prim)
	and #3
	ld l,a
	ld a,(_pv_sub)
	and #3
	ld h,a
	; step 3: page 1 = cartridge slot, other pages normal
	ld a,l
	add a,a
	add a,a
	ld c,a
	ld a,(sys_pri)
	and #0xf3
	or c
	ld (sys_slt3),a
	; step 1: page 3 = cartridge slot
	ld a,l
	rrca
	rrca
	ld c,a
	ld a,(sys_pri)
	and #0x0f
	or c
	ld (sys_slt1),a
	; step 2: expander register of the cartridge slot, page 1 = sub-slot
	ld a,h
	add a,a
	add a,a
	ld c,a
	ld a,(sys_sub)
	and #0xf3
	or c
	ld (sys_slt2),a
	call sys_slthlp
	ld a,#1
	ld (pv_open),a
	pop hl
	pop bc
	ret

; pv_leave - normal SymbOS slot layout, interrupts on. Keeps A,BC,DE,HL
; (pv_peek returns the byte it read in A).
pv_leave:
	push af
	ld a,(pv_open)
	or a
	jr z,pv_leave9
	ld a,(sys_pri)
	out (0xa8),a
	ld a,(sys_sub)
	ld (0xffff),a
	ld a,(pv_sv1)
	ld (sys_slt1),a
	ld a,(pv_sv2)
	ld (sys_slt2),a
	ld a,(pv_sv3)
	ld (sys_slt3),a
	xor a
	ld (pv_open),a
pv_leave9:
	pop af
	ei
	ret

.export _pv_setslot
_pv_setslot:
	ld hl,#2
	add hl,sp
	ld a,(hl)
	ld (_pv_prim),a
	inc hl
	inc hl
	ld a,(hl)
	ld (_pv_sub),a
	ret

.export _pv_peek
_pv_peek:
	ld hl,#2
	add hl,sp
	ld e,(hl)
	inc hl
	ld d,(hl)
	call pv_enter
	ld a,(de)
	call pv_leave
	ld l,a
	ld h,#0
	ret

.export _pv_poke
_pv_poke:
	ld hl,#2
	add hl,sp
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld a,(hl)
	call pv_enter
	ld (de),a
	call pv_leave
	ret

; arguments of pv_read/pv_write: addr, buf, len
pv_args:
	ld hl,#4                ; 2 for our own return address, 2 for the caller's
	add hl,sp
	ld e,(hl)
	inc hl
	ld d,(hl)               ; DE = window address
	inc hl
	ld a,(hl)
	ld (pv_buf),a
	inc hl
	ld a,(hl)
	ld (pv_buf+1),a         ; buffer address
	inc hl
	ld a,(hl)
	ld (pv_len),a
	inc hl
	ld a,(hl)
	ld (pv_len+1),a
	ret
pv_buf:	.word 0
pv_len:	.word 0

.export _pv_read
_pv_read:
	push bc
	call pv_args1
	ld hl,(pv_buf)
	ex de,hl                ; HL = window, DE = buffer
pv_read1:
	ld bc,(pv_len)
	ld a,b
	or c
	jr z,pv_read9
	ld a,b
	or a
	jr nz,pv_read2
	ld a,c
	cp #128
	jr c,pv_read3
pv_read2:
	ld bc,#128
pv_read3:
	push bc
	call pv_enter
	ldir
	call pv_leave
	pop bc
	push hl
	ld hl,(pv_len)
	or a
	sbc hl,bc
	ld (pv_len),hl
	pop hl
	jr pv_read1
pv_read9:
	pop bc
	ret

.export _pv_write
_pv_write:
	push bc
	call pv_args1
	ld hl,(pv_buf)          ; HL = buffer, DE = window
pv_write1:
	ld bc,(pv_len)
	ld a,b
	or c
	jr z,pv_write9
	ld a,b
	or a
	jr nz,pv_write2
	ld a,c
	cp #128
	jr c,pv_write3
pv_write2:
	ld bc,#128
pv_write3:
	push bc
	call pv_enter
	ldir
	call pv_leave
	pop bc
	push hl
	ld hl,(pv_len)
	or a
	sbc hl,bc
	ld (pv_len),hl
	pop hl
	jr pv_write1
pv_write9:
	pop bc
	ret

; pv_args with one extra word (the pushed BC) on the stack
pv_args1:
	ld hl,#6
	add hl,sp
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld a,(hl)
	ld (pv_buf),a
	inc hl
	ld a,(hl)
	ld (pv_buf+1),a
	inc hl
	ld a,(hl)
	ld (pv_len),a
	inc hl
	ld a,(hl)
	ld (pv_len+1),a
	ret

.export _pv_post
_pv_post:
	ld hl,#2
	add hl,sp
	ld e,(hl)               ; token
	inc hl
	inc hl
	ld d,(hl)               ; code
	call pv_enter
	ld a,e
	ld (0x4010),a
	ld a,d
	ld (0x4011),a
	call pv_leave
	ret
