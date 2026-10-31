# unapi.tcl - a TCP/IP UNAPI implementation for openMSX tests: FAKEUNAPI.ROM's
# entry (4010h, a RET) runs this before it returns. Answers come from fixture
# files (fixtures/index.txt: "URL file [status [Location]]"), as z80_rss does.
# set ::un_fixdir, ::un_notls (0/1), ::un_rate (bytes per ms) before sourcing.

set un_fix [dict create]
set un_hosts {}
proc un_load {} {
	set f [open "$::un_fixdir/index.txt" r]
	while {[gets $f line] >= 0} {
		if {$line eq "" || [string index $line 0] eq "#"} continue
		set w [regexp -all -inline {\S+} $line]
		set url [lindex $w 0]
		set st 200
		if {[llength $w] > 2} { set st [lindex $w 2] }
		dict set ::un_fix $url [list [lindex $w 1] $st [lindex $w 3]]
		regexp {://([^/:]+)} $url -> h
		if {[lsearch -exact $::un_hosts $h] < 0} { lappend ::un_hosts $h }
	}
	close $f
}
un_load

proc ms {} { return [expr {[machine_info time] * 1000.0}] }
proc rd16 {a} { return [expr {[debug read memory $a] | ([debug read memory [expr {$a + 1}]] << 8)}] }
proc cstr {a} {
	set s ""
	while {[set c [debug read memory $a]] != 0} { append s [format %c $c]; incr a }
	return $s
}
set un_conns [dict create]
set un_dns {}
set un_log {}
if {![info exists ::un_debug]} { set ::un_debug 0 }

proc un_resp {c} {
	set req [dict get $::un_conns $c req]
	regexp {GET (\S+)} $req -> path
	regexp {\nHost: (\S+)\r} $req -> host
	set tls [dict get $::un_conns $c tls]
	set url "[expr {$tls ? {https} : {http}}]://$host$path"
	lappend ::un_log $url
	puts stderr "GET $url"
	set body ""
	set st 404
	set loc ""
	if {[dict exists $::un_fix $url]} {
		lassign [dict get $::un_fix $url] file st loc
		if {$file ne "-"} {
			set f [open "$::un_fixdir/$file" r]
			fconfigure $f -translation binary
			set body [read $f]
			close $f
		}
	}
	set h "HTTP/1.1 $st X\r\nDate: Sat, 31 Oct 2026 07:58:12 GMT\r\n"
	if {$loc ne ""} { append h "Location: $loc\r\n" }
	append h "Content-Length: [string length $body]\r\nConnection: close\r\n\r\n"
	dict set ::un_conns $c resp "$h$body"
	dict set ::un_conns $c pos 0
	dict set ::un_conns $c t0 [expr {[ms] + 80}]
}

proc un_avail {c} {
	if {![dict exists $::un_conns $c resp]} { return 0 }
	set t [expr {[ms] - [dict get $::un_conns $c t0]}]
	if {$t < 0} { return 0 }
	set can [expr {int($t * $::un_rate) - [dict get $::un_conns $c pos]}]
	set left [expr {[string length [dict get $::un_conns $c resp]] - [dict get $::un_conns $c pos]}]
	if {$can < 0} { set can 0 }
	return [expr {$can < $left ? $can : $left}]
}

proc un_state {c} {
	set s [dict get $::un_conns $c state]
	if {$s == 2 && [ms] > [dict get $::un_conns $c topen] + 300} { set s 4; dict set ::un_conns $c state 4 }
	if {$s == 4 && [dict exists $::un_conns $c resp] && [dict get $::un_conns $c pos] >= [string length [dict get $::un_conns $c resp]]} { set s 7 }
	return $s
}

array set un_cnt {}
proc un_call {} {
	set f [reg A]
	if {[info exists ::un_cnt($f)]} { incr ::un_cnt($f) } else { set ::un_cnt($f) 1 }
	if {$::un_debug} { puts stderr "unapi [machine_info time] $f SP=[format %04X [reg SP]] BC=[format %04X [reg BC]] HL=[format %04X [reg HL]]" }
	switch $f {
		0 { reg HL 0x4100; reg BC 0x0102; reg DE 0x0101; reg A 0 }
		1 {
			set b [reg B]
			if {$b == 1} { reg HL 0x000C; reg DE 0x0012; reg B 4; reg A 0 } \
			elseif {$b == 4} { reg HL [expr {$::un_notls ? 0x0003 : 0x0103}]; reg DE 0; reg A 0 } \
			else { reg A 4 }
		}
		6 {
			set n [cstr [reg HL]]
			set k [lsearch -exact $::un_hosts $n]
			set ::un_dns [list [expr {[ms] + 50}] $k]
			reg A 0; reg B 0
		}
		7 {
			if {$::un_dns eq ""} { reg A 0; reg B 0; return }
			lassign $::un_dns t k
			if {[ms] < $t} { reg A 0; reg B 1; reg C 1; return }
			if {$k < 0} { reg A 8; reg B 3; return }
			reg A 0; reg B 2; reg C 0
			reg L 10; reg H 0; reg E 0; reg D [expr {$k + 1}]
		}
		13 {
			set p [reg HL]
			set fl [debug read memory [expr {$p + 10}]]
			if {($fl & 4) && $::un_notls} { reg A 1; return }
			for {set i 1} {$i <= 4 && [dict exists $::un_conns $i]} {incr i} {}
			if {$i > 4} { reg A 9; return }
			dict set ::un_conns $i [dict create state 2 topen [ms] tls [expr {($fl & 4) != 0}] req ""]
			reg A 0; reg B $i
		}
		14 - 15 {
			set b [reg B]
			if {$b == 0} { set ::un_conns [dict create] } else { dict unset ::un_conns $b }
			reg A 0
		}
		16 {
			set c [reg B]
			if {![dict exists $::un_conns $c]} { reg A 11; reg C 0; return }
			set s [un_state $c]
			set av [un_avail $c]
			if {$s == 7 && $av == 0} { dict unset ::un_conns $c; reg A 11; reg C 2; return }
			reg A 0; reg B $s; reg C [dict get $::un_conns $c tls]
			reg HL [expr {$av > 65535 ? 65535 : $av}]
			reg IX 1024
		}
		17 {
			set c [reg B]
			if {![dict exists $::un_conns $c]} { reg A 11; return }
			if {[un_state $c] != 4} { reg A 12; return }
			set d [debug read_block memory [reg DE] [reg HL]]
			set r [dict get $::un_conns $c req]
			append r $d
			dict set ::un_conns $c req $r
			if {![dict exists $::un_conns $c resp] && [string first "\r\n\r\n" [dict get $::un_conns $c req]] >= 0} { un_resp $c }
			reg A 0
		}
		18 {
			set c [reg B]
			if {![dict exists $::un_conns $c]} { reg A 11; return }
			set s [un_state $c]
			set av [un_avail $c]
			if {$s == 7 && $av == 0} { dict unset ::un_conns $c; reg A 11; return }
			set n [reg HL]
			if {$av > $n} { set av $n }
			set pos [dict get $::un_conns $c pos]
			if {$av > 0} {
				debug write_block memory [reg DE] [string range [dict get $::un_conns $c resp] $pos [expr {$pos + $av - 1}]]
				dict set ::un_conns $c pos [expr {$pos + $av}]
			}
			reg A 0; reg BC $av; reg HL 0
		}
		29 { reg A 0 }
		default { reg A 1 }
	}
}

proc un_extbio {} {
	if {[reg DE] != 0x2222} return
	set a [reg A]
	if {$a == 0xFF} return
	if {[string toupper [cstr 0xF847]] ne "TCP/IP"} return
	if {$a == 0} { reg B [expr {([reg B] + 1) & 255}]; return }
	if {$a > 1} { reg A [expr {$a - 1}]; return }
	reg A $::un_slot; reg B 0xFF; reg HL 0x4010
	set sp [reg SP]
	reg PC [peek16 $sp]
	reg SP [expr {$sp + 2}]
}
debug set_bp 0xFFCA {} un_extbio
debug set_bp 0x4010 {[debug read memory 0x4100] == 0x6F && [debug read memory 0x4101] == 0x70} un_call
