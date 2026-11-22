# counter.sed: a counter in pure sed, with the count in Roman numerals.
#
#	gpuifs -t Counter rc -c "echo 'window main title=Counter size=420,240' >/mnt/gpui/ctl; sed -nuf counter.sed /mnt/gpui/events"
#
# The sed is 9front's, running in the h9 machine, so the regular
# expressions are egrep-style: ( ) group, \1 refers back.
#
# sed reads the app's events file as its input, one event per line, keeps
# the count in the hold space, does the arithmetic with substitutions, and
# writes the screen to the root node's ctl with w. -u flushes the w files
# before each read, so every event's output is one write, which the ctl
# file applies as one atomic change. sed opens its w files when it starts,
# so the window must exist first: that is the one rc echo in the launch.
#
# The screen is re-rendered on every change: delete the five nodes, make
# them again in order. sed has only the root ctl, so it can't reach a
# child's text file, and new always appends to the order.

# Line 1 is resync seq=N: set the count to 0, bind keys, style the root.
1{
	s/.*/=	inc\
-	dec\
0	reset\
escape	quit/
	w /mnt/gpui/keymap
	s/(.|\n)*/h_flex flex_wrap size_full p=24 gap_x=16 gap_y=8 items_center justify_center content_center bg=background/
	w /mnt/gpui/windows/main/root/style
	s/.*/0/
	b render
}

# Which event: put the count in the pattern space and jump.
/^click .*tag=inc/b inc
/^action .*id=inc/b inc
/^click .*tag=dec/b dec
/^action .*id=dec/b dec
/^click .*tag=reset/b reset
/^action .*id=reset/b reset
/^action .*id=quit/q
/^close /q
/^quit /q
d

:reset
s/.*/0/
b render

# n+1. A negative count steps its magnitude down instead.
:inc
g
/^-/b incneg
b up
:incneg
s/^-//
b down

# n-1. Zero goes to -1; a negative count steps its magnitude up.
:dec
g
/^0$/{
	s/.*/-1/
	b render
}
/^-/{
	s/^-//
	b upneg
}
b down

# up: add one to the digits. The trailing nines become _ while they carry.
:up
s/9(_*)$/_\1/
t up
s/^(_*)$/1\1/
t upd
s/8(_*)$/9\1/
t upd
s/7(_*)$/8\1/
t upd
s/6(_*)$/7\1/
t upd
s/5(_*)$/6\1/
t upd
s/4(_*)$/5\1/
t upd
s/3(_*)$/4\1/
t upd
s/2(_*)$/3\1/
t upd
s/1(_*)$/2\1/
t upd
s/0(_*)$/1\1/
:upd
y/_/0/
b render

:upneg
s/9(_*)$/_\1/
t upneg
s/^(_*)$/1\1/
t unp
s/8(_*)$/9\1/
t unp
s/7(_*)$/8\1/
t unp
s/6(_*)$/7\1/
t unp
s/5(_*)$/6\1/
t unp
s/4(_*)$/5\1/
t unp
s/3(_*)$/4\1/
t unp
s/2(_*)$/3\1/
t unp
s/1(_*)$/2\1/
t unp
s/0(_*)$/1\1/
:unp
y/_/0/
s/^/-/
b render

# down: take one from the digits (n > 0). Trailing zeros borrow as _.
:down
s/0(_*)$/_\1/
t down
s/1(_*)$/0\1/
t dnd
s/2(_*)$/1\1/
t dnd
s/3(_*)$/2\1/
t dnd
s/4(_*)$/3\1/
t dnd
s/5(_*)$/4\1/
t dnd
s/6(_*)$/5\1/
t dnd
s/7(_*)$/6\1/
t dnd
s/8(_*)$/7\1/
t dnd
s/9(_*)$/8\1/
:dnd
y/_/9/
s/^0(.)/\1/
# If the count was negative (we came from incneg), put the sign back,
# unless we reached 0. The hold space still has the old count.
x
/^-/{
	x
	/^0$/!s/^/-/
	b render
}
x
b render

# render: the count is in the pattern space. Keep it, spell it in Roman
# numerals, then write the screen.
:render
h
s/^-//
/^0$/{
	s/.*/nulla/
	b sign
}
/^...../b big
/^[4-9].../b big
# Pad to four digits, put each digit before its unit letter, then
# spell digit-and-unit pairs. Only a digit's own unit follows it, so the
# rules for one place can't touch another.
s/^/000/
s/^.*(.)(.)(.)(.)$/\1M\2C\3X\4I/
s/0[MCXI]//g
s/1M/M/
s/2M/MM/
s/3M/MMM/
s/1C/C/
s/2C/CC/
s/3C/CCC/
s/4C/CD/
s/5C/D/
s/6C/DC/
s/7C/DCC/
s/8C/DCCC/
s/9C/CM/
s/1X/X/
s/2X/XX/
s/3X/XXX/
s/4X/XL/
s/5X/L/
s/6X/LX/
s/7X/LXX/
s/8X/LXXX/
s/9X/XC/
s/1I/I/
s/2I/II/
s/3I/III/
s/4I/IV/
s/5I/V/
s/6I/VI/
s/7I/VII/
s/8I/VIII/
s/9I/IX/
b sign
:big
s/.*/too big for Rome/
b out
:sign
x
/^-/{
	x
	s/^/−/
	x
}
x
:out
# Pattern: the Roman numeral. Hold: the count. Join them as "roman\ncount".
G
s/^(.*)\n(.*)$/new button dec label=− tag=dec style='lg w=64'\
new text n text=\2 style='text_size=52 font_bold text_center w=176'\
new button inc label=+ tag=inc style='lg primary w=64'\
new text roman text='\1' style='w_full text_center text_2xl text_color=muted_foreground font_family=C059'\
new button reset label=Reset tag=reset style='ghost sm'/
1!s/^/delete dec\
delete n\
delete inc\
delete roman\
delete reset\
/
w /mnt/gpui/windows/main/root/ctl
g
