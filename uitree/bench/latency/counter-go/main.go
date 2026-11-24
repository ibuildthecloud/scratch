// Command counter is counter.rc as a compiled client, for the latency
// bench (../README.md): the same tree, and on each click of inc or dec it
// writes the new number to n.
//
// Two builds of the same code:
//
//	GOOS=plan9 GOARCH=amd64 go build   # in h9: $ui is a mounted directory
//	go build                           # on the host: dials $UI_DIAL over 9P
//
// The host build talks 9P2000 itself (ninep.go), so it needs no mount.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

const screen = `set . title=Counter size=300,180 pos=center : h-flex size-full items-center justify-center gap=20 bg=background
new div dec tag=dec on=click : size=40 flex items-center justify-center rounded-full border-1 border-color=border text-xl cursor-pointer hover:bg=accent active:bg=muted
new text n text=0 : text-3xl font-semibold w=72 text-center
new div inc tag=inc on=click : size=40 flex items-center justify-center rounded-full border-1 border-color=border text-xl cursor-pointer hover:bg=accent active:bg=muted
new text dec/t text=−
new text inc/t text=+
`

func main() {
	fs, err := openUI()
	if err != nil {
		fmt.Fprintln(os.Stderr, "counter:", err)
		os.Exit(1)
	}
	ctl, err := fs.Open("win/main/ctl", true)
	if err != nil {
		fmt.Fprintln(os.Stderr, "counter: ctl:", err)
		os.Exit(1)
	}
	if _, err := ctl.Write([]byte(screen)); err != nil {
		fmt.Fprintln(os.Stderr, "counter: build:", err)
		os.Exit(1)
	}
	ev, err := fs.Open("events", false)
	if err != nil {
		fmt.Fprintln(os.Stderr, "counter: events:", err)
		os.Exit(1)
	}
	n := 0
	sc := bufio.NewScanner(ev)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 {
			continue
		}
		o := n
		switch f[0] + ":" + f[1] {
		case "click:inc", "action:inc":
			n++
		case "click:dec", "action:dec":
			n--
		case "action:reset":
			n = 0
		}
		if n != o {
			if _, err := ctl.Write([]byte(fmt.Sprintf("set n text=%d\n", n))); err != nil {
				fmt.Fprintln(os.Stderr, "counter: set:", err)
			}
		}
	}
}
